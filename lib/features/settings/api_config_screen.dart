import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/settings.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/utils/snackbar_helpers.dart';
import '../../shared/widgets/delayed_reveal.dart';
import 'settings_widgets.dart';

class ApiConfigScreen extends ConsumerStatefulWidget {
  const ApiConfigScreen({super.key});

  @override
  ConsumerState<ApiConfigScreen> createState() => _ApiConfigScreenState();
}

class _ApiConfigScreenState extends ConsumerState<ApiConfigScreen> {
  late final TextEditingController _aiBaseUrlCtrl, _aiApiKeyCtrl, _aiModelCtrl;
  late final TextEditingController _embBaseUrlCtrl, _embApiKeyCtrl, _embModelCtrl;
  late final TextEditingController _tavilyApiKeyCtrl;
  bool _aiSaving = false, _embSaving = false, _tavilySaving = false;

  @override
  void initState() {
    super.initState();
    _aiBaseUrlCtrl = TextEditingController(); _aiApiKeyCtrl = TextEditingController(); _aiModelCtrl = TextEditingController();
    _embBaseUrlCtrl = TextEditingController(); _embApiKeyCtrl = TextEditingController(); _embModelCtrl = TextEditingController();
    _tavilyApiKeyCtrl = TextEditingController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = ref.read(settingsProvider).valueOrNull;
    if (s != null) {
      _aiBaseUrlCtrl.text = s.aiBaseUrl; _aiApiKeyCtrl.text = s.aiApiKey; _aiModelCtrl.text = s.aiModel;
      _embBaseUrlCtrl.text = s.embeddingBaseUrl; _embApiKeyCtrl.text = s.embeddingApiKey; _embModelCtrl.text = s.embeddingModel;
      _tavilyApiKeyCtrl.text = s.tavilyApiKey;
    }
  }

  @override
  void dispose() {
    _aiBaseUrlCtrl.dispose(); _aiApiKeyCtrl.dispose(); _aiModelCtrl.dispose();
    _embBaseUrlCtrl.dispose(); _embApiKeyCtrl.dispose(); _embModelCtrl.dispose();
    _tavilyApiKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveAi() async {
    setState(() => _aiSaving = true);
    await ref.read(settingsProvider.notifier).setAiConfig(
      baseUrl: _aiBaseUrlCtrl.text.trim(), apiKey: _aiApiKeyCtrl.text.trim(), model: _aiModelCtrl.text.trim(),
    );
    if (mounted) {
      setState(() => _aiSaving = false);
      showAppSnackBar(context, message: ref.read(stringsProvider).aiSettingsSaved);
    }
  }



  Future<void> _saveEmb() async {
    setState(() => _embSaving = true);
    await ref.read(settingsProvider.notifier).setEmbeddingConfig(
      baseUrl: _embBaseUrlCtrl.text.trim(), apiKey: _embApiKeyCtrl.text.trim(), model: _embModelCtrl.text.trim(),
    );
    if (mounted) {
      setState(() => _embSaving = false);
      showAppSnackBar(context, message: ref.read(stringsProvider).aiSettingsSaved);
    }
  }

  Future<void> _saveTavily() async {
    setState(() => _tavilySaving = true);
    await ref.read(settingsProvider.notifier).setTavilyApiKey(
      _tavilyApiKeyCtrl.text.trim(),
    );
    if (mounted) {
      setState(() => _tavilySaving = false);
      showAppSnackBar(context, message: ref.read(stringsProvider).aiSettingsSaved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = theme.colorScheme.surface;
    final outlineColor = theme.colorScheme.outline;

    return Scaffold(
      appBar: AppBar(title: Text(s.apiConfig)),
      body: DelayedReveal(
        delayMs: 40, beginOffset: const Offset(0, 0.035),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SectionLabel(label: s.aiSummarySection, theme: theme),
            const SizedBox(height: 8),
            _ApiCard(icon: Icons.auto_awesome_rounded, title: s.aiSummarySection,
              fields: [
                _field(s.baseUrl, _aiBaseUrlCtrl, 'https://api.openai.com/v1'),
                _field(s.apiKey, _aiApiKeyCtrl, 'sk-...', obscured: true),
                _field(s.model, _aiModelCtrl, 'gpt-4o-mini'),
              ],
              saving: _aiSaving, onSave: _saveAi,
              theme: theme, cardColor: cardColor, outlineColor: outlineColor, isDark: isDark,
            ),
            const SizedBox(height: 14),
            SectionLabel(label: s.embeddingSection, theme: theme),
            const SizedBox(height: 8),
            _ApiCard(icon: Icons.dataset_rounded, title: s.embeddingConfig,
              fields: [
                _field(s.embeddingBaseUrl, _embBaseUrlCtrl, AppSettings.defaultEmbeddingBaseUrl),
                _field(s.embeddingApiKey, _embApiKeyCtrl, 'sk-...', obscured: true),
                _field(s.embeddingModel, _embModelCtrl, AppSettings.defaultEmbeddingModel),
              ],
              saving: _embSaving, onSave: _saveEmb,
              theme: theme, cardColor: cardColor, outlineColor: outlineColor, isDark: isDark,
            ),
            const SizedBox(height: 14),
            SectionLabel(label: s.webSearchSection, theme: theme),
            const SizedBox(height: 8),
            _ApiCard(icon: Icons.public_rounded, title: s.webSearchConfig,
              fields: [
                _field(s.webSearchApiKey, _tavilyApiKeyCtrl, 'tvly-...', obscured: true),
              ],
              saving: _tavilySaving, onSave: _saveTavily,
              theme: theme, cardColor: cardColor, outlineColor: outlineColor, isDark: isDark,
            ),
          ]),
        ),
      ),
    );
  }

  _Field _field(String label, TextEditingController ctrl, String hint, {bool obscured = false}) =>
      _Field(label: label, controller: ctrl, hint: hint, obscured: obscured);
}

class _Field {
  final String label; final TextEditingController controller; final String hint; final bool obscured;
  _Field({required this.label, required this.controller, required this.hint, this.obscured = false});
}

class _ApiCard extends StatelessWidget {
  final IconData icon; final String title; final List<_Field> fields;
  final bool saving; final VoidCallback onSave;
  final ThemeData theme; final Color cardColor; final Color outlineColor; final bool isDark;

  const _ApiCard({required this.icon, required this.title, required this.fields, required this.saving, required this.onSave, required this.theme, required this.cardColor, required this.outlineColor, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity, padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(24), border: Border.all(color: outlineColor.withValues(alpha: 0.3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(icon, size: 20, color: theme.colorScheme.primary), const SizedBox(width: 10), Text(title, style: theme.textTheme.titleMedium)]),
        const SizedBox(height: 16),
        for (final field in fields) ...[
          Text(field.label, style: theme.textTheme.labelLarge?.copyWith(color: isDark ? Colors.white70 : const Color(0xFF4A6678))),
          const SizedBox(height: 6),
          TextField(controller: field.controller, obscureText: field.obscured,
            decoration: InputDecoration(hintText: field.hint, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)), contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 14),
        ],
        SizedBox(width: double.infinity, child: FilledButton.icon(
          onPressed: saving ? null : onSave,
          icon: saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_rounded),
          label: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(saving ? '' : 'Save')),
        )),
      ]),
    );
  }
}
