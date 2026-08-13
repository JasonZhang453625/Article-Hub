import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memora/data/models/chat_message_record.dart';
import 'package:memora/data/models/chat_thread.dart';
import 'package:memora/data/models/memory_document.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/repositories/article_repository.dart';
import 'package:memora/data/repositories/chat_repository.dart';
import 'package:memora/data/services/agent_client_tool_store.dart';
import 'package:memora/data/services/auth_service.dart';
import 'package:memora/data/services/embedding_service.dart';
import 'package:memora/data/services/hosted_agent_service.dart';
import 'package:memora/data/services/hosted_ai_capabilities.dart';
import 'package:memora/data/services/index_service.dart';
import 'package:memora/data/services/retrieval_service.dart';
import 'package:memora/shared/providers/ai_providers.dart';
import 'package:memora/shared/providers/article_providers.dart';
import 'package:memora/shared/providers/auth_provider.dart';
import 'package:memora/shared/providers/chat_providers.dart';
import 'package:memora/shared/widgets/agent_client_tool_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'loading vault delays claim and 401 replays the same result receipt',
    (tester) async {
      final repository = _activeRepository();
      final store = _MemoryAgentClientToolStore();
      final retrieval = _FakeRetrievalService();
      final fresh = _session(tokenMarker: 'fresh');
      var accepted = false;
      var claimCalls = 0;
      var resultCalls = 0;
      final resultKeys = <String?>[];
      final resultBodies = <String>[];
      final authorization = <String?>[];
      final client = MockClient((request) async {
        authorization.add(request.headers['authorization']);
        if (request.method == 'GET' && request.url.path.endsWith('/pending')) {
          return _pendingResponse(
            calls: accepted ? const [] : [_call(status: 'pending')],
            status: accepted ? 'running' : 'waiting_client',
          );
        }
        if (request.url.path.endsWith('/claim')) {
          claimCalls++;
          return _claimResponse(token: _claimToken(1), epoch: '1');
        }
        if (request.url.path.endsWith('/result')) {
          resultCalls++;
          resultKeys.add(request.headers['idempotency-key']);
          resultBodies.add(request.body);
          if (resultCalls == 1) {
            return http.Response(
              jsonEncode({
                'error': {'code': 'invalid_authorization', 'retryable': false},
              }),
              401,
            );
          }
          accepted = true;
          return _acceptedResult();
        }
        return http.Response('{}', 500);
      });

      await http.runWithClient(() async {
        final harness = await _mountHost(
          tester,
          repository: repository,
          store: store,
          retrieval: retrieval,
          initialArticles: null,
          refreshSession: fresh,
        );

        await tester.pump(const Duration(seconds: 2));
        expect(claimCalls, 0);
        expect(resultCalls, 0);

        harness.articles.setData([_article()]);
        await _pumpUntil(tester, () => resultCalls == 2);

        expect(claimCalls, 1);
        expect(resultKeys, hasLength(2));
        expect(resultKeys.toSet(), hasLength(1));
        expect(resultBodies.toSet(), hasLength(1));
        expect(retrieval.calls, 1);
        expect(harness.auth.refreshCalls, 1);
        expect(
          authorization,
          containsAllInOrder([
            'Bearer ${_session().accessToken}',
            'Bearer ${fresh.accessToken}',
          ]),
        );
        expect(
          await store.getReceipt(binding: _binding, callId: 'call-1'),
          isNull,
        );
        expect(store.acknowledgeCalls, 1);
        await _unmount(tester);
      }, () => client);
    },
    semanticsEnabled: false,
  );

  testWidgets(
    'lease_expired waits for pending then reclaims with new keys and lease',
    (tester) async {
      final repository = _activeRepository();
      final store = _MemoryAgentClientToolStore();
      final retrieval = _FakeRetrievalService();
      var resultCalls = 0;
      var claimCalls = 0;
      var pendingAfterConflict = 0;
      var accepted = false;
      final claimKeys = <String?>[];
      final resultKeys = <String?>[];
      final resultBodies = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/pending')) {
          if (accepted) {
            return _pendingResponse(calls: const [], status: 'running');
          }
          if (resultCalls == 0) {
            return _pendingResponse(calls: [_call(status: 'pending')]);
          }
          pendingAfterConflict++;
          return _pendingResponse(
            calls: [
              _call(
                status: pendingAfterConflict == 1 ? 'claimed' : 'pending',
                epoch: '1',
              ),
            ],
          );
        }
        if (request.url.path.endsWith('/claim')) {
          claimCalls++;
          claimKeys.add(request.headers['idempotency-key']);
          return _claimResponse(
            token: _claimToken(claimCalls),
            epoch: '$claimCalls',
          );
        }
        if (request.url.path.endsWith('/result')) {
          resultCalls++;
          resultKeys.add(request.headers['idempotency-key']);
          resultBodies.add(
            Map<String, dynamic>.from(jsonDecode(request.body) as Map),
          );
          if (resultCalls == 1) {
            return _conflict('client_tool_lease_expired', retryable: true);
          }
          accepted = true;
          return _acceptedResult();
        }
        return http.Response('{}', 500);
      });

      await http.runWithClient(() async {
        await _mountHost(
          tester,
          repository: repository,
          store: store,
          retrieval: retrieval,
          initialArticles: [_article()],
        );
        await _pumpUntil(tester, () => resultCalls == 2, steps: 40);

        expect(claimCalls, 2);
        expect(pendingAfterConflict, greaterThanOrEqualTo(2));
        expect(claimKeys.toSet(), hasLength(2));
        expect(resultKeys.toSet(), hasLength(2));
        expect(resultBodies[0]['result'], resultBodies[1]['result']);
        expect(resultBodies[0]['claim_token'], _claimToken(1));
        expect(resultBodies[0]['lease_epoch'], '1');
        expect(resultBodies[1]['claim_token'], _claimToken(2));
        expect(resultBodies[1]['lease_epoch'], '2');
        expect(store.prepareLeaseReclaimCalls, 1);
        expect(store.prepareReclaimCalls, 0);
        expect(retrieval.calls, 1);
        expect(
          await store.getReceipt(binding: _binding, callId: 'call-1'),
          isNull,
        );
        await _unmount(tester);
      }, () => client);
    },
    semanticsEnabled: false,
  );

  testWidgets(
    'client_tool_fenced waits without mutation then reclaims only on pending',
    (tester) async {
      final repository = _activeRepository();
      final store = _MemoryAgentClientToolStore();
      var claimCalls = 0;
      var resultCalls = 0;
      var allowPending = false;
      var accepted = false;
      final client = MockClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/pending')) {
          if (accepted) {
            return _pendingResponse(calls: const [], status: 'running');
          }
          return _pendingResponse(
            calls: [
              _call(
                status: resultCalls == 0 || allowPending
                    ? 'pending'
                    : 'claimed',
                epoch: '$claimCalls',
              ),
            ],
          );
        }
        if (request.url.path.endsWith('/claim')) {
          claimCalls++;
          return _claimResponse(
            token: _claimToken(claimCalls),
            epoch: '${6 + claimCalls}',
          );
        }
        if (request.url.path.endsWith('/result')) {
          resultCalls++;
          if (resultCalls == 1) {
            return _conflict('client_tool_fenced', retryable: false);
          }
          accepted = true;
          return _acceptedResult();
        }
        return http.Response('{}', 500);
      });

      await http.runWithClient(() async {
        await _mountHost(
          tester,
          repository: repository,
          store: store,
          retrieval: _FakeRetrievalService(),
          initialArticles: [_article()],
        );
        await _pumpUntil(tester, () => resultCalls == 1);
        await tester.pump(const Duration(seconds: 4));
        await tester.pump();

        expect(claimCalls, 1);
        expect(resultCalls, 1);
        expect(store.prepareLeaseReclaimCalls, 0);
        expect(store.prepareReclaimCalls, 0);
        final staleReceipt = await store.getReceipt(
          binding: _binding,
          callId: 'call-1',
        );
        expect(staleReceipt?.state, 'submitting');
        expect(staleReceipt?.claimToken, _claimToken(1));
        expect(staleReceipt?.leaseEpoch, '7');

        allowPending = true;
        await _pumpUntil(tester, () => resultCalls == 2);
        expect(claimCalls, 2);
        expect(store.prepareLeaseReclaimCalls, 1);
        expect(store.prepareReclaimCalls, 0);
        expect(
          await store.getReceipt(binding: _binding, callId: 'call-1'),
          isNull,
        );
        await _unmount(tester);
      }, () => client);
    },
    semanticsEnabled: false,
  );

  testWidgets(
    'expired lost-claim key rotates only after an observed pending call',
    (tester) async {
      final repository = _activeRepository();
      final store = _MemoryAgentClientToolStore();
      final oldIntent = await store.beginClaimIntent(
        binding: _binding,
        callId: 'call-1',
        tool: 'local_search',
        arguments: const {'query': 'Agent'},
      );
      var claimCalls = 0;
      var resultCalls = 0;
      final claimKeys = <String?>[];
      final client = MockClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/pending')) {
          return _pendingResponse(calls: [_call(status: 'pending')]);
        }
        if (request.url.path.endsWith('/claim')) {
          claimCalls++;
          claimKeys.add(request.headers['idempotency-key']);
          if (claimCalls == 1) {
            return _conflict('client_tool_claim_key_expired', retryable: true);
          }
          return _claimResponse(token: _claimToken(2), epoch: '2');
        }
        if (request.url.path.endsWith('/result')) {
          resultCalls++;
          return _acceptedResult();
        }
        return http.Response('{}', 500);
      });

      await http.runWithClient(() async {
        await _mountHost(
          tester,
          repository: repository,
          store: store,
          retrieval: _FakeRetrievalService(),
          initialArticles: [_article()],
        );
        await _pumpUntil(tester, () => resultCalls == 1);

        expect(claimCalls, 2);
        expect(claimKeys.first, oldIntent.claimRequestKey);
        expect(claimKeys.last, isNot(oldIntent.claimRequestKey));
        expect(store.prepareLeaseReclaimCalls, 1);
        expect(store.prepareReclaimCalls, 0);
        expect(
          await store.getReceipt(binding: _binding, callId: 'call-1'),
          isNull,
        );
        await _unmount(tester);
      }, () => client);
    },
    semanticsEnabled: false,
  );

  testWidgets(
    'terminal run storage is retired once across cold remount',
    (tester) async {
      final repository = _terminalRepository();
      final store = _MemoryAgentClientToolStore()..seedRun(_binding);
      final client = MockClient((request) async {
        return http.Response('{}', 500);
      });

      await http.runWithClient(() async {
        await _mountHost(
          tester,
          repository: repository,
          store: store,
          retrieval: _FakeRetrievalService(),
          initialArticles: null,
        );
        await _pumpUntil(tester, () => store.deleteRunCalls == 1);
        expect(store.revokeRunCalls, 1);
        await _unmount(tester);

        await _mountHost(
          tester,
          repository: repository,
          store: store,
          retrieval: _FakeRetrievalService(),
          initialArticles: null,
        );
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();

        expect(store.revokeRunCalls, 1);
        expect(store.deleteRunCalls, 1);
        await _unmount(tester);
      }, () => client);
    },
    semanticsEnabled: false,
  );

  testWidgets(
    'server terminal run becomes dormant until the chat message finalizes',
    (tester) async {
      final repository = _activeRepository();
      final store = _MemoryAgentClientToolStore()..seedRun(_binding);
      var pendingCalls = 0;
      final client = MockClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/pending')) {
          pendingCalls++;
          return _pendingResponse(calls: const [], status: 'completed');
        }
        return http.Response('{}', 500);
      });

      await http.runWithClient(() async {
        await _mountHost(
          tester,
          repository: repository,
          store: store,
          retrieval: _FakeRetrievalService(),
          initialArticles: null,
        );
        await _pumpUntil(tester, () => pendingCalls == 1);
        await tester.pump(const Duration(seconds: 4));
        await tester.pump();

        expect(pendingCalls, 1);
        expect(store.revokeRunCalls, 0);
        expect(store.deleteRunCalls, 0);
        expect(
          await store.ownedRunIds(
            ownerUserId: 'user-1',
            ownerDeviceId: 'device-1',
          ),
          {'run-1'},
        );

        await repository.putMessage(
          repository
              .getMessage('message-1')!
              .copyWith(status: ChatMessageStatus.completed, content: 'Done'),
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();

        expect(store.revokeRunCalls, 1);
        expect(store.deleteRunCalls, 1);
        await tester.pump(const Duration(seconds: 2));
        expect(store.revokeRunCalls, 1);
        expect(store.deleteRunCalls, 1);
        await _unmount(tester);
      }, () => client);
    },
    semanticsEnabled: false,
  );

  testWidgets(
    'restart reconciles a lost result ACK and preserves refs until final',
    (tester) async {
      final repository = _activeRepository();
      final store = _MemoryAgentClientToolStore();
      final receipt = await store.beginClaimIntent(
        binding: _binding,
        callId: 'call-1',
        tool: 'local_search',
        arguments: const {'query': 'Agent'},
      );
      var durable = await store.recordClaim(
        receipt: receipt,
        claimToken: _claimToken(7),
        leaseEpoch: '7',
      );
      durable = await store.recordResultReady(
        receipt: durable,
        result: const {
          'schemaVersion': 1,
          'status': 'empty',
          'results': <Object>[],
          'truncated': false,
        },
      );
      await store.markSubmitting(durable);
      final reference = await store.createArticleReference(
        binding: _binding,
        articleId: 'article-1',
        title: 'Agent article',
      );
      var pendingCalls = 0;
      var statusCalls = 0;
      var resultCalls = 0;
      final client = MockClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/pending')) {
          pendingCalls++;
          return _pendingResponse(calls: const [], status: 'completed');
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/client-tools/call-1')) {
          statusCalls++;
          return _statusResponse(status: 'completed', epoch: '7');
        }
        if (request.url.path.endsWith('/result')) resultCalls++;
        return http.Response('{}', 500);
      });

      await http.runWithClient(() async {
        await _mountHost(
          tester,
          repository: repository,
          store: store,
          retrieval: _FakeRetrievalService(),
          initialArticles: null,
        );
        await _pumpUntil(
          tester,
          () => statusCalls == 1 && store.acknowledgeCalls == 1,
        );

        expect(pendingCalls, 1);
        expect(resultCalls, 0);
        expect(
          await store.getReceipt(binding: _binding, callId: 'call-1'),
          isNull,
        );
        expect(
          await store.resolveArticleReference(
            binding: _binding,
            articleRef: reference.articleRef,
          ),
          isNotNull,
        );
        expect(store.revokeRunCalls, 0);
        expect(store.deleteRunCalls, 0);

        await repository.putMessage(
          repository
              .getMessage('message-1')!
              .copyWith(status: ChatMessageStatus.completed, content: 'Done'),
        );
        await _pumpUntil(tester, () => store.deleteRunCalls == 1);
        expect(
          await store.resolveArticleReference(
            binding: _binding,
            articleRef: reference.articleRef,
          ),
          isNull,
        );
        expect(store.revokeRunCalls, 1);
        expect(store.deleteRunCalls, 1);
        await _unmount(tester);
      }, () => client);
    },
    semanticsEnabled: false,
  );

  testWidgets(
    'missing claimed receipt replays only the same epoch and durable result',
    (tester) async {
      final repository = _activeRepository();
      final store = _MemoryAgentClientToolStore();
      final intent = await store.beginClaimIntent(
        binding: _binding,
        callId: 'call-1',
        tool: 'local_search',
        arguments: const {'query': 'Agent'},
      );
      var durable = await store.recordClaim(
        receipt: intent,
        claimToken: _claimToken(7),
        leaseEpoch: '7',
      );
      durable = await store.recordResultReady(
        receipt: durable,
        result: const {
          'schemaVersion': 1,
          'status': 'empty',
          'results': <Object>[],
          'truncated': false,
        },
      );
      durable = await store.markSubmitting(durable);
      var accepted = false;
      var statusCalls = 0;
      var resultCalls = 0;
      String? resultKey;
      Map<String, dynamic>? resultBody;
      final client = MockClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/pending')) {
          return _pendingResponse(calls: const [], status: 'running');
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/client-tools/call-1')) {
          statusCalls++;
          return _statusResponse(
            status: accepted ? 'completed' : 'claimed',
            epoch: '7',
          );
        }
        if (request.url.path.endsWith('/result')) {
          resultCalls++;
          resultKey = request.headers['idempotency-key'];
          resultBody = Map<String, dynamic>.from(
            jsonDecode(request.body) as Map,
          );
          accepted = true;
          return _acceptedResult();
        }
        return http.Response('{}', 500);
      });

      await http.runWithClient(() async {
        await _mountHost(
          tester,
          repository: repository,
          store: store,
          retrieval: _FakeRetrievalService(),
          initialArticles: null,
        );
        await _pumpUntil(tester, () => resultCalls == 1);

        expect(statusCalls, 1);
        expect(resultKey, durable.resultReceiptKey);
        expect(resultBody?['claim_token'], _claimToken(7));
        expect(resultBody?['lease_epoch'], '7');
        expect(resultBody?['result'], durable.result);
        expect(
          await store.getReceipt(binding: _binding, callId: 'call-1'),
          isNull,
        );
        await _unmount(tester);
      }, () => client);
    },
    semanticsEnabled: false,
  );

  testWidgets(
    'missing fenced receipt observes status until pending then reclaims once',
    (tester) async {
      final repository = _activeRepository();
      final store = _MemoryAgentClientToolStore();
      final intent = await store.beginClaimIntent(
        binding: _binding,
        callId: 'call-1',
        tool: 'local_search',
        arguments: const {'query': 'Agent'},
      );
      var durable = await store.recordClaim(
        receipt: intent,
        claimToken: _claimToken(7),
        leaseEpoch: '7',
      );
      durable = await store.recordResultReady(
        receipt: durable,
        result: const {
          'schemaVersion': 1,
          'status': 'empty',
          'results': <Object>[],
          'truncated': false,
        },
      );
      await store.markSubmitting(durable);
      var status = 'claimed';
      var exposePendingCall = false;
      var statusCalls = 0;
      var claimCalls = 0;
      var resultCalls = 0;
      final client = MockClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/pending')) {
          return _pendingResponse(
            calls: [
              exposePendingCall
                  ? _call(status: 'pending')
                  : _call(status: 'claimed', callId: 'call-other'),
            ],
          );
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/client-tools/call-1')) {
          statusCalls++;
          return _statusResponse(status: status, epoch: '7');
        }
        if (request.url.path.endsWith('/claim')) {
          claimCalls++;
          return _claimResponse(token: _claimToken(8), epoch: '8');
        }
        if (request.url.path.endsWith('/result')) {
          resultCalls++;
          if (resultCalls == 1) {
            return _conflict('client_tool_fenced', retryable: false);
          }
          return _acceptedResult();
        }
        return http.Response('{}', 500);
      });

      await http.runWithClient(() async {
        final retrieval = _FakeRetrievalService();
        await _mountHost(
          tester,
          repository: repository,
          store: store,
          retrieval: retrieval,
          initialArticles: [_article()],
        );
        await _pumpUntil(tester, () => resultCalls == 1);
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();

        expect(statusCalls, greaterThan(1));
        expect(resultCalls, 1);
        expect(claimCalls, 0);
        expect(store.prepareLeaseReclaimCalls, 0);

        status = 'pending';
        await _pumpUntil(tester, () => store.prepareLeaseReclaimCalls == 1);
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        expect(store.prepareLeaseReclaimCalls, 1);
        expect(resultCalls, 1);

        exposePendingCall = true;
        await _pumpUntil(tester, () => resultCalls == 2);
        expect(claimCalls, 1);
        expect(retrieval.calls, 0);
        expect(
          await store.getReceipt(binding: _binding, callId: 'call-1'),
          isNull,
        );
        await _unmount(tester);
      }, () => client);
    },
    semanticsEnabled: false,
  );

  testWidgets(
    'permanent result rejection quarantines the receipt without hot replay',
    (tester) async {
      for (final testCase in const [
        (statusCode: 413, code: 'client_tool_result_token_limit_exceeded'),
        (statusCode: 413, code: 'client_tool_result_too_large'),
        (statusCode: 400, code: 'invalid_client_tool_result'),
        (statusCode: 413, code: 'client_tool_result_budget_exceeded'),
        (statusCode: 409, code: 'IDEMPOTENCY_CONFLICT'),
      ]) {
        final repository = _activeRepository();
        final store = _MemoryAgentClientToolStore();
        var resultCalls = 0;
        final client = MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path.endsWith('/pending')) {
            return _pendingResponse(calls: [_call(status: 'pending')]);
          }
          if (request.url.path.endsWith('/claim')) {
            return _claimResponse(token: _claimToken(1), epoch: '1');
          }
          if (request.url.path.endsWith('/result')) {
            resultCalls++;
            return _errorResponse(
              testCase.statusCode,
              testCase.code,
              retryable: false,
            );
          }
          return http.Response('{}', 500);
        });

        await http.runWithClient(() async {
          await _mountHost(
            tester,
            repository: repository,
            store: store,
            retrieval: _FakeRetrievalService(),
            initialArticles: [_article()],
          );
          await _pumpUntil(tester, () => resultCalls == 1);
          await tester.pump(const Duration(seconds: 3));
          await tester.pump();

          expect(resultCalls, 1, reason: testCase.code);
          expect(
            await store.getReceipt(binding: _binding, callId: 'call-1'),
            isNotNull,
          );
          await _unmount(tester);
        }, () => client);
      }
    },
    semanticsEnabled: false,
  );

  testWidgets(
    'restart status replay also quarantines a permanent result rejection',
    (tester) async {
      final repository = _activeRepository();
      final store = _MemoryAgentClientToolStore();
      final intent = await store.beginClaimIntent(
        binding: _binding,
        callId: 'call-1',
        tool: 'local_search',
        arguments: const {'query': 'Agent'},
      );
      var durable = await store.recordClaim(
        receipt: intent,
        claimToken: _claimToken(7),
        leaseEpoch: '7',
      );
      durable = await store.recordResultReady(
        receipt: durable,
        result: const {
          'schemaVersion': 1,
          'status': 'empty',
          'results': <Object>[],
          'truncated': false,
        },
      );
      await store.markSubmitting(durable);
      var statusCalls = 0;
      var resultCalls = 0;
      final client = MockClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/pending')) {
          return _pendingResponse(calls: const [], status: 'running');
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/client-tools/call-1')) {
          statusCalls++;
          return _statusResponse(status: 'claimed', epoch: '7');
        }
        if (request.url.path.endsWith('/result')) {
          resultCalls++;
          return _errorResponse(
            413,
            'client_tool_result_token_limit_exceeded',
            retryable: false,
          );
        }
        return http.Response('{}', 500);
      });

      await http.runWithClient(() async {
        await _mountHost(
          tester,
          repository: repository,
          store: store,
          retrieval: _FakeRetrievalService(),
          initialArticles: null,
        );
        await _pumpUntil(tester, () => resultCalls == 1);
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();

        expect(statusCalls, 1);
        expect(resultCalls, 1);
        expect(
          await store.getReceipt(binding: _binding, callId: 'call-1'),
          isNotNull,
        );
        await _unmount(tester);
      }, () => client);
    },
    semanticsEnabled: false,
  );

  testWidgets(
    'logout suspends an in-flight pending response before claim',
    (tester) async {
      final repository = _activeRepository();
      final store = _MemoryAgentClientToolStore();
      final pendingStarted = Completer<void>();
      final pendingResponse = Completer<http.Response>();
      var claimCalls = 0;
      var resultCalls = 0;
      final client = MockClient((request) {
        if (request.method == 'GET' && request.url.path.endsWith('/pending')) {
          if (!pendingStarted.isCompleted) pendingStarted.complete();
          return pendingResponse.future;
        }
        if (request.url.path.endsWith('/claim')) claimCalls++;
        if (request.url.path.endsWith('/result')) resultCalls++;
        return Future.value(http.Response('{}', 500));
      });

      await http.runWithClient(() async {
        final harness = await _mountHost(
          tester,
          repository: repository,
          store: store,
          retrieval: _FakeRetrievalService(),
          initialArticles: [_article()],
        );
        await _pumpUntil(tester, () => pendingStarted.isCompleted);

        harness.auth.setSession(null);
        await tester.pump();
        pendingResponse.complete(
          _pendingResponse(calls: [_call(status: 'pending')]),
        );
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();

        expect(claimCalls, 0);
        expect(resultCalls, 0);
        expect(
          await store.getReceipt(binding: _binding, callId: 'call-1'),
          isNull,
        );
        await _unmount(tester);
      }, () => client);
    },
    semanticsEnabled: false,
  );

  testWidgets(
    'global host does not reconcile a foreground create until POST settles',
    (tester) async {
      final repository = _ambiguousRepository();
      var lookups = 0;
      final client = MockClient((request) async {
        return http.Response('{}', 500);
      });

      await http.runWithClient(() async {
        final harness = await _mountHost(
          tester,
          repository: repository,
          store: _MemoryAgentClientToolStore(),
          retrieval: _FakeRetrievalService(),
          initialArticles: null,
          initialCapabilities: null,
          lookup: (_, {expectedOwnerUserId}) async {
            expect(expectedOwnerUserId, 'user-1');
            lookups++;
            throw const HostedAgentLookupException(
              message: 'not found',
              statusCode: 404,
              retryable: false,
              notFound: true,
            );
          },
        );
        final sessions = harness.container.read(chatSessionsProvider.notifier);
        final marked = await sessions.markClientToolRunCreateStarted(
          messageId: 'message-1',
          expectedRequestKey: 'attempt-1',
          ownerUserId: 'user-1',
          ownerDeviceId: 'device-1',
          protocolVersion: 3,
          clientToolsVersion: 1,
          knowledgeMode: 'only',
        );
        expect(marked, isNotNull);

        harness.container.read(harness.capabilities.notifier).state =
            _capabilities;
        await tester.pump();
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();
        expect(lookups, 0);
        expect(repository.getMessage('message-1')?.status, isNotNull);

        await sessions.finishServerRunCreate(
          ownerUserId: 'user-1',
          requestKey: 'attempt-1',
        );
        await _pumpUntil(tester, () => lookups == 3, steps: 30);
        expect(
          repository.getMessage('message-1')?.errorCode,
          'hosted_run_not_found',
        );
        await _unmount(tester);
      }, () => client);
    },
    semanticsEnabled: false,
  );
}

