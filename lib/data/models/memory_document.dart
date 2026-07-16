enum MemoryKind {
  aiMemory('ai_memory'),
  fullText('full_text'),
  legacyMarkdown('legacy_markdown');

  final String storedValue;
  const MemoryKind(this.storedValue);

  static MemoryKind fromStoredValue(dynamic value) {
    return MemoryKind.values.firstWhere(
      (kind) => kind.storedValue == value,
      orElse: () => MemoryKind.aiMemory,
    );
  }
}

class MemoryKeyPoint {
  final String id;
  final int order;
  final String topic;
  final String content;
  final List<String> sourceRefs;

  const MemoryKeyPoint({
    required this.id,
    required this.order,
    required this.topic,
    required this.content,
    this.sourceRefs = const [],
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'order': order,
      'topic': topic,
      'content': content,
      'sourceRefs': sourceRefs,
    };
  }

  factory MemoryKeyPoint.fromJson(Map<dynamic, dynamic> json) {
    return MemoryKeyPoint(
      id: json['id'] is String ? json['id'] as String : '',
      order: json['order'] is int ? json['order'] as int : 0,
      topic: json['topic'] is String ? json['topic'] as String : '',
      content: json['content'] is String ? json['content'] as String : '',
      sourceRefs:
          (json['sourceRefs'] as List?)?.whereType<String>().toList() ??
          const [],
    );
  }
}

class MemoryGeneration {
  final String method;
  final String? provider;
  final String? model;
  final String? promptVersion;
  final DateTime generatedAt;

  const MemoryGeneration({
    required this.method,
    this.provider,
    this.model,
    this.promptVersion,
    required this.generatedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'method': method,
      'provider': provider,
      'model': model,
      'promptVersion': promptVersion,
      'generatedAt': generatedAt.toUtc().toIso8601String(),
    };
  }

