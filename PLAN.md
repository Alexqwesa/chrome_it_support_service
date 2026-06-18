# Chrome Debug Relay — PLAN.md

## Goal

Create an internal Chrome remote-debugging relay service for IT support.

The user should only need to run a small Windows executable. The executable
starts or connects to a local Chrome debug session, connects outbound to a
Docker relay server, and keeps the console open.

The IT team should connect to the server through restricted SSH port forwarding.
They should not receive shell access on the server.

## Core idea

```text
User PC
  client_debug_agent.exe
    starts Chrome with local debug port
    exposes only 127.0.0.1:<clientChromePort>
    connects outbound to Docker relay over WSS

Server
  debug-relay Docker service
    accepts agent connections
    assigns server-local ports from fixed range
    exposes:
      127.0.0.1:41000
      127.0.0.1:41001
      ...
    shows active sessions in HTML page

IT operator PC
  ssh -N -L 9333:127.0.0.1:41001 vsp-debug

Operator Chrome
  chrome://inspect
    Configure: localhost:9333
```

## Non-goals

Do not expose the Chrome debug port directly to the LAN or Internet.

Do not give the IT team a real shell account on the server.

Do not use the user's normal Chrome profile for debugging.

Do not embed permanent high-privilege credentials inside the client exe.

## Main components

### 1. `client_debug_agent.exe`

Runs on the user's Windows PC.

Responsibilities:

```text
- Print clear console status.
- Detect PC name.
- Detect Windows user name.
- Find Chrome executable.
- Find free local Chrome debug port.
- Start Chrome with:
  --remote-debugging-address=127.0.0.1
  --remote-debugging-port=<freePort>
  --user-data-dir=<temporary profile dir>
- Verify:
  http://127.0.0.1:<freePort>/json/version
- Connect outbound to relay server using WSS.
- Register the session:
  pcName
  windowsUser
  localChromePort
  agentVersion
  startedAt
- Keep running until the user closes the console or presses Ctrl+C.
- Stop tunnel cleanly on exit.
```

Example console output:

```text
VSP Chrome Debug Agent

PC name: DESKTOP-ABC123
User: branchukov
Server: https://debug.example.com

Starting Chrome debug profile...
Chrome debug endpoint: 127.0.0.1:9222

Connected to server.
Assigned server port: 41001

Do not close this window while support is connected.
Press Ctrl+C to stop.
```

### 2. `debug_relay_server`

Runs constantly in Docker on the server.

Responsibilities:

```text
- Accept agent WebSocket connections.
- Authenticate the agent.
- Allocate one server-local port per connected client.
- Bind assigned ports only to loopback:
  127.0.0.1:41000-41049
- Relay TCP streams between:
  server local port <-> WebSocket <-> client Chrome debug port
- Keep session registry in memory.
- Show status HTML page.
- Provide JSON API for active sessions.
- Release ports when clients disconnect.
- Print connection/disconnection logs.
```

Example server console output:

```text
[CONNECTED]
PC: DESKTOP-ABC123
User: branchukov
Agent: 1.0.0
Server local port: 127.0.0.1:41001
Client Chrome: 127.0.0.1:9222
Connected at: 2026-06-11 10:42:12

[DISCONNECTED]
PC: DESKTOP-ABC123
Released port: 41001
Duration: 00:17:22
```

### 3. HTML status page

Path:

```text
/debug-sessions
```

Purpose:

```text
- Show active clients.
- Show PC name.
- Show Windows user.
- Show assigned server port.
- Show ready-to-copy SSH command.
- Show connected duration.
- Show last heartbeat.
```

Example table:

```text
Chrome Debug Sessions

Status   PC name          User        Server port          SSH command
Online   DESKTOP-ABC123   branchukov  127.0.0.1:41001      ssh -N -L 9333:127.0.0.1:41001 vsp-debug
Online   VSP-PC-22        tuan.dk     127.0.0.1:41002      ssh -N -L 9333:127.0.0.1:41002 vsp-debug
```

Admin page requirements:

```text
- Protect with authentication or internal VPN.
- Do not expose publicly.
- Include "copy SSH command" button.
- Include "disconnect session" button.
- Include warning:
  Close SSH tunnel after support is finished.
```

## Port policy

Use fixed non-overlapping ranges.

### Client-side Chrome debug port

Preferred range:

```text
9222-9299
```

Rules:

```text
- Try 9222 first.
- If busy, try 9223, 9224, ...
- Bind Chrome debug only to 127.0.0.1.
- Never bind Chrome debug to 0.0.0.0.
```

Chrome launch example:

```bat
chrome.exe ^
  --remote-debugging-address=127.0.0.1 ^
  --remote-debugging-port=9222 ^
  --user-data-dir="%TEMP%\vsp-debug-chrome-profile"
```

