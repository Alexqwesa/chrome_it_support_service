import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'help_content.dart';
import 'invitation_mailer.dart';
import 'operator_auth.dart';
import 'operator_store.dart';

class OperatorWeb {
  static const _keyCommand = r'''$k="$env:USERPROFILE\.ssh\id_ed25519"; $p="$k.pub"; if((Test-Path $k) -xor (Test-Path $p)){ throw "Only one key file exists. Fix the pair first." }; if(!(Test-Path $k)){ New-Item -ItemType Directory -Force -Path (Split-Path $k) | Out-Null; ssh-keygen -t ed25519 -f $k }; Get-Content $p''';
  OperatorWeb({
    required this.store,
    required this.help,
    required this.mailer,
    required this.auth,
    required this.adminUsername,
    required this.adminPassword,
    required this.publicBaseUrl,
    required this.downloadUrl,
    this.reloadSshd,
  }) : _localCsrf = _randomToken();

  final OperatorStore store;
  final HelpContent help;
  final InvitationMailer mailer;
  final OperatorAuth? auth;
  final String adminUsername;
  final String? adminPassword;
  final String publicBaseUrl;
  final String downloadUrl;
  final Future<void> Function()? reloadSshd;
  final String _localCsrf;

  String? principal(HttpRequest request) {
    if (auth != null) return auth!.userFor(request);
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (adminPassword == null || header == null || !header.startsWith('Basic ')) {
      return null;
    }
    try {
      final value = utf8.decode(base64Decode(header.substring(6)));
      return value == '$adminUsername:$adminPassword' ? 'local-admin' : null;
    } on FormatException {
      return null;
    }
  }

  bool canManageAdmin(String user) => user == 'local-admin' ||
      store.get(user)?.canManageAdmin == true;
  bool canManageOperator(String user) => user == 'local-admin' ||
      store.get(user)?.canManageOperator == true;

