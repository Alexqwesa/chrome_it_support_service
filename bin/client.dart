import 'dart:async';
import 'dart:io';

import 'package:chrome_it_support_service/debug_agent.dart';
import 'package:chrome_it_support_service/env_loader.dart';
import 'package:chrome_it_support_service/process_signals.dart';

Future<void> main() async {
  try {
    final environment = await loadMergedEnvironment();
    final agent = DebugAgent(DebugAgentConfig.fromEnvironment(environment));
    watchProcessSignal(ProcessSignal.sigint, () => agent.stop('Ctrl+C'));
    await agent.run();
  } catch (error, stackTrace) {
    stderr.writeln('\nAgent failed: $error\n$stackTrace');
    exitCode = 1;
  }
}
