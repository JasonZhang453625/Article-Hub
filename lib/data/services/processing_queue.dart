import 'dart:async';

import '../models/passage.dart';

typedef ProcessingQueueSave = Future<void> Function(Article article);
typedef ProcessingQueueProcess = Future<Article?> Function(Article article);
typedef ProcessingQueueEligibility = bool Function(Article article);

/// A single-worker queue backed by each article's persisted processing state.
///
/// The queue itself is deliberately in-memory: pending/processing markers are
/// saved before a job starts, so a new queue created after an app restart can
/// recover all unfinished jobs with [resume].
class ProcessingQueue {
  final List<Article> Function() _getArticles;
  final ProcessingQueueSave _save;
  final ProcessingQueueProcess _process;
  final ProcessingQueueEligibility _canProcess;

  bool _draining = false;
  bool _enqueueing = false;
  Future<void>? _drainFuture;
  final Set<String> _runningIds = <String>{};

  ProcessingQueue({
    required List<Article> Function() getArticles,
    required ProcessingQueueSave save,
    required ProcessingQueueProcess process,
    required ProcessingQueueEligibility canProcess,
  }) : _getArticles = getArticles,
       _save = save,
       _process = process,
       _canProcess = canProcess;

  /// Marks every job durable before starting the worker. This makes a batch
  /// safe to resume even if the process is terminated between two jobs.
  Future<void> enqueueAll(Iterable<Article> articles) async {
    _enqueueing = true;
    try {
      for (final article in articles.toList(growable: false)) {
        await _save(
          article.copyWith(
            processingStatus: ProcessingStatus.pending,
            processingStage: Article.clearValue,
            processingError: Article.clearValue,
          ),
        );
      }
    } finally {
      _enqueueing = false;
    }
    resume();
  }

  Future<void> enqueue(Article article) => enqueueAll([article]);

  /// Re-scans durable state. It is safe to call at startup, after a settings
  /// update, and whenever new articles are added.
  void resume() {
    if (_enqueueing) {
      return;
    }
    if (_draining) return;
    _draining = true;
    _drainFuture = _drain();
  }

  Future<void> get whenIdle async {
    while (_draining) {
      await _drainFuture;
    }
  }

  Future<void> _drain() async {
    try {
      while (true) {
        Article? next;
        for (final article in _getArticles()) {
          final isQueued =
              article.processingStatus == ProcessingStatus.pending ||
              article.processingStatus == ProcessingStatus.processing;
          if (!_runningIds.contains(article.id) &&
              isQueued &&
              _canProcess(article)) {
            next = article;
            break;
          }
        }
        if (next == null) return;

        _runningIds.add(next.id);
        try {
          await _process(next);
        } catch (error) {
          // The pipeline normally persists its own failures. This fallback
          // prevents an unexpected exception from leaving a pending record in
          // an infinite restart loop.
          await _save(
            next.copyWith(
              processingStatus: ProcessingStatus.failed,
              processingError: 'queue: $error',
              lastProcessedAt: DateTime.now(),
            ),
          );
        } finally {
          _runningIds.remove(next.id);
        }
      }
    } finally {
      _draining = false;
      _drainFuture = null;
    }
  }
}
