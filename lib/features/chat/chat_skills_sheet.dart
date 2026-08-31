import 'package:flutter/material.dart';

import '../../data/services/hosted_agent_service.dart';
import '../../shared/utils/locale_strings.dart';

/// Selects a subset of the active backend revision's official Pi Skills.
///
/// The App receives only names/descriptions. Skill paths, bodies, loading and
/// execution stay server-owned so the mobile client cannot invent resources.
class ChatSkillsSheet extends StatefulWidget {
  final LocaleStrings s;
  final Future<HostedAgentSkillCatalog> Function() loadCatalog;
  final Set<String>? initialSelection;

  const ChatSkillsSheet({
    super.key,
    required this.s,
    required this.loadCatalog,
    required this.initialSelection,
  });

  @override
  State<ChatSkillsSheet> createState() => _ChatSkillsSheetState();
}

class _ChatSkillsSheetState extends State<ChatSkillsSheet> {
  late Future<HostedAgentSkillCatalog> _catalog;
  Set<String>? _selection;
  int? _selectionRevision;

  @override
  void initState() {
    super.initState();
    _catalog = widget.loadCatalog();
  }

  void _retry() {
    setState(() {
      _catalog = widget.loadCatalog();
      _selection = null;
      _selectionRevision = null;
    });
  }

  Set<String> _selectionFor(HostedAgentSkillCatalog catalog) {
    if (_selectionRevision == catalog.resourceRevision && _selection != null) {
      return _selection!;
    }
    final available = catalog.skills.map((skill) => skill.name).toSet();
    _selection = widget.initialSelection == null
        ? available
        : widget.initialSelection!.intersection(available);
    _selectionRevision = catalog.resourceRevision;
    return _selection!;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.78,
        child: Material(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.4,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.s.chatSkillsTitle,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.s.chatSkillsSubtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: FutureBuilder<HostedAgentSkillCatalog>(
                    future: _catalog,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(
                          child: CircularProgressIndicator.adaptive(),
                        );
                      }
                      if (snapshot.hasError || snapshot.data == null) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.cloud_off_outlined,
                                color: theme.colorScheme.error,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                snapshot.error.toString(),
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall,
                              ),
                              const SizedBox(height: 10),
                              OutlinedButton(
                                key: const ValueKey('chat-skills-retry'),
                                onPressed: _retry,
                                child: Text(widget.s.retry),
                              ),
                            ],
                          ),
                        );
                      }
                      final catalog = snapshot.data!;
                      final selection = _selectionFor(catalog);
                      return Column(
                        children: [
                          Row(
                            children: [
                              Text(
                                widget.s.chatSkillsRevision.replaceAll(
                                  '{revision}',
                                  '${catalog.resourceRevision}',
                                ),
                                style: theme.textTheme.labelMedium,
                              ),
                              const Spacer(),
                              TextButton(
                                key: const ValueKey('chat-skills-select-all'),
                                onPressed: catalog.skills.isEmpty
                                    ? null
                                    : () => setState(
                                        () => _selection = catalog.skills
                                            .map((skill) => skill.name)
                                            .toSet(),
                                      ),
                                child: Text(widget.s.chatSkillsSelectAll),
                              ),
                              TextButton(
                                key: const ValueKey('chat-skills-clear'),
                                onPressed: selection.isEmpty
                                    ? null
                                    : () => setState(() => _selection = {}),
                                child: Text(widget.s.chatSkillsClear),
                              ),
                            ],
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              widget.s.chatSkillsSelectedCount
                                  .replaceAll(
                                    '{selected}',
                                    '${selection.length}',
                                  )
                                  .replaceAll(
                                    '{total}',
                                    '${catalog.skills.length}',
                                  ),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Expanded(
                            child: catalog.skills.isEmpty
                                ? Center(child: Text(widget.s.chatSkillsEmpty))
                                : ListView.builder(
                                    itemCount: catalog.skills.length,
                                    itemBuilder: (context, index) {
                                      final skill = catalog.skills[index];
                                      return CheckboxListTile(
                                        key: ValueKey(
                                          'chat-skill-${skill.name}',
                                        ),
                                        contentPadding: EdgeInsets.zero,
                                        title: Text(skill.name),
                                        subtitle: skill.description.isEmpty
                                            ? null
                                            : Text(skill.description),
                                        value: selection.contains(skill.name),
                                        onChanged: (selected) {
                                          setState(() {
                                            if (selected == true) {
                                              _selection!.add(skill.name);
                                            } else {
                                              _selection!.remove(skill.name);
                                            }
                                          });
                                        },
                                      );
                                    },
                                  ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: Text(widget.s.cancel),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                key: const ValueKey('chat-skills-apply'),
                                onPressed: () => Navigator.of(
                                  context,
                                ).pop(Set<String>.unmodifiable(selection)),
                                child: Text(widget.s.chatApply),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
