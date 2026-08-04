import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:memora/data/services/sync_protocol.dart';
import 'package:memora/data/services/sync_state_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late SyncStateService state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('memora_sync_state_test_');
    Hive.init(tempDir.path);
    state = SyncStateService();
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('isolates cursors and initialization markers by account', () async {
    await state.setCursor('user-1', 12);
    await state.setCursor('user-2', 99);
    await state.setInitialized(
      'user-1',
      true,
      protocolVersion: SyncProtocol.protocolVersion,
    );

    expect(await state.cursor('user-1'), 12);
    expect(await state.cursor('user-2'), 99);
    expect(
      await state.isInitialized(
        'user-1',
        protocolVersion: SyncProtocol.protocolVersion,
      ),
      isTrue,
    );
    expect(
      await state.isInitialized(
        'user-2',
        protocolVersion: SyncProtocol.protocolVersion,
      ),
      isFalse,
    );

    await state.resetAccount('user-1');
    expect(await state.cursor('user-1'), 0);
    expect(
      await state.isInitialized(
        'user-1',
        protocolVersion: SyncProtocol.protocolVersion,
      ),
      isFalse,
    );
    expect(await state.cursor('user-2'), 99);
  });

  test('requires a new snapshot after a protocol upgrade', () async {
    await state.setInitialized('user-1', true, protocolVersion: 2);

    expect(await state.isInitialized('user-1', protocolVersion: 2), isTrue);
    expect(
      await state.isInitialized(
        'user-1',
        protocolVersion: SyncProtocol.protocolVersion,
      ),
      isFalse,
    );
  });

  test(
    'prevents one local vault from silently syncing to another account',
    () async {
      await state.ensureVaultOwner('user-1');
      expect(await state.vaultOwner(), 'user-1');
      await expectLater(
        state.ensureVaultOwner('user-2'),
        throwsA(isA<SyncAccountMismatchException>()),
      );
    },
  );
}
