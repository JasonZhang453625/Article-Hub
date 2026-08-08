import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:memora/data/models/settings.dart';
import 'package:memora/data/services/auth_service.dart';
import 'package:memora/data/services/hosted_ai_capabilities.dart';
import 'package:memora/shared/providers/auth_provider.dart';
import 'package:memora/shared/providers/passage_providers.dart';
import 'package:memora/shared/providers/settings_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('memora-ai-settings-');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(AppSettings.typeId)) {
      Hive.registerAdapter(AppSettingsAdapter());
    }
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('new model fields persist through the Hive adapter', () async {
    final box = await Hive.openBox<AppSettings>('model-fields');
    final settings = AppSettings(
      chatAiBaseUrl: 'https://chat.example/v1',
      chatAiApiKey: 'chat-secret',
      chatAiModel: 'chat-model',
      imageAiBaseUrl: 'https://vision.example/v1',
      imageAiApiKey: 'vision-secret',
      imageAiModel: 'vision-model',
      aiProviderMode: 1,
      hostedAiModel: 'mimo-v2.5-pro',
      hostedChatModel: 'mimo-v2.5',
      hostedVisionModel: 'sensenova-6.7-flash-lite',
    );

    await box.put('settings', settings);
    final restored = box.get('settings')!;

    expect(restored.chatAiBaseUrl, settings.chatAiBaseUrl);
    expect(restored.chatAiApiKey, settings.chatAiApiKey);
    expect(restored.chatAiModel, settings.chatAiModel);
    expect(restored.imageAiBaseUrl, settings.imageAiBaseUrl);
    expect(restored.imageAiApiKey, settings.imageAiApiKey);
    expect(restored.imageAiModel, settings.imageAiModel);
    expect(restored.hostedAiModel, settings.hostedAiModel);
    expect(restored.hostedChatModel, settings.hostedChatModel);
    expect(restored.hostedVisionModel, settings.hostedVisionModel);
  });

  test(
    'auth loading preserves hosted mode, then logout persists BYOK',
    () async {
      final box = await Hive.openBox<AppSettings>('app_settings');
      await box.put('settings', AppSettings(aiProviderMode: 1));
      final auth = _ControllableAuthController(const AsyncValue.loading());
      final container = ProviderContainer(
        overrides: [
          hiveInitProvider.overrideWith((ref) async {}),
          authControllerProvider.overrideWith((ref) => auth),
        ],
      );
      addTearDown(container.dispose);

      await _waitFor(
        () => container.read(settingsProvider).valueOrNull != null,
      );
      expect(container.read(settingsProvider).value!.aiProviderMode, 1);

      auth.setSession(_session());
      await Future<void>.delayed(Duration.zero);
      expect(container.read(settingsProvider).value!.aiProviderMode, 1);

      auth.setSession(null);
      await _waitFor(
        () => container.read(settingsProvider).valueOrNull?.aiProviderMode == 0,
      );
      expect(box.get('settings')!.aiProviderMode, 0);

      await container.read(settingsProvider.notifier).setAiProviderMode(1);
      expect(container.read(settingsProvider).value!.aiProviderMode, 0);
    },
  );

  test('server-advertised deepseek model persists through hosted setters', () async {
    HostedAiCapabilitiesCache.instance.store(
      const HostedAiCapabilities(
        chatModels: [
          'mimo-v2.5',
          'mimo-v2.5-pro',
          'deepseek-v4-flash',
          'deepseek-v4-pro',
        ],
        summaryModels: [
          'mimo-v2.5',
          'mimo-v2.5-pro',
          'deepseek-v4-flash',
          'deepseek-v4-pro',
        ],
        visionModels: ['mimo-v2.5', 'sensenova-6.7-flash-lite'],
      ),
    );
    addTearDown(HostedAiCapabilitiesCache.instance.clear);

    final box = await Hive.openBox<AppSettings>('app_settings');
    await box.put('settings', AppSettings());
    final auth = _ControllableAuthController(AsyncValue.data(_session()));
    final container = ProviderContainer(
      overrides: [
        hiveInitProvider.overrideWith((ref) async {}),
        authControllerProvider.overrideWith((ref) => auth),
      ],
    );
    addTearDown(container.dispose);

    await _waitFor(
      () => container.read(settingsProvider).valueOrNull != null,
    );

    await container.read(settingsProvider.notifier).setAiProviderMode(
      1,
      hostedChatModel: 'deepseek-v4-flash',
      hostedModel: 'deepseek-v4-flash',
    );
    expect(
      container.read(settingsProvider).value!.hostedChatModel,
      'deepseek-v4-flash',
    );
    expect(
      container.read(settingsProvider).value!.hostedAiModel,
      'deepseek-v4-flash',
    );

    await container
        .read(settingsProvider.notifier)
        .setHostedAiModels(summaryModel: 'deepseek-v4-pro');
    expect(
      container.read(settingsProvider).value!.hostedAiModel,
      'deepseek-v4-pro',
    );
    expect(box.get('settings')!.hostedAiModel, 'deepseek-v4-pro');
  });
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for provider state');
}

class _NeverAuthService extends AuthService {
  final Completer<AuthSession?> _session = Completer<AuthSession?>();

  @override
  Future<AuthSession?> loadSession() => _session.future;
}

class _ControllableAuthController extends AuthController {
  _ControllableAuthController(AsyncValue<AuthSession?> initial)
    : super(_NeverAuthService()) {
    state = initial;
  }

  void setSession(AuthSession? session) {
    state = AsyncValue.data(session);
  }
}

AuthSession _session() {
  return const AuthSession(
    accessToken: 'test-access-token',
    refreshToken: 'test-refresh-token',
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
