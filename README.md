# Chrome IT Support Service

Internal Chrome remote-debugging relay implemented in Dart. A Windows agent
launches an isolated Chrome profile, connects outbound over WebSocket/WSS, and
receives a server-local relay port. IT operators reach that port only through a
restricted SSH local-forward.

## Security model

- Client Chrome debug endpoints bind only to `127.0.0.1`.
- Relay ports use the fixed `41000-41049` range.
- Docker can publish the read-only connection list to the LAN.
- Docker publishes relay tunnel ports only on host loopback.
- Agents authenticate with a revocable enrollment token.
- The status page and `GET /api/sessions` are read-only and public by default.
- Disconnect/admin actions require Basic authentication when enabled.
- Heartbeat and maximum-session timeouts remove stale sessions.
- SSH examples allow only local forwarding to the relay range and no shell.

The enrollment token permits a machine to create a debug session. Treat it as a
secret, rotate it when exposed, and do not use it as an admin credential.

## Server deployment

1. Copy the environment example and replace the agent token. Set
   `ADMIN_PASSWORD` only if you want admin actions such as disconnect:

   ```bash
   cp .env.example .env
   chmod 600 .env
   openssl rand -base64 32
   docker compose up -d --build
   docker compose logs -f debug-relay
   ```

   Docker Compose interpolates `$NAME` patterns in env files. If a generated
   token/password contains `$`, either regenerate it without `$`, single-quote
   the value, or escape `$` as `$$` so the container receives the intended
   secret.

2. Confirm loopback-only publishing:

   ```bash
   docker compose ps
   curl http://127.0.0.1:8080/health
   ```

3. Install the nginx example from
   `deploy/nginx-debug-relay.conf.example`. It exposes the read-only session
   list to configured internal networks and protects only the optional admin
   mutation endpoint. If `ADMIN_PASSWORD` is configured, create the Basic-auth
   file using the same username/password:

   ```bash
   sudo htpasswd -c /etc/nginx/.htpasswd-debug-relay admin
   sudo nginx -t
   sudo systemctl reload nginx
   ```

4. Adjust the nginx `allow` networks before deployment. `/agent` must remain
   reachable by supported user PCs, while `/debug-sessions` and
   `GET /api/sessions` should be limited to the local network or IT VPN.

The service binds tunnel ports to `0.0.0.0` **inside the container** so Docker
can publish them. `docker-compose.yml` publishes tunnel ports only to host
`127.0.0.1`, so they are not directly reachable from the LAN. The HTTP list
port is published on `${SERVER_HTTP_PUBLISH_BIND:-0.0.0.0}:18080`; set
`SERVER_HTTP_PUBLISH_BIND=127.0.0.1` when nginx is the only frontend.

## Restricted SSH setup

If the SSH relay host is Linux, use the commands below. If it is Windows, use
[deploy/windows-openssh-debug-tunnel-setup.md](C:\Users\user\StudioProjects\chrome_it_support_service\deploy\windows-openssh-debug-tunnel-setup.md).

Create the forwarding-only account:

```bash
sudo adduser --system --group --home /home/debug-tunnel debug-tunnel
sudo mkdir -p /home/debug-tunnel/.ssh
sudo touch /home/debug-tunnel/.ssh/authorized_keys
sudo chown -R debug-tunnel:debug-tunnel /home/debug-tunnel
sudo chmod 700 /home/debug-tunnel/.ssh
sudo chmod 600 /home/debug-tunnel/.ssh/authorized_keys
```

Add one public key per operator to `authorized_keys`. Do not share private keys.
Append `deploy/sshd_config.debug-tunnel.example` to `/etc/ssh/sshd_config`,
then validate and reload:

```bash
sudo sshd -t
sudo systemctl reload sshd  # use "ssh" on Debian/Ubuntu if required
```

Install `deploy/operator_ssh_config.example` in each operator's SSH config.
Verify that a shell and arbitrary forwarding fail:

```bash
ssh -p 2222 debug-tunnel@softapp.vietsov.com.vn
ssh -p 2222 -N -L 9333:127.0.0.1:22 debug-tunnel@softapp.vietsov.com.vn
```

## Build and run the Windows client

Build on Windows:

```powershell
dart pub get
powershell -ExecutionPolicy Bypass -File tool/build_clients.ps1
```

This creates two client executables:

