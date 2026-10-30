import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dartdap/dartdap.dart';

import 'operator_store.dart';

class OperatorAuth {
  OperatorAuth({
    required this.store,
    required this.domain,
    required this.host,
    required this.port,
    required this.bindDn,
    required this.bindPassword,
    required this.secureCookie,
    this.timeout = const Duration(seconds: 8),
  });

  final OperatorStore store;
  final String domain;
  final String host;
  final int port;
  final String bindDn;
  final String bindPassword;
  final bool secureCookie;
  final Duration timeout;
  final Map<String, _LoginSession> _sessions = {};
  final Map<String, List<DateTime>> _failures = {};
  final Random _random = Random.secure();

  bool _reject(String email) {
    (_failures[email] ??= []).add(DateTime.now());
    return false;
  }

  String? _attribute(SearchEntry entry, String name) {
    for (final attribute in entry.attributes.entries) {
      if (attribute.key.toLowerCase() == name.toLowerCase()) {
        return attribute.value.values.firstOrNull?.toString();
      }
    }
    return null;
  }

  String? userFor(HttpRequest request) {
    final cookie = request.cookies.where((c) => c.name == 'relay_session').firstOrNull;
    if (cookie == null) return null;
    final session = _sessions[cookie.value];
    if (session == null || DateTime.now().isAfter(session.expiresAt)) {
      _sessions.remove(cookie.value);
      return null;
    }
    return store.get(session.email) == null ? null : session.email;
  }

  bool validCsrf(HttpRequest request, String? token) {
    final cookie = request.cookies.where((c) => c.name == 'relay_session').firstOrNull;
    final session = cookie == null ? null : _sessions[cookie.value];
    return session != null && token != null && token == session.csrf &&
        userFor(request) != null;
  }

  String csrfFor(HttpRequest request) {
    final cookie = request.cookies.where((c) => c.name == 'relay_session').first;
    return _sessions[cookie.value]!.csrf;
  }

  Future<bool> signIn(HttpRequest request, String email, String password) async {
    email = email.trim().toLowerCase();
    final traceId = _token().substring(0, 8);
    if (store.get(email) == null || password.isEmpty ||
        !email.endsWith('@$domain')) {
      stdout.writeln('AD login [$traceId] rejected before LDAP: account not approved, invalid domain, or empty password.');
      return false;
    }
    final recentFailures = _failures[email] ??= [];
    recentFailures.removeWhere((at) =>
        DateTime.now().difference(at) > const Duration(minutes: 5));
    if (recentFailures.length >= 10) {
      stdout.writeln('AD login [$traceId] rejected: too many recent failures for $email.');
      return false;
    }
    stdout.writeln(
        'AD login [$traceId] starting for $email via LDAPS $host:$port '
        '(timeout ${timeout.inSeconds}s per stage).');
    final search = LdapConnection(host: host, port: port, ssl: true);
    try {
      await _stage(traceId, 'search connection', search.open);
      final bind = await _stage(traceId, 'search account bind',
          () => search.bind(dn: DN(bindDn), password: bindPassword));
      if (bind.resultCode != ResultCode.OK) {
        stderr.writeln('AD login [$traceId] search account bind refused: ${bind.resultCode}.');
        return _reject(email);
      }
      final base = DN(domain.split('.').map((part) => 'DC=$part').join(','));
      final result = await _stage(traceId, 'directory search', () =>
          search.search(base, Filter.equals('mail', email),
              ['mail', 'userAccountControl'], sizeLimit: 2));
      final entries = await _stage(traceId, 'directory results',
          () => result.stream.toList());
      final matches = <SearchEntry>[];
      for (final entry in entries) {
        if (!entry.hasReferrals && entry.dn.toString().trim().isNotEmpty &&
            _attribute(entry, 'mail')?.toLowerCase() == email) {
          matches.add(entry);
        }
      }
      stdout.writeln('AD login [$traceId] directory returned ${entries.length} '
          'entries, ${matches.length} exact email matches.');
      if (matches.length != 1) {
        return _reject(email);
      }
      final disabled = int.tryParse(
              _attribute(matches.single, 'userAccountControl') ?? '') ?? 0;
      if (disabled & 2 != 0) {
        stderr.writeln('AD login [$traceId] account is disabled in AD.');
        return _reject(email);
      }
      final user = LdapConnection(host: host, port: port, ssl: true);
      try {
        await _stage(traceId, 'user connection', user.open);
        final verified = await _stage(traceId, 'user password bind',
            () => user.bind(dn: matches.single.dn, password: password));
        if (verified.resultCode != ResultCode.OK) {
          stderr.writeln('AD login [$traceId] user password bind refused: ${verified.resultCode}.');
          return _reject(email);
        }
      } finally {
        if (user.isReady || user.isBound) await user.close();
      }
      final id = _token();
      _failures.remove(email);
      _sessions[id] = _LoginSession(email, _token(),
          DateTime.now().add(const Duration(hours: 8)));
      request.response.cookies.add(Cookie('relay_session', id)
        ..httpOnly = true
        ..secure = secureCookie
        ..sameSite = SameSite.strict
        ..path = '/'
        ..maxAge = 8 * 60 * 60);
      stdout.writeln('AD login [$traceId] succeeded for $email.');
      return true;
    } catch (error) {
      stderr.writeln('AD login [$traceId] failed for $email: $error');
      return _reject(email);
    } finally {
      if (search.isReady || search.isBound) await search.close();
    }
  }

  Future<T> _stage<T>(String traceId, String name, Future<T> Function() action) async {
    final timer = Stopwatch()..start();
    stdout.writeln('AD login [$traceId] $name started.');
    try {
      final value = await action().timeout(timeout);
      stdout.writeln('AD login [$traceId] $name completed in ${timer.elapsedMilliseconds} ms.');
      return value;
    } on TimeoutException {
      stderr.writeln('AD login [$traceId] $name timed out after ${timer.elapsedMilliseconds} ms '
          '(limit ${timeout.inSeconds}s).');
      rethrow;
    } catch (error) {
      stderr.writeln('AD login [$traceId] $name failed after ${timer.elapsedMilliseconds} ms: '
          '${error.runtimeType}: $error');
      rethrow;
    }
  }

  void signOut(HttpRequest request) {
    final cookie = request.cookies.where((c) => c.name == 'relay_session').firstOrNull;
    if (cookie != null) _sessions.remove(cookie.value);
    request.response.cookies.add(Cookie('relay_session', '')
      ..httpOnly = true
      ..secure = secureCookie
      ..path = '/'
      ..maxAge = 0);
  }

  String _token() => List<int>.generate(32, (_) => _random.nextInt(256))
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

class _LoginSession {
  _LoginSession(this.email, this.csrf, this.expiresAt);
  final String email;
  final String csrf;
  final DateTime expiresAt;
}
