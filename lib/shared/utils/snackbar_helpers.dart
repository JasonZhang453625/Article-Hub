import 'package:flutter/material.dart';

/// Shows a snackbar with a close button and 5s auto-dismiss by default.
void showAppSnackBar(
  BuildContext context, {
  required String message,
  Duration duration = const Duration(seconds: 5),
  SnackBarAction? action,
  bool clearExisting = false,
}) {
  final messenger = ScaffoldMessenger.of(context);
  if (clearExisting) messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: duration,
      action: action,
      showCloseIcon: true,
    ),
  );
}
