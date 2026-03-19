import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../data/models/source_platform.dart';

class UrlInputField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final SourcePlatform detectedPlatform;

  const UrlInputField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.detectedPlatform,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: controller,
          decoration: InputDecoration(
            labelText: 'URL',
            hintText: 'https://...',
            prefixIcon: const Icon(Icons.link),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.content_paste),
                  tooltip: 'Paste from clipboard',
                  onPressed: () async {
                    final data = await Clipboard.getData('text/plain');
                    if (data?.text != null) {
                      controller.text = data!.text!;
                      onChanged(data.text!);
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
              return 'Please enter a URL';
            }
            final uri = Uri.tryParse(value.trim());
            if (uri == null ||
                (uri.scheme != 'http' && uri.scheme != 'https')) {
              return 'Please enter a valid URL';
            }
            return null;
          },
        ),
        if (detectedPlatform != SourcePlatform.generic)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Icon(Icons.check_circle, size: 16, color: Colors.green[600]),
                const SizedBox(width: 4),
                Text(
                  'Detected: ${detectedPlatform.displayName}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.green[700],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
