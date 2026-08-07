import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/settings.dart';
import 'package:memora/data/services/auth_service.dart';
import 'package:memora/features/settings/api_config_screen.dart';
import 'package:memora/shared/providers/auth_provider.dart';
import 'package:memora/shared/providers/passage_providers.dart';
import 'package:memora/shared/providers/settings_providers.dart';

void main() {
  Future<ProviderContainer> pumpScreen(
    WidgetTester tester, {
    required AuthSession? session,
    required AppSettings settings,
  }) async {
    final auth = _TestAuthController(session);
    late final ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hiveInitProvider.overrideWith((ref) => Completer<void>().future),
          authControllerProvider.overrideWith((ref) => auth),
          languageIndexProvider.overrideWith((ref) => 2),
          settingsProvider.overrideWith((ref) {
            return _UiSettingsNotifier(ref, settings);
          }),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return const ApiConfigScreen();
            },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    return container;
  }

  testWidgets(
    'signed-out hosted switch is off, disabled, and shows BYOK cards',
    (tester) async {
      await pumpScreen(
        tester,
        session: null,
        settings: AppSettings(aiProviderMode: 1),
      );

      final tile = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('hosted-ai-switch')),
      );
      expect(tile.value, isFalse);
      expect(tile.onChanged, isNull);
      expect(find.text('Sign in to enable Memora hosted AI.'), findsOneWidget);
      expect(find.text('AI Chat'), findsOneWidget);
      expect(find.text('AI Memory'), findsOneWidget);
      expect(find.text('Image Understanding'), findsOneWidget);
      expect(find.text('Web Search (Tavily)'), findsOneWidget);
      expect(find.byKey(const ValueKey('hosted-chat-card')), findsNothing);
    },
  );

  testWidgets('signed-in user can enable hosted mode and see three selectors', (
    tester,
  ) async {
    final container = await pumpScreen(
      tester,
      session: _session(),
      settings: AppSettings(),
    );

    var tile = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('hosted-ai-switch')),
    );
    expect(tile.value, isFalse);
    expect(tile.onChanged, isNotNull);

    await tester.tap(find.byKey(const ValueKey('hosted-ai-switch')));
    await tester.pump(const Duration(milliseconds: 250));

    tile = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('hosted-ai-switch')),
    );
    expect(tile.value, isTrue);
    expect(container.read(settingsProvider).valueOrNull?.aiProviderMode, 1);
    expect(find.byKey(const ValueKey('hosted-chat-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('hosted-summary-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('hosted-vision-card')), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNWidgets(3));
    expect(find.text('Web Search (Tavily)'), findsNothing);
  });
}

class _UiSettingsNotifier extends SettingsNotifier {
  _UiSettingsNotifier(super.ref, AppSettings settings) {
    state = AsyncValue.data(settings);
  }

  @override
  Future<void> setAiProviderMode(
    int mode, {
    String? hostedModel,
    String? hostedChatModel,
    String? hostedVisionModel,
  }) async {
    final current = state.value!;
    state = AsyncValue.data(
      current.copyWith(
        aiProviderMode: mode == 1 ? 1 : 0,
        hostedAiModel: hostedModel,
        hostedChatModel: hostedChatModel,
        hostedVisionModel: hostedVisionModel,
      ),
    );
  }

  @override
  Future<void> setHostedAiModels({
    String? summaryModel,
    String? chatModel,
    String? visionModel,
  }) async {
    final current = state.value!;
    state = AsyncValue.data(
      current.copyWith(
        hostedAiModel: summaryModel,
        hostedChatModel: chatModel,
        hostedVisionModel: visionModel,
      ),
    );
  }
}

class _NeverAuthService extends AuthService {
  final Completer<AuthSession?> _session = Completer<AuthSession?>();

  @override
  Future<AuthSession?> loadSession() => _session.future;
}

class _TestAuthController extends AuthController {
  _TestAuthController(AuthSession? session) : super(_NeverAuthService()) {
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
