import 'package:flutter/material.dart';

class TagInput extends StatelessWidget {
  final TextEditingController controller;
  final List<String> tags;
  final ValueChanged<String> onAdd;
  final ValueChanged<String> onRemove;

  const TagInput({
    super.key,
    required this.controller,
    required this.tags,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: controller,
          decoration: InputDecoration(
            labelText: 'Tags',
            hintText: 'Type and press Enter to add',
            prefixIcon: const Icon(Icons.tag),
            suffixIcon: IconButton(
              icon: const Icon(Icons.add),
              onPressed: () {
                final text = controller.text.trim();
                if (text.isNotEmpty) {
                  onAdd(text);
                  controller.clear();
                }
              },
            ),
          ),
          onFieldSubmitted: (value) {
            final text = value.trim();
            if (text.isNotEmpty) {
              onAdd(text);
              controller.clear();
            }
          },
        ),
        if (tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: tags.map((tag) {
                return Chip(
                  label: Text(tag),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: () => onRemove(tag),
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
          ),
      ],
    );
  }
}
