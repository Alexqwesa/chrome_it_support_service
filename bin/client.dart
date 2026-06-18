import 'dart:io';

import 'package:chrome_it_support_service/client/client_build_defaults.dart';
import 'package:chrome_it_support_service/client/debug_agent.dart';
import 'package:chrome_it_support_service/shared/config_diagnostics.dart';
import 'package:chrome_it_support_service/shared/env_loader.dart';
import 'package:chrome_it_support_service/shared/process_signals.dart';

Future<void> main() async {
  try {
    final loaded = await loadMergedEnvironmentWithSources(
      defaults: clientBuildDefaults,
      defaultSource: 'compiled client default',
    );
    _printClientDefaultOverrides(loaded);
    _printTokenDiagnostics(loaded);
    final agent = DebugAgent(DebugAgentConfig.fromEnvironment(loaded.values));
    watchProcessSignal(ProcessSignal.sigint, () => agent.stop('Ctrl+C'));
    await agent.run();
  } catch (error, stackTrace) {
    stderr.writeln('\nAgent failed: $error\n$stackTrace');
    exitCode = 1;
  }
}

void _printTokenDiagnostics(LoadedEnvironment loaded) {
  final token = loaded.values['AGENT_ENROLLMENT_TOKEN'];
  stdout.writeln(
    'AGENT_ENROLLMENT_TOKEN source: '
    '${loaded.sources['AGENT_ENROLLMENT_TOKEN'] ?? 'unset'}; '
    '${secretFingerprint(token)}',
  );
}

void _printClientDefaultOverrides(LoadedEnvironment loaded) {
  for (final entry in clientBuildDefaults.entries) {
    final effectiveValue = loaded.values[entry.key];
    final source = loaded.sources[entry.key];
    if (effectiveValue != null &&
        effectiveValue != entry.value &&
        source != null &&
        source != 'compiled client default') {
      stdout.writeln(
        'Config override: ${entry.key} from $source overrides compiled default.',
      );
    }
  }
}
