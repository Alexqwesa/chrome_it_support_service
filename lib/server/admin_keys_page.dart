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

  const operatorKeyCommandPs = r'''& {
  $folder = "$env:USERPROFILE\.ssh"
  $private = Join-Path $folder id_ed25519
  $public = "$private.pub"

  if (!(Test-Path -LiteralPath $folder)) {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
  }

  $ready = (Test-Path -LiteralPath $private) -and (Test-Path -LiteralPath $public)
  $broken = (Test-Path -LiteralPath $private) -xor (Test-Path -LiteralPath $public)

  if ($ready) {
    [Console]::Out.WriteLine((Get-Content -LiteralPath $public -Raw).TrimEnd())
    return
  }

  if ($broken) {
    Write-Host "ERROR: incomplete SSH keypair in $folder" -ForegroundColor Red
    return
  }

  ssh-keygen -t ed25519 -f $private -N "" -C "$env:USERNAME@$env:COMPUTERNAME"

  if (Test-Path -LiteralPath $public) {
    [Console]::Out.WriteLine((Get-Content -LiteralPath $public -Raw).TrimEnd())
  } else {
    Write-Host "ERROR: public key was not created: $public" -ForegroundColor Red
  }
}
''';

  const operatorKeyCommandCmd = r'''set "FOLDER=%USERPROFILE%\.ssh"
set "PRIVATE=%FOLDER%\id_ed25519"
set "PUBLIC=%PRIVATE%.pub"
set "STATE="

if not exist "%FOLDER%" mkdir "%FOLDER%"

if exist "%PRIVATE%" if exist "%PUBLIC%" set "STATE=READY"
if exist "%PRIVATE%" if not exist "%PUBLIC%" set "STATE=BROKEN"
if not exist "%PRIVATE%" if exist "%PUBLIC%" set "STATE=BROKEN"

if "%STATE%"=="READY" (
  type "%PUBLIC%"
  echo.
) else if "%STATE%"=="BROKEN" (
  echo ERROR: incomplete SSH keypair in %FOLDER%
) else (
  ssh-keygen -t ed25519 -f "%PRIVATE%" -N "" -C "%USERNAME%@%COMPUTERNAME%"
  if exist "%PUBLIC%" (
    type "%PUBLIC%"
    echo.
  ) else (
    echo ERROR: public key was not created: %PUBLIC%
  )
)

set "FOLDER="
set "PRIVATE="
set "PUBLIC="
set "STATE="
''';

  return '''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SSH Key Admin</title>
  <style>
    body {
      font: 14px system-ui, sans-serif;
      margin: 2rem;
      color: #202124;
      background: #fff;
    }

    h1 {
      margin-bottom: .3rem;
    }

    h2 {
      margin-top: 1.8rem;
    }

    h3 {
      margin: 0;
      font-size: 1rem;
    }

    nav {
      margin-bottom: 1.5rem;
    }

    table {
      border-collapse: collapse;
      width: 100%;
      margin-top: 1.5rem;
    }

    th,
    td {
      border-bottom: 1px solid #ddd;
      padding: .7rem;
      text-align: left;
      vertical-align: top;
    }

    th {
      background: #f5f5f5;
    }

    textarea {
      width: min(58rem, 100%);
      font-family: ui-monospace, SFMono-Regular, Consolas, monospace;
    }

    button {
      margin: .15rem;
      padding: .45rem .7rem;
      border: 1px solid #c8cdd2;
      border-radius: 6px;
      background: #fff;
      cursor: pointer;
    }

    button:hover {
      background: #f6f8fa;
    }

    form {
      margin: 0;
    }

    code {
      white-space: nowrap;
    }

    pre {
      margin: 0;
      padding: .85rem;
      overflow-x: auto;
      background: #f6f8fa;
      border-top: 1px solid #d0d7de;
      font-family: ui-monospace, SFMono-Regular, Consolas, monospace;
      font-size: 13px;
      line-height: 1.45;
    }

    .enabled {
      color: #137333;
      font-weight: 600;
    }

    .disabled {
      color: #8a4b00;
      font-weight: 600;
    }

    .danger {
      color: #b3261e;
    }

    .message {
      color: #137333;
      background: #e6f4ea;
      padding: .8rem;
      border-radius: 6px;
    }

    .error {
      color: #b3261e;
      background: #fce8e6;
      padding: .8rem;
      border-radius: 6px;
    }

    .note {
      color: #5f6368;
    }

    .help {
      background: #f8fafd;
      border: 1px solid #d0d7de;
      border-radius: 8px;
      padding: 1rem;
    }

    .code-card {
      margin-top: .9rem;
      border: 1px solid #d0d7de;
      border-radius: 8px;
      background: #fff;
      overflow: hidden;
    }

    .code-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: .8rem;
      padding: .65rem .8rem;
      background: #f6f8fa;
    }

    .code-actions {
      display: flex;
      gap: .35rem;
      flex-wrap: wrap;
    }

    .hidden {
      display: none;
    }
  </style>
</head>
<body>
  <nav><a href="/debug-sessions">Back to sessions</a></nav>

  <h1>SSH Key Admin</h1>
  <p class="note">Editing <code>${_escape(authorizedKeysPath)}</code>.</p>

  ${message == null ? '' : '<p class="message">${_escape(message)}</p>'}
  ${error == null ? '' : '<p class="error">${_escape(error)}</p>'}

  <h2>Add key</h2>

  <div class="help">
    <p>
      <strong>Operator key rule:</strong>
      each operator must use their own SSH keypair.
      Never share a private key.
    </p>

    <p>
      Copy and paste one of the command blocks directly into the console.
      The commands print the existing public key when a full keypair already
      exists, show an error when only one file exists, or create a new keypair
      and then print the public key.
    </p>

    <div class="code-card">
      <div class="code-header">
        <h3>PowerShell</h3>
        <div class="code-actions">
          <button type="button" onclick='copyText(${jsonEncode(operatorKeyCommandPs)}, this)'>
            Copy
          </button>
          <button type="button" onclick="toggleCode('powershell-code', this)">
            Show
          </button>
        </div>
      </div>
      <pre id="powershell-code" class="hidden">${_escape(operatorKeyCommandPs)}</pre>
    </div>

    <div class="code-card">
      <div class="code-header">
        <h3>Command Prompt / BAT</h3>
        <div class="code-actions">
          <button type="button" onclick='copyText(${jsonEncode(operatorKeyCommandCmd)}, this)'>
            Copy
          </button>
          <button type="button" onclick="toggleCode('cmd-code', this)">
            Show
          </button>
        </div>
      </div>
      <pre id="cmd-code" class="hidden">${_escape(operatorKeyCommandCmd)}</pre>
    </div>

    <p class="note">
      The private key file, without <code>.pub</code>, stays on the operator
      PC and must not be uploaded or shared.
    </p>
  </div>

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
    <thead>
      <tr>
        <th>Status</th>
        <th>Type</th>
        <th>Key preview</th>
        <th>Comment</th>
        <th>Key line</th>
        <th>Actions</th>
      </tr>
    </thead>
    <tbody>
      ${rows.isEmpty ? '<tr><td colspan="6">No SSH keys found.</td></tr>' : rows}
    </tbody>
  </table>

  <script>
    function copyText(text, button) {
      const normalized = text.endsWith('\\n') ? text : text + '\\n';
      navigator.clipboard.writeText(normalized);

      const label = button.textContent;
      button.textContent = 'Copied';
      setTimeout(() => {
        button.textContent = label;
      }, 1200);
    }

    function toggleCode(id, button) {
      const block = document.getElementById(id);
      const hidden = block.classList.toggle('hidden');
      button.textContent = hidden ? 'Show' : 'Hide';
    }
  </script>
</body>
</html>''';
}

String _escape(String value) {
  return const HtmlEscape(HtmlEscapeMode.element).convert(value);
}