import 'dart:io';

import 'package:chrome_it_support_service/server/ldap_credential_validator.dart';
import 'package:chrome_it_support_service/server/relay_server.dart';
import 'package:dartdap/dartdap.dart';
import 'package:test/test.dart';

SearchEntry entry(String dn, String mail, {String control = '512'}) {
  final result = SearchEntry(DN(dn));
  result.attributes['mail'] = Attribute('mail', mail);
  result.attributes['userAccountControl'] =
      Attribute('userAccountControl', control);
  result.attributes['sAMAccountName'] = Attribute('sAMAccountName', 'operator');
  return result;
}

void main() {
  test('selects only an active exact email match', () {
    final disabled = entry(
        'CN=disabled,DC=example,DC=test', 'operator@example.test',
        control: '514');
    final active =
        entry('CN=active,DC=example,DC=test', 'Operator@Example.Test');
    final other = entry('CN=other,DC=example,DC=test', 'other@example.test');
    expect(
        uniqueActiveLdapEmailEntry(
            [disabled, other, active], 'operator@example.test'),
        same(active));
    expect(uniqueActiveLdapEmailEntry([disabled], 'operator@example.test'),
        isNull);
  });

  test('rejects duplicate active email matches', () {
    final first = entry('CN=first,DC=example,DC=test', 'a@example.test');
    final second = entry('CN=second,DC=example,DC=test', 'a@example.test');
    expect(() => uniqueActiveLdapEmailEntry([first, second], 'a@example.test'),
        throwsStateError);
  });

  test('missing LDAPS CA file fails startup', () async {
    final dir = await Directory.systemTemp.createTemp('relay-ca-test-');
    addTearDown(() => dir.delete(recursive: true));
    final server = RelayServer(RelayServerConfig.fromEnvironment({
      'AGENT_ENROLLMENT_TOKEN': 'test-token',
      'DOMAIN_HOSTNAME': 'vietsov.com.vn',
      'LDAP_BIND_DN': 'CN=reader,DC=vietsov,DC=com,DC=vn',
      'LDAP_BIND_PASSWORD': 'test-password',
      'LDAP_CA_CERT_FILE': '${dir.path}/missing.pem',
    }));
    await expectLater(
        server.start(),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('LDAP_CA_CERT_FILE'))));
  });
}
