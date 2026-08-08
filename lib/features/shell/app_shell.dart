import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/connectivity_provider.dart';
import '../../shared/providers/home_navigation_provider.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/utils/breakpoints.dart';
import 'share_handler.dart';

class AppShell extends ConsumerStatefulWidget {
  final StatefulNavigationShell navigationShell;

  const AppShell({super.key, required this.navigationShell});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _redirected = false;
  DateTime? _lastKnowledgeTap;

  static const _doubleTapWindow = Duration(milliseconds: 360);

  void _handleMobileDestinationSelected({
    required int branchIndex,
    required int currentBranchIndex,
  }) {
    final now = DateTime.now();
    final isKnowledgeTap = branchIndex == 1;
    final isDoubleTap =
        isKnowledgeTap &&
        _lastKnowledgeTap != null &&
        now.difference(_lastKnowledgeTap!) <= _doubleTapWindow;

    _lastKnowledgeTap = isKnowledgeTap ? now : null;
    widget.navigationShell.goBranch(
      branchIndex,
      initialLocation: branchIndex == currentBranchIndex,
    );

    if (isDoubleTap) {
      ref.read(homeScrollToTopRequestProvider.notifier).state++;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_redirected) {
      final settings = ref.watch(settingsProvider).valueOrNull;
      if (settings != null) {
        _redirected = true;
        if (settings.startupTabIndex == 1) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              widget.navigationShell.goBranch(1);
            }
          });
        }
      }
    }
    final s = ref.watch(stringsProvider);
    final hideInbox = ref.watch(hideInboxTabProvider);
    final pendingCount = ref.watch(pendingArticlesProvider).maybeWhen(
          data: (articles) => articles.length,
          orElse: () => 0,
        );
    final online = ref.watch(connectivityProvider).valueOrNull ?? true;

    // Build all 4 possible destinations.
    final allDestinations = <_NavDest>[
      _NavDest(
        icon: Icons.chat_bubble_outline_rounded,
        selectedIcon: Icons.chat_bubble_rounded,
        label: s.tabChat,
      ),
      _NavDest(
        icon: Icons.library_books_outlined,
        selectedIcon: Icons.library_books_rounded,
        label: s.tabKnowledge,
      ),
      _NavDest(
        icon: Icons.inbox_outlined,
        selectedIcon: Icons.inbox_rounded,
        label: s.tabInbox,
        badgeCount: pendingCount,
      ),
      _NavDest(
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings_rounded,
        label: s.tabSettings,
      ),
    ];

    // Filter out inbox when hidden.
    final destinations =
        hideInbox
            ? [allDestinations[0], allDestinations[1], allDestinations[3]]
            : allDestinations;

    // Map the visual (rendered) index back to the real branch index.
    // Branch indices: 0=Chat, 1=Knowledge, 2=Inbox, 3=Settings.
    int toBranchIndex(int visualIndex) {
      return hideInbox && visualIndex >= 2 ? visualIndex + 1 : visualIndex;
    }

    int toRenderedIndex(int branchIndex) {
      if (!hideInbox) return branchIndex;
      if (branchIndex == 3) return 2;
      return branchIndex;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
                final isDesktop = constraints.maxWidth >= tabletBreakpoint;

        // ── Offline banner reused by both layouts ──
        Widget? offlineBanner;
        if (!online) {
          final bannerTheme = Theme.of(context);
          offlineBanner = Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
            color: bannerTheme.colorScheme.errorContainer,
            child: Row(
              children: [
                Icon(Icons.cloud_off_rounded,
                    size: 14,
                    color: bannerTheme.colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Text(
                  'No internet connection',
                  style: TextStyle(
                    fontSize: 12,
                    color: bannerTheme.colorScheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          );
        }

        // Decide layout based on available width.
        Widget shell = isDesktop
            ? _DesktopShell(
                navigationShell: widget.navigationShell,
                destinations: destinations,
                currentIndex: toRenderedIndex(widget.navigationShell.currentIndex),
                onDestinationSelected: (i) {
                  widget.navigationShell.goBranch(
                    toBranchIndex(i),
                    initialLocation:
                        toBranchIndex(i) == widget.navigationShell.currentIndex,
                  );
                },
                offlineBanner: offlineBanner,
              )
            : _MobileShell(
                navigationShell: widget.navigationShell,
                destinations: destinations,
                currentIndex: toRenderedIndex(widget.navigationShell.currentIndex),
                onDestinationSelected: (i) {
                  _handleMobileDestinationSelected(
                    branchIndex: toBranchIndex(i),
                    currentBranchIndex: widget.navigationShell.currentIndex,
                  );
                },
                offlineBanner: offlineBanner,
              );

        if (!kIsWeb && !Platform.isWindows) {
          return ShareHandler(child: shell);
        }
        return shell;
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Data class for navigation destinations
// ─────────────────────────────────────────────────────────────

class _NavDest {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final int badgeCount;

  const _NavDest({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badgeCount = 0,
  });
}

// ─────────────────────────────────────────────────────────────
// Mobile layout — same as before but extracted
// ─────────────────────────────────────────────────────────────

class _MobileShell extends StatelessWidget {
  final StatefulNavigationShell navigationShell;
  final List<_NavDest> destinations;
  final int currentIndex;
  final ValueChanged<int> onDestinationSelected;
  final Widget? offlineBanner;

  const _MobileShell({
    required this.navigationShell,
    required this.destinations,
    required this.currentIndex,
    required this.onDestinationSelected,
    this.offlineBanner,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          ?offlineBanner,
          Expanded(child: navigationShell),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: onDestinationSelected,
        maintainBottomViewPadding: true,
        destinations: destinations.map((d) {
          return NavigationDestination(
            icon: d.badgeCount > 0
                ? Badge(
                    isLabelVisible: true,
                    label: Text('${d.badgeCount}'),
                    child: Icon(d.icon),
                  )
                : Icon(d.icon),
            selectedIcon: d.badgeCount > 0
                ? Badge(
                    isLabelVisible: true,
                    label: Text('${d.badgeCount}'),
                    child: Icon(d.selectedIcon),
                  )
                : Icon(d.selectedIcon),
            label: d.label,
          );
        }).toList(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Desktop layout — NavigationRail on the left
// ─────────────────────────────────────────────────────────────

class _DesktopShell extends StatelessWidget {
  final StatefulNavigationShell navigationShell;
  final List<_NavDest> destinations;
  final int currentIndex;
  final ValueChanged<int> onDestinationSelected;
  final Widget? offlineBanner;

  const _DesktopShell({
    required this.navigationShell,
    required this.destinations,
    required this.currentIndex,
    required this.onDestinationSelected,
    this.offlineBanner,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: currentIndex,
            onDestinationSelected: onDestinationSelected,
            labelType: NavigationRailLabelType.all,
            backgroundColor:
                theme.colorScheme.surfaceContainerLowest,
            leading: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Image.asset(
                'assets/branding/memora_icon.png',
                width: 32,
                height: 32,
              ),
            ),
            destinations: destinations.map((d) {
              return NavigationRailDestination(
                icon: d.badgeCount > 0
                    ? Badge(
                        isLabelVisible: true,
                        label: Text('${d.badgeCount}'),
                        child: Icon(d.icon),
                      )
                    : Icon(d.icon),
                selectedIcon: d.badgeCount > 0
                    ? Badge(
                        isLabelVisible: true,
                        label: Text('${d.badgeCount}'),
                        child: Icon(d.selectedIcon),
                      )
                    : Icon(d.selectedIcon),
                label: Text(d.label),
              );
            }).toList(),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: Column(
              children: [
                ?offlineBanner,
                Expanded(child: navigationShell),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
