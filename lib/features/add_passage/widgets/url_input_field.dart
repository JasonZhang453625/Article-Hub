import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/models/source_platform.dart';
import '../../../shared/providers/locale_provider.dart';

class UrlInputField extends ConsumerWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final SourcePlatform detectedPlatform;

  /// Called when reading the clipboard fails (e.g. permission denied), so the
  /// parent can surface a message. Optional.
  final VoidCallback? onPasteError;

  const UrlInputField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.detectedPlatform,
    this.onPasteError,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: controller,
          decoration: InputDecoration(
            labelText: s.urlLabel,
            hintText: s.urlHint,
            prefixIcon: const Icon(Icons.link),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.content_paste),
                  tooltip: s.pasteFromClipboard,
                  onPressed: () async {
                    try {
                      final data = await Clipboard.getData('text/plain');
                      final text = data?.text;
                      if (text != null && text.isNotEmpty) {
                        controller.text = text;
                        onChanged(text);
                      }
                    } catch (_) {
                      onPasteError?.call();
                    }
                  },
                ),
              ],
            ),
          ),
          keyboardType: TextInputType.url,
          autocorrect: false,
          onChanged: onChanged,
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return s.pleaseEnterUrl;
            }
            final uri = Uri.tryParse(value.trim());
            if (uri == null ||
                (uri.scheme != 'http' && uri.scheme != 'https')) {
              return s.pleaseEnterValidUrl;
            }
            return null;
          },
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeOutCubic,
          child: detectedPlatform == SourcePlatform.web
              ? const SizedBox.shrink()
              : Padding(
                  key: ValueKey(detectedPlatform),
                  padding: const EdgeInsets.only(top: 10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: detectedPlatform.accentColor.withValues(
                        alpha: 0.1,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          detectedPlatform.icon,
                          size: 18,
                          color: detectedPlatform.accentColor,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${s.detected}: ${detectedPlatform.displayName}',
                          style: TextStyle(
                            fontSize: 12,
                            color: detectedPlatform.accentColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
