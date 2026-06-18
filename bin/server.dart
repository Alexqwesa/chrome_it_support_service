import 'dart:io';

import 'package:chrome_it_support_service/server/relay_server.dart';
import 'package:chrome_it_support_service/shared/env_loader.dart';
import 'package:chrome_it_support_service/shared/process_signals.dart';

Future<void> main() async {
  try {
    final environment = await loadMergedEnvironment();
    final server = RelayServer(RelayServerConfig.fromEnvironment(environment));
    await server.start();
    watchProcessSignal(ProcessSignal.sigint, server.stop);
    watchProcessSignal(ProcessSignal.sigterm, server.stop);
  } catch (error, stackTrace) {
    stderr.writeln('Server failed: $error\n$stackTrace');
    exitCode = 1;
  }
}
