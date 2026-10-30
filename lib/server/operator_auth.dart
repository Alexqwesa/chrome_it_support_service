import 'dart:io';
import 'dart:math';

import 'ldap_credential_validator.dart';
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
    this.acceptBadCertificate = false,
    this.debugLogging = false,
  });

  final OperatorStore store;
  final String domain;
  final String host;
  final int port;
  final String bindDn;
  final String bindPassword;
  final bool secureCookie;
  final Duration timeout;
  final bool acceptBadCertificate;
  final bool debugLogging;
  final Map<String, _LoginSession> _sessions = {};
  final Map<String, List<DateTime>> _failures = {};
  final Random _random = Random.secure();

  bool _reject(String email) {
    (_failures[email] ??= []).add(DateTime.now());
    return false;
  }

  String? userFor(HttpRequest request) {
    final cookie =
        request.cookies.where((c) => c.name == 'relay_session').firstOrNull;
    if (cookie == null) return null;
    final session = _sessions[cookie.value];
    if (session == null || DateTime.now().isAfter(session.expiresAt)) {
      _sessions.remove(cookie.value);
      return null;
    }
    return store.get(session.email) == null ? null : session.email;
  }

  bool validCsrf(HttpRequest request, String? token) {
    final cookie =
        request.cookies.where((c) => c.name == 'relay_session').firstOrNull;
    final session = cookie == null ? null : _sessions[cookie.value];
    return session != null &&
        token != null &&
        token == session.csrf &&
        userFor(request) != null;
  }

  String csrfFor(HttpRequest request) {
    final cookie =
        request.cookies.where((c) => c.name == 'relay_session').first;
    return _sessions[cookie.value]!.csrf;
  }

  Future<bool> signIn(
      HttpRequest request, String email, String password) async {
    email = email.trim().toLowerCase();
    final traceId = _token().substring(0, 8);
    if (store.get(email) == null ||
        password.isEmpty ||
        !email.endsWith('@$domain')) {
      stdout.writeln(
          'AD login [$traceId] rejected before LDAP: account not approved, invalid domain, or empty password.');
      return false;
    }
    final recentFailures = _failures[email] ??= [];
    recentFailures.removeWhere(
        (at) => DateTime.now().difference(at) > const Duration(minutes: 5));
    if (recentFailures.length >= 10) {
      stdout.writeln(
          'AD login [$traceId] rejected: too many recent failures for $email.');
      return false;
    }
    if (debugLogging) {
      stdout.writeln(
        'AD login [$traceId] starting for $email via LDAPS $host:$port '
        '(timeout ${timeout.inSeconds}s per stage).');
    }
    try {
      final verified = await LdapCredentialValidator(
        domain: domain,
        host: host,
        port: port,
        bindDn: bindDn,
        bindPassword: bindPassword,
        timeout: timeout,
        acceptBadCertificate: acceptBadCertificate,
        debugLogging: debugLogging,
      ).validate(email, password, traceId);
      if (!verified) return _reject(email);
      final id = _token();
      _failures.remove(email);
      _sessions[id] = _LoginSession(
          email, _token(), DateTime.now().add(const Duration(hours: 8)));
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
    }
  }

  void signOut(HttpRequest request) {
    final cookie =
        request.cookies.where((c) => c.name == 'relay_session').firstOrNull;
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
