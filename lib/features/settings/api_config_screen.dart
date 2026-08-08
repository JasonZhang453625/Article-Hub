import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/settings.dart';
import '../../data/services/hosted_ai_capabilities.dart';
import '../../shared/providers/ai_providers.dart';
import '../../shared/providers/auth_provider.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/utils/snackbar_helpers.dart';
import '../../shared/widgets/animated_dropdown.dart';
import '../../shared/widgets/delayed_reveal.dart';
import 'settings_widgets.dart';

class ApiConfigScreen extends ConsumerStatefulWidget {
  const ApiConfigScreen({super.key});

  @override
  ConsumerState<ApiConfigScreen> createState() => _ApiConfigScreenState();
}

class _ApiConfigScreenState extends ConsumerState<ApiConfigScreen> {
  late final TextEditingController _aiBaseUrlCtrl, _aiApiKeyCtrl, _aiModelCtrl;
  late final TextEditingController _chatAiBaseUrlCtrl,
      _chatAiApiKeyCtrl,
      _chatAiModelCtrl;
  late final TextEditingController _imageAiBaseUrlCtrl,
      _imageAiApiKeyCtrl,
      _imageAiModelCtrl;
  bool _initialized = false;
  bool _modeSaving = false;
  bool _aiSaving = false;
  bool _chatAiSaving = false;
  bool _imageAiSaving = false;

  @override
  void initState() {
    super.initState();
    _aiBaseUrlCtrl = TextEditingController();
    _aiApiKeyCtrl = TextEditingController();
    _aiModelCtrl = TextEditingController();
    _chatAiBaseUrlCtrl = TextEditingController();
    _chatAiApiKeyCtrl = TextEditingController();
    _chatAiModelCtrl = TextEditingController();
    _imageAiBaseUrlCtrl = TextEditingController();
    _imageAiApiKeyCtrl = TextEditingController();
    _imageAiModelCtrl = TextEditingController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = ref.read(settingsProvider).valueOrNull;
    if (s != null) _initializeControllers(s);
  }

  void _initializeControllers(AppSettings settings) {
    if (_initialized) return;
    _initialized = true;
    _aiBaseUrlCtrl.text = settings.aiBaseUrl;
    _aiApiKeyCtrl.text = settings.aiApiKey;
    _aiModelCtrl.text = settings.aiModel;
    _chatAiBaseUrlCtrl.text = settings.chatAiBaseUrl;
    _chatAiApiKeyCtrl.text = settings.chatAiApiKey;
    _chatAiModelCtrl.text = settings.chatAiModel;
    _imageAiBaseUrlCtrl.text = settings.imageAiBaseUrl;
    _imageAiApiKeyCtrl.text = settings.imageAiApiKey;
    _imageAiModelCtrl.text = settings.imageAiModel;
  }

