import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/routes.dart';
import '../../config/supabase_config.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/providers/auth_provider.dart';
import '../../shared/widgets/delayed_reveal.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final usageDays = ref.watch(usageDaysProvider);
    final articleCount = ref.watch(articlesCountProvider);
    final totalTokens = ref.watch(totalTokensUsedProvider);
    final cardColor = theme.colorScheme.surface;
    final outlineColor = theme.colorScheme.outline;

    final isLoggedIn = ref.watch(isLoggedInProvider);
    final email = ref.watch(currentEmailProvider);
    final auth = ref.watch(authServiceProvider);
    final authAvailable = SupabaseConfig.isConfigured;

    return Scaffold(
      appBar: AppBar(title: Text(s.settingsAccount)),
      body: DelayedReveal(
        delayMs: 40, beginOffset: const Offset(0, 0.035),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Avatar + title + usage days ──
              Center(
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    Container(
                      width: 72, height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [
                            theme.colorScheme.primary,
                            theme.colorScheme.primary.withValues(alpha: 0.6),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: Center(
                        child: isLoggedIn
                            ? Text(
                                (email ?? '?')[0].toUpperCase(),
                                style: const TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.person_rounded, size: 36, color: Colors.white),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      isLoggedIn && email != null ? email : s.accountTitle,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.calendar_today_rounded, size: 14,
                          color: isDark ? Colors.white54 : const Color(0xFF6C8594)),
                        const SizedBox(width: 6),
                        Text(
                          '${s.usageDays} $usageDays ${s.daysN}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: isDark ? Colors.white54 : const Color(0xFF6C8594),
                          ),
                        ),
                      ],
                    ),
                    if (!isLoggedIn && authAvailable) ...[
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () => context.push(AppRoutes.settingsLogin),
                        icon: const Icon(Icons.login_rounded, size: 18),
                        label: Text(s.accountLogin),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // ── Medals ──
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _MedalIcon(
                        icon: Icons.emoji_events_rounded,
                        color: const Color(0xFFFFD700),
                        label: '🥇',
                        isDark: isDark,
                      ),
                      const SizedBox(width: 20),
                      _MedalIcon(
                        icon: Icons.emoji_events_rounded,
                        color: const Color(0xFFC0C0C0),
                        label: '🥈',
                        isDark: isDark,
                      ),
                      const SizedBox(width: 20),
                      _MedalIcon(
                        icon: Icons.emoji_events_rounded,
                        color: const Color(0xFFCD7F32),
                        label: '🥉',
                        isDark: isDark,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  s.futureMembership,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: isDark ? Colors.white38 : const Color(0xFF8AA1AF),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // ── Stats cards ──
              Row(
                children: [
                  Expanded(child: _StatCard(
                    icon: Icons.memory_rounded,
                    label: s.memoryCount,
                                        value: '$articleCount ${s.entriesN}',
                    theme: theme, cardColor: cardColor, outlineColor: outlineColor, isDark: isDark,
                  )),
                  const SizedBox(width: 12),
                  Expanded(child: _StatCard(
                    icon: Icons.bolt_rounded,
                    label: s.tokenConsumption,
                    value: _formatNumber(totalTokens),
                    theme: theme, cardColor: cardColor, outlineColor: outlineColor, isDark: isDark,
                  )),
                ],
              ),

              const SizedBox(height: 20),

              if (authAvailable) ...[
                // ── Account Security ──
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: Text(
                    s.accountSecurity,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: const Color(0xFF00AEEF),
                    ),
                  ),
                ),
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    children: [
                      if (isLoggedIn) ...[
                        _SecurityTile(
                          icon: Icons.logout_rounded,
                          title: s.logout,
                          theme: theme, isDark: isDark,
                          onTap: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text(s.logoutConfirmTitle),
                              content: Text(s.logoutConfirm),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(false),
                                  child: Text(s.cancel),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(true),
                                  child: Text(s.logout),
                                ),
                              ],
                            ),
                          );
                          if (confirm == true) {
                            await auth.signOut();
                          }
                        },
                        ),
                      ] else ...[
                        _SecurityTile(
                          icon: Icons.login_rounded,
                          title: s.accountLogin,
                          theme: theme, isDark: isDark,
                          onTap: () => context.push(AppRoutes.settingsLogin),
                        ),
                      ],
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  String _formatNumber(int n) {
    if (n >= 1000000) {
      return '${(n / 1000000).toStringAsFixed(1)}M';
    } else if (n >= 1000) {
      return '${(n / 1000).toStringAsFixed(1)}K';
    }
    return n.toString();
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final ThemeData theme;
  final Color cardColor;
  final Color outlineColor;
  final bool isDark;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.theme,
    required this.cardColor,
    required this.outlineColor,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
              Icon(icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(label, style: theme.textTheme.bodySmall?.copyWith(
                color: isDark ? Colors.white54 : const Color(0xFF6C8594),
              )),
            ],
          ),
          const SizedBox(height: 10),
          Text(value, style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.primary,
          )),
        ],
      ),
    );
  }
}

class _MedalIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final bool isDark;

  const _MedalIcon({
    required this.icon,
    required this.color,
    required this.label,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Icon(icon, size: 22, color: color),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 16,
            color: isDark ? Colors.white70 : Colors.black87,
          ),
        ),
      ],
    );
  }
}

class _SecurityTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final ThemeData theme;
  final bool isDark;
  final VoidCallback onTap;

  const _SecurityTile({
    required this.icon,
    required this.title,
    required this.theme,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.vertical(top: const Radius.circular(24), bottom: const Radius.circular(24)),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 20, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title, style: theme.textTheme.titleMedium),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: isDark ? Colors.white38 : const Color(0xFF8AA1AF),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
