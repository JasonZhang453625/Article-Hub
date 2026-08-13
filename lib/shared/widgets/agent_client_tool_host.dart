import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/chat_message_record.dart';
import '../../data/services/agent_client_tool_api.dart';
import '../../data/services/agent_client_tool_executor.dart';
import '../../data/services/agent_client_tool_store.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/hosted_ai_capabilities.dart';
import '../providers/ai_providers.dart';
import '../providers/article_providers.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_providers.dart';

class AgentClientToolLifecycleCoordinator {
  Future<void> Function()? _beforeSignOut;
  Future<void> Function(String runId)? _revokeRun;

  Future<void> beforeSignOut() => _beforeSignOut?.call() ?? Future.value();

  Future<void> revokeRun(String runId) =>
      _revokeRun?.call(runId) ?? Future.value();

  void attach({
    required Future<void> Function() beforeSignOut,
    required Future<void> Function(String runId) revokeRun,
  }) {
    _beforeSignOut = beforeSignOut;
    _revokeRun = revokeRun;
  }

  void detach() {
    _beforeSignOut = null;
    _revokeRun = null;
  }
}

final agentClientToolLifecycleProvider =
    Provider<AgentClientToolLifecycleCoordinator>(
      (ref) => AgentClientToolLifecycleCoordinator(),
    );

/// App-global owner of protocol-v3 device tools.
///
/// REST pending/claim/result is authoritative. SSE events only wake the chat
/// observer and are never required for execution or crash recovery.
class AgentClientToolHost extends ConsumerStatefulWidget {
  final Widget child;

  const AgentClientToolHost({super.key, required this.child});

  @override
  ConsumerState<AgentClientToolHost> createState() =>
      _AgentClientToolHostState();
}

class _AgentClientToolHostState extends ConsumerState<AgentClientToolHost> {
  static const int _maxConcurrentCalls = 2;
  static const Duration _pollInterval = Duration(milliseconds: 800);

  _HostBinding? _binding;
  HostedAgentClientToolsCapabilities? _capabilities;
  AgentClientToolApi? _api;
  Timer? _timer;
  int _generation = 0;
  bool _tickRunning = false;
  final Set<String> _inFlight = {};
  final Set<String> _blockedCalls = {};
  final Set<String> _awaitingPendingReclaim = {};
  final Set<String> _preparedMissingPendingReclaims = {};
  final Set<String> _knownRunIds = {};
  final Set<String> _retiredRunIds = {};
  final Set<String> _dormantRunIds = {};
  bool _reconcilingCreates = false;
  AgentClientToolLifecycleCoordinator? _lifecycleCoordinator;

  @override
  void initState() {
    super.initState();
    final coordinator = ref.read(agentClientToolLifecycleProvider);
    _lifecycleCoordinator = coordinator;
    coordinator.attach(
      beforeSignOut: _beforeSignOut,
      revokeRun: _revokeRunFromUi,
    );
  }

