import 'dart:convert';
import 'dart:io';

import 'package:chrome_it_support_service/server/relay_server.dart';
import 'package:test/test.dart';

void main() {
  test('AD timeout uses configured seconds', () {
    final config = RelayServerConfig.fromEnvironment({
      'AGENT_ENROLLMENT_TOKEN': 'test-token',
      'AD_TIMEOUT_SECONDS': '20',
    });
    expect(config.adTimeout, const Duration(seconds: 20));
  });

  test('shared password cannot reach legacy key mutation in AD mode', () async {
    final dir = await Directory.systemTemp.createTemp('relay-ad-');
    addTearDown(() => dir.delete(recursive: true));
    final server = RelayServer(RelayServerConfig.fromEnvironment({
      'AGENT_ENROLLMENT_TOKEN': 'test-token',
      'SERVER_HTTP_BIND': '127.0.0.1',
      'SERVER_HTTP_PORT': '0',
      'OPERATOR_STATE_DIR': dir.path,
      'DOMAIN_HOSTNAME': 'ad.example.test',
      'DOMAIN_NAME': 'example.test',
      'LDAP_BIND_DN': 'CN=reader,DC=example,DC=test',
      'LDAP_BIND_PASSWORD': 'bind-password',
      'ADMIN_BOOTSTRAP_EMAIL': 'first@example.test',
      'ADMIN_PASSWORD': 'local-password',
    }));
    await server.start();
    addTearDown(server.stop);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.boundHttpPort}/admin/keys/add'));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('admin:local-password'))}');
    request.write('key=ssh-ed25519+AAAA');
    final response = await request.close();
    await response.drain();
    expect(response.statusCode, HttpStatus.seeOther);
    expect(response.headers.value(HttpHeaders.locationHeader), '/admin/login');
    expect(File('${dir.path}/operator_keys').readAsStringSync(), isEmpty);
  });
}
