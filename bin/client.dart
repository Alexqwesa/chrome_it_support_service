import 'dart:async';
import 'dart:io';

import 'package:chrome_it_support_service/debug_agent.dart';

Future<void> main() async {
  try {
    final agent =
        DebugAgent(DebugAgentConfig.fromEnvironment(Platform.environment));
    ProcessSignal.sigint.watch().listen((_) => unawaited(agent.stop('Ctrl+C')));
    await agent.run();
  } catch (error, stackTrace) {
    stderr.writeln('\nAgent failed: $error\n$stackTrace');
    exitCode = 1;
  }
}
