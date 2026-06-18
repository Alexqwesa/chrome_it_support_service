import 'dart:async';
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
  final Map<int, _ClientStream> _streams = <int, _ClientStream>{};
  final Completer<void> _done = Completer<void>();
  var _stopping = false;

  Future<void> run() async {
    final pcName =
        Platform.environment['COMPUTERNAME'] ?? Platform.localHostname;
    final windowsUser = Platform.environment['USERNAME'] ?? 'unknown';
    stdout.writeln(
      'VSP Chrome Debug Agent\n\n'
      'PC name: $pcName\n'
      'User: $windowsUser\n'
      'Server: ${config.serverUrl}\n\n'
      'Starting Chrome debug profile...',
    );
    _chrome = await ChromeLauncher(chromePath: config.chromePath).start();
    stdout.writeln('Chrome debug endpoint: 127.0.0.1:${_chrome!.port}\n');

    final agentUri = _agentUri(config.serverUrl);
    _webSocket = await WebSocket.connect(
      agentUri.toString(),
      headers: <String, dynamic>{
        HttpHeaders.authorizationHeader: 'Bearer ${config.agentToken}',
      },
    );
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
            'Press Ctrl+C to stop.',
          );
        case TunnelFrameType.open:
          if (frame.streamId != null) unawaited(_openStream(frame.streamId!));
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
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _chrome!.port,
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

  Future<void> stop(String reason) async {
    if (_stopping) return;
    _stopping = true;
    stdout.writeln('\nStopping agent: $reason');
    _heartbeat?.cancel();
    for (final stream in _streams.values) {
      stream.destroy();
    }
    _streams.clear();
    await _webSocket?.close(WebSocketStatus.normalClosure, reason);
    await _chrome?.stop();
    if (!_done.isCompleted) _done.complete();
  }
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
    _ => throw FormatException(
        'RELAY_SERVER_URL must use http, https, ws, or wss.'),
  };
  return serverUrl.replace(scheme: scheme, path: '/agent', query: null);
}
