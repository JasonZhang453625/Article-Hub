import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:memora/data/services/sync_crypto_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late SyncCryptoService crypto;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('memora_sync_crypto_test_');
    Hive.init(tempDir.path);
    crypto = SyncCryptoService();
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('exported recovery key can restore access to old payloads', () async {
    final recoveryKey = await crypto.exportRecoveryKey();
    final encrypted = await crypto.encryptJson(
      {'id': 'a1', 'title': 'Encrypted'},
      collection: 'articles',
      itemId: 'a1',
      revision: 1,
    );

    final box = await Hive.openBox<dynamic>('sync_crypto');
    await box.put('local_master_key', base64Encode(List<int>.filled(32, 7)));

    await expectLater(
      crypto.decryptJson(encrypted),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );

    await crypto.importRecoveryKey(recoveryKey);
    final decrypted = await crypto.decryptJson(encrypted);
    expect(decrypted['title'], 'Encrypted');
  });

  test('import rejects malformed recovery keys', () async {
    await expectLater(
      crypto.importRecoveryKey('bad-key'),
      throwsA(isA<FormatException>()),
    );

    final recoveryKey = await crypto.exportRecoveryKey();
    final parts = recoveryKey.split(':');
    final tampered = '${parts[0]}:${parts[1]}:deadbeef';
    await expectLater(
      crypto.importRecoveryKey(tampered),
      throwsA(isA<FormatException>()),
    );
  });

  test('decrypt rejects payloads with mismatched content hash', () async {
    final encrypted = await crypto.encryptJson(
      {'id': 'a2', 'title': 'Hash checked'},
      collection: 'articles',
      itemId: 'a2',
      revision: 1,
    );

    final tampered = EncryptedSyncPayload(
      ciphertext: encrypted.ciphertext,
      nonce: encrypted.nonce,
      aad: encrypted.aad,
      contentHash: '0' * 64,
    );

    await expectLater(
      crypto.decryptJson(tampered),
      throwsA(isA<FormatException>()),
    );
  });
}
