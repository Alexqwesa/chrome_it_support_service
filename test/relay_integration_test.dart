import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:chrome_it_support_service/agent_protocol.dart';
import 'package:chrome_it_support_service/relay_server.dart';
import 'package:chrome_it_support_service/tunnel_frames.dart';
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
        'SERVER_PORT_END': '$tunnelPort',
        'AGENT_ENROLLMENT_TOKEN': 'agent-test-token',
        'ADMIN_PASSWORD': 'admin-test-password',
      }),
    );
    await server.start();
    addTearDown(server.stop);

    final assigned = Completer<int>();
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
  });
}
