import 'dart:async';
import 'dart:io';

import 'package:chrome_it_support_service/env_loader.dart';
import 'package:chrome_it_support_service/process_signals.dart';
import 'package:chrome_it_support_service/relay_server.dart';

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