  factory MemoryGeneration.fromJson(Map<dynamic, dynamic> json) {
    return MemoryGeneration(
      method: json['method'] is String ? json['method'] as String : 'unknown',
      provider: json['provider'] is String ? json['provider'] as String : null,
      model: json['model'] is String ? json['model'] as String : null,
      promptVersion: json['promptVersion'] is String
          ? json['promptVersion'] as String
          : null,
      generatedAt: json['generatedAt'] is String
          ? DateTime.tryParse(json['generatedAt'] as String)?.toUtc() ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

class MemoryDocument {
  final MemoryKind kind;
  final int revision;
  final String overview;
  final List<MemoryKeyPoint> keyPoints;
  final String conclusion;
  final String? body;
  final String? format;
  final MemoryGeneration? generation;

  const MemoryDocument._({
    required this.kind,
    required this.revision,
    required this.overview,
    required this.keyPoints,
    required this.conclusion,
    this.body,
    this.format,
    this.generation,
  });

  factory MemoryDocument.ai({
    int revision = 1,
    required String overview,
    required List<MemoryKeyPoint> keyPoints,
    required String conclusion,
    MemoryGeneration? generation,
  }) {
    return MemoryDocument._(
      kind: MemoryKind.aiMemory,
      revision: revision,
      overview: overview,
      keyPoints: List.unmodifiable(keyPoints),
      conclusion: conclusion,
      generation: generation,
    );
  }

  factory MemoryDocument.fullText({
    int revision = 1,
    required String body,
    String format = 'plain',
    MemoryGeneration? generation,
  }) {
    return MemoryDocument._(
      kind: MemoryKind.fullText,
      revision: revision,
      overview: '',
      keyPoints: const [],
      conclusion: '',
      body: body,
      format: format,
      generation: generation,
    );
  }

  factory MemoryDocument.legacyMarkdown({
    int revision = 1,
    required String body,
  }) {
    return MemoryDocument._(
      kind: MemoryKind.legacyMarkdown,
      revision: revision,
      overview: '',
      keyPoints: const [],
      conclusion: '',
      body: body,
      format: 'markdown',
    );
  }

  MemoryDocument withGeneration(MemoryGeneration? value) {
    return MemoryDocument._(
      kind: kind,
      revision: revision,
      overview: overview,
      keyPoints: keyPoints,
      conclusion: conclusion,
      body: body,
      format: format,
      generation: value,
    );
  }

  Map<String, dynamic> toContentJson() {
    final json = toJson();
    json.remove('generation');
    return json;
  }

  Map<String, dynamic> toJson() {
    if (kind == MemoryKind.fullText || kind == MemoryKind.legacyMarkdown) {
      return {
        'kind': kind.storedValue,
        'revision': revision,
        'format': format ?? 'plain',
        'body': body ?? '',
        if (generation != null) 'generation': generation!.toJson(),
      };
    }

    return {
      'kind': kind.storedValue,
      'revision': revision,
      'overview': overview,
      'keyPoints': keyPoints.map((point) => point.toJson()).toList(),
      'conclusion': conclusion,
      if (generation != null) 'generation': generation!.toJson(),
    };
  }

  factory MemoryDocument.fromJson(Map<dynamic, dynamic> json) {
    final kind = MemoryKind.fromStoredValue(json['kind']);
    final generationMap = _asMap(json['generation']);
    if (kind == MemoryKind.fullText || kind == MemoryKind.legacyMarkdown) {
      return MemoryDocument._(
        kind: kind,
        revision: json['revision'] is int ? json['revision'] as int : 1,
        overview: '',
        keyPoints: const [],
        conclusion: '',
        body: json['body'] is String ? json['body'] as String : '',
        format: json['format'] is String ? json['format'] as String : 'plain',
        generation: generationMap == null
            ? null
            : MemoryGeneration.fromJson(generationMap),
      );
    }

    final rawPoints = json['keyPoints'] as List? ?? const [];
    return MemoryDocument.ai(
      revision: json['revision'] is int ? json['revision'] as int : 1,
      overview: json['overview'] is String ? json['overview'] as String : '',
      keyPoints: rawPoints
          .map(_asMap)
          .whereType<Map<dynamic, dynamic>>()
          .map(MemoryKeyPoint.fromJson)
          .toList(),
      conclusion: json['conclusion'] is String
          ? json['conclusion'] as String
          : '',
      generation: generationMap == null
          ? null
          : MemoryGeneration.fromJson(generationMap),
    );
  }

  String toMarkdown() {
    if (kind == MemoryKind.fullText || kind == MemoryKind.legacyMarkdown) {
      return body ?? '';
    }

    final parts = <String>[];
    if (overview.trim().isNotEmpty) {
      parts.add('**摘要**\n\n${overview.trim()}');
    }
    if (keyPoints.isNotEmpty) {
      final sorted = [...keyPoints]..sort((a, b) => a.order.compareTo(b.order));
      final rendered = <String>[];
      for (var i = 0; i < sorted.length; i++) {
        final point = sorted[i];
        final topic = point.topic.trim();
        final prefix = topic.isEmpty ? '' : '**$topic**：';
        rendered.add('${i + 1}. $prefix${point.content.trim()}');
      }
      parts.add('**要点**\n\n${rendered.join('\n')}');
    }
    if (conclusion.trim().isNotEmpty) {
      parts.add('**总结**\n\n${conclusion.trim()}');
    }
    return parts.join('\n\n');
  }

  String toRetrievalText() {
    if (kind == MemoryKind.fullText || kind == MemoryKind.legacyMarkdown) {
      return body ?? '';
    }

    return [
      overview,
      for (final point in [
        ...keyPoints,
      ]..sort((a, b) => a.order.compareTo(b.order))) ...[
        point.topic,
        point.content,
      ],
      conclusion,
    ].map((text) => text.trim()).where((text) => text.isNotEmpty).join('\n');
  }
}

Map<dynamic, dynamic>? _asMap(dynamic value) {
  return value is Map ? value : null;
}
