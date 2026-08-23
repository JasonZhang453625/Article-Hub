import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:memora/data/services/auth_service.dart';
import 'package:memora/data/services/hosted_ai_capabilities.dart';

void main() {
  group('HostedAiCapabilities.fromJson', () {
    test('parses text, vision, and Agent image capabilities', () {
      final capabilities = HostedAiCapabilities.fromJson({
        'chat': {
          'models': ['mimo-v2.5', 'deepseek-v4-flash'],
          'available': true,
        },
        'summary': {
          'models': ['mimo-v2.5-pro'],
          'available': true,
        },
        'image': {
          'providers': [
            {
              'provider': 'mimo',
              'models': ['mimo-v2.5'],
              'available': true,
            },
            {
              'provider': 'sensenova',
              'models': ['sensenova-6.7-flash-lite'],
              'available': false,
            },
          ],
        },
        'agent': {
          'available': true,
          'protocolVersion': 2,
          'imageInput': {
            'models': ['mimo-v2.5'],
            'mimeTypes': ['image/png', 'image/jpeg'],
            'maxImages': 4,
            'maxImageBytes': 5242880,
            'maxTotalImageBytes': 12582912,
            'maxBodyBytes': 18874368,
          },
        },
      });

      expect(capabilities.chatModels, ['mimo-v2.5', 'deepseek-v4-flash']);
      expect(capabilities.summaryModels, ['mimo-v2.5-pro']);
      // Unavailable providers must not contribute models.
      expect(capabilities.visionModels, ['mimo-v2.5']);
      expect(capabilities.hasServerChatModels, isTrue);
      expect(capabilities.agentAvailable, isTrue);
      expect(capabilities.agentProtocolVersion, 2);
      expect(capabilities.agentImageInput?.models, ['mimo-v2.5']);
      expect(capabilities.agentImageInput?.maxImages, 4);
      expect(
        hostedAgentImageInputForModel(capabilities, 'MIMO-V2.5'),
        same(capabilities.agentImageInput),
      );
    });

    test('handles malformed payloads without throwing', () {
      final capabilities = HostedAiCapabilities.fromJson({
        'chat': {'models': 'not-a-list'},
        'summary': null,
      });

      expect(capabilities.chatModels, isEmpty);
      expect(capabilities.summaryModels, isEmpty);
      expect(capabilities.visionModels, isEmpty);
      expect(capabilities.hasServerChatModels, isFalse);
      expect(capabilities.agentAvailable, isFalse);
      expect(capabilities.agentImageInput, isNull);
    });

    test('fails closed for Agent protocol v1 and unsupported models', () {
      final protocolV1 = HostedAiCapabilities.fromJson({
        'agent': {
          'available': true,
          'protocolVersion': 1,
          'imageInput': {
            'models': ['mimo-v2.5'],
            'mimeTypes': ['image/png'],
            'maxImages': 4,
            'maxImageBytes': 5242880,
            'maxTotalImageBytes': 12582912,
            'maxBodyBytes': 18874368,
          },
        },
      });
      final protocolV2 = HostedAiCapabilities.fromJson({
        'agent': {
          'available': true,
          'protocolVersion': 2,
          'imageInput': {
            'models': ['mimo-v2.5'],
            'mimeTypes': ['image/png'],
            'maxImages': 2,
            'maxImageBytes': 1024,
            'maxTotalImageBytes': 2048,
            'maxBodyBytes': 4096,
          },
        },
      });

      expect(hostedAgentImageInputForModel(protocolV1, 'mimo-v2.5'), isNull);
      expect(
        hostedAgentImageInputForModel(protocolV2, 'deepseek-v4-flash'),
        isNull,
      );
      expect(
        hostedAgentImageInputForModel(protocolV2, 'mimo-v2.5')?.maxImages,
        2,
      );
    });

    test('parses only the protocol-v4 durable task contract', () {
      final capabilities = HostedAiCapabilities.fromJson({
        'agent': {
          'available': true,
          'protocolVersion': 4,
          'tasks': {
            'version': 1,
            'createEndpoint': '/ai/tasks/runs',
            'maxBodyBytes': 2097152,
            'profiles': [
              {
                'id': 'summary.final',
                'version': 1,
                'resultSchemaVersion': 1,
                'durable': true,
                'requiresImages': false,
                'models': ['mimo-v2.5-pro'],
                'available': true,
              },
              {
                'id': 'image.understand',
                'version': 1,
                'resultSchemaVersion': 1,
                'durable': false,
                'requiresImages': true,
                'models': ['mimo-v2.5'],
                'available': true,
              },
            ],
          },
        },
      });

      expect(capabilities.agentTasks?.version, 1);
      expect(
        capabilities.agentTasks?.profileForModel(
          'summary.final',
          'MIMO-V2.5-PRO',
        ),
        isNotNull,
      );
      expect(
        capabilities.agentTasks?.profileForModel(
          'image.understand',
          'mimo-v2.5',
        ),
        isNull,
        reason: 'durable text task negotiation must exclude image profiles',
      );
    });

    test('parses only the exact memora.chat@2 provenance contract', () {
      HostedAiCapabilities parse(Map<String, dynamic> chatRuns) {
        return HostedAiCapabilities.fromJson({
          'agent': {
            'available': true,
            'protocolVersion': 4,
            'chatRuns': chatRuns,
          },
        });
      }

      final exact = parse(_chatRunsV2());
      expect(exact.agentChatRuns, isNotNull);
      expect(exact.agentChatRuns?.models, ['mimo-v2.5']);
      expect(
        hostedChatRunsForModel(exact, 'MIMO-V2.5'),
        same(exact.agentChatRuns),
      );

      final stalePrompt = _chatRunsV2();
      (stalePrompt['promptSpec'] as Map<String, dynamic>)['version'] = 1;
      (stalePrompt['promptSpec'] as Map<String, dynamic>)['wire'] =
          'memora.chat@1';
      expect(parse(stalePrompt).agentChatRuns, isNull);

      final missingHistoryRule = _chatRunsV2();
      final fields = missingHistoryRule['fields'] as Map<String, dynamic>;
      final historyMessage = Map<String, dynamic>.from(
        fields['historyMessage'] as Map,
      )..remove('monotonicRule');
      fields['historyMessage'] = historyMessage;
      expect(parse(missingHistoryRule).agentChatRuns, isNull);

      final unsafePrivacy = _chatRunsV2();
      (unsafePrivacy['privacy']
              as Map<String, dynamic>)['historyPrivateEvidenceWithWebSearch'] =
          true;
      expect(parse(unsafePrivacy).agentChatRuns, isNull);

      final missingResult = _chatRunsV2()..remove('resultFields');
      expect(parse(missingResult).agentChatRuns, isNull);
    });

    test('fails closed for stale or malformed task capability contracts', () {
      HostedAiCapabilities parse(int protocol, String endpoint) {
        return HostedAiCapabilities.fromJson({
          'agent': {
            'available': true,
            'protocolVersion': protocol,
            'tasks': {
              'version': 1,
              'createEndpoint': endpoint,
              'maxBodyBytes': 2097152,
              'profiles': [
                {
                  'id': 'summary.final',
                  'version': 1,
                  'resultSchemaVersion': 1,
                  'durable': true,
                  'requiresImages': false,
                  'models': ['mimo-v2.5-pro'],
                  'available': true,
                },
              ],
            },
          },
        });
      }

      expect(parse(3, '/ai/tasks/runs').agentTasks, isNull);
      expect(parse(4, '/wrong').agentTasks, isNull);
    });

    test('fails closed when protocol-v4 agent is unavailable', () {
      final capabilities = HostedAiCapabilities.fromJson({
        'agent': {
          'available': false,
          'protocolVersion': 4,
          'tasks': {
            'version': 1,
            'createEndpoint': '/ai/tasks/runs',
            'maxBodyBytes': 2097152,
            'profiles': [
              {
                'id': 'summary.final',
                'version': 1,
                'resultSchemaVersion': 1,
                'durable': true,
                'requiresImages': false,
                'models': ['mimo-v2.5-pro'],
                'available': true,
              },
            ],
          },
        },
      });

      expect(capabilities.agentAvailable, isFalse);
      expect(capabilities.agentTasks, isNull);
    });
  });

  group('hostedTextModelOptions', () {
    test('prefers server models over built-ins', () {
      expect(
        hostedTextModelOptions(
          serverModels: ['deepseek-v4-flash'],
          builtInModels: ['mimo-v2.5'],
        ),
        ['deepseek-v4-flash'],
      );
    });

    test('falls back to built-ins when server list is empty', () {
      expect(
        hostedTextModelOptions(
          serverModels: const [],
          builtInModels: ['mimo-v2.5'],
        ),
        ['mimo-v2.5'],
      );
    });
  });

  group('HostedAiCapabilitiesService', () {
    test('returns server models on success', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/ai/capabilities');
        expect(request.headers['Authorization'], 'Bearer test-token');
        return http.Response(
          jsonEncode({
            'chat': {
              'models': ['mimo-v2.5', 'deepseek-v4-flash'],
              'available': true,
            },
            'summary': {
              'models': ['mimo-v2.5', 'deepseek-v4-flash'],
              'available': true,
            },
            'image': {'providers': []},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final service = HostedAiCapabilitiesService(
        getSession: () => _session(),
        client: client,
      );
      final capabilities = await service.fetch();
      expect(capabilities.chatModels, ['mimo-v2.5', 'deepseek-v4-flash']);
    });

    test('returns empty capabilities when signed out', () async {
      final service = HostedAiCapabilitiesService(getSession: () => null);
      final capabilities = await service.fetch();
      expect(capabilities.chatModels, isEmpty);
      expect(capabilities.hasServerChatModels, isFalse);
    });

    test('bounded retry recovers from transient capability failures', () async {
      var calls = 0;
      final service = HostedAiCapabilitiesService(
        getSession: _session,
        client: MockClient((_) async {
          calls++;
          if (calls < 3) return http.Response('{}', 503);
          return http.Response(
            jsonEncode({
              'chat': {
                'models': ['mimo-v2.5'],
              },
            }),
            200,
          );
        }),
      );

      final result = await service.fetchWithRetry(initialDelay: Duration.zero);

      expect(calls, 3);
      expect(result.chatModels, ['mimo-v2.5']);
    });
  });

  group('HostedAiCapabilitiesCache', () {
    test('reports freshness within TTL and expires after', () async {
      final cache = HostedAiCapabilitiesCache();
      expect(cache.isFresh, isFalse);
      expect(cache.value, isNull);

      cache.store(
        const HostedAiCapabilities(
          chatModels: ['deepseek-v4-flash'],
          summaryModels: ['deepseek-v4-flash'],
          visionModels: ['mimo-v2.5'],
        ),
      );
      expect(cache.isFresh, isTrue);
      expect(cache.value!.chatModels, ['deepseek-v4-flash']);
    });

    test('does not reuse a fresh cache entry across account scopes', () {
      final cache = HostedAiCapabilitiesCache();
      cache.store(
        const HostedAiCapabilities(
          chatModels: ['mimo-v2.5'],
          summaryModels: [],
          visionModels: [],
        ),
        scope: 'user-a-device-a',
      );

      expect(cache.isFreshFor('user-a-device-a'), isTrue);
      expect(cache.isFreshFor('user-b-device-b'), isFalse);
    });
  });
}

AuthSession _session() {
  return const AuthSession(
    accessToken: 'test-token',
    refreshToken: 'test-refresh',
    refreshTokenExpiresAt: null,
    user: AuthUser(
      id: 'user-1',
      email: 'user@example.com',
      displayName: null,
      status: 'active',
      plan: 'free',
      storageUsedBytes: '0',
    ),
    device: AuthDevice(
      id: 'device-1',
      userId: 'user-1',
      deviceName: 'Test device',
      platform: 'test',
      appVersion: '1.0.0',
    ),
  );
}

Map<String, dynamic> _chatRunsV2() {
  return {
    'protocolVersion': 4,
    'createEndpoint': '/ai/chat/runs',
    'durable': true,
    'promptSpec': {'id': 'memora.chat', 'version': 2, 'wire': 'memora.chat@2'},
    'models': ['mimo-v2.5'],
    'available': true,
    'fields': {
      'knowledgeMode': ['only', 'hybrid'],
      'length': ['concise', 'detailed'],
      'language': ['follow-user', 'zh-CN', 'en'],
      'webSearch': 'boolean',
      'localKnowledge': 'boolean',
      'historyMessage': {
        'fields': ['role', 'content', 'private_evidence'],
        'roles': ['user', 'assistant'],
        'privateEvidence': 'boolean',
        'pairRule': 'same_value_on_completed_user_assistant_pair',
        'monotonicRule': 'true_remains_true_for_all_later_pairs',
      },
    },
    'resultFields': {'privateEvidenceUsed': 'boolean'},
    'lengthTokenLimits': {'concise': 1000, 'detailed': 2500},
    'limits': {
      'maxBodyBytes': 18874368,
      'maxQuestionChars': 20000,
      'maxHistoryMessages': 20,
      'maxHistoryMessageChars': 8000,
      'maxHistoryChars': 120000,
      'maxAttachments': 4,
      'maxAttachmentIdChars': 128,
      'maxAttachmentNameChars': 256,
      'maxAttachmentTextChars': 100000,
      'maxTotalAttachmentTextChars': 200000,
      'maxPromptChars': 250000,
      'maxImages': 4,
      'maxImageBytes': 5242880,
      'maxTotalImageBytes': 12582912,
    },
    'privacy': {
      'attachmentsWithWebSearch': false,
      'imagesWithWebSearch': false,
      'historyPrivateEvidenceWithWebSearch': false,
      'privateEvidencePropagation': 'transitive',
      'enforcement': 'fail-closed',
    },
  };
}
