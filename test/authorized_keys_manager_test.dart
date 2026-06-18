import 'dart:io';

import 'package:chrome_it_support_service/server/authorized_keys_manager.dart';
import 'package:test/test.dart';

void main() {
  test('authorized keys manager adds, edits, disables, enables, and deletes',
      () async {
    final directory = await Directory.systemTemp.createTemp('keys-manager-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/authorized_keys');
    final manager = AuthorizedKeysManager(file.path);

    await manager.add('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest operator-a');
    var keys = await manager.list();
    expect(keys, hasLength(1));
    expect(keys.single.enabled, isTrue);
    expect(keys.single.comment, 'operator-a');

    await manager.edit(
      keys.single.index,
      'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUpdated operator-b',
    );
    keys = await manager.list();
    expect(keys.single.comment, 'operator-b');

    await manager.disable(keys.single.index);
    keys = await manager.list();
    expect(keys.single.enabled, isFalse);
    expect(await file.readAsString(), contains('# disabled: ssh-ed25519'));

    await manager.enable(keys.single.index);
    keys = await manager.list();
    expect(keys.single.enabled, isTrue);

    await manager.delete(keys.single.index);
    expect(await manager.list(), isEmpty);
  });

  test('authorized keys manager rejects invalid key lines', () async {
    final directory = await Directory.systemTemp.createTemp('keys-manager-');
    addTearDown(() => directory.delete(recursive: true));
    final manager = AuthorizedKeysManager('${directory.path}/authorized_keys');

    expect(() => manager.add('not a public key'), throwsFormatException);
  });
}
