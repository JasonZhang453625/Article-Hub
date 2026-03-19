import 'package:flutter/material.dart';
import '../../../data/models/passage.dart';
import '../../../data/models/source_platform.dart';
import '../../../shared/utils/date_formatter.dart';

class PassageCard extends StatelessWidget {
  final Passage passage;
  final VoidCallback onTap;
  final VoidCallback onInfoTap;

  const PassageCard({
    super.key,
    required this.passage,
    required this.onTap,
    required this.onInfoTap,
  });

  Color _platformColor(SourcePlatform platform) {
    switch (platform) {
      case SourcePlatform.wechat:
        return const Color(0xFF07C160);
      case SourcePlatform.zhihu:
        return const Color(0xFF0084FF);
      case SourcePlatform.generic:
        return const Color(0xFF6B7280);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 48,
                decoration: BoxDecoration(
                  color: _platformColor(passage.source),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      passage.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: _platformColor(passage.source)
                                .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            passage.source.displayName,
                            style: TextStyle(
                              fontSize: 11,
                              color: _platformColor(passage.source),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            formatRelative(passage.updatedAt),
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[500],
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (passage.tags.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: passage.tags.take(3).map((tag) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey[100],
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              tag,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[600],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.info_outline,
                  color: Colors.grey[400],
                  size: 20,
                ),
                onPressed: onInfoTap,
                tooltip: 'Details',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