### Server-side tunnel port

Preferred range:

```text
41000-41049
```

Rules:

```text
- Dart relay allocates only from this range.
- Do not allocate random ports.
- Bind on host only to 127.0.0.1.
- Release port when client disconnects.
- Reject new sessions when all ports are busy.
```

### Local operator port

Recommended:

```text
9333
```

If busy:

```text
9334
9335
...
```

Example:

```bash
ssh -N -L 9333:127.0.0.1:41001 vsp-debug
```

Then operator opens:

```text
chrome://inspect
Configure: localhost:9333
```

## Docker plan

### Service layout

```text
debug-relay/
  Dockerfile
  docker-compose.yml
  pubspec.yaml
  bin/
    server.dart
    client.dart
  lib/
    agent_protocol.dart
    chrome_launcher.dart
    html_page.dart
    port_allocator.dart
    session_registry.dart
    tcp_tunnel.dart
    tunnel_frames.dart
```

### Docker Compose

Use host loopback binding.

```yaml
services:
  debug-relay:
    build: .
    container_name: debug-relay
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"
      - "127.0.0.1:41000-41049:41000-41049"
    environment:
      ADMIN_PASSWORD: "change-me"
      AGENT_ENROLLMENT_TOKEN: "change-me"
      SERVER_HTTP_PORT: "8080"
      SERVER_PORT_START: "41000"
      SERVER_PORT_END: "41049"
```

Important:

```text
Inside Docker:
  service may listen on 0.0.0.0

On host:
  Docker publishes only to 127.0.0.1
```

Result:

```text
Allowed:
  server itself can reach 127.0.0.1:41001

Allowed:
  IT team can reach 127.0.0.1:41001 through SSH -L

Blocked:
  LAN users cannot directly reach server-ip:41001
```

## SSH access plan for IT team

The IT team connects to the server only for port forwarding.

They should not get:

```text
- terminal
- shell
- sudo
- file transfer
- agent forwarding
- X11 forwarding
- remote forwarding
- arbitrary internal port access
```

### Create restricted user

```bash
sudo adduser --system --group --home /home/debug-tunnel debug-tunnel

sudo mkdir -p /home/debug-tunnel/.ssh
sudo touch /home/debug-tunnel/.ssh/authorized_keys

sudo chown -R debug-tunnel:debug-tunnel /home/debug-tunnel
sudo chmod 700 /home/debug-tunnel/.ssh
sudo chmod 600 /home/debug-tunnel/.ssh/authorized_keys
```

Do not add this user to `sudo`.

### `/etc/ssh/sshd_config`

Add at the end:

```sshconfig
Match User debug-tunnel
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes

    AllowTcpForwarding local
    PermitOpen 127.0.0.1:41000 127.0.0.1:41001 127.0.0.1:41002 127.0.0.1:41003 127.0.0.1:41004
    PermitOpen 127.0.0.1:41005 127.0.0.1:41006 127.0.0.1:41007 127.0.0.1:41008 127.0.0.1:41009
    PermitOpen 127.0.0.1:41010 127.0.0.1:41011 127.0.0.1:41012 127.0.0.1:41013 127.0.0.1:41014
    PermitOpen 127.0.0.1:41015 127.0.0.1:41016 127.0.0.1:41017 127.0.0.1:41018 127.0.0.1:41019
    PermitOpen 127.0.0.1:41020 127.0.0.1:41021 127.0.0.1:41022 127.0.0.1:41023 127.0.0.1:41024
    PermitOpen 127.0.0.1:41025 127.0.0.1:41026 127.0.0.1:41027 127.0.0.1:41028 127.0.0.1:41029
    PermitOpen 127.0.0.1:41030 127.0.0.1:41031 127.0.0.1:41032 127.0.0.1:41033 127.0.0.1:41034
    PermitOpen 127.0.0.1:41035 127.0.0.1:41036 127.0.0.1:41037 127.0.0.1:41038 127.0.0.1:41039
    PermitOpen 127.0.0.1:41040 127.0.0.1:41041 127.0.0.1:41042 127.0.0.1:41043 127.0.0.1:41044
    PermitOpen 127.0.0.1:41045 127.0.0.1:41046 127.0.0.1:41047 127.0.0.1:41048 127.0.0.1:41049

    PermitTTY no
    PermitTunnel no
    X11Forwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    GatewayPorts no

    ForceCommand /bin/false
```

Notes:

```text
- AllowTcpForwarding local allows ssh -L only.
- PermitOpen restricts the destination host and port.
- PermitOpen does not support numeric ranges in many OpenSSH versions.
  Therefore the ports are listed explicitly.
- ForceCommand /bin/false blocks shell usage.
- PermitTTY no prevents terminal allocation.
```

