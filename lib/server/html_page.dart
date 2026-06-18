import 'dart:convert';

import 'session_registry.dart';

String renderSessionsPage(
  Iterable<RelaySession> sessions, {
  required String sshHost,
  required int sshPort,
  required String clientDownloadUrl,
  required bool canDisconnect,
}) {
  final rows = sessions.map((session) {
    final json = session.toJson(sshHost: sshHost, sshPort: sshPort);
    final command = json['sshCommand']! as String;
    final disconnectButton = canDisconnect
        ? '<button class="danger" onclick=\'disconnectSession(${jsonEncode(session.id)})\'>Disconnect</button>'
        : '';
    return '''
      <tr>
        <td><span class="online">Online</span></td>
        <td>${_escape(session.registration.pcName)}</td>
        <td>${_escape(session.registration.windowsUser)}</td>
        <td><code>127.0.0.1:${session.serverPort}</code></td>
        <td>${_escape(session.connectedAt.toLocal().toString())}</td>
        <td><span data-duration="${session.connectedAt.toIso8601String()}"></span></td>
        <td>${_escape(session.lastHeartbeat.toLocal().toString())}</td>
        <td class="actions">
          <button onclick='copyCommand(${jsonEncode(command)})'>Copy SSH command</button>
          $disconnectButton
        </td>
      </tr>''';
  }).join();

  return '''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="30">
  <title>Chrome Debug Sessions</title>
  <style>
    body { font: 14px system-ui, sans-serif; margin: 2rem; color: #202124; }
    h1 { margin-bottom: .3rem; }
    .warning { color: #8a4b00; background: #fff4db; padding: .8rem; border-radius: 6px; }
    table { border-collapse: collapse; width: 100%; margin-top: 1.5rem; }
    th, td { border-bottom: 1px solid #ddd; padding: .7rem; text-align: left; }
    th { background: #f5f5f5; }
    .online { color: #137333; font-weight: 600; }
    button { margin: .15rem; padding: .45rem .7rem; cursor: pointer; }
    .danger { color: #b3261e; }
    code { white-space: nowrap; }
  </style>
</head>
<body>
  <h1>Chrome Debug Sessions</h1>
  <p class="warning">Close the SSH tunnel after support is finished.</p>
  <p>
    User agent download:
    <a href="${_escape(clientDownloadUrl)}" download>client_debug_agent.exe</a>
    |
    <a href="/admin/keys">SSH key admin</a>
  </p>
  <table>
    <thead><tr><th>Status</th><th>PC name</th><th>User</th><th>Server local port</th><th>Connected at</th><th>Duration</th><th>Last heartbeat</th><th>Actions</th></tr></thead>
    <tbody>${rows.isEmpty ? '<tr><td colspan="8">No active sessions.</td></tr>' : rows}</tbody>
  </table>
  <script>
    function copyCommand(command) {
      navigator.clipboard.writeText(command);
    }
    async function disconnectSession(id) {
      if (!confirm('Disconnect this session?')) return;
      const response = await fetch('/api/sessions/' + encodeURIComponent(id) + '/disconnect', {method: 'POST'});
      if (!response.ok) alert(await response.text());
      location.reload();
    }
    function updateDurations() {
      document.querySelectorAll('[data-duration]').forEach((element) => {
        const seconds = Math.max(0, Math.floor((Date.now() - Date.parse(element.dataset.duration)) / 1000));
        const hours = String(Math.floor(seconds / 3600)).padStart(2, '0');
        const minutes = String(Math.floor(seconds % 3600 / 60)).padStart(2, '0');
        const remainder = String(seconds % 60).padStart(2, '0');
        element.textContent = hours + ':' + minutes + ':' + remainder;
      });
    }
    updateDurations();
    setInterval(updateDurations, 1000);
  </script>
</body>
</html>''';
}

String _escape(String value) {
  return const HtmlEscape(HtmlEscapeMode.element).convert(value);
}
