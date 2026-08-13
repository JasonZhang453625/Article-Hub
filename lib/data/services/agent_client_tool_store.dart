import 'dart:convert';
import 'dart:math';

import 'package:hive/hive.dart';

class AgentToolRunBinding {
  final String ownerUserId;
  final String ownerDeviceId;
  final String runId;

  const AgentToolRunBinding({
    required this.ownerUserId,
    required this.ownerDeviceId,
    required this.runId,
  });

  String get storageKey => '$ownerUserId\u0000$ownerDeviceId\u0000$runId';
}

class AgentArticleReference {
  final AgentToolRunBinding binding;
  final String articleRef;
  final String articleId;
  final String title;
  final DateTime expiresAt;
  final bool revoked;

  const AgentArticleReference({
    required this.binding,
    required this.articleRef,
    required this.articleId,
    required this.title,
    required this.expiresAt,
    this.revoked = false,
  });
}

class AgentClientToolReceipt {
  final AgentToolRunBinding binding;
  final String callId;
  final String tool;
  final String argumentsJson;
  final String argumentsHash;
  final String claimRequestKey;
  final String resultReceiptKey;
  final String? claimToken;
  final String? leaseEpoch;
  final Map<String, dynamic>? result;
  final String state;
  final DateTime expiresAt;
  final bool acknowledged;
  final bool revoked;

  const AgentClientToolReceipt({
    required this.binding,
    required this.callId,
    required this.tool,
    required this.argumentsJson,
    required this.argumentsHash,
    required this.claimRequestKey,
    required this.resultReceiptKey,
    required this.claimToken,
    required this.leaseEpoch,
    required this.result,
    required this.state,
    required this.expiresAt,
    this.acknowledged = false,
    this.revoked = false,
  });

  AgentClientToolReceipt copyWith({
    String? claimRequestKey,
    String? resultReceiptKey,
    Object? claimToken = _notSet,
    Object? leaseEpoch = _notSet,
    Object? result = _notSet,
    String? state,
    bool? acknowledged,
    bool? revoked,
  }) {
    return AgentClientToolReceipt(
      binding: binding,
      callId: callId,
      tool: tool,
      argumentsJson: argumentsJson,
      argumentsHash: argumentsHash,
      claimRequestKey: claimRequestKey ?? this.claimRequestKey,
      resultReceiptKey: resultReceiptKey ?? this.resultReceiptKey,
      claimToken: identical(claimToken, _notSet)
          ? this.claimToken
          : claimToken as String?,
      leaseEpoch: identical(leaseEpoch, _notSet)
          ? this.leaseEpoch
          : leaseEpoch as String?,
      result: identical(result, _notSet)
          ? this.result
          : result as Map<String, dynamic>?,
      state: state ?? this.state,
      expiresAt: expiresAt,
      acknowledged: acknowledged ?? this.acknowledged,
      revoked: revoked ?? this.revoked,
    );
  }
}

const Object _notSet = Object();

/// Run-scoped local storage for opaque article references and PUT receipts.
///
/// Both boxes contain plain Maps and therefore consume no Hive type id. The
/// records never enter backup/sync or UI history, and are always checked
/// against account + device + run before use.
class AgentClientToolStore {
  static const String articleRefsBoxName = 'agent_article_refs_v1';
  static const String receiptsBoxName = 'agent_client_tool_receipts_v1';
  static const Duration defaultTtl = Duration(days: 7);
  static final RegExp articleRefPattern = RegExp(r'^ar_[A-Za-z0-9_-]{22,64}$');

  final Random _random;
  final DateTime Function() _now;
  Box<Map>? _articleRefs;
  Box<Map>? _receipts;

  AgentClientToolStore({Random? random, DateTime Function()? now})
    : _random = random ?? Random.secure(),
      _now = now ?? DateTime.now;

  Future<void> init() async {
    _articleRefs ??= await Hive.openBox<Map>(articleRefsBoxName);
    _receipts ??= await Hive.openBox<Map>(receiptsBoxName);
    await cleanupExpired();
  }

