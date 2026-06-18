import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../shared/agent_protocol.dart';
import '../shared/tunnel_frames.dart';
import 'chrome_launcher.dart';

class DebugAgentConfig {
  DebugAgentConfig.fromEnvironment(Map<String, String> env)
      : serverUrl = Uri.parse(_required(env, 'RELAY_SERVER_URL')),
        agentToken = _required(env, 'AGENT_ENROLLMENT_TOKEN'),
        chromePath = env['CHROME_PATH'],
        agentVersion = env['AGENT_VERSION'] ?? '1.0.0';

  final Uri serverUrl;
  final String agentToken;
  final String? chromePath;
  final String agentVersion;

  static String _required(Map<String, String> env, String key) {
    final value = env[key];
    if (value == null ||
        value.isEmpty ||
        value == 'change-me' ||
        value.startsWith('replace-with-')) {
      throw StateError('$key must be set to a non-default value.');
    }
    return value;
  }
}

class DebugAgent {
  DebugAgent(this.config);

  final DebugAgentConfig config;
  ChromeDebugSession? _chrome;
  WebSocket? _webSocket;
  Timer? _heartbeat;
  StreamSubscription<String>? _consoleInput;
  final Map<int, _ClientStream> _streams = <int, _ClientStream>{};
  final Map<String, int> _targetPorts = <String, int>{};
  final Completer<void> _done = Completer<void>();
  var _stopping = false;
  var _nextTargetId = 1;