- `build/client_debug_agent_dev.exe`: compiled with localhost URL
  (`http://127.0.0.1:8080`) and the current `.env` `AGENT_ENROLLMENT_TOKEN`
  when available, otherwise `dev-agent-token`.
- `build/client_debug_agent_configured.exe`: compiled with the current `.env`
  values for `RELAY_SERVER_URL`, `AGENT_ENROLLMENT_TOKEN`, and `AGENT_VERSION`.

Runtime `.env.example`, `.env`, or real environment variables still override
compiled defaults. When that happens, the client prints a console line such as
`Config override: RELAY_SERVER_URL from .env overrides compiled default.`
For production, prefer injecting override values through managed device
configuration when possible. Code-sign the executable.

The client finds Chrome in standard install paths or through `CHROME_PATH`,
uses the first free port in `9222-9299`, and creates a temporary profile.

## Operator workflow

1. Ask the user to run the client and keep its console open.
2. Open `https://softapp.vietsov.com.vn/debug-sessions`.
3. Find the PC and copy its SSH command.
4. Run the command, for example:

   ```bash
   ssh -p 2222 -N -L 9333:127.0.0.1:41001 debug-tunnel@softapp.vietsov.com.vn
   ```

5. Open `chrome://inspect`, choose **Configure**, and add `localhost:9333`.
6. Close the SSH command and disconnect the session after support is finished.

To verify forwarding without DevTools, open
`http://127.0.0.1:9333/json/version`.

## Local development

```powershell
$env:ADMIN_PASSWORD = "local-admin-password"
$env:AGENT_ENROLLMENT_TOKEN = "local-agent-token"
dart run bin/server.dart
```

In a second Windows shell:

```powershell
$env:RELAY_SERVER_URL = "http://127.0.0.1:8080"
$env:AGENT_ENROLLMENT_TOKEN = "local-agent-token"
dart run bin/client.dart
```

Open `http://127.0.0.1:8080/debug-sessions` and authenticate as `admin` with
the configured admin password only if `SESSION_LIST_REQUIRES_AUTH=true`.

## Configuration

| Variable | Component | Default | Purpose |
| --- | --- | --- | --- |
| `ADMIN_USERNAME` | server | `admin` | Status/API Basic-auth username |
| `ADMIN_PASSWORD` | server | optional | Enables protected admin actions such as disconnect |
| `SESSION_LIST_REQUIRES_AUTH` | server | `false` | Require Basic auth for `GET /debug-sessions` and `GET /api/sessions` |
| `AGENT_ENROLLMENT_TOKEN` | both | required | Agent WebSocket bearer token |
| `SERVER_HTTP_PORT` | server | `8080` | HTTP/WebSocket listener port |
| `SERVER_HTTP_BIND` | server | `0.0.0.0` | HTTP listener address |
| `SERVER_TUNNEL_BIND` | server | `127.0.0.1` | Relay listener address; Docker uses `0.0.0.0` |
| `SERVER_HTTP_PUBLISH_BIND` | compose | `0.0.0.0` | Host bind address for the read-only HTTP list |
| `SERVER_PORT_START/END` | server | `41000/41049` | Fixed relay range |
| `SSH_RELAY_HOST` | server | `debug-tunnel@softapp.vietsov.com.vn` | SSH target shown in copied SSH commands |
| `SSH_RELAY_PORT` | server | `2222` | SSH port shown in copied SSH commands |
| `HEARTBEAT_TIMEOUT_SECONDS` | server | `60` | Stale-agent timeout |
| `SESSION_TIMEOUT_SECONDS` | server | `28800` | Maximum session lifetime |
| `RELAY_SERVER_URL` | client | required | Public relay URL, normally HTTPS |
| `CHROME_PATH` | client | auto-detected | Optional full path to Chrome |
| `AGENT_VERSION` | client | `1.0.0` | Version shown in logs |

The JSON list endpoint is `GET /api/sessions`. Each row includes both legacy
camelCase fields and explicit snake_case fields, including
`time_of_begin_of_connection` and `server_local_port`.

## Environment loading

Both binaries load configuration in this order:

1. `.env.example`
2. `.env`
3. Real process environment variables

Later sources override earlier sources. This means `.env.example` can provide
local defaults, `.env` can provide machine-specific values, and Docker/CI can
still inject final overrides.

## Verification

```powershell
dart format --output=none --set-exit-if-changed .
dart analyze
dart test
powershell -ExecutionPolicy Bypass -File tool/build_clients.ps1
docker compose config
```
