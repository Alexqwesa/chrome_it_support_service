import 'dart:io';

import 'package:chrome_it_support_service/server/operator_store.dart';
import 'package:test/test.dart';

void main() {
  test('AD bootstrap seeds an existing empty local state', () async {
    final dir = await Directory.systemTemp.createTemp('relay-empty-');
    addTearDown(() => dir.delete(recursive: true));
    await OperatorStore(dir.path).initialize(null);
    final adStore = OperatorStore(dir.path);
    await adStore.initialize('first@vietsov.com.vn');
    expect(adStore.get('first@vietsov.com.vn')!.canManageAdmin, isTrue);
  });

  test('bootstrap, permissions, managed keys, and history survive restart', () async {
    final dir = await Directory.systemTemp.createTemp('relay-operators-');
    addTearDown(() => dir.delete(recursive: true));
    final store = OperatorStore(dir.path);
    await store.initialize('first@vietsov.com.vn');
    expect(store.get('first@vietsov.com.vn')!.canManageAdmin, isTrue);
    await store.upsertUser('operator@vietsov.com.vn', 'first@vietsov.com.vn',
        canManageAdmin: false, canManageOperator: false);
    const key = 'ssh-ed25519 dGVzdA== operator';
    await store.setOwnKey('operator@vietsov.com.vn', key);
    expect(await File('${dir.path}/operator_keys').readAsString(), contains(key));
    expect(await store.history(owner: 'operator@vietsov.com.vn'), hasLength(1));

    final reloaded = OperatorStore(dir.path);
    await reloaded.initialize('other@vietsov.com.vn');
    expect(reloaded.get('other@vietsov.com.vn'), isNull);
    expect(reloaded.get('operator@vietsov.com.vn')!.publicKey, key);
    await reloaded.removeUser('operator@vietsov.com.vn', 'first@vietsov.com.vn');
    expect(reloaded.get('operator@vietsov.com.vn'), isNull);
    expect(await File('${dir.path}/operator_keys').readAsString(), isEmpty);
    await reloaded.upsertUser('operator@vietsov.com.vn', 'first@vietsov.com.vn',
        canManageAdmin: false, canManageOperator: false);
    expect(reloaded.get('operator@vietsov.com.vn')!.publicKey, isNull);
  });
}
