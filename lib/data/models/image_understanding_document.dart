import 'article_attachment.dart';

class ImageUnderstandingSourceImage {
  final String attachmentId;
  final int order;
  final String sha256;

  const ImageUnderstandingSourceImage({
    required this.attachmentId,
    required this.order,
    required this.sha256,
  });

  Map<String, dynamic> toJson() => {
    'attachmentId': attachmentId,
    'order': order,
    'sha256': sha256,
  };

  factory ImageUnderstandingSourceImage.fromJson(Map<dynamic, dynamic> json) {
    final attachmentId = json['attachmentId'];
    final order = json['order'];
    final sha256 = json['sha256'];
    if (attachmentId is! String || order is! int || sha256 is! String) {
      throw const FormatException(
        'Image understanding source is missing required fields',
      );
    }
    return ImageUnderstandingSourceImage(
      attachmentId: attachmentId,
      order: order,
      sha256: sha256.toLowerCase(),
    );
  }
}

class ImageUnderstandingUncertainSegment {
  final String content;
  final String reason;

  const ImageUnderstandingUncertainSegment({
    required this.content,
    required this.reason,
  });

  Map<String, dynamic> toJson() => {'content': content, 'reason': reason};

  factory ImageUnderstandingUncertainSegment.fromJson(
    Map<dynamic, dynamic> json,
  ) {
    return ImageUnderstandingUncertainSegment(
      content: json['content'] is String ? json['content'] as String : '',
      reason: json['reason'] is String ? json['reason'] as String : '',
    );
  }
}

class ImageUnderstandingPage {
  final String attachmentId;
  final int order;
  final String transcriptionMarkdown;
  final String visualDescription;
  final List<ImageUnderstandingUncertainSegment> uncertainSegments;

  const ImageUnderstandingPage({
    required this.attachmentId,
    required this.order,
    required this.transcriptionMarkdown,
    required this.visualDescription,
    this.uncertainSegments = const [],
  });

  Map<String, dynamic> toJson() => {
    'attachmentId': attachmentId,
    'order': order,
    'transcriptionMarkdown': transcriptionMarkdown,
    'visualDescription': visualDescription,
    'uncertainSegments': uncertainSegments
        .map((segment) => segment.toJson())
        .toList(),
  };

  factory ImageUnderstandingPage.fromJson(Map<dynamic, dynamic> json) {
    final attachmentId = json['attachmentId'];
    final order = json['order'];
    if (attachmentId is! String || order is! int) {
      throw const FormatException(
        'Image understanding page is missing required fields',
      );
    }
    return ImageUnderstandingPage(
      attachmentId: attachmentId,
      order: order,
      transcriptionMarkdown: json['transcriptionMarkdown'] is String
          ? json['transcriptionMarkdown'] as String
          : '',
      visualDescription: json['visualDescription'] is String
          ? json['visualDescription'] as String
          : '',
      uncertainSegments: _mapList(
        json['uncertainSegments'],
      ).map(ImageUnderstandingUncertainSegment.fromJson).toList(),
    );
  }
}

class ImageUnderstandingUsage {
  final int inputTokens;
  final int outputTokens;

  const ImageUnderstandingUsage({
    required this.inputTokens,
    required this.outputTokens,
  });

  Map<String, dynamic> toJson() => {
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
  };

  factory ImageUnderstandingUsage.fromJson(Map<dynamic, dynamic> json) {
    return ImageUnderstandingUsage(
      inputTokens: json['inputTokens'] is int ? json['inputTokens'] as int : 0,
      outputTokens: json['outputTokens'] is int
          ? json['outputTokens'] as int
          : 0,
    );
  }
}

/// Canonical, validated result of the image-understanding stage.
class ImageUnderstandingDocument {
  final int schemaVersion;
  final String requestId;
  final String provider;
  final String model;
  final String promptVersion;
  final DateTime generatedAt;
  final List<ImageUnderstandingSourceImage> sourceImages;
  final String suggestedTitle;
  final String documentType;
  final List<ImageUnderstandingPage> pages;
  final String combinedMarkdown;
  final List<String> languages;
  final List<String> keywords;
  final ImageUnderstandingUsage? usage;

