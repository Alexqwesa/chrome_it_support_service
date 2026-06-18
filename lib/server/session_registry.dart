import 'dart:io';

import '../shared/agent_protocol.dart';

class RelaySession {
  RelaySession({
    required this.id,
    required this.registration,
    required this.serverPort,
    required this.webSocket,
    required this.tunnelSocket,
  })  : connectedAt = DateTime.now().toUtc(),
        lastHeartbeat = DateTime.now().toUtc() {
    targets.add(
      RelayTarget(
        id: 'default',
        label: 'Started Chrome profile',
        localChromePort: registration.localChromePort,
        serverPort: serverPort,
        addedAt: connectedAt,
      ),
    );
  }

  final String id;
  final AgentRegistration registration;
  final int serverPort;
  final WebSocket webSocket;
  final ServerSocket tunnelSocket;
  final DateTime connectedAt;
  final List<RelayTarget> targets = <RelayTarget>[];
  DateTime lastHeartbeat;

  Map<String, Object?> toJson({
    required String sshHost,
    required int sshPort,
  }) {
    final portArg = sshPort == 22 ? '' : ' -p $sshPort';
    return <String, Object?>{
      'id': id,
      ...registration.toJson(),
      'serverPort': serverPort,
      'server_local_port': serverPort,
      'serverAddress': '127.0.0.1:$serverPort',
      'targets': targets
          .map(
            (target) => target.toJson(
              sshHost: sshHost,
              sshPort: sshPort,
            ),
          )
          .toList(),
      'connectedAt': connectedAt.toIso8601String(),
      'time_of_begin_of_connection': connectedAt.toIso8601String(),
      'lastHeartbeat': lastHeartbeat.toIso8601String(),
      'sshHost': sshHost,
      'sshPort': sshPort,
      'sshCommand': 'ssh$portArg -N -L 9333:127.0.0.1:$serverPort $sshHost',
    };
  }
}

class RelayTarget {
  const RelayTarget({
    required this.id,
    required this.label,
    required this.localChromePort,
    required this.serverPort,
    required this.addedAt,
  });

  final String id;
  final String label;
  final int localChromePort;
  final int serverPort;
  final DateTime addedAt;

  Map<String, Object?> toJson({
    required String sshHost,
    required int sshPort,
  }) {
    final portArg = sshPort == 22 ? '' : ' -p $sshPort';
    return <String, Object?>{
      'id': id,
      'label': label,
      'localChromePort': localChromePort,
      'serverPort': serverPort,
      'server_local_port': serverPort,
      'serverAddress': '127.0.0.1:$serverPort',
      'addedAt': addedAt.toIso8601String(),
      'sshCommand': 'ssh$portArg -N -L 9333:127.0.0.1:$serverPort $sshHost',
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
