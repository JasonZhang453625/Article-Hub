import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../data/models/passage.dart';
import '../features/article_resolver.dart';
import '../features/chat/chat_screen.dart';
import '../features/home/home_screen.dart';
import '../features/add_passage/add_passage_screen.dart';
import '../features/inbox/inbox_screen.dart';
import '../features/reader/reader_screen.dart';
import '../features/reader/summary_screen.dart';
import '../features/detail/detail_screen.dart';
import '../features/folders/folders_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/appearance_screen.dart';
import '../features/settings/api_config_screen.dart';
import '../features/settings/operations_screen.dart';
import '../features/settings/other_screen.dart';
import '../features/settings/developer_screen.dart';
import '../features/settings/source_platforms_screen.dart';
import '../features/settings/account_screen.dart';
import '../features/settings/login_screen.dart';
import '../features/shell/app_shell.dart';

class AppRoutes {
  static const String chat = '/chat';
  static const String knowledge = '/knowledge';
  static const String inbox = '/inbox';
  static const String settings = '/settings';
  static const String settingsAppearance = '/settings/appearance';
  static const String settingsApiConfig = '/settings/api-config';
  static const String settingsOperations = '/settings/operations';
  static const String settingsOther = '/settings/other';
  static const String settingsDeveloper = '/settings/developer';
  static const String sourcePlatforms = '/settings/source-platforms';
  static const String settingsAccount = '/settings/account';
  static const String settingsLogin = '/settings/login';
  static const String addArticle = '/add';
  static const String summary = '/summary';
  static const String reader = '/reader';
  static const String detail = '/detail';
  static const String folders = '/folders';

  static String summaryWithId(String id) => '/summary/$id';
  static String readerWithId(String id) => '/reader/$id';
  static String detailWithId(String id) => '/detail/$id';
}

CustomTransitionPage<void> _buildPage({
  required GoRouterState state,
  required Widget child,
}) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 380),
    reverseTransitionDuration: const Duration(milliseconds: 320),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final primaryCurved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      final secondaryCurved = CurvedAnimation(
        parent: secondaryAnimation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );

      return FadeTransition(
        opacity: Tween<double>(begin: 0.0, end: 1.0).animate(primaryCurved),
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.045, 0),
            end: Offset.zero,
          ).animate(primaryCurved),
          child: FadeTransition(
            opacity: Tween<double>(
              begin: 1.0,
              end: 0.88,
            ).animate(secondaryCurved),
            child: ScaleTransition(
              scale: Tween<double>(
                begin: 1.0,
                end: 0.96,
              ).animate(secondaryCurved),
              child: child,
            ),
          ),
        ),
      );
    },
  );
}

final appRouter = GoRouter(
  initialLocation: AppRoutes.chat,
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) {
        return AppShell(navigationShell: navigationShell);
      },
      branches: [
        // Tab 0: Chat
        StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.chat,
            pageBuilder: (context, state) =>
                _buildPage(state: state, child: const ChatScreen()),
          ),
        ]),
        // Tab 1: Knowledge Base
        StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.knowledge,
            pageBuilder: (context, state) =>
                _buildPage(state: state, child: const HomeScreen()),
          ),
        ]),
        // Tab 2: Inbox
        StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.inbox,
            pageBuilder: (context, state) =>
                _buildPage(state: state, child: const InboxScreen()),
          ),
        ]),
        // Tab 3: Settings
        StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.settings,
            pageBuilder: (context, state) =>
                _buildPage(state: state, child: const SettingsScreen()),
          ),
        ]),
      ],
    ),
    // Overlay routes (push on top of shell)
    GoRoute(
      path: AppRoutes.addArticle,
      pageBuilder: (context, state) => _buildPage(
        state: state,
        child: AddArticleScreen(
          initialUrl: state.extra is String ? state.extra as String : null,
        ),
      ),
    ),
    GoRoute(
      path: '${AppRoutes.summary}/:id',
      pageBuilder: (context, state) {
        final article = state.extra as Article?;
        return _buildPage(
          state: state,
          child: ArticleResolver(
            article: article,
            id: state.pathParameters['id'],
            builder: (resolved) => SummaryScreen(article: resolved),
          ),
        );
      },
    ),
    GoRoute(
      path: '${AppRoutes.reader}/:id',
      pageBuilder: (context, state) {
        final article = state.extra as Article?;
        return _buildPage(
          state: state,
          child: ArticleResolver(
            article: article,
            id: state.pathParameters['id'],
            builder: (resolved) => ReaderScreen(article: resolved),
          ),
        );
      },
    ),
    GoRoute(
      path: '${AppRoutes.detail}/:id',
      pageBuilder: (context, state) {
        final article = state.extra as Article?;
        return _buildPage(
          state: state,
          child: ArticleResolver(
            article: article,
            id: state.pathParameters['id'],
            builder: (resolved) => DetailScreen(article: resolved),
          ),
        );
      },
    ),
    GoRoute(
      path: AppRoutes.folders,
      pageBuilder: (context, state) =>
          _buildPage(state: state, child: const FoldersScreen()),
    ),
    GoRoute(
      path: AppRoutes.sourcePlatforms,
      pageBuilder: (context, state) =>
          _buildPage(state: state, child: const SourcePlatformsScreen()),
    ),
    GoRoute(
      path: AppRoutes.settingsAppearance,
      pageBuilder: (context, state) =>
          _buildPage(state: state, child: const AppearanceScreen()),
    ),
    GoRoute(
      path: AppRoutes.settingsApiConfig,
      pageBuilder: (context, state) =>
          _buildPage(state: state, child: const ApiConfigScreen()),
    ),
    GoRoute(
      path: AppRoutes.settingsOperations,
      pageBuilder: (context, state) =>
          _buildPage(state: state, child: const OperationsScreen()),
    ),
    GoRoute(
      path: AppRoutes.settingsOther,
      pageBuilder: (context, state) =>
          _buildPage(state: state, child: const OtherScreen()),
    ),
    GoRoute(
      path: AppRoutes.settingsDeveloper,
      pageBuilder: (context, state) =>
          _buildPage(state: state, child: const DeveloperScreen()),
    ),
    GoRoute(
      path: AppRoutes.settingsAccount,
      pageBuilder: (context, state) =>
          _buildPage(state: state, child: const AccountScreen()),
    ),
    GoRoute(
      path: AppRoutes.settingsLogin,
      pageBuilder: (context, state) =>
          _buildPage(state: state, child: const LoginScreen()),
    ),
  ],
);