  @override
  void dispose() {
    _lifecycleCoordinator?.detach();
    _lifecycleCoordinator = null;
    _timer?.cancel();
    _api?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(currentSessionProvider);
    final capabilities = ref.watch(hostedAgentClientToolsCapabilitiesProvider);
    ref.watch(chatSessionsProvider);
    final nextBinding = session == null ? null : _HostBinding(session);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _configure(nextBinding, capabilities);
    });
    return widget.child;
  }

  void _configure(
    _HostBinding? next,
    HostedAgentClientToolsCapabilities? capabilities,
  ) {
    final previous = _binding;
    final sameGeneration = previous?.generationKey == next?.generationKey;
    final sameCapabilities = identical(_capabilities, capabilities);
    if (sameGeneration && sameCapabilities) {
      _scheduleTick();
      return;
    }

    _generation++;
    _timer?.cancel();
    _timer = null;
    _api?.close();
    _api = null;
    _binding = next;
    _capabilities = capabilities;
    _inFlight.clear();
    _blockedCalls.clear();
    _awaitingPendingReclaim.clear();
    _preparedMissingPendingReclaims.clear();

    if (previous != null &&
        (next == null || previous.ownerKey != next.ownerKey)) {
      // Logout/account switch suspends old work. Its durable receipts stay
      // fenced by owner+device and can resume only after that owner returns.
      _knownRunIds.clear();
      _retiredRunIds.clear();
      _dormantRunIds.clear();
    }

    if (next == null || capabilities == null) return;
    _api = AgentClientToolApi(
      getSession: () => ref.read(currentSessionProvider),
      refreshSession: () => ref.read(authControllerProvider.notifier).refresh(),
    );
    _timer = Timer.periodic(_pollInterval, (_) => _scheduleTick());
    _scheduleTick();
  }

  void _scheduleTick() {
    if (_tickRunning || _binding == null || _capabilities == null) return;
    _tickRunning = true;
    unawaited(
      _tick().whenComplete(() {
        _tickRunning = false;
      }),
    );
  }

  Future<void> _tick() async {
    final binding = _binding;
    final capabilities = _capabilities;
    final api = _api;
    if (binding == null || capabilities == null || api == null) return;
    final generation = _generation;
    void guard() => _guard(generation, binding);

    try {
      guard();
      final sessions = ref.read(chatSessionsProvider.notifier);
      // ChatScreen may be inside the foreground create window. Serializing
      // reconciliation per host avoids overlapping delayed GET backoffs; the
      // repository CAS remains authoritative if a late 202 races this GET.
      if (!_reconcilingCreates) {
        _reconcilingCreates = true;
        try {
          await sessions.reconcileAmbiguousServerRuns(
            ownerUserId: binding.userId,
            ownerDeviceId: binding.deviceId,
          );
        } finally {
          _reconcilingCreates = false;
        }
      }
      guard();
      final attempts = await sessions.clientToolAttempts();
      guard();
      final owned = {
        for (final message in attempts)
          if (message.aiRunOwnerUserId == binding.userId &&
              message.aiRunOwnerDeviceId == binding.deviceId &&
              message.aiRunId != null &&
              !_retiredRunIds.contains(message.aiRunId))
            message.aiRunId!: message,
      };
      final store = ref.read(agentClientToolStoreProvider);
      guard();
      final storedRuns = await store.ownedRunIds(
        ownerUserId: binding.userId,
        ownerDeviceId: binding.deviceId,
      );
      guard();
      // Remember only work observed active in this process. On cold start a
      // terminal history record with no run-scoped store is already retired;
      // adding every historical run here would revoke/delete it on every app
      // launch. A terminal record that still has refs/receipts is covered by
      // storedRuns and is cleaned exactly once.
      final activeAttemptRunIds = attempts
          .where(
            (message) =>
                message.aiRunOwnerUserId == binding.userId &&
                message.aiRunOwnerDeviceId == binding.deviceId &&
                message.aiRunId != null &&
                message.status == ChatMessageStatus.sending &&
                message.errorCode != 'hosted_cancel_requested',
          )
          .map((message) => message.aiRunId!);
      _knownRunIds.addAll(activeAttemptRunIds);
      final allKnown = {...storedRuns, ..._knownRunIds};
      for (final runId in allKnown) {
        final message = owned[runId];
        if (message == null ||
            message.status != ChatMessageStatus.sending ||
            message.errorCode == 'hosted_cancel_requested') {
          await _retireRun(binding, runId, guard: guard);
          _knownRunIds.remove(runId);
          _dormantRunIds.remove(runId);
        }
      }

      final active = owned.values.where(
        (message) =>
            message.status == ChatMessageStatus.sending &&
            message.errorCode != 'hosted_cancel_requested',
      );
      for (final message in active) {
        if (_inFlight.length >= _maxConcurrentCalls) break;
        final runId = message.aiRunId!;
        if (_dormantRunIds.contains(runId)) continue;
        final runBinding = AgentToolRunBinding(
          ownerUserId: binding.userId,
          ownerDeviceId: binding.deviceId,
          runId: runId,
        );
        guard();
        final pending = await api.pending(binding: runBinding, guard: guard);
        guard();
        final terminalRun = _isTerminalStatus(pending.status);
        final pendingCallIds = pending.calls.map((call) => call.callId).toSet();
        final receipts = await store.receiptsForRun(runBinding);
        guard();
        for (final receipt in receipts) {
          if (!terminalRun && _inFlight.length >= _maxConcurrentCalls) break;
          if (pendingCallIds.contains(receipt.callId)) continue;
          final callKey = '$runId\u0000${receipt.callId}';
          if (_blockedCalls.contains(callKey) || !_inFlight.add(callKey)) {
            continue;
          }
          if (terminalRun) {
            // Reconcile every durable receipt before making a terminal run
            // dormant; otherwise the concurrency cap could strand receipts
            // that were not part of the first batch forever.
            try {
              await _reconcileMissingReceipt(
                hostBinding: binding,
                runBinding: runBinding,
                receipt: receipt,
                api: api,
                generation: generation,
              );
            } finally {
              _inFlight.remove(callKey);
            }
            guard();
          } else {
            unawaited(
              _reconcileMissingReceipt(
                    hostBinding: binding,
                    runBinding: runBinding,
                    receipt: receipt,
                    api: api,
                    generation: generation,
                  )
                  .onError((error, stackTrace) {
                    if (error is! _AgentToolGenerationChanged) {
                      developer.log(
                        'device tool receipt reconciliation failed',
                        name: 'memora.agent.client_tools',
                        error: error,
                        stackTrace: stackTrace,
                      );
                    }
                  })
                  .whenComplete(() => _inFlight.remove(callKey)),
            );
          }
        }
        if (terminalRun) {
          // The server answer is ready, but the chat observer may not be
          // mounted yet to persist the final answer and resolve local refs.
          // Keep run storage intact and stop the 800ms polling loop. A chat
          // message transition to terminal above retires it exactly once.
          _dormantRunIds.add(runId);
          continue;
        }
        for (final call in pending.calls) {
          if (call.remainingResultBytes > capabilities.maxResultBytes) {
            throw const FormatException(
              'Client-tool run remainder exceeds advertised limit.',
            );
          }
          if (_inFlight.length >= _maxConcurrentCalls) break;
          final callKey = '$runId\u0000${call.callId}';
          if (_blockedCalls.contains(callKey)) continue;
          if (!_inFlight.add(callKey)) continue;
          unawaited(
            _processCall(
                  hostBinding: binding,
                  runBinding: runBinding,
                  call: call,
                  capabilities: capabilities,
                  api: api,
                  generation: generation,
                )
                .onError((error, stackTrace) {
                  if (error is! _AgentToolGenerationChanged) {
                    developer.log(
                      'device tool detached call failed',
                      name: 'memora.agent.client_tools',
                      error: error,
                      stackTrace: stackTrace,
                    );
                  }
                })
                .whenComplete(() => _inFlight.remove(callKey)),
          );
        }
      }
    } on _AgentToolGenerationChanged {
      // A logout, account/device switch, or capability change fences every
      // continuation. Same-owner access-token refresh is handled in-place by
      // the transport so a durable request can replay its exact key/payload.
    } on AgentClientToolApiException catch (error, stackTrace) {
      if (!error.retryable && !error.conflict && !error.notFound) {
        developer.log(
          'device tool polling rejected',
          name: 'memora.agent.client_tools',
          error: error,
          stackTrace: stackTrace,
        );
      }
    } catch (error, stackTrace) {
      developer.log(
        'device tool polling failed',
        name: 'memora.agent.client_tools',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _reconcileMissingReceipt({
    required _HostBinding hostBinding,
    required AgentToolRunBinding runBinding,
    required AgentClientToolReceipt receipt,
    required AgentClientToolApi api,
    required int generation,
  }) async {
    void guard() => _guard(generation, hostBinding);
    final store = ref.read(agentClientToolStoreProvider);
    final callKey = '${runBinding.runId}\u0000${receipt.callId}';
    try {
      guard();
      final status = await api.callStatus(
        binding: runBinding,
        receipt: receipt,
        guard: guard,
      );
      guard();
      switch (status.status) {
        case 'completed':
          // A completed receipt proves the prior PUT committed even if its
          // response was lost. Drop only replay credentials/result; article
          // refs remain until the final answer is persisted and cited.
          await store.acknowledgeReceipt(
            binding: runBinding,
            callId: receipt.callId,
          );
          _awaitingPendingReclaim.remove(callKey);
          _preparedMissingPendingReclaims.remove(callKey);
          guard();
          return;
        case 'pending':
          if (_preparedMissingPendingReclaims.add(callKey)) {
            await store.prepareLeaseReclaim(receipt);
          }
          _awaitingPendingReclaim.remove(callKey);
          guard();
          return;
        case 'claimed':
          // Status intentionally reveals no token. Replay is safe only when
          // the local durable receipt still owns this exact epoch and already
          // contains the original token, result, and idempotency key.
          if (_awaitingPendingReclaim.contains(callKey) ||
              receipt.leaseEpoch != status.leaseEpoch ||
              receipt.claimToken == null ||
              receipt.result == null ||
              (receipt.state != 'ready' && receipt.state != 'submitting')) {
            return;
          }
          final submitting = receipt.state == 'submitting'
              ? receipt
              : await store.markSubmitting(receipt);
          guard();
          await api.submitResult(
            binding: runBinding,
            receipt: submitting,
            guard: guard,
          );
          guard();
          await store.acknowledgeReceipt(
            binding: runBinding,
            callId: receipt.callId,
          );
          _awaitingPendingReclaim.remove(callKey);
          _preparedMissingPendingReclaims.remove(callKey);
          guard();
          return;
        case 'cancelled':
        case 'expired':
          // The server has permanently terminalized this call. Never execute
          // or submit it. Run retirement will remove the receipt together
          // with the refs after the local answer reaches a terminal state.
          _blockedCalls.add(callKey);
          _preparedMissingPendingReclaims.remove(callKey);
          return;
      }
    } on _AgentToolGenerationChanged {
      rethrow;
    } on AgentClientToolApiException catch (error) {
      if (_isPermanentReceiptRejection(error.code)) {
        _blockedCalls.add(callKey);
        return;
      }
      if (error.notFound) {
        // A 404 is deliberately ambiguous across owner/device/run/call. Keep
        // the durable receipt fail-closed until run retirement or expiry.
        _blockedCalls.add(callKey);
        return;
      }
      if (error.conflict &&
          (error.code == 'client_tool_lease_expired' ||
              error.code == 'client_tool_fenced')) {
        _awaitingPendingReclaim.add(callKey);
        return;
      }
      rethrow;
    }
  }

  Future<void> _processCall({
    required _HostBinding hostBinding,
    required AgentToolRunBinding runBinding,
    required AgentClientToolCall call,
    required HostedAgentClientToolsCapabilities capabilities,
    required AgentClientToolApi api,
    required int generation,
  }) async {
    void guard() => _guard(generation, hostBinding);
    final store = ref.read(agentClientToolStoreProvider);
    final callKey = '${runBinding.runId}\u0000${call.callId}';
    var activeCall = call;
    try {
      guard();
      var receipt = await store.getReceipt(
        binding: runBinding,
        callId: call.callId,
      );
      guard();
      _preparedMissingPendingReclaims.remove(callKey);

      // A rejected result lease is not authority to rotate credentials. Wait
      // until REST exposes this exact call as pending; only that transition
      // proves the previous claim is no longer live. The durable result is
      // retained and submitted under the next token/epoch.
      if (_awaitingPendingReclaim.contains(callKey)) {
        if (call.status != 'pending' || receipt == null) return;
        receipt = await store.prepareLeaseReclaim(receipt);
        _awaitingPendingReclaim.remove(callKey);
        guard();
      }

      if (call.status == 'claimed' && receipt == null) {
        // The claim belongs to an intent that is not present on this device.
        // Never invent a new key/token; the server lease will return it to
        // pending if the original receipt really was lost.
        return;
      }
      final articlesState = ref.read(articlesProvider);
      if ((receipt == null || receipt.result == null) &&
          !articlesState.hasValue) {
        // This includes a claim intent restored after process death. Cold
        // article hydration must complete before a new lease is consumed.
        return;
      }
      if (receipt == null) {
        // Article hydration must be authoritative before a lease is consumed.
        // Loading/error is not an empty knowledge base and must never become
        // a durable `empty` tool result.
        if (!ref.read(articlesProvider).hasValue) return;
        guard();
        receipt = await store.beginClaimIntent(
          binding: runBinding,
          callId: call.callId,
          tool: call.tool,
          arguments: call.arguments,
        );
        guard();
      } else if (receipt.argumentsHash !=
          stablePayloadHash(canonicalJsonEncode(call.arguments))) {
        throw StateError('Client-tool arguments changed.');
      }

      if (call.status == 'pending' && receipt.state != 'claim_intent') {
        guard();
        receipt = await store.prepareReclaim(receipt);
        guard();
      }

      if (receipt.state == 'claim_intent') {
        guard();
        final claim = await api.claim(
          binding: runBinding,
          call: activeCall,
          idempotencyKey: receipt.claimRequestKey,
          guard: guard,
        );
        guard();
        activeCall = claim.call;
        receipt = await store.recordClaim(
          receipt: receipt,
          claimToken: claim.claimToken,
          leaseEpoch: claim.call.leaseEpoch,
        );
        guard();
      }

      if (receipt.result == null) {
        final retrieval = ref.read(retrievalServiceProvider);
        if (retrieval == null) return;
        final articlesState = ref.read(articlesProvider);
        if (!articlesState.hasValue) return;
        final executor = AgentClientToolExecutor(
          retrieval: retrieval,
          store: store,
        );
        final articles = articlesState.requireValue;
        guard();
        final result = await executor.execute(
          binding: runBinding,
          call: activeCall,
          articles: articles,
          capabilities: capabilities,
          guard: guard,
        );
        guard();
        receipt = await store.recordResultReady(
          receipt: receipt,
          result: result,
        );
        guard();
      }

      receipt = await store.markSubmitting(receipt);
      guard();
      await api.submitResult(
        binding: runBinding,
        receipt: receipt,
        guard: guard,
      );
      guard();
      await store.acknowledgeReceipt(binding: runBinding, callId: call.callId);
      _awaitingPendingReclaim.remove(callKey);
      _preparedMissingPendingReclaims.remove(callKey);
      guard();
    } on _AgentToolGenerationChanged {
      rethrow;
    } on AgentClientToolApiException catch (error) {
      if (error.notFound) {
        await store.revokeRun(runBinding);
        _awaitingPendingReclaim.remove(callKey);
      }
      if (error.conflict && error.code == 'client_tool_lease_expired') {
        // lease_expired is explicitly reclaimable, but REST must still expose
        // this exact call as pending before credentials and receipt keys are
        // rotated. Until then the prior result remains durable and untouched.
        _awaitingPendingReclaim.add(callKey);
      }
      if (error.conflict && error.code == 'client_tool_fenced') {
        // A fence can mean a live token/epoch mismatch, a non-WAITING run, or
        // a wall-deadline terminalization. It is not reclaim authority, so
        // preserve the stale receipt and only observe REST. If the same call
        // later becomes pending after an active lease expires, that pending
        // transition is the authority to rotate; terminal cleanup otherwise
        // retires the receipt without another PUT.
        _awaitingPendingReclaim.add(callKey);
      }
      if (error.conflict &&
          error.code == 'client_tool_claim_key_expired' &&
          call.status == 'pending') {
        // A lost claim response can leave only the old claim intent locally.
        // The current pending response is reclaim authority; rotate on the
        // next pass instead of replaying an idempotency key bound to the
        // expired server lease forever.
        _awaitingPendingReclaim.add(callKey);
      }
      if (_isPermanentReceiptRejection(error.code)) {
        _blockedCalls.add(callKey);
      }
      // Retryable transport loss and claim conflicts retain the durable
      // intent/receipt. A later REST poll replays the same idempotency key.
    } on AgentClientToolBudgetExhausted {
      // The server owns terminalization when its run-wide result budget has
      // no room for even the schema-minimal result. Do not hot-loop this call
      // while waiting for the terminal run state to propagate.
      _blockedCalls.add(callKey);
    } catch (error, stackTrace) {
      developer.log(
        'device tool call failed',
        name: 'memora.agent.client_tools',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _guard(int generation, _HostBinding expected) {
    final current = ref.read(currentSessionProvider);
    if (!mounted ||
        generation != _generation ||
        _binding?.generationKey != expected.generationKey ||
        current == null ||
        current.user.id != expected.userId ||
        current.device.id != expected.deviceId) {
      throw const _AgentToolGenerationChanged();
    }
  }

  static bool _isTerminalStatus(String status) =>
      status == 'completed' || status == 'failed' || status == 'cancelled';

  static bool _isPermanentReceiptRejection(String? code) =>
      code == 'IDEMPOTENCY_CONFLICT' ||
      code == 'client_tool_result_budget_exceeded' ||
      code == 'client_tool_result_token_limit_exceeded' ||
      code == 'client_tool_result_too_large' ||
      code == 'invalid_client_tool_result';

  Future<void> _beforeSignOut() async {
    _generation++;
    _timer?.cancel();
    _api?.close();
    _api = null;
    _inFlight.clear();
    _blockedCalls.clear();
    _awaitingPendingReclaim.clear();
    _preparedMissingPendingReclaims.clear();
    _knownRunIds.clear();
    _retiredRunIds.clear();
    _dormantRunIds.clear();
  }

  Future<void> _revokeRunFromUi(String runId) async {
    final binding = _binding;
    if (binding == null || runId.trim().isEmpty) return;
    _generation++;
    _api?.close();
    _api = null;
    await _retireRun(binding, runId);
    _knownRunIds.remove(runId);
    _dormantRunIds.remove(runId);
    _blockedCalls.removeWhere((key) => key.startsWith('$runId\u0000'));
    _awaitingPendingReclaim.removeWhere(
      (key) => key.startsWith('$runId\u0000'),
    );
    _preparedMissingPendingReclaims.removeWhere(
      (key) => key.startsWith('$runId\u0000'),
    );
    if (mounted && _capabilities != null) {
      _api = AgentClientToolApi(
        getSession: () => ref.read(currentSessionProvider),
        refreshSession: () =>
            ref.read(authControllerProvider.notifier).refresh(),
      );
      _scheduleTick();
    }
  }

  Future<void> _retireRun(
    _HostBinding binding,
    String runId, {
    AgentToolGenerationGuard? guard,
  }) async {
    if (!_retiredRunIds.add(runId)) return;
    final runBinding = AgentToolRunBinding(
      ownerUserId: binding.userId,
      ownerDeviceId: binding.deviceId,
      runId: runId,
    );
    final store = ref.read(agentClientToolStoreProvider);
    _dormantRunIds.remove(runId);
    _blockedCalls.removeWhere((key) => key.startsWith('$runId\u0000'));
    _awaitingPendingReclaim.removeWhere(
      (key) => key.startsWith('$runId\u0000'),
    );
    _preparedMissingPendingReclaims.removeWhere(
      (key) => key.startsWith('$runId\u0000'),
    );
    guard?.call();
    try {
      await store.revokeRun(runBinding);
      guard?.call();
      await store.deleteRun(runBinding);
      guard?.call();
    } catch (_) {
      // Revocation is durable. Let a future lifecycle/tick retry physical
      // deletion if the second phase did not complete.
      _retiredRunIds.remove(runId);
      rethrow;
    }
  }
}

class _HostBinding {
  final AuthSession session;

  const _HostBinding(this.session);

  String get userId => session.user.id;
  String get deviceId => session.device.id;
  String get ownerKey => '$userId\u0000$deviceId';
  String get generationKey => ownerKey;
}

class _AgentToolGenerationChanged implements Exception {
  const _AgentToolGenerationChanged();
}
