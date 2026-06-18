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
- SSH key admin and disconnect/admin actions require Basic authentication when
  `ADMIN_PASSWORD` is configured.
- Heartbeat and maximum-session timeouts remove stale sessions.
- SSH examples allow only local forwarding to the relay range and no shell.

The enrollment token permits a machine to create a debug session. Treat it as a
secret, rotate it when exposed, and do not use it as an admin credential.

## Server deployment

1. Copy the environment example and edit the production section at the top of
   `.env`. At minimum, replace `AGENT_ENROLLMENT_TOKEN`. Set `ADMIN_PASSWORD`
   to enable the `/admin/keys` page for managing operator SSH keys:

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
   curl http://127.0.0.1:9998/health
   ```

3. Install the nginx example from
   `deploy/nginx-debug-relay.conf.example`. It exposes the read-only session
   list and client exe download to configured internal networks, and protects
   admin pages and mutation endpoints to the Dart server, which performs its
   own Basic-auth checks from `ADMIN_USERNAME` and `ADMIN_PASSWORD`:

   ```bash
   sudo nginx -t
   sudo systemctl reload nginx
   ```

   The example listens on HTTPS port `9999` and proxies to the Dart relay
   backend on `127.0.0.1:9998`. This avoids a port conflict when nginx and the
   Dart relay run on the same host.


4. Adjust the nginx `allow` networks before deployment. `/agent` must remain
   reachable by supported user PCs, while `/debug-sessions`,
   `/download/client_debug_agent.exe`, and `GET /api/sessions` should be
   limited to the local network or IT VPN.

The service binds tunnel ports to `0.0.0.0` **inside the container** so Docker
can publish them. `docker-compose.yml` publishes tunnel ports only to host
`127.0.0.1`, so they are not directly reachable from the LAN. The Dart backend
HTTP port is published on
`${SERVER_HTTP_PUBLISH_BIND:-127.0.0.1}:${SERVER_HTTP_PUBLISH_PORT:-9998}`;
keep it loopback-only when nginx is the public frontend.

## Restricted SSH setup

SSH runs in the `ssh-relay` Docker sidecar. No Windows OpenSSH service and no
Windows `debug-tunnel` user are required.

Generate one keypair per operator on the operator PC:

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\vsp_debug_tunnel_ed25519" -C "vsp-debug-tunnel-$env:USERNAME"
Get-Content "$env:USERPROFILE\.ssh\vsp_debug_tunnel_ed25519.pub"
```

Create the mounted authorized keys file and add each operator public key. Only
paste `.pub` content; never copy or share private keys:

```bash
cp deploy/authorized_keys.example deploy/authorized_keys
# Edit deploy/authorized_keys and add one .pub key per line.
docker compose up -d --build ssh-relay
```

`docker-compose.yml` mounts the `deploy` directory, not the individual
`authorized_keys` file. This lets the admin page create
`deploy/authorized_keys` if it does not exist yet, and avoids Docker creating a
directory at the file path when the file is missing.

SSH server host keys are stored in the Docker volume `ssh_host_keys`. Do not
copy `deploy/ssh_host_keys` to production; host private keys need Linux file
permissions such as `0600`, and bind mounts from some hosts can expose them as
too open for OpenSSH.

After `ADMIN_PASSWORD` is configured, open
`https://softapp.vietsov.com.vn:9999/admin/keys` to add, edit, disable, or
delete keys through the server admin page. The main `/debug-sessions` page links
to this admin page, but the password prompt is enforced only by the Dart server.
The reload button signals the Docker ssh-relay sidecar through a shared marker
file in the mounted `deploy` directory. New `authorized_keys` entries are
normally read by OpenSSH without a reload, but the button is available when you
want to force sshd to re-read its configuration.

Install `deploy/operator_ssh_config.example` in each operator's SSH config.
This file is only a client-side convenience alias; it is not required on the
server because the full command also works.
The container applies the restricted settings from `deploy/sshd_config.docker`:
public-key auth only, `ssh -L` only, no shell/session, no agent forwarding, and
`PermitOpen` limited to `127.0.0.1:41000-41049`.

Verify that allowed forwarding works:

```bash
ssh -p 2223 -N -L 9333:127.0.0.1:41000 debug-tunnel@softapp.vietsov.com.vn
```

Verify that shell and arbitrary forwarding fail:

```bash
ssh -p 2223 debug-tunnel@softapp.vietsov.com.vn
ssh -p 2223 -N -L 9333:127.0.0.1:22 debug-tunnel@softapp.vietsov.com.vn
```

## Build and run the Windows client

Build on Windows:

```powershell
dart pub get
powershell -ExecutionPolicy Bypass -File tool/build_clients.ps1
```

This creates two client executables:

- `build/client_debug_agent_dev.exe`: compiled with localhost backend URL
  (`http://127.0.0.1:9998`) and the current `.env` `AGENT_ENROLLMENT_TOKEN`
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
It also accepts additional Chrome debug endpoints from the console. If a user
already has a Chrome window with remote debugging enabled, they can paste a
loopback address such as `127.0.0.1:9223` into the agent console. The server
will allocate another relay port and show a second row on `/debug-sessions`.

## Operator workflow

1. Ask the user to run the client and keep its console open.
2. Open `https://softapp.vietsov.com.vn:9999/debug-sessions`.
3. Find the PC and copy its SSH command.
4. Run the command, for example:

   ```bash
   ssh -p 2223 -N -L 9333:127.0.0.1:41001 debug-tunnel@softapp.vietsov.com.vn
   ```

5. Open `chrome://inspect`, choose **Configure**, and add `localhost:9333`.
6. Close the SSH command and disconnect the session after support is finished.

To verify forwarding without DevTools, open
`http://127.0.0.1:9333/json/version`.

## Configuration

Use `.env.example` as the configuration reference. Values that must be changed
for production are grouped at the top; safe defaults are below them.

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
