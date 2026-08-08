import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import '../../config/backend_config.dart';
import 'auth_service.dart';

/// Best-effort client for account-scoped conversation feedback analytics.
///
/// The local chat message remains the source of truth for the UI. This
/// service only mirrors the latest vote to the authenticated backend and
/// deliberately excludes question/answer text from the analytics payload.
class ConversationFeedbackService {
  final AuthSession? Function() _getSession;
  final Future<AuthSession?> Function() _refreshSession;
  final http.Client _client;
  final Duration timeout;

  ConversationFeedbackService({
    required AuthSession? Function() getSession,
    required Future<AuthSession?> Function() refreshSession,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _getSession = getSession,
       _refreshSession = refreshSession,
       _client = client ?? http.Client();

  /// Uploads the latest feedback for one assistant message.
  ///
  /// Network/API failures are intentionally swallowed: feedback must never
  /// make a completed chat answer fail or block the interaction.
  Future<void> submit({
    required String messageId,
    required String threadId,
    required int feedback,
    String? retrievalLogId,
    String? method,
    bool isNoResult = false,
  }) async {
    if (!BackendConfig.isConfigured ||
        messageId.trim().isEmpty ||
        threadId.trim().isEmpty ||
        (feedback != 1 && feedback != -1)) {
      return;
    }

    var session = _getSession();
    if (session == null) return;
    if (!session.hasValidAccessToken) {
      session = await _refreshSession();
      if (session == null) return;
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _client
            .put(
              BackendConfig.uri(
                '/feedback/conversations/${Uri.encodeComponent(messageId.trim())}',
              ),
              headers: {
                'Authorization': 'Bearer ${session!.accessToken}',
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: jsonEncode({
                'threadId': threadId.trim(),
                'feedback': feedback,
                'retrievalLogId': _optionalText(retrievalLogId),
                'method': _optionalText(method),
                'isNoResult': isNoResult,
              }),
            )
            .timeout(timeout);

        if (response.statusCode == 401 && attempt == 0) {
          final refreshed = await _refreshSession();
          if (refreshed != null) {
            session = refreshed;
            continue;
          }
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          developer.log(
            'feedback upload failed: HTTP ${response.statusCode}',
            name: 'memora.feedback',
          );
        }
        return;
      } catch (error) {
        developer.log('feedback upload skipped: $error', name: 'memora.feedback');
        return;
      }
    }
  }

  void dispose() => _client.close();

  static String? _optionalText(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
