import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:memora/data/models/article_attachment.dart';
import 'package:memora/data/models/image_understanding_document.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';

const _shaA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _shaB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

ArticleAttachment _attachment({
  String id = 'image-1',
  int order = 0,
  String sha256 = _shaA,
}) {
  return ArticleAttachment(
    id: id,
    order: order,
    localPath: 'attachments/article-1/$id.jpg',
    mimeType: 'image/jpeg',
    originalFileName: '$id.jpg',
    byteLength: 1024 + order,
    sha256: sha256,
    width: 1080,
    height: 1440,
  );
}

ImageUnderstandingDocument _understanding({
  List<ArticleAttachment>? attachments,
  String promptVersion = 'image-understanding-v1',
}) {
  final images = attachments ?? [_attachment()];
  return ImageUnderstandingDocument(
    requestId: 'request-1',
    provider: 'sensenova',
    model: 'sensenova-6.7-flash-lite',
    promptVersion: promptVersion,
    generatedAt: DateTime.utc(2026, 8, 1, 9, 30),
    sourceImages: images
        .map(
          (attachment) => ImageUnderstandingSourceImage(
            attachmentId: attachment.id,
            order: attachment.order,
            sha256: attachment.sha256,
          ),
        )
        .toList(),
    suggestedTitle: '图片中的标题',
    documentType: 'screenshot',
    pages: images
        .map(
          (attachment) => ImageUnderstandingPage(
            attachmentId: attachment.id,
            order: attachment.order,
            transcriptionMarkdown: '# 第 ${attachment.order + 1} 页',
            visualDescription: '一张包含文字的截图。',
            uncertainSegments: const [
              ImageUnderstandingUncertainSegment(
                content: '[无法辨认]',
                reason: '文字模糊',
              ),
            ],
          ),
        )
        .toList(),
    combinedMarkdown: '# 图片转写全文\n\n完整内容',
    languages: const ['zh-CN'],
    keywords: const ['测试'],
    usage: const ImageUnderstandingUsage(inputTokens: 120, outputTokens: 80),
  );
}

