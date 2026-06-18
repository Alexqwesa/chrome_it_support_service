import 'dart:convert';

import 'authorized_keys_manager.dart';

String renderAdminKeysPage({
  required List<AuthorizedKeyEntry> keys,
  required String authorizedKeysPath,
  required bool reloadAvailable,
  String? message,
  String? error,
}) {
  final rows = keys.map((key) {
    final status = key.enabled
        ? '<span class="enabled">Enabled</span>'
        : '<span class="disabled">Disabled</span>';
    final toggleAction = key.enabled ? 'disable' : 'enable';
    final toggleLabel = key.enabled ? 'Disable' : 'Enable';
    return '''
      <tr>
        <td>$status</td>
        <td>${_escape(key.keyType)}</td>
        <td><code>${_escape(key.fingerprintPreview)}</code></td>
        <td>${_escape(key.comment)}</td>
        <td>
          <form method="post" action="/admin/keys/${key.index}/edit">
            <textarea name="key" rows="3" spellcheck="false">${_escape(key.keyLine)}</textarea>
            <button type="submit">Save</button>
          </form>
        </td>
        <td class="actions">
          <form method="post" action="/admin/keys/${key.index}/$toggleAction">
            <button type="submit">$toggleLabel</button>
          </form>
          <form method="post" action="/admin/keys/${key.index}/delete" onsubmit="return confirm('Delete this SSH key?')">
            <button class="danger" type="submit">Delete</button>
          </form>
        </td>
      </tr>''';
  }).join();

  final reloadText = reloadAvailable
      ? 'Signals the Docker ssh-relay sidecar to reload sshd.'
      : 'Reload marker is not configured. authorized_keys changes are still used by new SSH logins without reload.';

  return '''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SSH Key Admin</title>
  <style>
    body { font: 14px system-ui, sans-serif; margin: 2rem; color: #202124; }
    h1 { margin-bottom: .3rem; }
    nav { margin-bottom: 1.5rem; }
    table { border-collapse: collapse; width: 100%; margin-top: 1.5rem; }
    th, td { border-bottom: 1px solid #ddd; padding: .7rem; text-align: left; vertical-align: top; }
    th { background: #f5f5f5; }
    textarea { width: min(58rem, 100%); font-family: ui-monospace, SFMono-Regular, Consolas, monospace; }
    button { margin: .15rem; padding: .45rem .7rem; cursor: pointer; }
    form { margin: 0; }
    .enabled { color: #137333; font-weight: 600; }
    .disabled { color: #8a4b00; font-weight: 600; }
    .danger { color: #b3261e; }
    .message { color: #137333; background: #e6f4ea; padding: .8rem; border-radius: 6px; }
    .error { color: #b3261e; background: #fce8e6; padding: .8rem; border-radius: 6px; }
    .note { color: #5f6368; }
    code { white-space: nowrap; }
  </style>
</head>
<body>
  <nav><a href="/debug-sessions">Back to sessions</a></nav>
  <h1>SSH Key Admin</h1>
  <p class="note">Editing <code>${_escape(authorizedKeysPath)}</code>.</p>
  ${message == null ? '' : '<p class="message">${_escape(message)}</p>'}
  ${error == null ? '' : '<p class="error">${_escape(error)}</p>'}

  <h2>Add key</h2>
  <form method="post" action="/admin/keys/add">
    <textarea name="key" rows="4" spellcheck="false" placeholder="ssh-ed25519 AAAA... operator-name"></textarea>
    <p><button type="submit">Add key</button></p>
  </form>

  <h2>Reload sshd</h2>
  <p class="note">$reloadText</p>
  <form method="post" action="/admin/ssh/reload">
    <button type="submit">Force reload sshd</button>
  </form>

  <h2>Current keys</h2>
  <table>
    <thead><tr><th>Status</th><th>Type</th><th>Key preview</th><th>Comment</th><th>Key line</th><th>Actions</th></tr></thead>
    <tbody>${rows.isEmpty ? '<tr><td colspan="6">No SSH keys found.</td></tr>' : rows}</tbody>
  </table>
</body>
</html>''';
}

String _escape(String value) {
  return const HtmlEscape(HtmlEscapeMode.element).convert(value);
}
