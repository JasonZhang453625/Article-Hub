import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/features/chat/chat_input_bar.dart';
import 'package:memora/data/models/chat_attachment.dart';
import 'package:memora/data/services/chat_attachment_service.dart';
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
    expect(
      tester.getCenter(find.byKey(const ValueKey('chat-tools-plus-icon'))).dx,
      tester.getCenter(tools).dx - 2,
    );
  });

  testWidgets('renders selected image and file drafts with remove actions', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final drafts = [
      ChatAttachmentDraft(
        attachment: const ChatAttachment(
          id: 'image-1',
          kind: ChatAttachmentKind.image,
          localPath: 'image',
          mimeType: 'image/png',
          originalFileName: 'chart.png',
          byteLength: 4,
          sha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        previewBytes: Uint8List.fromList([137, 80, 78, 71]),
      ),
      ChatAttachmentDraft(
        attachment: const ChatAttachment(
          id: 'file-1',
          kind: ChatAttachmentKind.file,
          localPath: 'file',
          mimeType: 'text/plain',
          originalFileName: 'notes.txt',
          byteLength: 4,
          sha256:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
        previewBytes: Uint8List.fromList([1, 2, 3, 4]),
      ),
    ];
    ChatAttachmentDraft? removed;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatInputBar(
              controller: controller,
              loading: false,
              s: LocaleStrings.of(2),
              attachments: drafts,
              onRemoveAttachment: (draft) => removed = draft,
              onSend: () {},
              onOpenTools: () {},
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('chat-attachment-drafts')),
      findsOneWidget,
    );
    expect(find.text('notes.txt'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('chat-attachment-remove-file-1')),
    );
    expect(removed, drafts.last);
  });

  testWidgets('loading generation exposes a Stop action', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var stops = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInputBar(
            controller: controller,
            loading: true,
            s: LocaleStrings.of(2),
            onSend: () {},
            onStop: () => stops++,
            onOpenTools: () {},
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('chat-stop-icon')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.byKey(const ValueKey('chat-send-button')));
    expect(stops, 1);
  });
}