Future<_HostHarness> _mountHost(
  WidgetTester tester, {
  required _HostChatRepository repository,
  required _MemoryAgentClientToolStore store,
  required _FakeRetrievalService retrieval,
  required List<Article>? initialArticles,
  AuthSession? refreshSession,
  HostedAgentClientToolsCapabilities? initialCapabilities = _capabilities,
  HostedAgentRunLookupResolver? lookup,
}) async {
  final capabilities = StateProvider<HostedAgentClientToolsCapabilities?>((
    ref,
  ) {
    return initialCapabilities;
  });
  final articleRepositoryGate = Completer<ArticleRepository>();
  late _TestArticlesNotifier articles;
  late _TestAuthController auth;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(
          (ref) => auth = _TestAuthController(
            _session(),
            refreshSession: refreshSession,
          ),
        ),
        hostedAgentClientToolsCapabilitiesProvider.overrideWith(
          (ref) => ref.watch(capabilities),
        ),
        chatRepositoryProvider.overrideWith((ref) async => repository),
        chatSessionsProvider.overrideWith((ref) => ChatSessionsNotifier(ref)),
        articleRepositoryProvider.overrideWith(
          (ref) => articleRepositoryGate.future,
        ),
        articlesProvider.overrideWith(
          (ref) => articles = _TestArticlesNotifier(
            ref,
            initialArticles: initialArticles,
          ),
        ),
        agentClientToolStoreProvider.overrideWithValue(store),
        retrievalServiceProvider.overrideWithValue(retrieval),
        if (lookup != null)
          hostedAgentRunLookupProvider.overrideWithValue(lookup),
      ],
      child: const Directionality(
        textDirection: TextDirection.ltr,
        child: AgentClientToolHost(child: SizedBox()),
      ),
    ),
  );
  await tester.pump();
  for (var i = 0; i < 10; i++) {
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AgentClientToolHost)),
    );
    if (!container.read(chatSessionsProvider).isLoading) {
      container.read(articlesProvider);
      return _HostHarness(
        container: container,
        capabilities: capabilities,
        articles: articles,
        auth: auth,
      );
    }
    await tester.pump(const Duration(milliseconds: 10));
  }
  fail('chat sessions did not hydrate');
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int steps = 25,
}) async {
  for (var i = 0; i < steps && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(condition(), isTrue);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

class _HostHarness {
  final ProviderContainer container;
  final StateProvider<HostedAgentClientToolsCapabilities?> capabilities;
  final _TestArticlesNotifier articles;
  final _TestAuthController auth;

  const _HostHarness({
    required this.container,
    required this.capabilities,
    required this.articles,
    required this.auth,
  });
}

const _binding = AgentToolRunBinding(
  ownerUserId: 'user-1',
  ownerDeviceId: 'device-1',
  runId: 'run-1',
);

const _capabilities = HostedAgentClientToolsCapabilities(
  version: 1,
  models: ['mimo-v2.5'],
  tools: {'local_search', 'read_article'},
  maxTotalCalls: 6,
  maxLocalSearchCalls: 4,
  maxReadArticleCalls: 4,
  maxResultBytes: 65536,
  leaseSeconds: 60,
  waitSeconds: 600,
  wallSeconds: 900,
  localSearch: HostedAgentLocalSearchLimits(
    maxResults: 5,
    maxSnippetsPerResult: 2,
    maxResultBytes: 16384,
    maxResultTokens: 1200,
  ),
  readArticle: HostedAgentClientToolResultLimits(
    maxResultBytes: 24576,
    maxResultTokens: 4000,
  ),
);

Map<String, dynamic> _call({
  required String status,
  String epoch = '1',
  String callId = 'call-1',
}) {
  final now = DateTime.utc(2026, 8, 13);
  return {
    'callId': callId,
    'tool': 'local_search',
    'arguments': {'query': 'Agent'},
    'status': status,
    'leaseEpoch': epoch,
    'remainingResultBytes': 65536,
    'leaseExpiresAt': status == 'claimed'
        ? now.add(const Duration(minutes: 1)).toIso8601String()
        : null,
    'createdAt': now.toIso8601String(),
  };
}

http.Response _pendingResponse({
  required List<Map<String, dynamic>> calls,
  String status = 'waiting_client',
}) {
  return http.Response(
    jsonEncode({'runId': 'run-1', 'status': status, 'calls': calls}),
    200,
  );
}

http.Response _claimResponse({required String token, required String epoch}) {
  return http.Response(
    jsonEncode({
      ..._call(status: 'claimed', epoch: epoch),
      'claimToken': token,
    }),
    200,
  );
}

http.Response _statusResponse({required String status, required String epoch}) {
  final now = DateTime.utc(2026, 8, 13);
  return http.Response(
    jsonEncode({
      'callId': 'call-1',
      'tool': 'local_search',
      'status': status,
      'leaseEpoch': epoch,
      'leaseExpiresAt': status == 'claimed'
          ? now.add(const Duration(minutes: 1)).toIso8601String()
          : null,
      'completedAt': status == 'completed'
          ? now.add(const Duration(minutes: 2)).toIso8601String()
          : null,
      'remainingResultBytes': 65536,
      'createdAt': now.toIso8601String(),
    }),
    200,
  );
}

http.Response _acceptedResult() => http.Response(
  jsonEncode({
    'accepted': true,
    'idempotent': false,
    'run': {'id': 'run-1', 'status': 'running'},
  }),
  200,
);

http.Response _conflict(String code, {required bool retryable}) =>
    _errorResponse(409, code, retryable: retryable);

http.Response _errorResponse(
  int statusCode,
  String code, {
  required bool retryable,
}) => http.Response(
  jsonEncode({
    'error': {
      'code': code,
      'message': 'conflict',
      'retryable': retryable,
      'requestId': 'request-1',
    },
  }),
  statusCode,
);

_HostChatRepository _activeRepository() => _HostChatRepository(
  thread: _thread(),
  message: _message(status: ChatMessageStatus.sending, runId: 'run-1'),
);

_HostChatRepository _terminalRepository() => _HostChatRepository(
  thread: _thread(),
  message: _message(status: ChatMessageStatus.completed, runId: 'run-1'),
);

_HostChatRepository _ambiguousRepository() => _HostChatRepository(
  thread: _thread(),
  message: _message(status: ChatMessageStatus.sending, runId: null),
);

ChatThread _thread() {
  final now = DateTime.utc(2026, 8, 13);
  return ChatThread(
    id: 'thread-1',
    title: 'Agent',
    createdAt: now,
    updatedAt: now,
  );
}

ChatMessageRecord _message({
  required ChatMessageStatus status,
  required String? runId,
}) {
  return ChatMessageRecord(
    id: 'message-1',
    threadId: 'thread-1',
    role: ChatMessageRole.assistant,
    content: status == ChatMessageStatus.completed ? 'Done' : '',
    createdAt: DateTime.utc(2026, 8, 13),
    status: status,
    aiRunId: runId,
    aiRunRequestKey: 'attempt-1',
    aiRunOwnerUserId: 'user-1',
    aiRunOwnerDeviceId: 'device-1',
    aiRunProtocolVersion: 3,
    aiRunClientToolsVersion: 1,
    aiRunKnowledgeMode: 'only',
  );
}

Article _article() => Article(
  id: 'article-1',
  url: 'https://example.com/agent',
  title: 'Agent article',
  source: SourcePlatform.web,
  processingStatus: ProcessingStatus.completed,
  memory: MemoryDocument.ai(
    overview: 'Agent evidence.',
    keyPoints: const [],
    conclusion: 'Done.',
  ),
);

class _TestArticlesNotifier extends ArticlesNotifier {
  _TestArticlesNotifier(super.ref, {required List<Article>? initialArticles}) {
    state = initialArticles == null
        ? const AsyncValue.loading()
        : AsyncValue.data(List.unmodifiable(initialArticles));
  }

  void setData(List<Article> articles) {
    state = AsyncValue.data(List.unmodifiable(articles));
  }
}

class _TestAuthController extends AuthController {
  final AuthSession? refreshSession;
  int refreshCalls = 0;

  _TestAuthController(AuthSession session, {this.refreshSession})
    : super(_TestAuthService(session)) {
    state = AsyncValue.data(session);
  }

  @override
  Future<void> get initialLoad => Future.value();

  @override
  Future<AuthSession?> refresh() async {
    refreshCalls++;
    final refreshed = refreshSession ?? state.valueOrNull;
    state = AsyncValue.data(refreshed);
    return refreshed;
  }

  void setSession(AuthSession? session) {
    state = AsyncValue.data(session);
  }
}

class _TestAuthService extends AuthService {
  final AuthSession session;

  _TestAuthService(this.session);

  @override
  Future<AuthSession?> loadSession() async => session;
}

class _FakeRetrievalService extends RetrievalService {
  int calls = 0;

  _FakeRetrievalService()
    : super(
        embedding: EmbeddingService(baseUrl: '', apiKey: '', model: ''),
        index: IndexService(),
      );

  @override
  Future<RetrievalResult> retrieveLocalOnly(
    String query,
    List<Article> articles,
  ) async {
    calls++;
    return RetrievalResult(
      articles: articles,
      method: RetrievalMethod.keyword,
      duration: Duration.zero,
    );
  }
}

class _HostChatRepository implements ChatRepository, ClientToolChatRepository {
  final Map<String, ChatThread> _threads;
  final Map<String, ChatMessageRecord> _messages;
  final Map<String, PendingChatThreadDeletion> _deletions = {};

  _HostChatRepository({
    required ChatThread thread,
    required ChatMessageRecord message,
  }) : _threads = {thread.id: thread},
       _messages = {message.id: message};

  @override
  Future<void> init() async {}

  @override
  List<ChatThread> getThreads() => List.unmodifiable(_threads.values);

  @override
  ChatThread? getThread(String id) => _threads[id];

  @override
  List<ChatMessageRecord> getMessages(String threadId) => List.unmodifiable(
    _messages.values.where((message) => message.threadId == threadId),
  );

  @override
  ChatMessageRecord? getMessage(String id) => _messages[id];

  @override
  Future<void> putThread(ChatThread thread) async {
    _threads[thread.id] = thread;
  }

  @override
  Future<ChatThread?> updateThreadIfExists(
    String id, {
    String? title,
    bool? isPinned,
    DateTime? activityAt,
    String? lastMessagePreview,
  }) async {
    final current = _threads[id];
    if (current == null) return null;
    final updated = current.copyWith(
      title: title,
      isPinned: isPinned,
      updatedAt: activityAt,
      lastMessagePreview: lastMessagePreview,
    );
    _threads[id] = updated;
    return updated;
  }

  @override
  Future<void> putMessage(ChatMessageRecord message) async {
    if (!_threads.containsKey(message.threadId)) throw StateError('missing');
    _messages[message.id] = message;
  }

  @override
  Future<ChatMessageRecord?> markAiRunCreateStarted({
    required String messageId,
    required String expectedRequestKey,
    required String ownerUserId,
  }) async {
    final current = _messages[messageId];
    if (current == null || current.aiRunRequestKey != expectedRequestKey) {
      return null;
    }
    final updated = current.copyWith(aiRunOwnerUserId: ownerUserId);
    _messages[messageId] = updated;
    return updated;
  }

  @override
  Future<ChatMessageRecord?> markAiRunClientToolsCreateStarted({
    required String messageId,
    required String expectedRequestKey,
    required String ownerUserId,
    required String ownerDeviceId,
    required int protocolVersion,
    required int clientToolsVersion,
    required String knowledgeMode,
  }) async {
    final current = _messages[messageId];
    if (current == null ||
        current.status != ChatMessageStatus.sending ||
        current.aiRunId != null ||
        current.aiRunRequestKey != expectedRequestKey ||
        current.aiRunOwnerUserId != ownerUserId ||
        current.aiRunOwnerDeviceId != ownerDeviceId) {
      return null;
    }
    return current;
  }

  @override
  Future<ChatMessageRecord?> attachAiRunToPendingMessage({
    required String messageId,
    required String? expectedRequestKey,
    required String? expectedOwnerUserId,
    required String runId,
  }) async {
    final current = _messages[messageId];
    if (current == null ||
        current.aiRunRequestKey != expectedRequestKey ||
        current.aiRunOwnerUserId != expectedOwnerUserId) {
      return null;
    }
    final updated = current.copyWith(aiRunId: runId, aiRunEventSeq: 0);
    _messages[messageId] = updated;
    return updated;
  }

  @override
  Future<ChatMessageRecord?> attachAiRunClientToolsToPendingMessage({
    required String messageId,
    required String? expectedRequestKey,
    required String? expectedOwnerUserId,
    required String expectedOwnerDeviceId,
    required int expectedProtocolVersion,
    required int expectedClientToolsVersion,
    required String expectedKnowledgeMode,
    required String runId,
  }) async {
    final current = _messages[messageId];
    if (current == null ||
        current.aiRunRequestKey != expectedRequestKey ||
        current.aiRunOwnerUserId != expectedOwnerUserId ||
        current.aiRunOwnerDeviceId != expectedOwnerDeviceId ||
        current.aiRunProtocolVersion != expectedProtocolVersion ||
        current.aiRunClientToolsVersion != expectedClientToolsVersion ||
        current.aiRunKnowledgeMode != expectedKnowledgeMode) {
      return null;
    }
    final updated = current.copyWith(aiRunId: runId, aiRunEventSeq: 0);
    _messages[messageId] = updated;
    return updated;
  }

  @override
  Future<ChatMessageRecord?> completeAiRunReconciliationNotFound({
    required String messageId,
    required String expectedRequestKey,
    required String ownerUserId,
  }) async {
    final current = _messages[messageId];
    if (current == null ||
        current.aiRunRequestKey != expectedRequestKey ||
        current.aiRunOwnerUserId != ownerUserId ||
        current.aiRunId != null) {
      return null;
    }
    final updated = current.copyWith(
      status: ChatMessageStatus.interrupted,
      errorCode: current.errorCode == 'hosted_cancel_requested'
          ? 'hosted_run_cancelled'
          : 'hosted_run_not_found',
    );
    _messages[messageId] = updated;
    return updated;
  }

  @override
  Future<ChatMessageRecord?> requestAiRunCancellation({
    required String messageId,
    required String? expectedRequestKey,
  }) async {
    final current = _messages[messageId];
    if (current == null || current.aiRunRequestKey != expectedRequestKey) {
      return null;
    }
    final updated = current.copyWith(
      status: ChatMessageStatus.interrupted,
      errorCode: 'hosted_cancel_requested',
    );
    _messages[messageId] = updated;
    return updated;
  }

  @override
  Future<ChatMessageRecord?> completeUncreatedAiRunCancellation({
    required String messageId,
    required String? expectedRequestKey,
  }) async {
    final current = _messages[messageId];
    if (current == null || current.aiRunId != null) return null;
    final updated = current.copyWith(
      status: ChatMessageStatus.interrupted,
      errorCode: 'hosted_run_cancelled',
    );
    _messages[messageId] = updated;
    return updated;
  }

  @override
  Future<void> deleteMessage(String id) async {
    _messages.remove(id);
  }

  @override
  Future<PendingChatThreadDeletion> deleteThread(String id) async {
    _threads.remove(id);
    _messages.removeWhere((_, message) => message.threadId == id);
    final deletion = PendingChatThreadDeletion(
      threadId: id,
      dataDeleted: true,
      revision: 1,
    );
    _deletions[id] = deletion;
    return deletion;
  }

  @override
  List<PendingChatThreadDeletion> getPendingThreadDeletions() =>
      List.unmodifiable(_deletions.values);

  @override
  Future<PendingChatThreadDeletion> queueAiRunCancellation(
    String threadId,
    String runId, {
    String? ownerUserId,
  }) async {
    final deletion = PendingChatThreadDeletion(
      threadId: threadId,
      aiRunIdsToCancel: [runId],
      aiRunOwnerUserIds: {runId: ?ownerUserId},
      dataDeleted: true,
      revision: 1,
      canAcknowledge: ownerUserId != null,
    );
    _deletions[threadId] = deletion;
    return deletion;
  }

  @override
  Future<PendingChatThreadDeletion?> completeAiRunCancellation(
    String threadId,
    String runId,
  ) async => _deletions[threadId];

  @override
  Future<PendingChatThreadDeletion?> resolveAiRunLookup(
    String threadId, {
    required String ownerUserId,
    required String requestKey,
    String? runId,
  }) async => _deletions[threadId];

  @override
  Future<void> completeThreadDeletion(
    String id, {
    required int expectedRevision,
  }) async {
    _deletions.remove(id);
  }
}

class _MemoryAgentClientToolStore extends AgentClientToolStore {
  final Map<String, AgentClientToolReceipt> _receipts = {};
  final Map<String, AgentArticleReference> _references = {};
  final Set<String> _seededRuns = {};
  int _keySequence = 0;
  int _referenceSequence = 0;
  int prepareReclaimCalls = 0;
  int prepareLeaseReclaimCalls = 0;
  int acknowledgeCalls = 0;
  int revokeRunCalls = 0;
  int deleteRunCalls = 0;

  String _receiptKey(AgentToolRunBinding binding, String callId) =>
      '${binding.storageKey}\u0000$callId';

  String _referenceKey(AgentToolRunBinding binding, String articleRef) =>
      '${binding.storageKey}\u0000$articleRef';

  String _nextKey(String kind) => 'ct_${kind}_${++_keySequence}';

  void seedRun(AgentToolRunBinding binding) {
    _seededRuns.add(binding.storageKey);
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> cleanupExpired() async {}

  @override
  Future<AgentClientToolReceipt?> getReceipt({
    required AgentToolRunBinding binding,
    required String callId,
  }) async => _receipts[_receiptKey(binding, callId)];

  @override
  Future<List<AgentClientToolReceipt>> receiptsForRun(
    AgentToolRunBinding binding,
  ) async => List.unmodifiable(
    _receipts.values.where(
      (receipt) => receipt.binding.storageKey == binding.storageKey,
    ),
  );

  @override
  Future<AgentClientToolReceipt> beginClaimIntent({
    required AgentToolRunBinding binding,
    required String callId,
    required String tool,
    required Map<String, dynamic> arguments,
  }) async {
    final key = _receiptKey(binding, callId);
    final existing = _receipts[key];
    if (existing != null) return existing;
    final argumentsJson = canonicalJsonEncode(arguments);
    final receipt = AgentClientToolReceipt(
      binding: binding,
      callId: callId,
      tool: tool,
      argumentsJson: argumentsJson,
      argumentsHash: stablePayloadHash(argumentsJson),
      claimRequestKey: _nextKey('claim'),
      resultReceiptKey: _nextKey('result'),
      claimToken: null,
      leaseEpoch: null,
      result: null,
      state: 'claim_intent',
      expiresAt: DateTime.utc(2030),
    );
    _receipts[key] = receipt;
    return receipt;
  }

  AgentClientToolReceipt _rotate(AgentClientToolReceipt receipt) {
    final updated = receipt.copyWith(
      claimRequestKey: _nextKey('claim'),
      resultReceiptKey: _nextKey('result'),
      claimToken: null,
      leaseEpoch: null,
      state: 'claim_intent',
      acknowledged: false,
    );
    _receipts[_receiptKey(receipt.binding, receipt.callId)] = updated;
    return updated;
  }

  @override
  Future<AgentClientToolReceipt> prepareReclaim(
    AgentClientToolReceipt receipt,
  ) async {
    prepareReclaimCalls++;
    return _rotate(receipt);
  }

  @override
  Future<AgentClientToolReceipt> prepareLeaseReclaim(
    AgentClientToolReceipt receipt,
  ) async {
    prepareLeaseReclaimCalls++;
    return _rotate(receipt);
  }

  @override
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
    _receipts[_receiptKey(receipt.binding, receipt.callId)] = updated;
    return updated;
  }

  @override
  Future<AgentClientToolReceipt> recordResultReady({
    required AgentClientToolReceipt receipt,
    required Map<String, dynamic> result,
  }) async {
    final updated = receipt.copyWith(result: result, state: 'ready');
    _receipts[_receiptKey(receipt.binding, receipt.callId)] = updated;
    return updated;
  }

  @override
  Future<AgentClientToolReceipt> markSubmitting(
    AgentClientToolReceipt receipt,
  ) async {
    final updated = receipt.copyWith(state: 'submitting');
    _receipts[_receiptKey(receipt.binding, receipt.callId)] = updated;
    return updated;
  }

  @override
  Future<void> acknowledgeReceipt({
    required AgentToolRunBinding binding,
    required String callId,
  }) async {
    acknowledgeCalls++;
    _receipts.remove(_receiptKey(binding, callId));
  }

  @override
  Future<AgentArticleReference> createArticleReference({
    required AgentToolRunBinding binding,
    required String articleId,
    required String title,
    Duration ttl = AgentClientToolStore.defaultTtl,
  }) async {
    for (final reference in _references.values) {
      if (reference.binding.storageKey == binding.storageKey &&
          reference.articleId == articleId) {
        return reference;
      }
    }
    final suffix = '${++_referenceSequence}'.padLeft(22, 'A');
    final reference = AgentArticleReference(
      binding: binding,
      articleRef: 'ar_$suffix',
      articleId: articleId,
      title: title,
      expiresAt: DateTime.utc(2030),
    );
    _references[_referenceKey(binding, reference.articleRef)] = reference;
    return reference;
  }

  @override
  Future<AgentArticleReference?> resolveArticleReference({
    required AgentToolRunBinding binding,
    required String articleRef,
  }) async => _references[_referenceKey(binding, articleRef)];

  @override
  Future<Set<String>> ownedRunIds({
    required String ownerUserId,
    required String ownerDeviceId,
  }) async {
    final prefix = '$ownerUserId\u0000$ownerDeviceId\u0000';
    final storageKeys = <String>{
      ..._seededRuns.where((key) => key.startsWith(prefix)),
      ..._receipts.values
          .map((receipt) => receipt.binding.storageKey)
          .where((key) => key.startsWith(prefix)),
      ..._references.values
          .map((reference) => reference.binding.storageKey)
          .where((key) => key.startsWith(prefix)),
    };
    return storageKeys.map((key) => key.substring(prefix.length)).toSet();
  }

  @override
  Future<void> revokeRun(AgentToolRunBinding binding) async {
    revokeRunCalls++;
  }

  @override
  Future<void> deleteRun(AgentToolRunBinding binding) async {
    deleteRunCalls++;
    _seededRuns.remove(binding.storageKey);
    _receipts.removeWhere(
      (_, receipt) => receipt.binding.storageKey == binding.storageKey,
    );
    _references.removeWhere(
      (_, reference) => reference.binding.storageKey == binding.storageKey,
    );
  }
}

AuthSession _session({String tokenMarker = 'initial'}) => AuthSession(
  accessToken: _jwt(tokenMarker),
  refreshToken: 'refresh-$tokenMarker',
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

String _jwt(String marker) {
  final payload = base64Url.encode(
    utf8.encode(
      jsonEncode({
        'sessionId': '11111111-1111-4111-8111-111111111111',
        'deviceId': '22222222-2222-4222-8222-222222222222',
        'marker': marker,
      }),
    ),
  );
  return 'header.${payload.replaceAll('=', '')}.signature';
}

String _claimToken(int sequence) =>
    '00000000-0000-4000-8000-${sequence.toString().padLeft(12, '0')}';