  @override
  void dispose() {
    _aiBaseUrlCtrl.dispose();
    _aiApiKeyCtrl.dispose();
    _aiModelCtrl.dispose();
    _chatAiBaseUrlCtrl.dispose();
    _chatAiApiKeyCtrl.dispose();
    _chatAiModelCtrl.dispose();
    _imageAiBaseUrlCtrl.dispose();
    _imageAiApiKeyCtrl.dispose();
    _imageAiModelCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveAi() async {
    setState(() => _aiSaving = true);
    await ref
        .read(settingsProvider.notifier)
        .setAiConfig(
          baseUrl: _aiBaseUrlCtrl.text.trim(),
          apiKey: _aiApiKeyCtrl.text.trim(),
          model: _aiModelCtrl.text.trim(),
        );
    if (mounted) {
      setState(() => _aiSaving = false);
      showAppSnackBar(
        context,
        message: ref.read(stringsProvider).aiSettingsSaved,
      );
    }
  }

  Future<void> _saveChatAi() async {
    setState(() => _chatAiSaving = true);
    await ref
        .read(settingsProvider.notifier)
        .setChatAiConfig(
          baseUrl: _chatAiBaseUrlCtrl.text.trim(),
          apiKey: _chatAiApiKeyCtrl.text.trim(),
          model: _chatAiModelCtrl.text.trim(),
        );
    if (mounted) {
      setState(() => _chatAiSaving = false);
      showAppSnackBar(
        context,
        message: ref.read(stringsProvider).aiSettingsSaved,
      );
    }
  }

  Future<void> _saveImageAi() async {
    setState(() => _imageAiSaving = true);
    await ref
        .read(settingsProvider.notifier)
        .setImageAiConfig(
          baseUrl: _imageAiBaseUrlCtrl.text.trim(),
          apiKey: _imageAiApiKeyCtrl.text.trim(),
          model: _imageAiModelCtrl.text.trim(),
        );
    if (mounted) {
      setState(() => _imageAiSaving = false);
      showAppSnackBar(
        context,
        message: ref.read(stringsProvider).aiSettingsSaved,
      );
    }
  }

  Future<void> _toggleHosted(bool enabled) async {
    if (_modeSaving || ref.read(currentSessionProvider) == null) return;
    setState(() => _modeSaving = true);
    await ref
        .read(settingsProvider.notifier)
        .setAiProviderMode(enabled ? 1 : 0);
    if (mounted) setState(() => _modeSaving = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    if (settings != null) _initializeControllers(settings);
    final isLoggedIn = ref.watch(currentSessionProvider) != null;
    final hostedEnabled = isLoggedIn && settings?.aiProviderMode == 1;
    final capabilities =
        ref.watch(hostedAiCapabilitiesProvider).valueOrNull ??
            const HostedAiCapabilities(
              chatModels: [],
              summaryModels: [],
              visionModels: [],
            );
    final chatModelOptions = hostedTextModelOptions(
      serverModels: capabilities.chatModels,
      builtInModels: AppSettings.hostedTextModels,
    );
    final summaryModelOptions = hostedTextModelOptions(
      serverModels: capabilities.summaryModels,
      builtInModels: AppSettings.hostedTextModels,
    );
    final visionModelOptions = hostedTextModelOptions(
      serverModels: capabilities.visionModels,
      builtInModels: AppSettings.hostedVisionModels,
    );
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = theme.colorScheme.surface;
    final outlineColor = theme.colorScheme.outline;

    return Scaffold(
      appBar: AppBar(title: Text(s.apiConfig)),
      body: DelayedReveal(
        delayMs: 40,
        beginOffset: const Offset(0, 0.035),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: outlineColor.withValues(alpha: 0.3),
                  ),
                ),
                child: SwitchListTile.adaptive(
                  key: const ValueKey('hosted-ai-switch'),
                  value: hostedEnabled,
                  onChanged: !isLoggedIn || _modeSaving ? null : _toggleHosted,
                  title: Text(
                    s.aiModeHosted,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: isLoggedIn ? null : theme.disabledColor,
                    ),
                  ),
                  subtitle: Text(
                    isLoggedIn ? s.aiModeHostedDesc : s.aiModeLoginRequired,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: isLoggedIn ? null : theme.disabledColor,
                    ),
                  ),
                  secondary: _modeSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          Icons.cloud_rounded,
                          color: isLoggedIn
                              ? theme.colorScheme.primary
                              : theme.disabledColor,
                        ),
                ),
              ),
              const SizedBox(height: 14),
              SectionLabel(
                label: hostedEnabled ? s.aiModeHosted : s.aiModeByok,
                theme: theme,
              ),
              const SizedBox(height: 8),
              if (hostedEnabled && settings != null) ...[
                _HostedModelCard(
                  key: const ValueKey('hosted-chat-card'),
                  icon: Icons.chat_bubble_rounded,
                  title: s.chatAiSection,
                  label: s.hostedModelLabel,
                  value: _hostedTextValue(
                    settings.hostedChatModel,
                    chatModelOptions,
                  ),
                  options: chatModelOptions,
                  onChanged: (value) {
                    if (value != null) {
                      ref
                          .read(settingsProvider.notifier)
                          .setHostedAiModels(chatModel: value);
                    }
                  },
                  theme: theme,
                  cardColor: cardColor,
                  outlineColor: outlineColor,
                ),
                const SizedBox(height: 14),
                _HostedModelCard(
                  key: const ValueKey('hosted-summary-card'),
                  icon: Icons.auto_awesome_rounded,
                  title: s.aiSummarySection,
                  label: s.hostedModelLabel,
                  value: _hostedTextValue(
                    settings.hostedAiModel,
                    summaryModelOptions,
                  ),
                  options: summaryModelOptions,
                  onChanged: (value) {
                    if (value != null) {
                      ref
                          .read(settingsProvider.notifier)
                          .setHostedAiModels(summaryModel: value);
                    }
                  },
                  theme: theme,
                  cardColor: cardColor,
                  outlineColor: outlineColor,
                ),
                const SizedBox(height: 14),
                _HostedModelCard(
                  key: const ValueKey('hosted-vision-card'),
                  icon: Icons.image_search_rounded,
                  title: s.imageAiSection,
                  label: s.hostedModelLabel,
                  value: _hostedVisionValue(
                    settings.hostedVisionModel,
                    visionModelOptions,
                  ),
                  options: visionModelOptions,
                  onChanged: (value) {
                    if (value != null) {
                      ref
                          .read(settingsProvider.notifier)
                          .setHostedAiModels(visionModel: value);
                    }
                  },
                  theme: theme,
                  cardColor: cardColor,
                  outlineColor: outlineColor,
                ),
                const SizedBox(height: 10),
              ] else ...[
                _ApiCard(
                  icon: Icons.chat_bubble_rounded,
                  title: s.chatAiSection,
                  fields: [
                    _field(
                      s.baseUrl,
                      _chatAiBaseUrlCtrl,
                      'https://api.openai.com/v1',
                    ),
                    _field(
                      s.apiKey,
                      _chatAiApiKeyCtrl,
                      'sk-...',
                      obscured: true,
                    ),
                    _field(s.model, _chatAiModelCtrl, 'gpt-4o-mini'),
                  ],
                  saving: _chatAiSaving,
                  onSave: _saveChatAi,
                  saveLabel: s.saveAiSettings,
                  theme: theme,
                  cardColor: cardColor,
                  outlineColor: outlineColor,
                  isDark: isDark,
                ),
                const SizedBox(height: 14),
                _ApiCard(
                  icon: Icons.auto_awesome_rounded,
                  title: s.aiSummarySection,
                  fields: [
                    _field(
                      s.baseUrl,
                      _aiBaseUrlCtrl,
                      'https://api.openai.com/v1',
                    ),
                    _field(s.apiKey, _aiApiKeyCtrl, 'sk-...', obscured: true),
                    _field(s.model, _aiModelCtrl, 'gpt-4o-mini'),
                  ],
                  saving: _aiSaving,
                  onSave: _saveAi,
                  saveLabel: s.saveAiSettings,
                  theme: theme,
                  cardColor: cardColor,
                  outlineColor: outlineColor,
                  isDark: isDark,
                ),
                const SizedBox(height: 14),
                _ApiCard(
                  icon: Icons.image_search_rounded,
                  title: s.imageAiSection,
                  fields: [
                    _field(
                      s.baseUrl,
                      _imageAiBaseUrlCtrl,
                      'https://api.openai.com/v1',
                    ),
                    _field(
                      s.apiKey,
                      _imageAiApiKeyCtrl,
                      'sk-...',
                      obscured: true,
                    ),
                    _field(s.model, _imageAiModelCtrl, 'mimo-v2.5'),
                  ],
                  saving: _imageAiSaving,
                  onSave: _saveImageAi,
                  saveLabel: s.saveAiSettings,
                  theme: theme,
                  cardColor: cardColor,
                  outlineColor: outlineColor,
                  isDark: isDark,
                ),
              ],
              const SizedBox(height: 14),
              SectionLabel(label: s.embeddingSection, theme: theme),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  s.usingBuiltIn,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _Field _field(
    String label,
    TextEditingController ctrl,
    String hint, {
    bool obscured = false,
  }) => _Field(label: label, controller: ctrl, hint: hint, obscured: obscured);

  String _hostedTextValue(String value, List<String> options) {
    return options.contains(value) ? value : AppSettings.defaultHostedTextModel;
  }

  String _hostedVisionValue(String value, List<String> options) {
    return options.contains(value)
        ? value
        : AppSettings.defaultHostedVisionModel;
  }
}

