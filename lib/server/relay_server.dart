import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../shared/agent_protocol.dart';
import '../shared/port_allocator.dart';
import '../shared/tunnel_frames.dart';
import 'html_page.dart';
import 'session_registry.dart';

class RelayServerConfig {
  RelayServerConfig.fromEnvironment(Map<String, String> env)
      : httpPort = _int(env, 'SERVER_HTTP_PORT', 9998),
        httpBind = env['SERVER_HTTP_BIND'] ?? '0.0.0.0',
        tunnelBind = env['SERVER_TUNNEL_BIND'] ?? '127.0.0.1',
        portStart = _int(env, 'SERVER_PORT_START', 41000),
        portEnd = _int(env, 'SERVER_PORT_END', 41049),
        agentToken = _required(env, 'AGENT_ENROLLMENT_TOKEN'),
        adminUsername = env['ADMIN_USERNAME'] ?? 'admin',
        adminPassword = _optionalSecret(env, 'ADMIN_PASSWORD'),
        sessionListRequiresAuth =
            _bool(env, 'SESSION_LIST_REQUIRES_AUTH', false),
        sshRelayHost =
            env['SSH_RELAY_HOST'] ?? 'debug-tunnel@softapp.vietsov.com.vn',
        sshRelayPort = _int(env, 'SSH_RELAY_PORT', 2222),
        clientDownloadUrl =
            env['CLIENT_DOWNLOAD_URL'] ?? '/download/client_debug_agent.exe',
        heartbeatTimeout = Duration(
          seconds: _int(env, 'HEARTBEAT_TIMEOUT_SECONDS', 60),
        ),
        sessionTimeout = Duration(
          seconds: _int(env, 'SESSION_TIMEOUT_SECONDS', 28800),
        );

  final int httpPort;
  final String httpBind;
  final String tunnelBind;
  final int portStart;
  final int portEnd;
  final String agentToken;
  final String adminUsername;
  final String? adminPassword;
  final bool sessionListRequiresAuth;
  final String sshRelayHost;
  final int sshRelayPort;
  final String clientDownloadUrl;
  final Duration heartbeatTimeout;
  final Duration sessionTimeout;

  static int _int(Map<String, String> env, String key, int fallback) {
    return int.tryParse(env[key] ?? '') ?? fallback;
  }

  static bool _bool(Map<String, String> env, String key, bool fallback) {
    final value = env[key]?.trim().toLowerCase();
    if (value == null || value.isEmpty) return fallback;
    return value == '1' || value == 'true' || value == 'yes' || value == 'on';
  }

  static String _required(Map<String, String> env, String key) {
    final value = env[key];
    if (value == null || value.isEmpty || value == 'change-me') {
      throw StateError('$key must be set to a non-default value.');
    }
    return value;
  }

  static String? _optionalSecret(Map<String, String> env, String key) {
    final value = env[key];
    if (value == null ||
        value.isEmpty ||
        value == 'change-me' ||
        value.startsWith('replace-with-')) {
      return null;
    }
    return value;
  }
}

class RelayServer {
  RelayServer(this.config)
      : _allocator = PortAllocator(config.portStart, config.portEnd);

  final RelayServerConfig config;
  final PortAllocator _allocator;
  final SessionRegistry _registry = SessionRegistry();
  final Map<String, _ServerTunnel> _tunnels = <String, _ServerTunnel>{};
  HttpServer? _httpServer;
  Timer? _sweepTimer;
  var _nextSessionId = 1;

  int? get boundHttpPort => _httpServer?.port;

