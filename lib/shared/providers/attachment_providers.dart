import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/attachment_store.dart';
import '../../data/services/chat_attachment_service.dart';

final attachmentStoreProvider = Provider<AttachmentStore>((ref) {
  return AttachmentStore();
});

final chatAttachmentServiceProvider = Provider<ChatAttachmentService>((ref) {
  return ChatAttachmentService(store: ref.watch(attachmentStoreProvider));
});
