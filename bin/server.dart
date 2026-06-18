import 'dart:async';
import 'dart:io';

import 'package:chrome_it_support_service/relay_server.dart';

Future<void> main() async {
  try {
    final server =
        RelayServer(RelayServerConfig.fromEnvironment(Platform.environment));
    await server.start();
    ProcessSignal.sigint.watch().listen((_) => unawaited(server.stop()));
    ProcessSignal.sigterm.watch().listen((_) => unawaited(server.stop()));
  } catch (error, stackTrace) {
    stderr.writeln('Server failed: $error\n$stackTrace');
    exitCode = 1;
  }
}