  Future<AgentArticleReference> createArticleReference({
    required AgentToolRunBinding binding,
    required String articleId,
    required String title,
    Duration ttl = defaultTtl,
  }) async {
    await init();
    final now = _now().toUtc();
    final existing = _articleRefs!.values
        .map(_decodeArticleReference)
        .whereType<AgentArticleReference>()
        .where(
          (item) =>
              item.binding.storageKey == binding.storageKey &&
              item.articleId == articleId &&
              !item.revoked &&
              item.expiresAt.isAfter(now),
        )
        .firstOrNull;
    if (existing != null) return existing;

    late String articleRef;
    do {
      final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
      articleRef = 'ar_${base64Url.encode(bytes).replaceAll('=', '')}';
    } while (_articleRefs!.containsKey(_articleKey(binding, articleRef)));
    final record = AgentArticleReference(
      binding: binding,
      articleRef: articleRef,
      articleId: articleId,
      title: title,
      expiresAt: now.add(ttl),
    );
    await _articleRefs!.put(_articleKey(binding, articleRef), {
      'schema': 1,
      'ownerUserId': binding.ownerUserId,
      'ownerDeviceId': binding.ownerDeviceId,
      'runId': binding.runId,
      'articleRef': articleRef,
      'articleId': articleId,
      'title': title,
      'expiresAt': record.expiresAt.toIso8601String(),
      'revoked': false,
    });
    return record;
  }

  Future<AgentArticleReference?> resolveArticleReference({
    required AgentToolRunBinding binding,
    required String articleRef,
  }) async {
    await init();
    if (!articleRefPattern.hasMatch(articleRef)) return null;
    final raw = _articleRefs!.get(_articleKey(binding, articleRef));
    final decoded = _decodeArticleReference(raw);
    if (decoded == null ||
        decoded.binding.storageKey != binding.storageKey ||
        decoded.revoked ||
        !decoded.expiresAt.isAfter(_now().toUtc())) {
      return null;
    }
    return decoded;
  }

  Future<AgentClientToolReceipt> beginClaimIntent({
    required AgentToolRunBinding binding,
    required String callId,
    required String tool,
    required Map<String, dynamic> arguments,
  }) async {
    await init();
    final argumentsJson = canonicalJsonEncode(arguments);
    final argumentsHash = stablePayloadHash(argumentsJson);
    final existing = await getReceipt(binding: binding, callId: callId);
    if (existing != null) {
      if (existing.tool != tool ||
          existing.argumentsHash != argumentsHash ||
          existing.argumentsJson != argumentsJson) {
        throw StateError('Client-tool call identity changed.');
      }
      return existing;
    }
    final receipt = AgentClientToolReceipt(
      binding: binding,
      callId: callId,
      tool: tool,
      argumentsJson: argumentsJson,
      argumentsHash: argumentsHash,
      claimRequestKey: _randomRequestKey('claim'),
      resultReceiptKey: _randomRequestKey('result'),
      claimToken: null,
      leaseEpoch: null,
      result: null,
      state: 'claim_intent',
      expiresAt: _now().toUtc().add(defaultTtl),
    );
    await _putReceipt(receipt);
    return receipt;
  }

  Future<AgentClientToolReceipt> prepareReclaim(
    AgentClientToolReceipt receipt,
  ) async {
    final updated = receipt.copyWith(
      claimRequestKey: _randomRequestKey('claim'),
      resultReceiptKey: _randomRequestKey('result'),
      claimToken: null,
      leaseEpoch: null,
      state: 'claim_intent',
      acknowledged: false,
    );
    await _putReceipt(updated);
    return updated;
  }

  /// Invalidates only the expired lease while preserving a result that was
  /// already computed locally. A new result receipt key is required because
  /// its PUT payload will carry the next lease credentials.
  Future<AgentClientToolReceipt> prepareLeaseReclaim(
    AgentClientToolReceipt receipt,
  ) async {
    final updated = receipt.copyWith(
      claimRequestKey: _randomRequestKey('claim'),
      resultReceiptKey: _randomRequestKey('result'),
      claimToken: null,
      leaseEpoch: null,
      state: 'claim_intent',
      acknowledged: false,
    );
    await _putReceipt(updated);
    return updated;
  }

  Future<AgentClientToolReceipt> recordClaim({
    required AgentClientToolReceipt receipt,
    required String claimToken,
    required String leaseEpoch,
  }) async {
    final updated = receipt.copyWith(
      claimToken: claimToken,
      leaseEpoch: leaseEpoch,
      state: receipt.result == null ? 'claimed' : 'ready',
    );
    await _putReceipt(updated);
    return updated;
  }

