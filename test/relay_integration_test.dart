import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chrome_it_support_service/server/relay_server.dart';
import 'package:chrome_it_support_service/shared/agent_protocol.dart';
import 'package:chrome_it_support_service/shared/tunnel_frames.dart';
import 'package:test/test.dart';

void main() {
  test('relay assigns a port and multiplexes bytes through the agent',
      () async {
    final reservation =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final tunnelPort = reservation.port;
    await reservation.close();

    final server = RelayServer(
      RelayServerConfig.fromEnvironment(<String, String>{
        'SERVER_HTTP_PORT': '0',
        'SERVER_HTTP_BIND': '127.0.0.1',
        'SERVER_TUNNEL_BIND': '127.0.0.1',
        'SERVER_PORT_START': '$tunnelPort',
        'SERVER_PORT_END': '${tunnelPort + 20}',
        'SSH_RELAY_HOST': 'debug-tunnel@softapp.vietsov.com.vn',
        'SSH_RELAY_PORT': '2223',
        'AGENT_ENROLLMENT_TOKEN': 'agent-test-token',
      }),
    );
    await server.start();
    addTearDown(server.stop);

    final assigned = Completer<int>();
    final secondAssigned = Completer<int>();
    final agent = await WebSocket.connect(
      'ws://127.0.0.1:${server.boundHttpPort}/agent',
      headers: <String, dynamic>{
        HttpHeaders.authorizationHeader: 'Bearer agent-test-token',
      },
    );
    addTearDown(agent.close);
    agent.listen((raw) {
      final frame = TunnelFrame.decode(raw);
      if (frame.type == TunnelFrameType.registered) {
        assigned.complete(frame.metadata['serverPort']! as int);
      } else if (frame.type == TunnelFrameType.targetRegistered) {
        secondAssigned.complete(frame.metadata['serverPort']! as int);
      } else if (frame.type == TunnelFrameType.data) {
        agent.add(frame.encode());
      }
    });
    agent.add(
      TunnelFrame(
        type: TunnelFrameType.register,
        metadata: AgentRegistration(
          pcName: 'TEST-PC',
          windowsUser: 'tester',
          localChromePort: 9222,
          agentVersion: 'test',
          startedAt: DateTime.now().toUtc(),
        ).toJson(),
      ).encode(),
    );

    final port = await assigned.future.timeout(const Duration(seconds: 5));
    final sessions = await _getJsonList(
      Uri.parse('http://127.0.0.1:${server.boundHttpPort}/api/sessions'),
    );
    expect(sessions, hasLength(1));
    expect(sessions.single['server_local_port'], port);
    expect(sessions.single['time_of_begin_of_connection'], isA<String>());
    expect(
      sessions.single['sshCommand'],
      'ssh -p 2223 -N -L 9333:127.0.0.1:$port debug-tunnel@softapp.vietsov.com.vn',
    );

    final operator = await Socket.connect(InternetAddress.loopbackIPv4, port);
    addTearDown(operator.destroy);
    final response = Completer<List<int>>();
    operator.listen((data) {
      if (!response.isCompleted) response.complete(data);
    });
    operator.add(Uint8List.fromList(<int>[4, 5, 6]));

    expect(
      await response.future.timeout(const Duration(seconds: 5)),
      <int>[4, 5, 6],
    );

    agent.add(
      const TunnelFrame(
        type: TunnelFrameType.addTarget,
        metadata: <String, Object?>{
          'targetId': 'manual-1',
          'label': 'Existing Chrome 127.0.0.1:9333',
          'localChromePort': 9333,
        },
      ).encode(),
    );
    final secondPort =
        await secondAssigned.future.timeout(const Duration(seconds: 5));
    expect(secondPort, isNot(port));

    final updatedSessions = await _getJsonList(
      Uri.parse('http://127.0.0.1:${server.boundHttpPort}/api/sessions'),
    );
    final targets = updatedSessions.single['targets'] as List<dynamic>;
    expect(targets, hasLength(2));
    expect(targets.last['server_local_port'], secondPort);

    final secondOperator =
        await Socket.connect(InternetAddress.loopbackIPv4, secondPort);
    addTearDown(secondOperator.destroy);
    final secondResponse = Completer<List<int>>();
    secondOperator.listen((data) {
      if (!secondResponse.isCompleted) secondResponse.complete(data);
    });
    secondOperator.add(Uint8List.fromList(<int>[7, 8, 9]));

    expect(
      await secondResponse.future.timeout(const Duration(seconds: 5)),
      <int>[7, 8, 9],
    );
  });
}

Future<List<dynamic>> _getJsonList(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    expect(response.statusCode, HttpStatus.ok);
    return jsonDecode(body) as List<dynamic>;
  } finally {
    client.close(force: true);
  }
}
