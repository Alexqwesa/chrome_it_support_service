import 'dart:io';

import 'package:chrome_it_support_service/server/relay_server.dart';
import 'package:chrome_it_support_service/shared/config_diagnostics.dart';
import 'package:chrome_it_support_service/shared/env_loader.dart';
import 'package:chrome_it_support_service/shared/process_signals.dart';

Future<void> main() async {
  try {
    final loaded = await loadMergedEnvironmentWithSources();
    stdout.writeln(
      'AGENT_ENROLLMENT_TOKEN source: '
      '${loaded.sources['AGENT_ENROLLMENT_TOKEN'] ?? 'unset'}; '
      '${secretFingerprint(loaded.values['AGENT_ENROLLMENT_TOKEN'])}',
    );
    final server =
        RelayServer(RelayServerConfig.fromEnvironment(loaded.values));
    await server.start();
    watchProcessSignal(ProcessSignal.sigint, server.stop);
    watchProcessSignal(ProcessSignal.sigterm, server.stop);
  } catch (error, stackTrace) {
    stderr.writeln('Server failed: $error\n$stackTrace');
    exitCode = 1;
  }
}