  Future<void> start() async {
    _httpServer = await HttpServer.bind(config.httpBind, config.httpPort);
    _httpServer!.listen(_handleRequest);
    _sweepTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_sweepStaleSessions());
    });
    stdout.writeln(
      'Debug relay listening on ${config.httpBind}:${config.httpPort}; '
      'tunnel range ${config.tunnelBind}:${config.portStart}-${config.portEnd}',
    );
  }

  Future<void> stop() async {
    _sweepTimer?.cancel();
    for (final id in _registry.sessions.map((session) => session.id).toList()) {
      await disconnect(id, reason: 'server shutting down');
    }
    await _httpServer?.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.uri.path == '/health' && request.method == 'GET') {
        return _text(request, HttpStatus.ok, 'ok');
      }
      if (request.uri.path == '/agent') {
        return _acceptAgent(request);
      }
      if (request.uri.path == '/debug-sessions' && request.method == 'GET') {
        if (config.sessionListRequiresAuth && !await _requireAdmin(request)) {
          return;
        }
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          renderSessionsPage(
            _registry.sessions,
            sshHost: config.sshRelayHost,
            sshPort: config.sshRelayPort,
            clientDownloadUrl: config.clientDownloadUrl,
            canDisconnect: config.adminPassword != null,
          ),
        );
        return request.response.close();
      }
      if (request.uri.path == '/api/sessions' && request.method == 'GET') {
        if (config.sessionListRequiresAuth && !await _requireAdmin(request)) {
          return;
        }
        return _json(
          request,
          HttpStatus.ok,
          _registry.sessions
              .map(
                (session) => session.toJson(
                  sshHost: config.sshRelayHost,
                  sshPort: config.sshRelayPort,
                ),
              )
              .toList(),
        );
      }
      final match = RegExp(r'^/api/sessions/([^/]+)/disconnect$')
          .firstMatch(request.uri.path);
      if (match != null && request.method == 'POST') {
        if (!await _requireAdmin(request)) return;
        final id = Uri.decodeComponent(match.group(1)!);
        if (_registry[id] == null) {
          return _text(request, HttpStatus.notFound, 'Session not found.');
        }
        await disconnect(id, reason: 'disconnected by administrator');
        return _json(request, HttpStatus.ok, <String, Object?>{'ok': true});
      }
      return _text(request, HttpStatus.notFound, 'Not found.');
    } catch (error, stackTrace) {
      stderr.writeln('Request failed: $error\n$stackTrace');
      try {
        await _text(request, HttpStatus.internalServerError, 'Internal error.');
      } on StateError {
        await request.response.close();
      }
    }
  }

  Future<void> _acceptAgent(HttpRequest request) async {
    if (request.method != 'GET' ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      return _text(
          request, HttpStatus.badRequest, 'WebSocket upgrade required.');
    }
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer ${config.agentToken}') {
      return _text(request, HttpStatus.unauthorized, 'Invalid agent token.');
    }
    final webSocket = await WebSocketTransformer.upgrade(request);
    var registered = false;
    var registering = false;
    _ServerTunnel? tunnel;
    final registrationTimer = Timer(const Duration(seconds: 10), () {
      if (!registered) {
        webSocket.close(
            WebSocketStatus.policyViolation, 'Registration timeout');
      }
    });
    webSocket.listen(
      (raw) async {
        if (tunnel != null) {
          tunnel!.handleFrame(raw);
        } else if (!registering) {
          registering = true;
          try {
            final frame = TunnelFrame.decode(raw);
            if (frame.type != TunnelFrameType.register) {
              throw const FormatException(
                  'First frame must register the agent.');
            }
            registered = true;
            registrationTimer.cancel();
            tunnel = await _registerAgent(
              webSocket,
              AgentRegistration.fromJson(frame.metadata),
            );
          } catch (error) {
            await webSocket.close(WebSocketStatus.policyViolation, '$error');
          }
        }
      },
      onDone: () {
        registrationTimer.cancel();
        tunnel?.onDone?.call();
      },
      onError: (_) {
        registrationTimer.cancel();
        tunnel?.onDone?.call();
      },
      cancelOnError: true,
    );
  }

  Future<_ServerTunnel?> _registerAgent(
    WebSocket webSocket,
    AgentRegistration registration,
  ) async {
    final allocation = await _allocateTunnelSocket();
    if (allocation == null) {
      await webSocket.close(
        1013,
        'No relay ports available',
      );
      return null;
    }
    final (port, serverSocket) = allocation;
    final id = '${DateTime.now().millisecondsSinceEpoch}-${_nextSessionId++}';
    final session = RelaySession(
      id: id,
      registration: registration,
      serverPort: port,
      webSocket: webSocket,
      tunnelSocket: serverSocket,
    );
    final tunnel = _ServerTunnel(webSocket, serverSocket);
    _registry.add(session);
    _tunnels[id] = tunnel;
    tunnel.onHeartbeat = () => session.lastHeartbeat = DateTime.now().toUtc();
    tunnel.onDone =
        () => unawaited(disconnect(id, reason: 'agent disconnected'));
    webSocket.add(
      TunnelFrame(
        type: TunnelFrameType.registered,
        metadata: <String, Object?>{'sessionId': id, 'serverPort': port},
      ).encode(),
    );
    tunnel.start();
    _logConnected(session);
    return tunnel;
  }

  Future<(int, ServerSocket)?> _allocateTunnelSocket() async {
    while (true) {
      final port = _allocator.allocate();
      if (port == null) return null;
      try {
        final socket = await ServerSocket.bind(config.tunnelBind, port);
        return (port, socket);
      } on SocketException {
        stderr.writeln('Relay port $port is already in use; skipping it.');
      }
    }
  }

  Future<void> disconnect(String id, {required String reason}) async {
    final session = _registry.remove(id);
    final tunnel = _tunnels.remove(id);
    if (session == null) return;
    _allocator.release(session.serverPort);
    await tunnel?.close(reason);
    final duration = DateTime.now().toUtc().difference(session.connectedAt);
    stdout.writeln(
      '\n[DISCONNECTED]\n'
      'PC: ${session.registration.pcName}\n'
      'Released port: ${session.serverPort}\n'
      'Reason: $reason\n'
      'Duration: ${_formatDuration(duration)}',
    );
  }

  Future<void> _sweepStaleSessions() async {
    final now = DateTime.now().toUtc();
    for (final session in _registry.sessions.toList()) {
      if (now.difference(session.lastHeartbeat) > config.heartbeatTimeout) {
        await disconnect(session.id, reason: 'heartbeat timeout');
      } else if (now.difference(session.connectedAt) > config.sessionTimeout) {
        await disconnect(session.id, reason: 'session timeout');
      }
    }
  }

  bool _isAdmin(HttpRequest request) {
    final password = config.adminPassword;
    if (password == null) return false;
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Basic ')) return false;
    try {
      final credentials = utf8.decode(base64Decode(header.substring(6)));
      return credentials == '${config.adminUsername}:$password';
    } on FormatException {
      return false;
    }
  }

  Future<bool> _requireAdmin(HttpRequest request) async {
    if (_isAdmin(request)) return true;
    if (config.adminPassword == null) {
      await _text(
        request,
        HttpStatus.forbidden,
        'Admin password is not configured for this operation.',
      );
      return false;
    }
    request.response.headers.set(
      HttpHeaders.wwwAuthenticateHeader,
      'Basic realm="Chrome debug relay"',
    );
    await _text(request, HttpStatus.unauthorized, 'Authentication required.');
    return false;
  }

  void _logConnected(RelaySession session) {
    stdout.writeln(
      '\n[CONNECTED]\n'
      'PC: ${session.registration.pcName}\n'
      'User: ${session.registration.windowsUser}\n'
      'Agent: ${session.registration.agentVersion}\n'
      'Server local port: 127.0.0.1:${session.serverPort}\n'
      'Client Chrome: 127.0.0.1:${session.registration.localChromePort}\n'
      'Connected at: ${session.connectedAt.toLocal()}',
    );
  }
}

