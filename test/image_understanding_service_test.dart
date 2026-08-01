import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memora/data/models/article_attachment.dart';
import 'package:memora/data/models/image_understanding_document.dart';
import 'package:memora/data/services/attachment_store.dart';
import 'package:memora/data/services/auth_service.dart';
import 'package:memora/data/services/image_understanding_service.dart';
import 'package:memora/data/services/local_image_importer.dart';

void main() {
  group('LocalImageImporter', () {
    test(
      'copies ordered files and creates fingerprinted pending article',
      () async {
        final temp = await Directory.systemTemp.createTemp('memora-images-');
        final first = File('${temp.path}/first.jpg');
        final second = File('${temp.path}/second.png');
        await first.writeAsBytes([1, 2, 3]);
        await second.writeAsBytes([4, 5, 6, 7]);
        final store = _FakeAttachmentStore();
        final importer = LocalImageImporter(attachments: store);

        try {
          final article = await importer.prepare(
            images: [
              LocalImageCandidate(
                path: first.path,
                fileName: 'first.jpg',
                mimeType: 'image/jpeg',
              ),
              LocalImageCandidate(
                path: second.path,
                fileName: 'second.png',
                mimeType: 'image/png',
              ),
            ],
            title: 'Two images',
            notes: 'note',
            tags: const ['tag'],
            fullText: true,
          );

          expect(article.processingStatus.name, 'pending');
          expect(article.isFullText, isTrue);
          expect(article.attachments, hasLength(2));
          expect(article.attachments.map((item) => item.order), [0, 1]);
          expect(
            article.attachments.every((item) => item.hasUploadFingerprint),
            isTrue,
          );
          expect(article.attachments.first.byteLength, 3);
          expect(store.savedNames, ['00_first.jpg', '01_second.png']);
        } finally {
          await temp.delete(recursive: true);
        }
      },
    );

    test('rejects more than nine images before saving files', () async {
      final store = _FakeAttachmentStore();
      final importer = LocalImageImporter(attachments: store);
      final candidates = List.generate(
        10,
        (index) => LocalImageCandidate(
          path: 'missing-$index.jpg',
          fileName: '$index.jpg',
          mimeType: 'image/jpeg',
        ),
      );

      await expectLater(
        importer.prepare(images: candidates),
        throwsArgumentError,
      );
      expect(store.savedNames, isEmpty);
    });

    test(
      'creates a completed attachment-only article when processing is off',
      () async {
        final temp = await Directory.systemTemp.createTemp('memora-images-');
        final image = File('${temp.path}/offline.jpg');
        await image.writeAsBytes([1, 2, 3]);
        final importer = LocalImageImporter(
          attachments: _FakeAttachmentStore(),
        );

        try {
          final article = await importer.prepare(
            images: [
              LocalImageCandidate(
                path: image.path,
                fileName: 'offline.jpg',
                mimeType: 'image/jpeg',
              ),
            ],
            processImages: false,
          );

          expect(article.processingStatus.name, 'completed');
          expect(article.processingStage, isNull);
          expect(article.imageUnderstanding, isNull);
          expect(article.attachments, hasLength(1));
          expect(article.lastProcessedAt, isNotNull);
        } finally {
          await temp.delete(recursive: true);
        }
      },
    );
  });

  group('ImageUnderstandingService', () {
    test('fetches the key then sends images directly to SenseNova', () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final attachment = await _attachmentFor(bytes);
      final captured = <http.Request>[];
      final client = MockClient((request) async {
        captured.add(request);
        if (request.url.path == '/ai/sensenova-credential') {
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'provider': 'sensenova',
              'apiKey': 'sk-direct-test',
            }),
            200,
          );
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode(_providerResponse(attachment))),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final service = ImageUnderstandingService(
        client: client,
        getSession: () => _session('access-1'),
        refreshSession: () async => null,
      );

      final result = await service.understand(
        articleId: 'article-1',
        images: [
          ImageUnderstandingUpload(attachment: attachment, bytes: bytes),
        ],
        locale: 'zh-CN',
      );

      expect(result.requestId, 'provider-request-1');
      expect(result.combinedMarkdown, contains('完整内容'));
      expect(result.usage?.inputTokens, 12);
      expect(captured, hasLength(2));
      expect(captured.first.method, 'GET');
      expect(captured.first.url.path, '/ai/sensenova-credential');
      expect(captured.first.headers['authorization'], 'Bearer access-1');
      expect(captured.last.method, 'POST');
      expect(captured.last.url.host, 'token.sensenova.cn');
      expect(captured.last.url.path, '/v1/messages');
      expect(captured.last.headers['authorization'], 'Bearer sk-direct-test');
      expect(captured.last.body, contains('image-understanding-v1'));
      expect(captured.last.body, contains('attachment-1'));
      expect(captured.last.body, contains(base64Encode(bytes)));
      service.dispose();
    });

    test('refreshes the Memora session once before fetching the key', () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final attachment = await _attachmentFor(bytes);
      var calls = 0;
      final authorizations = <String?>[];
      final client = MockClient((request) async {
        calls++;
        authorizations.add(request.headers['authorization']);
        if (calls == 1) return http.Response('{}', 401);
        if (calls == 2) {
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'provider': 'sensenova',
              'apiKey': 'sk-after-refresh',
            }),
            200,
          );
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode(_providerResponse(attachment))),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final service = ImageUnderstandingService(
        client: client,
        getSession: () => _session('expired'),
        refreshSession: () async => _session('fresh'),
      );

      await service.understand(
        articleId: 'article-1',
        images: [
          ImageUnderstandingUpload(attachment: attachment, bytes: bytes),
        ],
        locale: 'zh-CN',
      );

      expect(calls, 3);
      expect(authorizations, [
        'Bearer expired',
        'Bearer fresh',
        'Bearer sk-after-refresh',
      ]);
      service.dispose();
    });

    test('rejects changed bytes before making a network request', () async {
      final original = Uint8List.fromList([1, 2, 3, 4]);
      final attachment = await _attachmentFor(original);
      var calls = 0;
      final service = ImageUnderstandingService(
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 500);
        }),
        getSession: () => _session('access'),
        refreshSession: () async => null,
      );

      await expectLater(
        service.understand(
          articleId: 'article-1',
          images: [
            ImageUnderstandingUpload(
              attachment: attachment,
              bytes: Uint8List.fromList([4, 3, 2, 1]),
            ),
          ],
          locale: 'zh-CN',
        ),
        throwsA(
          isA<ImageUnderstandingException>().having(
            (error) => error.code,
            'code',
            'attachment_changed',
          ),
        ),
      );
      expect(calls, 0);
      service.dispose();
    });
  });
}

