import 'dart:async';
import 'dart:io';

import 'package:dartdap/dartdap.dart';

String? ldapAttribute(SearchEntry entry, String name) {
  for (final attribute in entry.attributes.entries) {
    if (attribute.key.toLowerCase() == name.toLowerCase()) {
      final value = attribute.value.values.firstOrNull?.toString().trim();
      return value == null || value.isEmpty ? null : value;
    }
  }
  return null;
}

bool ldapEntryMatchesEmail(SearchEntry entry, String email) =>
    !entry.hasReferrals &&
    entry.dn.toString().trim().isNotEmpty &&
    ldapAttribute(entry, 'mail')?.toLowerCase() == email.trim().toLowerCase();

bool ldapEntryIsActive(SearchEntry entry) {
  final control =
      int.tryParse(ldapAttribute(entry, 'userAccountControl') ?? '');
  return control == null || (control & 2) == 0;
}

SearchEntry? uniqueActiveLdapEmailEntry(
    Iterable<SearchEntry> entries, String email) {
  SearchEntry? match;
  for (final entry in entries) {
    if (!ldapEntryMatchesEmail(entry, email) || !ldapEntryIsActive(entry)) {
      continue;
    }
    if (match != null) {
      throw StateError('Multiple active LDAP users have email $email.');
    }
    match = entry;
  }
  return match;
}

class LdapCredentialValidator {
  const LdapCredentialValidator({
    required this.domain,
    required this.host,
    required this.port,
    required this.bindDn,
    required this.bindPassword,
    required this.timeout,
    this.acceptBadCertificate = false,
    this.debugLogging = false,
  });

  final String domain;
  final String host;
  final int port;
  final String bindDn;
  final String bindPassword;
  final Duration timeout;
  final bool acceptBadCertificate;
  final bool debugLogging;

  LdapConnection _connection() => LdapConnection(
        host: host,
        port: port,
        ssl: true,
        badCertificateHandler: acceptBadCertificate
            ? (_) => true
            : LdapConnection.defaultBadCertHandler,
      );

  Future<bool> validate(String email, String password, String traceId) async {
    if (password.isEmpty) return false;
    final search = _connection();
    try {
      await _stage(traceId, 'search connection', search.open);
      final bind = await _stage(traceId, 'search account bind',
          () => search.bind(dn: DN(bindDn), password: bindPassword));
      if (bind.resultCode != ResultCode.OK) {
        stderr.writeln(
            'AD login [$traceId] search account bind refused: ${bind.resultCode}.');
        return false;
      }
      final base = DN(domain.split('.').map((part) => 'DC=$part').join(','));
      final result = await _stage(
          traceId,
          'directory search',
          () => search.search(base, Filter.equals('mail', email),
              ['sAMAccountName', 'mail', 'givenName', 'userAccountControl'],
              sizeLimit: 100));
      final entries = await _stage(
          traceId, 'directory results', () => result.stream.toList());
      final match = uniqueActiveLdapEmailEntry(entries, email);
      if (debugLogging) {
        stdout.writeln('AD login [$traceId] directory returned ${entries.length} entries; '
            'unique active exact-email match: ${match != null}.');
      }
      if (match == null || ldapAttribute(match, 'sAMAccountName') == null) {
        return false;
      }
      final user = _connection();
      try {
        await _stage(traceId, 'user connection', user.open);
        final verified = await _stage(traceId, 'user password bind',
            () => user.bind(dn: match.dn, password: password));
        if (verified.resultCode != ResultCode.OK) {
          stderr.writeln(
              'AD login [$traceId] user password bind refused: ${verified.resultCode}.');
          return false;
        }
        return true;
      } finally {
        if (user.isReady || user.isBound) await user.close();
      }
    } finally {
      if (search.isReady || search.isBound) await search.close();
    }
  }

  Future<T> _stage<T>(
      String traceId, String name, Future<T> Function() action) async {
    final timer = Stopwatch()..start();
    if (debugLogging) {
      stdout.writeln('AD login [$traceId] $name started.');
    }
    try {
      final value = await action().timeout(timeout);
      if (debugLogging) {
        stdout.writeln('AD login [$traceId] $name completed in ${timer.elapsedMilliseconds} ms.');
      }
      return value;
    } on TimeoutException {
      stderr.writeln(
          'AD login [$traceId] $name timed out after ${timer.elapsedMilliseconds} ms '
          '(limit ${timeout.inSeconds}s).');
      rethrow;
    } catch (error) {
      stderr.writeln(
          'AD login [$traceId] $name failed after ${timer.elapsedMilliseconds} ms: '
          '${error.runtimeType}: $error');
      rethrow;
    }
  }
}
