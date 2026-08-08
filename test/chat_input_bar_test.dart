import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/features/chat/chat_input_bar.dart';
import 'package:memora/shared/utils/locale_strings.dart';

void main() {
  testWidgets('tools and send buttons use matching circular diameters', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatInputBar(
              controller: controller,
              loading: false,
              s: LocaleStrings.of(0),
              onSend: () {},
              onOpenTools: () {},
            ),
          ),
        ),
      ),
    );

    final tools = find.byKey(const ValueKey('chat-tools-button'));
    final send = find.byKey(const ValueKey('chat-send-button'));
    expect(tester.getSize(tools), tester.getSize(send));
    expect(tester.getSize(tools), const Size.square(48));
  });
}