  Future<AgentClientToolReceipt> recordResultReady({
    required AgentClientToolReceipt receipt,
    required Map<String, dynamic> result,
  }) async {
    if (receipt.claimToken == null || receipt.leaseEpoch == null) {
      throw StateError('Client-tool claim is not durable.');
    }
    final updated = receipt.copyWith(result: result, state: 'ready');
    await _putReceipt(updated);
    return updated;
  }

  Future<AgentClientToolReceipt> markSubmitting(
    AgentClientToolReceipt receipt,
  ) async {
    final updated = receipt.copyWith(state: 'submitting');
    await _putReceipt(updated);
    return updated;
  }

  Future<void> _putReceipt(AgentClientToolReceipt receipt) async {
    await init();
    final key = _receiptKey(receipt.binding, receipt.callId);
    final existing = _decodeReceipt(_receipts!.get(key));
    if (existing != null &&
        !existing.revoked &&
        (existing.tool != receipt.tool ||
            existing.argumentsJson != receipt.argumentsJson ||
            existing.argumentsHash != receipt.argumentsHash)) {
      throw StateError('Client-tool receipt identity changed.');
    }
    await _receipts!.put(key, _encodeReceipt(receipt));
  }

  Future<AgentClientToolReceipt?> getReceipt({
    required AgentToolRunBinding binding,
    required String callId,
  }) async {
    await init();
    final decoded = _decodeReceipt(
      _receipts!.get(_receiptKey(binding, callId)),
    );
    if (decoded == null ||
        decoded.binding.storageKey != binding.storageKey ||
        decoded.revoked ||
        !decoded.expiresAt.isAfter(_now().toUtc())) {
      return null;
    }
    return decoded;
  }

  /// Enumerates only live, unrevoked receipts for one exact owner/device/run.
  /// This is used after process restart to reconcile result requests whose
  /// server ACK may have been lost without exposing receipts across owners.
  Future<List<AgentClientToolReceipt>> receiptsForRun(
    AgentToolRunBinding binding,
  ) async {
    await init();
    final now = _now().toUtc();
    final receipts =
        _receipts!.values
            .map(_decodeReceipt)
            .whereType<AgentClientToolReceipt>()
            .where(
              (receipt) =>
                  receipt.binding.storageKey == binding.storageKey &&
                  !receipt.revoked &&
                  receipt.expiresAt.isAfter(now),
            )
            .toList(growable: false)
          ..sort((left, right) => left.callId.compareTo(right.callId));
    return List.unmodifiable(receipts);
  }

  Future<void> acknowledgeReceipt({
    required AgentToolRunBinding binding,
    required String callId,
  }) async {
    final receipt = await getReceipt(binding: binding, callId: callId);
    if (receipt == null) return;
    // The backend ACK is the durability commit point. Claim credentials and
    // the local result payload are no longer needed for replay and are
    // removed immediately; run-scoped article refs remain for final citation
    // resolution until the answer is persisted.
    await _receipts!.delete(_receiptKey(binding, callId));
  }

  Future<Set<String>> ownedRunIds({
    required String ownerUserId,
    required String ownerDeviceId,
  }) async {
    await init();
    final now = _now().toUtc();
    final ids = <String>{};
    for (final raw in _articleRefs!.values) {
      final item = _decodeArticleReference(raw);
      if (item != null &&
          item.binding.ownerUserId == ownerUserId &&
          item.binding.ownerDeviceId == ownerDeviceId &&
          !item.revoked &&
          item.expiresAt.isAfter(now)) {
        ids.add(item.binding.runId);
      }
    }
    for (final raw in _receipts!.values) {
      final item = _decodeReceipt(raw);
      if (item != null &&
          item.binding.ownerUserId == ownerUserId &&
          item.binding.ownerDeviceId == ownerDeviceId &&
          !item.revoked &&
          item.expiresAt.isAfter(now)) {
        ids.add(item.binding.runId);
      }
    }
    return ids;
  }

