import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:memora/data/services/auth_service.dart';
import 'package:memora/data/services/hosted_ai_capabilities.dart';

void main() {
  group('HostedAiCapabilities.fromJson', () {
    test('parses chat, summary and vision model lists', () {
      final capabilities = HostedAiCapabilities.fromJson({
        'chat': {'models': ['mimo-v2.5', 'deepseek-v4-flash'], 'available': true},
        'summary': {'models': ['mimo-v2.5-pro'], 'available': true},
        'image': {
          'providers': [
            {'provider': 'mimo', 'models': ['mimo-v2.5'], 'available': true},
            {
              'provider': 'sensenova',
              'models': ['sensenova-6.7-flash-lite'],
              'available': false,
            },
          ],
        },
      });

      expect(capabilities.chatModels,
          ['mimo-v2.5', 'deepseek-v4-flash']);
      expect(capabilities.summaryModels, ['mimo-v2.5-pro']);
      // Unavailable providers must not contribute models.
      expect(capabilities.visionModels, ['mimo-v2.5']);
      expect(capabilities.hasServerChatModels, isTrue);
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
            'chat': {'models': ['mimo-v2.5', 'deepseek-v4-flash'], 'available': true},
            'summary': {'models': ['mimo-v2.5', 'deepseek-v4-flash'], 'available': true},
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
      expect(
        capabilities.chatModels,
        ['mimo-v2.5', 'deepseek-v4-flash'],
      );
    });

    test('returns empty capabilities when signed out', () async {
      final service = HostedAiCapabilitiesService(getSession: () => null);
      final capabilities = await service.fetch();
      expect(capabilities.chatModels, isEmpty);
      expect(capabilities.hasServerChatModels, isFalse);
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