  Future<bool> handle(HttpRequest request) async {
    final path = request.uri.path;
    if (path == '/help' && request.method == 'GET') {
      await _html(request, help.page(request.uri.queryParameters['lang'], downloadUrl));
      return true;
    }
    if (path == '/admin/login' && auth != null) {
      if (request.method == 'GET') {
        await _html(request, _page('Operator sign-in', '''<form method="post">
          <input type="hidden" name="csrf" value="$_localCsrf">
          <label>AD email <input name="email" type="email" required></label>
          <label>Password <input name="password" type="password" required></label>
          <button>Sign in</button></form>'''));
      } else if (request.method == 'POST') {
        final form = await _form(request);
        if (form['csrf'] != _localCsrf) {
          await _error(request, HttpStatus.forbidden, 'Invalid form token.');
        } else if (await auth!.signIn(request, form['email'] ?? '', form['password'] ?? '')) {
          await _redirect(request, '/admin/keys');
        } else {
          await _html(request, _page('Sign-in failed',
              '<p>Invalid credentials or account is not approved.</p><a href="/admin/login">Try again</a>'),
              status: HttpStatus.unauthorized);
        }
      } else {
        await _error(request, HttpStatus.methodNotAllowed, 'Method not allowed.');
      }
      return true;
    }
    if (!path.startsWith('/admin/')) return false;
    if (auth == null && (path.startsWith('/admin/keys') || path == '/admin/ssh/reload')) {
      return false;
    }
    final actor = principal(request);
    if (actor == null) {
      if (auth != null) {
        await _redirect(request, '/admin/login');
      } else {
        request.response.headers.set(HttpHeaders.wwwAuthenticateHeader,
            'Basic realm="Chrome debug relay"');
        await _error(request, HttpStatus.unauthorized, 'Authentication required.');
      }
      return true;
    }
    if (path == '/admin/logout' && request.method == 'GET') {
      auth?.signOut(request);
      await _redirect(request, '/admin/login');
      return true;
    }
    if (path == '/admin/ssh/reload' && auth != null && request.method == 'POST') {
      if (!canManageAdmin(actor)) {
        await _error(request, HttpStatus.forbidden, 'Admin permission required.');
        return true;
      }
      final form = await _form(request);
      if (!await _checkCsrf(request, form)) return true;
      if (reloadSshd == null) {
        await _error(request, HttpStatus.serviceUnavailable, 'Reload is not configured.');
        return true;
      }
      await reloadSshd!();
      await store.journal(actor, 'sshd_reload_requested');
      await _redirect(request, '/admin/operators');
      return true;
    }
    if (path == '/admin/keys' && request.method == 'GET') {
      final record = store.get(actor);
      final history = await store.history(owner: actor);
      final key = record?.publicKey;
      await _html(request, _page('My SSH key', '''
        <p>Only your public key belongs here. Keep the private key on your PC.</p>
        <p>In PowerShell, generate your own key if needed and print the public key:</p>
        <button type="button" onclick='navigator.clipboard.writeText(${jsonEncode(_keyCommand)})'>Copy PowerShell command</button>
        <pre>${_e(_keyCommand)}</pre>
        <form method="post" action="/admin/keys/save">${_csrf(request)}
          <textarea name="key" rows="3" required>${_e(key ?? '')}</textarea>
          <button>Save my key</button></form>
        ${key == null ? '' : '<form method="post" action="/admin/keys/remove">${_csrf(request)}<button>Remove my key</button></form>'}
        <h2>My key history</h2>${_history(history)}'''));
      return true;
    }
    if ((path == '/admin/keys/save' || path == '/admin/keys/remove') &&
        request.method == 'POST') {
      final form = await _form(request);
      if (!await _checkCsrf(request, form)) return true;
      try {
        if (path.endsWith('/save')) {
          await store.setOwnKey(actor, form['key'] ?? '');
        } else {
          await store.clearOwnKey(actor);
        }
        await _redirect(request, '/admin/keys');
      } catch (error) {
        await _error(request, HttpStatus.badRequest, '$error');
      }
      return true;
    }
    if (path == '/admin/invite') {
      if (!canManageOperator(actor)) {
        await _error(request, HttpStatus.forbidden, 'Operator permission required.');
        return true;
      }
      if (request.method == 'GET') {
        await _html(request, _page('Send support invitation', '''
          <form method="post" action="/admin/invite">${_csrf(request)}
          <label>User email <input name="email" type="email" required></label>
          <label><input type="checkbox" name="existing" value="yes"> Ask user to connect existing Chrome</label>
          <p class="warn">Existing Chrome may expose open tabs and signed-in sessions.</p>
          <button ${mailer.configured ? '' : 'disabled'}>Send email</button></form>
          ${mailer.configured ? '' : '<p>SMTP is not configured.</p>'}'''));
      } else if (request.method == 'POST') {
        final form = await _form(request);
        if (!await _checkCsrf(request, form)) return true;
        final to = (form['email'] ?? '').trim().toLowerCase();
        final existing = form['existing'] == 'yes';
        await store.journal(actor, 'invitation_attempt', subject: to,
            details: {'existingChrome': existing});
        try {
          final base = publicBaseUrl.replaceFirst(RegExp(r'/$'), '');
          final helpUrl = '$base/help';
          final exeUrl = downloadUrl.startsWith('http') ? downloadUrl : '$base$downloadUrl';
          await mailer.sendInvitation(to, help.emailSubject(),
              help.emailBody(helpUrl: helpUrl, downloadUrl: exeUrl,
                  existingChrome: existing));
          await store.journal(actor, 'invitation_sent', subject: to,
              details: {'existingChrome': existing});
          await _html(request, _page('Invitation sent',
              '<p>Invitation sent to ${_e(to)}.</p><a href="/admin/invite">Send another</a>'));
        } catch (error, stack) {
          stderr.writeln('Invitation failed: $error\n$stack');
          await store.journal(actor, 'invitation_failed', subject: to,
              details: {'existingChrome': existing, 'error': '$error'});
          await _error(request, HttpStatus.badGateway,
              'Invitation failed. Ask an administrator to check the journal.');
        }
      } else {
        await _error(request, HttpStatus.methodNotAllowed, 'Method not allowed.');
      }
      return true;
    }
    if (path == '/admin/journal' && request.method == 'GET') {
      if (!canManageOperator(actor) && !canManageAdmin(actor)) {
        await _error(request, HttpStatus.forbidden, 'Manager permission required.');
        return true;
      }
      var rows = await store.history();
      if (!canManageAdmin(actor)) {
        rows = rows.where((row) =>
            (row['action'] as String).startsWith('invitation_')).toList();
      }
      await _html(request, _page('Journal', _history(rows)));
      return true;
    }
    if (path == '/admin/operators' || path == '/admin/operators/save' ||
        path == '/admin/operators/remove') {
      if (!canManageAdmin(actor)) {
        await _error(request, HttpStatus.forbidden, 'Admin permission required.');
        return true;
      }
      if (request.method == 'GET') {
        final rows = store.users.map((user) => '''<tr><td>${_e(user.email)}</td>
          <td>${user.isDeleted ? 'Disabled' : 'Active'}</td>
          <td>${user.canManageAdmin}</td><td>${user.canManageOperator}</td>
          <td>${_e(user.createdBy)} / ${_e(user.updatedBy)}</td>
          <td>${_e(user.createdAt)} / ${_e(user.updatedAt)}</td>
          <td><form method="post" action="/admin/operators/remove">${_csrf(request)}
          <input type="hidden" name="email" value="${_e(user.email)}"><button>Disable</button></form></td></tr>''').join();
        await _html(request, _page('Approved AD operators', '''
          <form method="post" action="/admin/operators/save">${_csrf(request)}
          <label>AD email <input name="email" type="email" required></label>
          <label><input type="checkbox" name="canManageAdmin" value="yes"> Manage admins</label>
          <label><input type="checkbox" name="canManageOperator" value="yes"> Send invitations and view journal</label>
          <button>Add or update</button></form>
          <p>To change permissions, enter the same email and select its new permissions.</p>
          <p>Legacy authorized_keys entries remain active and unmanaged.</p>
          ${reloadSshd == null ? '' : '<form method="post" action="/admin/ssh/reload">${_csrf(request)}<button>Force reload sshd</button></form>'}
          <table><tr><th>Email</th><th>Status</th><th>Manage admins</th><th>Manage operators</th><th>Created / updated by</th><th>Created / updated at</th><th></th></tr>$rows</table>'''));
      } else if (request.method == 'POST' &&
          (path.endsWith('/save') || path.endsWith('/remove'))) {
        final form = await _form(request);
        if (!await _checkCsrf(request, form)) return true;
        try {
          final email = form['email'] ?? '';
          if (auth != null &&
              !email.trim().toLowerCase().endsWith('@${auth!.domain}')) {
            throw FormatException('Operator email must belong to ${auth!.domain}.');
          }
          if (path.endsWith('/save')) {
            if (email.trim().toLowerCase() == actor && form['canManageAdmin'] != 'yes') {
              throw StateError('Cannot remove your own admin permission.');
            }
            await store.upsertUser(email, actor,
                canManageAdmin: form['canManageAdmin'] == 'yes',
                canManageOperator: form['canManageOperator'] == 'yes');
          } else {
            await store.removeUser(email, actor);
          }
          await _redirect(request, '/admin/operators');
        } catch (error) {
          await _error(request, HttpStatus.badRequest, '$error');
        }
      } else {
        await _error(request, HttpStatus.methodNotAllowed, 'Method not allowed.');
      }
      return true;
    }
    await _error(request, HttpStatus.notFound, 'Not found.');
    return true;
  }