void main() {
  group('Image understanding models', () {
    test('attachment JSON round-trip preserves upload fingerprint', () {
      final original = _attachment();
      final restored = ArticleAttachment.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.localPath, original.localPath);
      expect(restored.sha256, _shaA);
      expect(restored.hasUploadFingerprint, isTrue);
      expect(restored.width, 1080);
      expect(restored.height, 1440);
    });

    test(
      'understanding JSON round-trip preserves pages and generation data',
      () {
        final original = _understanding();
        final restored = ImageUnderstandingDocument.fromJson(original.toJson());

        expect(restored.requestId, 'request-1');
        expect(restored.provider, 'sensenova');
        expect(restored.pages.single.attachmentId, 'image-1');
        expect(restored.pages.single.uncertainSegments.single.reason, '文字模糊');
        expect(restored.combinedMarkdown, contains('完整内容'));
        expect(restored.usage?.inputTokens, 120);
        expect(restored.generatedAt, DateTime.utc(2026, 8, 1, 9, 30));
      },
    );

    test(
      'cached result only matches the same ordered fingerprinted images',
      () {
        final attachments = [
          _attachment(id: 'image-1', order: 0),
          _attachment(id: 'image-2', order: 1, sha256: _shaB),
        ];
        final result = _understanding(attachments: attachments);

        expect(
          result.matchesAttachments(
            attachments.reversed.toList(),
            expectedPromptVersion: 'image-understanding-v1',
          ),
          isTrue,
        );
        expect(
          result.matchesAttachments(
            attachments,
            expectedPromptVersion: 'image-understanding-v2',
          ),
          isFalse,
        );
        expect(
          result.matchesAttachments([
            attachments.first,
            _attachment(id: 'image-2', order: 1),
          ], expectedPromptVersion: 'image-understanding-v1'),
          isFalse,
        );
      },
    );
  });

  group('Article image storage', () {
    test('schema v2 JSON round-trip keeps ordered attachments and result', () {
      final attachments = [
        _attachment(id: 'image-2', order: 1, sha256: _shaB),
        _attachment(id: 'image-1', order: 0),
      ];
      final article = Article(
        id: 'article-1',
        url: '',
        title: '多图记忆',
        source: SourcePlatform.local,
        attachments: attachments,
        imageUnderstanding: _understanding(attachments: attachments),
        processingStatus: ProcessingStatus.processing,
        processingStage: ProcessingStage.imageUnderstanding,
      );

      final json = article.toJson();
      expect(json['schemaVersion'], 2);
      final source = json['source'] as Map;
      expect(source['attachments'], isA<List>());
      expect((source['attachments'] as List).length, 2);
      expect(json['imageUnderstanding'], isA<Map>());

      final restored = Article.fromJson(json);
      expect(restored.attachments.map((item) => item.id), [
        'image-1',
        'image-2',
      ]);
      expect(restored.imageUnderstanding?.requestId, 'request-1');
      expect(restored.processingStage, ProcessingStage.imageUnderstanding);
      expect(restored.isLocalAttachment, isTrue);
      expect(restored.isLocalImage, isTrue);
    });

    test('legacy single image is projected without mutating stored fields', () {
      final article = Article(
        id: 'legacy-image',
        url: '',
        title: '旧图片',
        source: SourcePlatform.local,
        localFilePath: r'attachments\legacy-image\old.png',
        localMimeType: 'image/png',
      );

      expect(article.attachments, isEmpty);
      expect(article.imageAttachments, hasLength(1));
      expect(article.imageAttachments.single.id, 'legacy-legacy-image');
      expect(article.imageAttachments.single.originalFileName, 'old.png');
      expect(article.imageAttachments.single.hasUploadFingerprint, isFalse);
      expect(article.isLocalImage, isTrue);
    });

    test('copyWith can replace attachments and clear understanding', () {
      final article = Article(
        id: 'article-1',
        url: '',
        title: '多图记忆',
        source: SourcePlatform.local,
        attachments: [_attachment()],
        imageUnderstanding: _understanding(),
      );

      final changed = article.copyWith(
        attachments: const [],
        imageUnderstanding: Article.clearValue,
      );
      expect(changed.attachments, isEmpty);
      expect(changed.imageUnderstanding, isNull);
    });

    test('malformed optional image data does not make article unreadable', () {
      final restored = Article.fromJson({
        'schemaVersion': 2,
        'id': 'article-1',
        'title': '可恢复',
        'source': {
          'platform': 'local',
          'uri': '',
          'attachments': [
            {'id': 'missing-required-fields'},
          ],
        },
        'imageUnderstanding': {'requestId': 'incomplete'},
      });

      expect(restored.attachments, isEmpty);
      expect(restored.imageUnderstanding, isNull);
    });
  });

  test(
    'ProcessingStage stable storage values preserve all legacy integers',
    () {
      const expected = <ProcessingStage, int>{
        ProcessingStage.metadata: 0,
        ProcessingStage.content: 1,
        ProcessingStage.summary: 2,
        ProcessingStage.tags: 3,
        ProcessingStage.folderSuggestion: 4,
        ProcessingStage.indexing: 5,
        ProcessingStage.imageUnderstanding: 6,
      };

      for (final entry in expected.entries) {
        expect(processingStageToStoredValue(entry.key), entry.value);
        expect(processingStageFromStoredValue(entry.value), entry.key);
      }
      expect(processingStageFromStoredValue(99), isNull);
    },
  );

  test('new ArticleAdapter reads a legacy 23-field Hive record', () async {
    final temp = await Directory.systemTemp.createTemp('memora-image-hive-');
    Hive.init(temp.path);
    Hive.registerAdapter(_LegacyArticleAdapter(), override: true);
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(SourcePlatformAdapter());
    }

    try {
      var box = await Hive.openBox<Article>('legacy-image-storage-test');
      await box.put(
        'legacy',
        Article(
          id: 'legacy',
          url: 'https://example.com',
          title: 'Legacy Hive',
          source: SourcePlatform.web,
          processingStatus: ProcessingStatus.processing,
          processingStage: ProcessingStage.indexing,
        ),
      );
      await Hive.close();

      Hive.init(temp.path);
      Hive.registerAdapter(ArticleAdapter(), override: true);
      box = await Hive.openBox<Article>('legacy-image-storage-test');

      final restored = box.get('legacy');
      expect(restored, isNotNull);
      expect(restored?.processingStage, ProcessingStage.indexing);
      expect(restored?.attachments, isEmpty);
      expect(restored?.imageUnderstanding, isNull);
    } finally {
      await Hive.close();
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  });
}

/// Writes the exact Article Hive layout that existed before image support.
class _LegacyArticleAdapter extends TypeAdapter<Article> {
  @override
  final int typeId = Article.typeId;

  @override
  Article read(BinaryReader reader) {
    throw UnsupportedError('Legacy adapter is write-only in this test');
  }

  @override
  void write(BinaryWriter writer, Article obj) {
    writer
      ..writeByte(23)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.url)
      ..writeByte(2)
      ..write(obj.title)
      ..writeByte(3)
      ..write(SourcePlatformAdapter.toStoredValue(obj.source))
      ..writeByte(4)
      ..write(obj.tags)
      ..writeByte(5)
      ..write(obj.notes)
      ..writeByte(6)
      ..write(obj.createdAt)
      ..writeByte(7)
      ..write(obj.updatedAt)
      ..writeByte(8)
      ..write(obj.isFavorite)
      ..writeByte(9)
      ..write(obj.coverImageUrl)
      ..writeByte(10)
      ..write(obj.summary)
      ..writeByte(11)
      ..write(obj.folderId)
      ..writeByte(12)
      ..write(obj.summaryFeedback)
      ..writeByte(13)
      ..write(obj.processingStatus.index)
      ..writeByte(14)
      ..write(obj.processingStage?.index)
      ..writeByte(15)
      ..write(obj.processingError)
      ..writeByte(16)
      ..write(obj.retryCount)
      ..writeByte(17)
      ..write(obj.lastProcessedAt)
      ..writeByte(18)
      ..write(obj.suggestedFolderId)
      ..writeByte(19)
      ..write(obj.isFullText)
      ..writeByte(20)
      ..write(obj.localFilePath)
      ..writeByte(21)
      ..write(obj.localMimeType)
      ..writeByte(22)
      ..write(obj.memory?.toJson());
  }
}
