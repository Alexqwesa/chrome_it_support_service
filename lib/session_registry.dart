import 'dart:io';

import 'agent_protocol.dart';

class RelaySession {
  RelaySession({
    required this.id,
    required this.registration,
    required this.serverPort,
    required this.webSocket,
    required this.tunnelSocket,
  })  : connectedAt = DateTime.now().toUtc(),
        lastHeartbeat = DateTime.now().toUtc();

  final String id;
  final AgentRegistration registration;
  final int serverPort;
  final WebSocket webSocket;
  final ServerSocket tunnelSocket;
  final DateTime connectedAt;
  DateTime lastHeartbeat;

  Map<String, Object?> toJson({required String sshHost}) {
    return <String, Object?>{
      'id': id,
      ...registration.toJson(),
      'serverPort': serverPort,
      'server_local_port': serverPort,
      'serverAddress': '127.0.0.1:$serverPort',
      'connectedAt': connectedAt.toIso8601String(),
      'time_of_begin_of_connection': connectedAt.toIso8601String(),
      'lastHeartbeat': lastHeartbeat.toIso8601String(),
      'sshCommand': 'ssh -N -L 9333:127.0.0.1:$serverPort $sshHost',
    };
  }
}

class SessionRegistry {
  final Map<String, RelaySession> _sessions = <String, RelaySession>{};

  Iterable<RelaySession> get sessions => _sessions.values;

  RelaySession? operator [](String id) => _sessions[id];

  void add(RelaySession session) => _sessions[session.id] = session;

  RelaySession? remove(String id) => _sessions.remove(id);
}