  String csrfToken(HttpRequest request) => auth == null ? _localCsrf : auth!.csrfFor(request);
  bool checkApiCsrf(HttpRequest request) {
    final token = request.headers.value('x-csrf-token');
    return auth == null ? token == _localCsrf : auth!.validCsrf(request, token);
  }

  String _csrf(HttpRequest request) =>
      '<input type="hidden" name="csrf" value="${_e(csrfToken(request))}">';

  Future<bool> _checkCsrf(HttpRequest request, [Map<String, String>? form]) async {
    form ??= await _form(request);
    final valid = auth == null ? form['csrf'] == _localCsrf :
        auth!.validCsrf(request, form['csrf']);
    if (!valid) await _error(request, HttpStatus.forbidden, 'Invalid form token.');
    return valid;
  }

  String _history(List<Map<String, dynamic>> rows) => rows.isEmpty
      ? '<p>No history yet.</p>'
      : '<table><tr><th>Time (UTC)</th><th>Actor</th><th>Action</th><th>Subject</th><th>Details</th></tr>${rows.map((row) => '<tr><td>${_e('${row['at']}')}</td><td>${_e('${row['actor']}')}</td><td>${_e('${row['action']}')}</td><td>${_e('${row['subject'] ?? ''}')}</td><td>${_e(row.entries.where((e) => !['at','actor','action','subject'].contains(e.key)).map((e) => '${e.key}=${e.value}').join(', '))}</td></tr>').join()}</table>';

  String _page(String title, String body) => '''<!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1"><title>${_e(title)}</title>
    <style>body{font:15px system-ui,sans-serif;max-width:1050px;margin:2rem auto;padding:0 1rem;color:#202124}
    nav a{margin-right:1rem}label{display:block;margin:.8rem 0}input,textarea{font:inherit;padding:.4rem}
    textarea{width:100%}button{padding:.5rem;margin:.3rem 0}table{border-collapse:collapse;width:100%}
    td,th{border-bottom:1px solid #ddd;padding:.5rem;text-align:left}.warn{background:#fff3d7;padding:.8rem}</style>
    </head><body><nav><a href="/help">Help</a><a href="/debug-sessions">Sessions</a>
    <a href="/admin/keys">My key</a><a href="/admin/invite">Send invitation</a>
    <a href="/admin/journal">Journal</a><a href="/admin/operators">Operators</a>
    ${auth == null ? '' : '<a href="/admin/logout">Sign out</a>'}</nav>
    <h1>${_e(title)}</h1>$body</body></html>''';

  static String _e(String value) => const HtmlEscape(HtmlEscapeMode.attribute).convert(value);
  static String _randomToken() {
    final random = Random.secure();
    return List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

Future<Map<String, String>> _form(HttpRequest request) async =>
    Uri.splitQueryString(await utf8.decodeStream(request));

Future<void> _html(HttpRequest request, String body, {int status = 200}) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.html;
  request.response.write(body);
  await request.response.close();
}

Future<void> _error(HttpRequest request, int status, String message) =>
    _html(request, '<h1>Error</h1><p>${const HtmlEscape(HtmlEscapeMode.element).convert(message)}</p>',
        status: status);

Future<void> _redirect(HttpRequest request, String location) async {
  request.response.statusCode = HttpStatus.seeOther;
  request.response.headers.set(HttpHeaders.locationHeader, location);
  await request.response.close();
}
