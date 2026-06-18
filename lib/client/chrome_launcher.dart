import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ChromeDebugSession {
  ChromeDebugSession({
    required this.process,
    required this.port,
    required this.profileDirectory,
  });

  final Process process;
  final int port;
  final Directory profileDirectory;

  Future<void> stop() async {
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    try {
      await profileDirectory.delete(recursive: true);
    } on FileSystemException {
      // Chrome can briefly retain profile files while shutting down.
    }
  }
}

class ChromeLauncher {
  ChromeLauncher({
    this.portStart = 9222,
    this.portEnd = 9299,
    this.chromePath,
  });

  final int portStart;
  final int portEnd;
  final String? chromePath;

  Future<ChromeDebugSession> start() async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
          'The client agent currently supports Windows only.');
    }
    final executable = await findChrome();
    final port = await findFreePort();
    final profile = await Directory.systemTemp.createTemp('vsp-debug-chrome-');
    final process = await Process.start(
      executable,
      <String>[
        '--remote-debugging-address=127.0.0.1',
        '--remote-debugging-port=$port',
        '--user-data-dir=${profile.path}',
        '--no-first-run',
        '--no-default-browser-check',
        'about:blank',
      ],
      mode: ProcessStartMode.detachedWithStdio,
    );

    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    final session = ChromeDebugSession(
      process: process,
      port: port,
      profileDirectory: profile,
    );
    try {
      await _waitForDebugEndpoint(port, process);
      return session;
    } catch (_) {
      await session.stop();
      rethrow;
    }
  }

  Future<String> findChrome() async {
    final configured = chromePath ?? Platform.environment['CHROME_PATH'];
    final candidates = <String>[
      if (configured != null && configured.isNotEmpty) configured,
      '${Platform.environment['PROGRAMFILES'] ?? ''}\\Google\\Chrome\\Application\\chrome.exe',
      '${Platform.environment['PROGRAMFILES(X86)'] ?? ''}\\Google\\Chrome\\Application\\chrome.exe',
      '${Platform.environment['LOCALAPPDATA'] ?? ''}\\Google\\Chrome\\Application\\chrome.exe',
    ];
    for (final candidate in candidates) {
      if (candidate.isNotEmpty && await File(candidate).exists()) {
        return candidate;
      }
    }
    final where = await Process.run('where.exe', <String>['chrome.exe']);
    if (where.exitCode == 0) {
      final first = LineSplitter.split(where.stdout.toString()).firstOrNull;
      if (first != null && await File(first).exists()) {
        return first;
      }
    }
    throw StateError(
      'Google Chrome was not found. Set CHROME_PATH to chrome.exe.',
    );
  }

  Future<int> findFreePort() async {
    for (var port = portStart; port <= portEnd; port++) {
      try {
        final socket =
            await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        await socket.close();
        return port;
      } on SocketException {
        // Try the next fixed-range port.
      }
    }
    throw StateError('No free Chrome debug port in $portStart-$portEnd.');
  }

  Future<void> _waitForDebugEndpoint(int port, Process process) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      for (var attempt = 0; attempt < 30; attempt++) {
        try {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:$port/json/version'),
          );
          final response = await request.close();
          await response.drain<void>();
          if (response.statusCode == HttpStatus.ok) {
            return;
          }
        } on SocketException {
          // Chrome is still starting.
        }
        if (await _hasExited(process)) {
          throw StateError(
              'Chrome exited before its debug endpoint was ready.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } finally {
      client.close(force: true);
    }
    throw TimeoutException('Chrome debug endpoint did not become ready.');
  }

  Future<bool> _hasExited(Process process) async {
    try {
      await process.exitCode.timeout(Duration.zero);
      return true;
    } on TimeoutException {
      return false;
    }
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
