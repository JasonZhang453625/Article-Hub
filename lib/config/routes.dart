import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../data/models/passage.dart';
import '../features/home/home_screen.dart';
import '../features/add_passage/add_passage_screen.dart';
import '../features/reader/reader_screen.dart';
import '../features/detail/detail_screen.dart';

class AppRoutes {
  static const String home = '/';
  static const String addArticle = '/add';
  static const String reader = '/reader';
  static const String detail = '/detail';

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
    reverseTransitionDuration: const Duration(milliseconds: 260),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.045, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
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
  ],
);
