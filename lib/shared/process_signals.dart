import 'dart:async';
import 'dart:io';

void watchProcessSignal(
  ProcessSignal signal,
  FutureOr<void> Function() onSignal,
) {
  if (Platform.isWindows && signal == ProcessSignal.sigterm) {
    stderr.writeln('Signal ${signal.toString()} is not supported on Windows.');
    return;
  }
  try {
    signal.watch().listen((_) => unawaited(Future<void>.sync(onSignal)));
  } catch (error) {
    stderr.writeln('Signal ${signal.toString()} is not supported: $error');
  }
}