Restart SSH after testing the config:

```bash
sudo sshd -t
sudo systemctl reload sshd
```

On some systems the service is named `ssh`:

```bash
sudo systemctl reload ssh
```

### Operator SSH config

On each IT operator PC:

```sshconfig
Host vsp-debug
    HostName debug.example.com
    User debug-tunnel
    IdentityFile ~/.ssh/vsp_debug_tunnel_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ExitOnForwardFailure yes
```

Usage:

```bash
ssh -N -L 9333:127.0.0.1:41001 vsp-debug
```

Two sessions:

```bash
ssh -N \
  -L 9333:127.0.0.1:41001 \
  -L 9334:127.0.0.1:41002 \
  vsp-debug
```

## Authentication plan

### Client agent

Avoid permanent high-privilege credentials in the exe.

Allowed for MVP:

```text
- Low-privilege enrollment token
- Revocable agent token
- Server URL
- Organization id
```

Better final design:

```text
1. Agent starts.
2. Agent connects with low-privilege enrollment token.
3. Server creates pending session.
4. Admin page shows pending client.
5. IT operator approves the session.
6. Server activates the tunnel.
7. Session expires automatically.
```

### Admin page

Protect `/debug-sessions`.

Options:

```text
- Internal VPN only
- Nginx basic auth
- SSO
- IP allowlist
```

MVP:

```text
- Nginx basic auth
- Internal network only
```

## Tunnel protocol

Use one WebSocket connection per agent.

Each server TCP connection becomes a logical stream over the WebSocket.

Frame types:

```json
{
  "type": "open",
  "streamId": 17
}
```

```json
{
  "type": "data",
  "streamId": 17,
  "base64": "..."
}
```

```json
{
  "type": "close",
  "streamId": 17
}
```

```json
{
  "type": "error",
  "streamId": 17,
  "message": "connection refused"
}
```

Flow:

```text
Operator Chrome / DevTools
  connects to local 127.0.0.1:9333

SSH tunnel
  forwards to server 127.0.0.1:41001

debug-relay server
  accepts TCP connection
  creates streamId
  sends "open" to client agent

client agent
  opens TCP connection to local Chrome:
  127.0.0.1:<clientChromePort>

Both sides
  relay bytes using data frames
```

DevTools may use multiple HTTP and WebSocket connections, so the relay must
support multiple simultaneous logical streams per agent.

## Dart implementation plan

### Packages

```yaml
dependencies:
  shelf: ^1.4.0
  shelf_router: ^1.1.0
  shelf_web_socket: ^3.0.0
  web_socket_channel: ^3.0.0
  crypto: ^3.0.0
```

### Suggested files

```text
bin/server.dart
  starts HTTP server
  registers routes
  owns session registry

bin/client.dart
  starts Windows console agent
  launches Chrome
  connects to relay

lib/session_registry.dart
  stores active sessions
  stores assigned ports
  stores last heartbeat

lib/port_allocator.dart
  finds free ports
  prevents conflicts

lib/tunnel_frames.dart
  encodes/decodes tunnel frames

lib/tcp_tunnel.dart
  handles stream open/data/close

lib/chrome_launcher.dart
  finds Chrome
  starts debug Chrome
  verifies /json/version

lib/html_page.dart
  renders /debug-sessions
```

### Server routes

```text
GET /health
  returns "ok"

GET /debug-sessions
  returns simple HTML page

GET /api/sessions
  returns JSON sessions

POST /api/sessions/<id>/disconnect
  disconnects selected session

WS /agent
  client agent WebSocket endpoint
```

## Build plan

### Server binary

Build on Linux:

```bash
dart pub get
dart compile exe bin/server.dart -o build/debug_relay_server
```

### Windows client binary

Build on Windows:

```powershell
dart pub get
dart compile exe bin/client.dart -o build/client_debug_agent.exe
```

Optional:

```text
- Sign the Windows exe.
- Add company name and version resource.
- Zip the exe with README.txt.
```

## Implementation phases

### Phase 1 — Local proof of concept

```text
- Start Chrome manually with --remote-debugging-port=9222.
- Dart server exposes 127.0.0.1:41001.
- Forward 41001 directly to local 9222 inside one machine.
- Verify:
  http://127.0.0.1:41001/json/version
```

Acceptance:

```text
- /json/version works through relay.
- /json/list works through relay.
```

### Phase 2 — Client agent

```text
- Build client_debug_agent.exe.
- Find free local port.
- Start Chrome with temporary profile.
- Verify local Chrome debug endpoint.
- Keep console open.
```

Acceptance:

```text
- User sees PC name and debug port.
- Chrome starts with a temporary profile.
- Closing console stops the session.
```

### Phase 3 — WebSocket tunnel

