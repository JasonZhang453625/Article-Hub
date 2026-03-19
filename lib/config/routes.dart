import 'package:go_router/go_router.dart';
import '../data/models/passage.dart';
import '../features/home/home_screen.dart';
import '../features/add_passage/add_passage_screen.dart';
import '../features/reader/reader_screen.dart';
import '../features/detail/detail_screen.dart';

class AppRoutes {
  static const String home = '/';
  static const String addPassage = '/add';
  static const String reader = '/reader';
  static const String detail = '/detail';

  static String readerWithId(String id) => '/reader/$id';
  static String detailWithId(String id) => '/detail/$id';
}

final appRouter = GoRouter(
  initialLocation: AppRoutes.home,
  routes: [
    GoRoute(
      path: AppRoutes.home,
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: AppRoutes.addPassage,
      builder: (context, state) => const AddPassageScreen(),
    ),
    GoRoute(
      path: '${AppRoutes.reader}/:id',
      builder: (context, state) {
        final passage = state.extra as Passage;
        return ReaderScreen(passage: passage);
      },
    ),
    GoRoute(
      path: '${AppRoutes.detail}/:id',
      builder: (context, state) {
        final passage = state.extra as Passage;
        return DetailScreen(passage: passage);
      },
    ),
  ],
);