  Future<List<String>> resolveCitedArticleIds({
    required AgentToolRunBinding binding,
    required String answer,
    required List<({String id, String articleRef})> localSources,
    required Set<String> existingArticleIds,
  }) async {
    await init();
    final sourceById = <String, String>{};
    for (final source in localSources) {
      if (sourceById.containsKey(source.id)) return const [];
      sourceById[source.id] = source.articleRef;
    }
    final citedNumbers = RegExp(
      r'(?<![A-Za-z0-9_])\[([1-9]\d*)\]',
    ).allMatches(answer).map((match) => match.group(1)!).toSet();
    final articleIds = <String>[];
    for (final source in localSources) {
      if (!citedNumbers.contains(source.id)) continue;
      final reference = await resolveArticleReference(
        binding: binding,
        articleRef: source.articleRef,
      );
      if (reference != null &&
          existingArticleIds.contains(reference.articleId) &&
          !articleIds.contains(reference.articleId)) {
        articleIds.add(reference.articleId);
      }
    }
    return List.unmodifiable(articleIds);
  }

  Future<void> revokeRun(AgentToolRunBinding binding) async {
    await init();
    for (final entry in _articleRefs!.toMap().entries) {
      final item = _decodeArticleReference(entry.value);
      if (item?.binding.storageKey == binding.storageKey && !item!.revoked) {
        final updated = Map<String, dynamic>.from(entry.value)
          ..['revoked'] = true;
        await _articleRefs!.put(entry.key, updated);
      }
    }
    for (final entry in _receipts!.toMap().entries) {
      final item = _decodeReceipt(entry.value);
      if (item?.binding.storageKey == binding.storageKey && !item!.revoked) {
        await _receipts!.put(
          entry.key,
          _encodeReceipt(item.copyWith(revoked: true)),
        );
      }
    }
  }

  Future<void> deleteRun(AgentToolRunBinding binding) async {
    await init();
    final refKeys = _articleRefs!
        .toMap()
        .entries
        .where(
          (entry) =>
              _decodeArticleReference(entry.value)?.binding.storageKey ==
              binding.storageKey,
        )
        .map((entry) => entry.key)
        .toList(growable: false);
    final receiptKeys = _receipts!
        .toMap()
        .entries
        .where(
          (entry) =>
              _decodeReceipt(entry.value)?.binding.storageKey ==
              binding.storageKey,
        )
        .map((entry) => entry.key)
        .toList(growable: false);
    if (refKeys.isNotEmpty) await _articleRefs!.deleteAll(refKeys);
    if (receiptKeys.isNotEmpty) await _receipts!.deleteAll(receiptKeys);
  }

  Future<void> revokeOwner({
    required String ownerUserId,
    required String ownerDeviceId,
  }) async {
    final runIds = await ownedRunIds(
      ownerUserId: ownerUserId,
      ownerDeviceId: ownerDeviceId,
    );
    for (final runId in runIds) {
      await revokeRun(
        AgentToolRunBinding(
          ownerUserId: ownerUserId,
          ownerDeviceId: ownerDeviceId,
          runId: runId,
        ),
      );
    }
  }

  Future<void> cleanupExpired() async {
    if (_articleRefs == null || _receipts == null) return;
    final now = _now().toUtc();
    final refKeys = <dynamic>[];
    for (final entry in _articleRefs!.toMap().entries) {
      final item = _decodeArticleReference(entry.value);
      if (item == null || !item.expiresAt.isAfter(now)) refKeys.add(entry.key);
    }
    if (refKeys.isNotEmpty) await _articleRefs!.deleteAll(refKeys);
    final receiptKeys = <dynamic>[];
    for (final entry in _receipts!.toMap().entries) {
      final item = _decodeReceipt(entry.value);
      if (item == null || !item.expiresAt.isAfter(now)) {
        receiptKeys.add(entry.key);
      }
    }
    if (receiptKeys.isNotEmpty) await _receipts!.deleteAll(receiptKeys);
  }

  static String _articleKey(AgentToolRunBinding binding, String articleRef) =>
      '${binding.storageKey}\u0000$articleRef';

  static String _receiptKey(AgentToolRunBinding binding, String callId) =>
      '${binding.storageKey}\u0000$callId';

