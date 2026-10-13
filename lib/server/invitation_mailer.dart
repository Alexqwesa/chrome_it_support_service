import 'dart:io';

import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';

class InvitationMailer {
  InvitationMailer({
    required this.host,
    required this.port,
    required this.from,
    required this.user,
    required this.password,
    required this.ssl,
    required this.allowStartTls,
  });

  final String host;
  final int port;
  final String from;
  final String? user;
  final String? password;
  final bool ssl;
  final bool allowStartTls;

  bool get configured => host.isNotEmpty && from.isNotEmpty;

  Future<void> sendInvitation(String to, String subject, String body) async {
    if (!configured) throw StateError('SMTP is not configured.');
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(to) ||
        to.contains('\n') || to.contains('\r')) {
      throw const FormatException('Invalid recipient email.');
    }
    final message = Message()
      ..from = Address(from)
      ..recipients.add(to)
      ..subject = subject
      ..text = body;
    final server = SmtpServer(host,
        port: port,
        username: user,
        password: password,
        ssl: ssl,
        allowInsecure: !allowStartTls);
    await send(message, server, timeout: const Duration(seconds: 30));
    stdout.writeln('Invitation SMTP accepted for $to');
  }
}
