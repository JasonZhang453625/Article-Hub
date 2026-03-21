import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../data/models/passage.dart';
import '../features/home/home_screen.dart';
import '../features/add_passage/add_passage_screen.dart';
import '../features/reader/reader_screen.dart';
import '../features/detail/detail_screen.dart';
import '../features/settings/settings_screen.dart';

class AppRoutes {
  static const String home = '/';
  static const String addArticle = '/add';
  static const String reader = '/reader';
  static const String detail = '/detail';
  static const String settings = '/settings';

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
      // Primary animation: the incoming page fades + slides in
      final primaryCurved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );

      // Secondary animation: when another page is pushed on top,
      // the current page fades out slightly and scales down.
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
            // When a page is pushed on top, fade this page slightly
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
  initialLocation: AppRoutes.home,
  routes: [
    GoRoute(
      path: AppRoutes.home,
      pageBuilder: (context, state) =>
          _buildPage(state: state, child: const HomeScreen()),
    ),
    GoRoute(
      path: AppRoutes.addArticle,
      pageBuilder: (context, state) =>
          _buildPage(state: state, child: const AddArticleScreen()),
    ),
    GoRoute(
      path: '${AppRoutes.reader}/:id',
      pageBuilder: (context, state) {
        final article = state.extra as Article;
        return _buildPage(
          state: state,
          child: ReaderScreen(article: article),
        );
      },
    ),
    GoRoute(
      path: '${AppRoutes.detail}/:id',
      pageBuilder: (context, state) {
        final article = state.extra as Article;
        return _buildPage(
          state: state,
          child: DetailScreen(article: article),
        );
      },
    ),
    GoRoute(
      path: AppRoutes.settings,
      pageBuilder: (context, state) =>
          _buildPage(state: state, child: const SettingsScreen()),
    ),
  ],
);