  Future<void> run() async {
    final pcName = Platform.environment['COMPUTERNAME'] ?? Platform.localHostname;
    final windowsUser = Platform.environment['USERNAME'] ?? 'unknown';
    stdout.writeln(
      'VSP Chrome Debug Agent\n\n'
      'PC name: $pcName\n'
      'User: $windowsUser\n'
      'Server: ${config.serverUrl}\n\n'
      'Starting Chrome debug profile...',
    );
    _chrome = await ChromeLauncher(chromePath: config.chromePath).start();
    _targetPorts['default'] = _chrome!.port;
    stdout.writeln('Chrome debug endpoint: 127.0.0.1:${_chrome!.port}\n');

    final agentUri = _agentUri(config.serverUrl);
    try {
      _webSocket = await WebSocket.connect(
        agentUri.toString(),
        headers: <String, dynamic>{
          HttpHeaders.authorizationHeader: 'Bearer ${config.agentToken}',
        },
      );
    } on WebSocketException catch (error) {
      if ('$error'.contains('HTTP status code: 401')) {
        throw StateError(
          'Server rejected AGENT_ENROLLMENT_TOKEN. Rebuild the client with '
          'the same token as the server or override it at runtime.',
        );
      }
      rethrow;
    }
    _webSocket!.listen(
      _handleFrame,
      onDone: () => unawaited(stop('server disconnected')),
      onError: (Object error) => unawaited(stop('connection error: $error')),
      cancelOnError: true,
    );
    _send(
      TunnelFrame(
        type: TunnelFrameType.register,
        metadata: AgentRegistration(
          pcName: pcName,
          windowsUser: windowsUser,
          localChromePort: _chrome!.port,
          agentVersion: config.agentVersion,
          startedAt: DateTime.now().toUtc(),
        ).toJson(),
      ),
    );
    _heartbeat = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _send(const TunnelFrame(type: TunnelFrameType.heartbeat)),
    );
    _startConsoleInput();
    await _done.future;
  }

  void _handleFrame(Object? raw) {
    try {
      final frame = TunnelFrame.decode(raw);
      switch (frame.type) {
        case TunnelFrameType.registered:
          stdout.writeln(
            'Connected to server.\n'
            'Assigned server port: ${frame.metadata['serverPort']}\n\n'
            'Do not close this window while support is connected.\n'
            'Press Ctrl+C to stop.\n',
          );
        case TunnelFrameType.targetRegistered:
          stdout.writeln(
            '\nAdditional Chrome endpoint registered.\n'
            'Local Chrome: 127.0.0.1:${frame.metadata['localChromePort']}\n'
            'Assigned server port: ${frame.metadata['serverPort']}\n'
            'Ask the operator to refresh /debug-sessions and copy the new SSH command.\n',
          );
        case TunnelFrameType.open:
          if (frame.streamId != null) {
            final targetId = frame.metadata['targetId'];
            if (targetId is String) {
              _lastOpenTargetIds[frame.streamId!] = targetId;
            }
            unawaited(_openStream(frame.streamId!));
          }
        case TunnelFrameType.data:
          final stream = _streams[frame.streamId];
          if (stream != null && frame.data != null) stream.write(frame.data!);
        case TunnelFrameType.close:
        case TunnelFrameType.error:
          if (frame.streamId != null) {
            _closeStream(frame.streamId!, notifyPeer: false);
          }
        case TunnelFrameType.heartbeat:
        case TunnelFrameType.register:
        case TunnelFrameType.addTarget:
          break;
      }
    } on FormatException catch (error) {
      stderr.writeln('Invalid server frame: $error');
    }
  }

  Future<void> _openStream(int streamId) async {
    if (_stopping || _streams.containsKey(streamId)) return;
    final stream = _ClientStream();
    _streams[streamId] = stream;
    try {
      final targetId = _targetIdFromFrame(streamId);
      final port = _targetPorts[targetId];
      if (port == null) {
        throw StateError('Unknown Chrome endpoint target: $targetId');
      }
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 5),
      );
      if (_streams[streamId] != stream) {
        return socket.destroy();
      }
      stream.attach(socket);
      socket.listen(
        (data) => _send(
          TunnelFrame(
            type: TunnelFrameType.data,
            streamId: streamId,
            data: Uint8List.fromList(data),
          ),
        ),
        onDone: () => _closeStream(streamId, notifyPeer: true),
        onError: (Object error) {
          _send(
            TunnelFrame(
              type: TunnelFrameType.error,
              streamId: streamId,
              message: '$error',
            ),
          );
          _closeStream(streamId, notifyPeer: true);
        },
        cancelOnError: true,
      );
    } catch (error) {
      _streams.remove(streamId);
      _send(
        TunnelFrame(
          type: TunnelFrameType.error,
          streamId: streamId,
          message: 'Local Chrome connection failed: $error',
        ),
      );
    }
  }

  void _closeStream(int streamId, {required bool notifyPeer}) {
    _streams.remove(streamId)?.destroy();
    if (notifyPeer) {
      _send(TunnelFrame(type: TunnelFrameType.close, streamId: streamId));
    }
  }

  void _send(TunnelFrame frame) {
    if (_webSocket?.readyState == WebSocket.open) {
      _webSocket!.add(frame.encode());
    }
  }

  String _targetIdFromFrame(int streamId) {
    return _lastOpenTargetIds.remove(streamId) ?? 'default';
  }

  final Map<int, String> _lastOpenTargetIds = <int, String>{};

  void _startConsoleInput() {
    stdout.writeln(
      '==================================================================\n'
      'Optional: to connect to a previously opened Chrome window, open '
      'chrome://inspect/#remote-debugging in that Chrome and paste its '
      '127.0.0.1:PORT debug address here, then press Enter.\n'
      '------------------------------------------------------------------\n',
    );
    _consoleInput = stdin
        .transform(systemEncoding.decoder)
        .transform(const LineSplitter())
        .listen(_handleConsoleLine);
  }

  void _handleConsoleLine(String line) {
    final endpoint = _parseLoopbackEndpoint(line);
    if (endpoint == null) {
      if (line.trim().isNotEmpty) {
        stdout.writeln('Enter a loopback Chrome debug address like 127.0.0.1:9222.');
      }
      return;
    }
    final targetId = 'manual-${_nextTargetId++}';
    _targetPorts[targetId] = endpoint.port;
    _send(
      TunnelFrame(
        type: TunnelFrameType.addTarget,
        metadata: <String, Object?>{
          'targetId': targetId,
          'label': 'Existing Chrome ${endpoint.host}:${endpoint.port}',
          'localChromePort': endpoint.port,
        },
      ),
    );
    stdout.writeln(
      'Requested forwarding for existing Chrome endpoint '
      '${endpoint.host}:${endpoint.port}.',
    );
  }

  _LoopbackEndpoint? _parseLoopbackEndpoint(String input) {
    final trimmed = input.trim();
    final uri = Uri.tryParse(
      trimmed.contains('://') ? trimmed : 'http://$trimmed',
    );
    if (uri == null || uri.host.isEmpty || !uri.hasPort) return null;
    if (uri.host != '127.0.0.1' && uri.host.toLowerCase() != 'localhost') {
      return null;
    }
    if (uri.port <= 0 || uri.port > 65535) return null;
    return _LoopbackEndpoint(uri.host, uri.port);
  }

  Future<void> stop(String reason) async {
    if (_stopping) return;
    _stopping = true;
    stdout.writeln('\nStopping agent: $reason');
    _heartbeat?.cancel();
    await _consoleInput?.cancel();
    for (final stream in _streams.values) {
      stream.destroy();
    }
    _streams.clear();
    await _webSocket?.close(WebSocketStatus.normalClosure, reason);
    await _chrome?.stop();
    if (!_done.isCompleted) _done.complete();
  }
}

class _LoopbackEndpoint {
  const _LoopbackEndpoint(this.host, this.port);

  final String host;
  final int port;
}

class _ClientStream {
  Socket? _socket;
  final List<Uint8List> _pending = <Uint8List>[];

  void attach(Socket socket) {
    _socket = socket;
    for (final data in _pending) {
      socket.add(data);
    }
    _pending.clear();
  }

  void write(Uint8List data) {
    final socket = _socket;
    if (socket == null) {
      _pending.add(data);
    } else {
      socket.add(data);
    }
  }

  void destroy() {
    _pending.clear();
    _socket?.destroy();
  }
}

Uri _agentUri(Uri serverUrl) {
  final scheme = switch (serverUrl.scheme) {
    'https' => 'wss',
    'http' => 'ws',
    'wss' || 'ws' => serverUrl.scheme,
    _ => throw FormatException('RELAY_SERVER_URL must use http, https, ws, or wss.'),
  };
  return serverUrl.replace(scheme: scheme, path: '/agent', query: null);
}