class _ServerTunnel {
  _ServerTunnel(this.webSocket, this.serverSocket);

  final WebSocket webSocket;
  final ServerSocket serverSocket;
  final Map<int, Socket> _streams = <int, Socket>{};
  var _nextStreamId = 1;
  var _closed = false;
  void Function()? onHeartbeat;
  void Function()? onDone;

  void start() {
    serverSocket.listen(_acceptSocket, onError: (_) => onDone?.call());
  }

  void _acceptSocket(Socket socket) {
    if (_closed) return socket.destroy();
    final streamId = _nextStreamId++;
    _streams[streamId] = socket;
    _send(TunnelFrame(type: TunnelFrameType.open, streamId: streamId));
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
  }

  void handleFrame(Object? raw) {
    try {
      final frame = TunnelFrame.decode(raw);
      switch (frame.type) {
        case TunnelFrameType.data:
          final socket = _streams[frame.streamId];
          if (socket != null && frame.data != null) socket.add(frame.data!);
        case TunnelFrameType.close:
        case TunnelFrameType.error:
          if (frame.streamId != null) {
            _closeStream(frame.streamId!, notifyPeer: false);
          }
        case TunnelFrameType.heartbeat:
          onHeartbeat?.call();
        case TunnelFrameType.register:
        case TunnelFrameType.registered:
        case TunnelFrameType.open:
          break;
      }
    } on FormatException catch (error) {
      stderr.writeln('Invalid agent frame: $error');
    }
  }

  void _closeStream(int streamId, {required bool notifyPeer}) {
    final socket = _streams.remove(streamId);
    socket?.destroy();
    if (notifyPeer) {
      _send(TunnelFrame(type: TunnelFrameType.close, streamId: streamId));
    }
  }

  void _send(TunnelFrame frame) {
    if (!_closed && webSocket.readyState == WebSocket.open) {
      webSocket.add(frame.encode());
    }
  }

  Future<void> close(String reason) async {
    if (_closed) return;
    _closed = true;
    for (final socket in _streams.values.toList()) {
      socket.destroy();
    }
    _streams.clear();
    await serverSocket.close();
    await webSocket.close(WebSocketStatus.normalClosure, reason);
  }
}

Future<void> _text(HttpRequest request, int status, String body) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.text
    ..write(body);
  await request.response.close();
}

Future<void> _json(HttpRequest request, int status, Object? body) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  await request.response.close();
}

String _formatDuration(Duration duration) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(duration.inHours)}:${two(duration.inMinutes % 60)}:${two(duration.inSeconds % 60)}';
}