class _Field {
  final String label;
  final TextEditingController controller;
  final String hint;
  final bool obscured;
  _Field({
    required this.label,
    required this.controller,
    required this.hint,
    this.obscured = false,
  });
}

class _ApiCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<_Field> fields;
  final bool saving;
  final VoidCallback onSave;
  final String saveLabel;
  final ThemeData theme;
  final Color cardColor;
  final Color outlineColor;
  final bool isDark;

  const _ApiCard({
    required this.icon,
    required this.title,
    required this.fields,
    required this.saving,
    required this.onSave,
    required this.saveLabel,
    required this.theme,
    required this.cardColor,
    required this.outlineColor,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
            ],
          ),
          const SizedBox(height: 16),
          for (final field in fields) ...[
            Text(
              field.label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: isDark ? Colors.white70 : const Color(0xFF4A6678),
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: field.controller,
              obscureText: field.obscured,
              decoration: InputDecoration(
                hintText: field.hint,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
          ],
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: saving ? null : onSave,
              icon: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_rounded),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(saving ? '' : saveLabel),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HostedModelCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String?> onChanged;
  final ThemeData theme;
  final Color cardColor;
  final Color outlineColor;

  const _HostedModelCard({
    super.key,
    required this.icon,
    required this.title,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.theme,
    required this.cardColor,
    required this.outlineColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
            ],
          ),
          const SizedBox(height: 16),
          AnimatedDropdownButton<String>(
            key: ValueKey('hosted-model-$title-$value'),
            value: value,
            options: options,
            hint: label,
            labelOf: (v) => v,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
