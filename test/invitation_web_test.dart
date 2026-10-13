import 'dart:convert';
import 'dart:io';

import 'package:chrome_it_support_service/server/help_content.dart';
import 'package:chrome_it_support_service/server/invitation_mailer.dart';
import 'package:chrome_it_support_service/server/operator_store.dart';
import 'package:chrome_it_support_service/server/operator_web.dart';
import 'package:test/test.dart';

class _FakeMailer extends InvitationMailer {
  _FakeMailer() : super(host: 'test.local', port: 25, from: 'test@test.local',
      user: null, password: null, ssl: false, allowStartTls: true);
  String? recipient;
  String? body;
  bool fail = false;

  @override
  Future<void> sendInvitation(String to, String subject, String body) async {
    recipient = to;
    this.body = body;
    if (fail) throw StateError('SMTP unavailable');
  }
}

void main() {
  test('invitation includes checked Chrome instructions and journals sender', () async {
    final dir = await Directory.systemTemp.createTemp('relay-invite-');
    addTearDown(() => dir.delete(recursive: true));
    final store = OperatorStore(dir.path);
    await store.initialize(null);
    final help = HelpContent('deploy/help_locales');
    await help.load();
    expect(help.page('ru', '/download/client_debug_agent.exe'),
        contains('Подключения'));
    expect(help.page('vi', '/download/client_debug_agent.exe'),
        contains('Phiên kết nối'));
    final mailer = _FakeMailer();
    final web = OperatorWeb(store: store, help: help, mailer: mailer,
        auth: null, adminUsername: 'admin', adminPassword: 'test-password',
        publicBaseUrl: 'https://example.test:9999',
        downloadUrl: '/download/client_debug_agent.exe');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await web.handle(request);
    });
    addTearDown(() => server.close(force: true));
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final get = await client.getUrl(base.resolve('/admin/invite'));
    get.headers.set(HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('admin:test-password'))}');
    final page = await utf8.decodeStream(await get.close());
    final csrf = RegExp('name="csrf" value="([^"]+)"').firstMatch(page)!.group(1)!;

    final post = await client.postUrl(base.resolve('/admin/invite'));
    post.headers.set(HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('admin:test-password'))}');
    post.headers.contentType = ContentType.parse('application/x-www-form-urlencoded');
    post.write(Uri(queryParameters: {
      'csrf': csrf,
      'email': 'user@example.test',
      'existing': 'yes',
    }).query);
    final response = await post.close();
    await response.drain();
    expect(response.statusCode, 200);
    expect(mailer.recipient, 'user@example.test');
    expect(mailer.body, contains('chrome://inspect/#remote-debugging'));
    expect(mailer.body, contains('https://example.test:9999/help'));
    final history = await store.history();
    expect(history.map((row) => row['action']),
        containsAll(['invitation_attempt', 'invitation_sent']));
    expect(history.first['existingChrome'], isTrue);
    expect(history.first['actor'], 'local-admin');

    mailer.fail = true;
    final failed = await client.postUrl(base.resolve('/admin/invite'));
    failed.headers.set(HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('admin:test-password'))}');
    failed.headers.contentType = ContentType.parse('application/x-www-form-urlencoded');
    failed.write(Uri(queryParameters: {
      'csrf': csrf,
      'email': 'other@example.test',
    }).query);
    final failedResponse = await failed.close();
    await failedResponse.drain();
    expect(failedResponse.statusCode, HttpStatus.badGateway);
    expect(mailer.body, isNot(contains('chrome://inspect/#remote-debugging')));
    expect((await store.history()).first['action'], 'invitation_failed');
    expect((await store.history()).first['existingChrome'], isFalse);
  });
}