  const ImageUnderstandingDocument({
    this.schemaVersion = 1,
    required this.requestId,
    required this.provider,
    required this.model,
    required this.promptVersion,
    required this.generatedAt,
    required this.sourceImages,
    required this.suggestedTitle,
    required this.documentType,
    required this.pages,
    required this.combinedMarkdown,
    this.languages = const [],
    this.keywords = const [],
    this.usage,
  });

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'requestId': requestId,
    'provider': provider,
    'model': model,
    'promptVersion': promptVersion,
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'sourceImages': sourceImages.map((image) => image.toJson()).toList(),
    'suggestedTitle': suggestedTitle,
    'documentType': documentType,
    'pages': pages.map((page) => page.toJson()).toList(),
    'combinedMarkdown': combinedMarkdown,
    'languages': languages,
    'keywords': keywords,
    if (usage != null) 'usage': usage!.toJson(),
  };

  factory ImageUnderstandingDocument.fromJson(Map<dynamic, dynamic> json) {
    final requestId = json['requestId'];
    final provider = json['provider'];
    final model = json['model'];
    final promptVersion = json['promptVersion'];
    final generatedAt = json['generatedAt'];
    final combinedMarkdown = json['combinedMarkdown'];
    if (requestId is! String ||
        provider is! String ||
        model is! String ||
        promptVersion is! String ||
        generatedAt is! String ||
        combinedMarkdown is! String) {
      throw const FormatException(
        'Image understanding document is missing required fields',
      );
    }
    final parsedGeneratedAt = DateTime.tryParse(generatedAt);
    if (parsedGeneratedAt == null) {
      throw const FormatException('Image understanding generatedAt is invalid');
    }
    final usageMap = _asMap(json['usage']);
    return ImageUnderstandingDocument(
      schemaVersion: json['schemaVersion'] is int
          ? json['schemaVersion'] as int
          : 1,
      requestId: requestId,
      provider: provider,
      model: model,
      promptVersion: promptVersion,
      generatedAt: parsedGeneratedAt.toUtc(),
      sourceImages: _mapList(
        json['sourceImages'],
      ).map(ImageUnderstandingSourceImage.fromJson).toList(),
      suggestedTitle: json['suggestedTitle'] is String
          ? json['suggestedTitle'] as String
          : '',
      documentType: json['documentType'] is String
          ? json['documentType'] as String
          : '',
      pages: _mapList(
        json['pages'],
      ).map(ImageUnderstandingPage.fromJson).toList(),
      combinedMarkdown: combinedMarkdown,
      languages:
          (json['languages'] as List?)?.whereType<String>().toList() ??
          const [],
      keywords:
          (json['keywords'] as List?)?.whereType<String>().toList() ?? const [],
      usage: usageMap == null
          ? null
          : ImageUnderstandingUsage.fromJson(usageMap),
    );
  }

  /// Returns true only when this result was produced by the current prompt and
  /// exactly the same ordered, fingerprinted image set.
  bool matchesAttachments(
    List<ArticleAttachment> attachments, {
    required String expectedPromptVersion,
  }) {
    if (promptVersion != expectedPromptVersion ||
        attachments.length != sourceImages.length ||
        attachments.any((attachment) => !attachment.hasUploadFingerprint)) {
      return false;
    }
    final orderedAttachments = [...attachments]
      ..sort((a, b) => a.order.compareTo(b.order));
    final orderedSources = [...sourceImages]
      ..sort((a, b) => a.order.compareTo(b.order));
    for (var index = 0; index < orderedAttachments.length; index++) {
      final attachment = orderedAttachments[index];
      final source = orderedSources[index];
      if (attachment.id != source.attachmentId ||
          attachment.order != source.order ||
          attachment.sha256.toLowerCase() != source.sha256.toLowerCase()) {
        return false;
      }
    }
    return true;
  }
}

Map<dynamic, dynamic>? _asMap(dynamic value) => value is Map ? value : null;

List<Map<dynamic, dynamic>> _mapList(dynamic value) {
  return (value as List?)?.whereType<Map>().toList() ?? const [];
}