Future<ArticleAttachment> _attachmentFor(Uint8List bytes) async {
  final digest = await Sha256().hash(bytes);
  return ArticleAttachment(
    id: 'attachment-1',
    order: 0,
    localPath: 'attachments/article-1/image.jpg',
    mimeType: 'image/jpeg',
    originalFileName: 'image.jpg',
    byteLength: bytes.length,
    sha256: digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(),
  );
}

Map<String, dynamic> _resultJson(ArticleAttachment attachment) {
  return ImageUnderstandingDocument(
    requestId: 'request-1',
    provider: 'sensenova',
    model: 'sensenova-6.7-flash-lite',
    promptVersion: imageUnderstandingPromptVersion,
    generatedAt: DateTime.utc(2026, 8, 1),
    sourceImages: [
      ImageUnderstandingSourceImage(
        attachmentId: attachment.id,
        order: attachment.order,
        sha256: attachment.sha256,
      ),
    ],
    suggestedTitle: 'Title',
    documentType: 'screenshot',
    pages: [
      ImageUnderstandingPage(
        attachmentId: attachment.id,
        order: attachment.order,
        transcriptionMarkdown: '完整内容',
        visualDescription: '截图',
      ),
    ],
    combinedMarkdown: '# 图片转写\n\n完整内容',
  ).toJson();
}

Map<String, dynamic> _providerResponse(ArticleAttachment attachment) {
  final modelResult = _resultJson(attachment)
    ..remove('requestId')
    ..remove('provider')
    ..remove('model')
    ..remove('promptVersion')
    ..remove('generatedAt')
    ..remove('sourceImages')
    ..remove('usage');
  return {
    'id': 'provider-request-1',
    'model': 'sensenova-6.7-flash-lite',
    'stop_reason': 'end_turn',
    'content': [
      {'type': 'text', 'text': jsonEncode(modelResult)},
    ],
    'usage': {'input_tokens': 12, 'output_tokens': 34},
  };
}

AuthSession _session(String accessToken) {
  return AuthSession(
    accessToken: accessToken,
    refreshToken: 'refresh',
    refreshTokenExpiresAt: null,
    user: const AuthUser(
      id: 'user-1',
      email: 'user@example.com',
      displayName: null,
      status: 'active',
      plan: 'free',
      storageUsedBytes: '0',
    ),
    device: const AuthDevice(
      id: 'device-1',
      userId: 'user-1',
      deviceName: 'test',
      platform: 'test',
      appVersion: '1.0.0',
    ),
  );
}

class _FakeAttachmentStore extends AttachmentStore {
  final List<String> savedNames = [];

  @override
  Future<String> saveForArticle({
    required String articleId,
    required String sourcePath,
    String? preferredName,
  }) async {
    savedNames.add(preferredName!);
    return 'attachments/$articleId/$preferredName';
  }

  @override
  Future<void> deleteForArticle(String articleId) async {}
}