```text
- Client connects to server over WebSocket.
- Server assigns port from 41000-41049.
- Implement open/data/close/error frames.
- Support multiple logical streams.
```

Acceptance:

```text
- Server 127.0.0.1:41001 reaches client Chrome.
- DevTools can inspect through the tunnel.
```

### Phase 4 — HTML status page

```text
- Add /debug-sessions.
- Show connected clients.
- Show assigned ports.
- Show copyable SSH command.
- Show connected duration.
```

Acceptance:

```text
- IT operator can open page and copy command.
- Page updates correctly when client disconnects.
```

### Phase 5 — Docker deployment

```text
- Create Dockerfile.
- Create docker-compose.yml.
- Publish only:
  127.0.0.1:8080
  127.0.0.1:41000-41049
- Add restart policy.
```

Acceptance:

```text
- Relay survives container restart.
- Ports are not reachable from LAN directly.
- Ports are reachable through SSH -L.
```

### Phase 6 — Restricted SSH

```text
- Create debug-tunnel user.
- Add per-person SSH public keys.
- Configure Match User debug-tunnel.
- Disable shell.
- Allow only local forwarding.
- Restrict PermitOpen to 127.0.0.1:41000-41049.
```

Acceptance:

```text
ssh debug-tunnel@server
  fails to open shell

ssh -N -L 9333:127.0.0.1:41001 vsp-debug
  works

ssh -N -L 9333:127.0.0.1:22 vsp-debug
  fails

ssh -N -R 9000:127.0.0.1:41001 vsp-debug
  fails
```

### Phase 7 — Security hardening

```text
- Add admin authentication.
- Add agent authentication.
- Add session approval.
- Add session timeout.
- Add audit log.
- Add disconnect button.
- Add heartbeat timeout.
```

Acceptance:

```text
- Unknown agents are rejected.
- Stale sessions disappear.
- All session starts/stops are logged.
```

### Phase 8 — Packaging

```text
- Build signed Windows exe.
- Add README for users.
- Add README for IT operators.
- Add service installation docs.
- Add troubleshooting section.
```

Acceptance:

```text
- Non-technical user can run client exe.
- IT operator can connect using copied SSH command.
```

## Security checklist

Required:

```text
- Chrome debug listens only on 127.0.0.1.
- Server tunnel ports bind only to 127.0.0.1 on host.
- IT uses SSH -L to reach server-local ports.
- SSH user has no shell.
- SSH user has no sudo.
- SSH user has no password login.
- SSH user can only forward to 127.0.0.1:41000-41049.
- Admin page is protected.
- Agent token is low privilege and revocable.
- Sessions have timeout.
- Console clearly says "Do not close this window".
```

Avoid:

```text
- Publishing 41000-41049 on 0.0.0.0.
- Using the user's normal Chrome profile.
- Embedding admin password inside client exe.
- Sharing one SSH private key between all IT users.
- Allowing arbitrary SSH forwarding.
```

## Operator workflow

1. User runs `client_debug_agent.exe`.

2. User keeps the console open.

3. IT operator opens:

```text
https://debug.example.com/debug-sessions
```

4. IT operator finds the user's PC name.

5. IT operator copies command:

```bash
ssh -N -L 9333:127.0.0.1:41001 vsp-debug
```

6. IT operator opens Chrome:

```text
chrome://inspect
```

7. IT operator configures:

```text
localhost:9333
```

8. IT operator clicks `inspect`.

9. When finished:

```text
- close DevTools
- stop SSH command
- ask user to close client console
```

## Troubleshooting

### Local port 9333 is busy

Use another local port:

```bash
ssh -N -L 9334:127.0.0.1:41001 vsp-debug
```

Then configure:

```text
localhost:9334
```

### Server port is not reachable through SSH

Check:

```bash
ssh -N -L 9333:127.0.0.1:41001 vsp-debug
```

Then on operator PC:

```text
http://127.0.0.1:9333/json/version
```

If it fails:

```text
- check that session is still online
- check that assigned port is correct
- check SSH PermitOpen
- check Docker port publishing
- check debug-relay logs
```

### Client Chrome did not start

Check:

```text
- Chrome installed path
- local antivirus blocking exe
- port 9222-9299 availability
- user has permission to create temp profile
```

### DevTools opens but page is empty

Check:

```text
- target Chrome was started with temporary user-data-dir
- user opened the app in that debug Chrome window
- /json/list returns tabs
```

## MVP decision

Build the first version with:

```text
- one Dart repo
- Windows client exe
- Linux Docker server
- HTTP status page
- WSS tunnel
- SSH restricted forwarding
- port range 41000-41049
```

Defer until after MVP:

```text
- GUI client
- SSO
- persistent database
- Windows service mode
- auto-update
- code signing
- session recording
```
