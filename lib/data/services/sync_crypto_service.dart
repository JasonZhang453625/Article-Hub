import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:hive_flutter/hive_flutter.dart';

class EncryptedSyncPayload {
  final String ciphertext;
  final String nonce;
  final String aad;
  final String contentHash;

  const EncryptedSyncPayload({
    required this.ciphertext,
    required this.nonce,
    required this.aad,
    required this.contentHash,
  });
}

class SyncCryptoService {
  static const String _boxName = 'sync_crypto';
  static const String _keyBytesKey = 'local_master_key';
  static const String _recoveryKeyPrefix = 'memora-sync-key-v1';
  static const int _keyLength = 32;
  static const int _macLength = 16;

  final AesGcm _cipher = AesGcm.with256bits();
  final Sha256 _sha256 = Sha256();
  Box<dynamic>? _box;

  Future<Box<dynamic>> _openBox() async {
    try {
      await Hive.initFlutter();
    } catch (_) {
      // Hive may already be initialized by repository providers.
    }
    return _box ??= await Hive.openBox<dynamic>(_boxName);
  }

  Future<SecretKey> _secretKey() async {
    return SecretKey(await _secretKeyBytes());
  }

  Future<List<int>> _secretKeyBytes() async {
    final box = await _openBox();
    final stored = box.get(_keyBytesKey);
    if (stored is String && stored.isNotEmpty) {
      return base64Decode(stored);
    }

    final key = await _cipher.newSecretKey();
    final bytes = await key.extractBytes();
    await box.put(_keyBytesKey, base64Encode(bytes));
    return bytes;
  }

  Future<String> exportRecoveryKey() async {
    final bytes = await _secretKeyBytes();
    final encoded = base64UrlEncode(bytes).replaceAll('=', '');
    return '$_recoveryKeyPrefix:$encoded:${await _checksum(bytes)}';
  }

  Future<void> importRecoveryKey(String recoveryKey) async {
    final normalized = recoveryKey.trim().replaceAll(RegExp(r'\s+'), '');
    final parts = normalized.split(':');
    if (parts.length != 3 || parts.first != _recoveryKeyPrefix) {
      throw const FormatException('Invalid Memora sync recovery key format');
    }

    final bytes = base64Url.decode(_withPadding(parts[1]));
    if (bytes.length != _keyLength) {
      throw const FormatException('Invalid Memora sync recovery key length');
    }

    final checksum = await _checksum(bytes);
    if (parts[2] != checksum) {
      throw const FormatException('Invalid Memora sync recovery key checksum');
    }

    final box = await _openBox();
    await box.put(_keyBytesKey, base64Encode(bytes));
  }

  Future<String> keyFingerprint() async {
    final bytes = await _secretKeyBytes();
    final hash = await _sha256.hash(bytes);
    return _hex(hash.bytes).substring(0, 12);
  }

  Future<EncryptedSyncPayload> encryptJson(
    Map<String, dynamic> payload, {
    required String collection,
    required String itemId,
    required int revision,
  }) async {
    final encoded = utf8.encode(jsonEncode(payload));
    final aad = '$collection:$itemId:$revision';
    final secretBox = await _cipher.encrypt(
      encoded,
      secretKey: await _secretKey(),
      aad: utf8.encode(aad),
    );
    final hash = await _sha256.hash(encoded);

    return EncryptedSyncPayload(
      ciphertext: base64Encode([
        ...secretBox.cipherText,
        ...secretBox.mac.bytes,
      ]),
      nonce: base64Encode(secretBox.nonce),
      aad: base64Encode(utf8.encode(aad)),
      contentHash: _hex(hash.bytes),
    );
  }

  Future<Map<String, dynamic>> decryptJson(EncryptedSyncPayload payload) async {
    final combined = base64Decode(payload.ciphertext);
    if (combined.length <= _macLength) {
      throw const FormatException('Encrypted sync payload is too short');
    }
    final cipherText = combined.sublist(0, combined.length - _macLength);
    final mac = Mac(combined.sublist(combined.length - _macLength));
    final clear = await _cipher.decrypt(
      SecretBox(cipherText, nonce: base64Decode(payload.nonce), mac: mac),
      secretKey: await _secretKey(),
      aad: base64Decode(payload.aad),
    );
    final hash = await _sha256.hash(clear);
    if (_hex(hash.bytes) != payload.contentHash) {
      throw const FormatException('Encrypted sync payload hash mismatch');
    }
    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('Decrypted sync payload is not an object');
  }

  Future<String> _checksum(List<int> bytes) async {
    final hash = await _sha256.hash(bytes);
    return _hex(hash.bytes).substring(0, 8);
  }

  String _withPadding(String input) {
    final remainder = input.length % 4;
    if (remainder == 0) return input;
    return input.padRight(input.length + 4 - remainder, '=');
  }

  String _hex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