  String _randomRequestKey(String operation) {
    final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
    return 'ct_${operation}_${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  static AgentArticleReference? _decodeArticleReference(dynamic raw) {
    if (raw is! Map || raw['schema'] != 1) return null;
    final owner = raw['ownerUserId'];
    final device = raw['ownerDeviceId'];
    final runId = raw['runId'];
    final articleRef = raw['articleRef'];
    final articleId = raw['articleId'];
    final title = raw['title'];
    final expiresAt = DateTime.tryParse((raw['expiresAt'] ?? '').toString());
    if (owner is! String ||
        device is! String ||
        runId is! String ||
        articleRef is! String ||
        !articleRefPattern.hasMatch(articleRef) ||
        articleId is! String ||
        title is! String ||
        expiresAt == null) {
      return null;
    }
    return AgentArticleReference(
      binding: AgentToolRunBinding(
        ownerUserId: owner,
        ownerDeviceId: device,
        runId: runId,
      ),
      articleRef: articleRef,
      articleId: articleId,
      title: title,
      expiresAt: expiresAt.toUtc(),
      revoked: raw['revoked'] == true,
    );
  }

  static Map<String, dynamic> _encodeReceipt(AgentClientToolReceipt item) => {
    'schema': 1,
    'ownerUserId': item.binding.ownerUserId,
    'ownerDeviceId': item.binding.ownerDeviceId,
    'runId': item.binding.runId,
    'callId': item.callId,
    'tool': item.tool,
    'argumentsJson': item.argumentsJson,
    'argumentsHash': item.argumentsHash,
    'claimRequestKey': item.claimRequestKey,
    'resultReceiptKey': item.resultReceiptKey,
    'claimToken': item.claimToken,
    'leaseEpoch': item.leaseEpoch,
    'result': item.result,
    'state': item.state,
    'expiresAt': item.expiresAt.toIso8601String(),
    'acknowledged': item.acknowledged,
    'revoked': item.revoked,
  };

  static AgentClientToolReceipt? _decodeReceipt(dynamic raw) {
    if (raw is! Map ||
        raw['schema'] != 1 ||
        (raw['result'] != null && raw['result'] is! Map)) {
      return null;
    }
    final owner = raw['ownerUserId'];
    final device = raw['ownerDeviceId'];
    final runId = raw['runId'];
    final callId = raw['callId'];
    final tool = raw['tool'];
    final argumentsJson = raw['argumentsJson'];
    final argumentsHash = raw['argumentsHash'];
    final claimRequestKey = raw['claimRequestKey'];
    final resultReceiptKey = raw['resultReceiptKey'];
    final claimToken = raw['claimToken'];
    final leaseEpoch = raw['leaseEpoch'];
    final state = raw['state'];
    final expiresAt = DateTime.tryParse((raw['expiresAt'] ?? '').toString());
    if (owner is! String ||
        device is! String ||
        runId is! String ||
        callId is! String ||
        tool is! String ||
        argumentsJson is! String ||
        argumentsHash is! String ||
        argumentsHash != stablePayloadHash(argumentsJson) ||
        claimRequestKey is! String ||
        resultReceiptKey is! String ||
        (claimToken != null && claimToken is! String) ||
        (leaseEpoch != null && leaseEpoch is! String) ||
        state is! String ||
        !const {
          'claim_intent',
          'claimed',
          'ready',
          'submitting',
          'acked',
        }.contains(state) ||
        expiresAt == null) {
      return null;
    }
    return AgentClientToolReceipt(
      binding: AgentToolRunBinding(
        ownerUserId: owner,
        ownerDeviceId: device,
        runId: runId,
      ),
      callId: callId,
      tool: tool,
      argumentsJson: argumentsJson,
      argumentsHash: argumentsHash,
      claimRequestKey: claimRequestKey,
      resultReceiptKey: resultReceiptKey,
      claimToken: claimToken as String?,
      leaseEpoch: leaseEpoch as String?,
      result: raw['result'] == null
          ? null
          : Map<String, dynamic>.from(raw['result'] as Map),
      state: state,
      expiresAt: expiresAt.toUtc(),
      acknowledged: raw['acknowledged'] == true,
      revoked: raw['revoked'] == true,
    );
  }
}

String canonicalJsonEncode(dynamic value) => jsonEncode(_canonicalJson(value));

dynamic _canonicalJson(dynamic value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, dynamic>{
      for (final key in keys) key: _canonicalJson(value[key]),
    };
  }
  if (value is List) return value.map(_canonicalJson).toList(growable: false);
  return value;
}

String stablePayloadHash(String value) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
