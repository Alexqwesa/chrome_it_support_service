# Chrome IT Support Service

Internal Chrome remote-debugging relay implemented in Dart. A Windows agent
launches an isolated Chrome profile, connects outbound over WebSocket/WSS, and
receives a server-local relay port. IT operators reach that port only through a
restricted SSH local-forward.

## Help, invitations, and operator accounts

The user-facing `/help` page offers Vietnamese, Russian, and English. Its text
and the email templates live in `deploy/help_locales/{vi,ru,en}.json`; add a
new locale JSON file there to include it in the page selector and emails.
The help page links to the Windows EXE and explains both the default separate
Chrome window and the optional existing-Chrome steps. The latter exposes the
user's open tabs and signed-in sessions to the support operator.

To use individual operator accounts, set `DOMAIN_HOSTNAME`, `DOMAIN_NAME`,
`DOMAIN_PORT`, `LDAP_BIND_DN`, `LDAP_BIND_PASSWORD`, and
`ADMIN_BOOTSTRAP_EMAIL` in `.env` before the first start. The relay looks up
the approved email over LDAPS and checks the password by binding as that user.
`ADMIN_BOOTSTRAP_EMAIL` creates the first administrator only when the operator
database has never existed. Subsequent accounts and permissions are managed at
`/admin/operators`. The first administrator has both permissions. New accounts
have neither `canManageAdmin` nor `canManageOperator` by default.

AD login logs a short trace ID, LDAPS host and port, and timing for search
connection, search account bind, directory search/results, user connection,
and user password bind. A timeout message names the stage that stalled.
`AD_TIMEOUT_SECONDS` sets the per-stage limit (default 8 seconds). Logs
never include passwords or the search account DN.


Approved operators manage only their own SSH public key at `/admin/keys` and
see their own key edit history. `canManageOperator` permits sending invitations
at `/admin/invite` and viewing the invitation journal at `/admin/journal`.
`canManageAdmin` permits changing approved accounts and viewing the complete
journal. Existing `deploy/authorized_keys` entries stay active as unmanaged
legacy entries. Managed keys are written separately to the `operator_state`
Docker volume, which is also mounted read-only in the SSH sidecar.

Configure `SMTP_SERVER`, `SMTP_FROM`, and, where required, `SMTP_USER` and
`SMTP_PASSWORD` to enable invitations. `PUBLIC_BASE_URL` must be the public
HTTPS origin. The email contains all three languages, a link to `/help`, and
the download link. The existing-Chrome checkbox adds instructions and a
warning, but does not change how the EXE starts. Send attempts, successes, and
failures include the AD sender, recipient, checkbox value, and UTC time in the
persistent journal. SMTP certificate validation is enabled; `SMTP_REQUIRE_TLS`
defaults to `true`.

If `DOMAIN_HOSTNAME` is unset, the existing `ADMIN_PASSWORD` Basic login remains
available. When AD is configured, the shared password is ignored even if AD
is unreachable. Operator state persists in the `operator_state` named volume;
do not remove that volume during ordinary upgrades.

## Security model

- Client Chrome debug endpoints bind only to `127.0.0.1`.
- Relay ports use the fixed `41000-41049` range.
- Docker can publish the read-only connection list to the LAN.
- Docker publishes relay tunnel ports only on host loopback.
- Agents authenticate with a revocable enrollment token.
- The status page and `GET /api/sessions` are read-only and public by default.
- Admin actions require an approved AD sign-in when AD is configured. Basic
  authentication is available only when AD is not configured.
- Heartbeat and maximum-session timeouts remove stale sessions.
- SSH examples allow only local forwarding to the relay range and no shell.

The enrollment token permits a machine to create a debug session. Treat it as a
secret, rotate it when exposed, and do not use it as an admin credential.

## Server deployment

1. Copy the environment example and edit the production section at the top of
   `.env`. At minimum, replace `AGENT_ENROLLMENT_TOKEN`. Configure AD for
   individual operator accounts, or set `ADMIN_PASSWORD` for local fallback:

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
   own AD session or local fallback authentication:

   ```bash
   sudo nginx -t
   sudo systemctl reload nginx
   ```

   For the Windows nginx installation, run these commands **on the nginx
   server**, from its local nginx installation directory after updating
   `conf/conf.d/nginx-debug-relay.conf`:

   ```powershell
   .\nginx.exe -t
   .\nginx.exe -s reload
   ```

   Editing a mapped drive alone does not reload nginx on the server. The
   active config must include `location = /help` or nginx's `location /`
   returns 404.

   The example listens on HTTPS port `9999` and proxies to the Dart relay
   backend on `127.0.0.1:9998`. This avoids a port conflict when nginx and the
   Dart relay run on the same host.


4. Adjust the nginx `allow` networks before deployment. `/agent` must remain
   reachable by supported user PCs, while `/debug-sessions`,
   `/help`, `/download/client_debug_agent.exe`, and `GET /api/sessions` should be
   limited to the local network or IT VPN.

The service binds tunnel ports to `0.0.0.0` **inside the container** so Docker
can publish them. `docker-compose.yml` publishes tunnel ports only to host
`127.0.0.1`, so they are not directly reachable from the LAN. The Dart backend
HTTP port is published on
`${SERVER_HTTP_PUBLISH_BIND:-127.0.0.1}:${SERVER_HTTP_PUBLISH_PORT:-9998}`;
keep it loopback-only when nginx is the public frontend.

When pulling a newer image, also update the production `docker-compose.yml`.
The `debug-relay` service must set `OPERATOR_STATE_DIR=/var/lib/debug-relay`
and `HELP_LOCALES_DIR=/etc/debug-relay/help_locales`, and mount the
`operator_state` volume at `/var/lib/debug-relay`. The `ssh-relay` service
mounts the same volume read-only. An older Compose file leaves the state path
at `deploy/operator_state`, which fails on the read-only container filesystem.
Use `docker compose config` to inspect the resolved settings, then
`docker compose up -d`. Do not use `down -v` for this upgrade; that removes
persistent SSH host keys and operator state.

## Restricted SSH setup

SSH runs in the `ssh-relay` Docker sidecar. No Windows OpenSSH service and no
Windows `debug-tunnel` user are required.

Generate one keypair per operator on the operator PC:

```powershell
$k="$env:USERPROFILE\.ssh\id_ed25519"; $p="$k.pub"; if((Test-Path $k) -xor (Test-Path $p)){ throw "Only one key file exists. Fix the pair first." }; if(!(Test-Path $k)){ New-Item -ItemType Directory -Force -Path (Split-Path $k) | Out-Null; ssh-keygen -t ed25519 -f $k }; Get-Content $p
```

In AD mode, each approved operator pastes only their own `.pub` content into
`/admin/keys`. Never copy or share private keys. For legacy entries or local
fallback mode, create the mounted authorized keys file manually:

```bash
cp deploy/authorized_keys.example deploy/authorized_keys
# Edit deploy/authorized_keys and add one .pub key per line.
docker compose up -d --build ssh-relay
```

`docker-compose.yml` mounts the `deploy` directory, not the individual
`authorized_keys` file. This allows creating the legacy file after deployment.
AD-managed keys live in the separate `operator_state` volume.

SSH server host keys are stored in the Docker volume `ssh_host_keys`. Do not
copy `deploy/ssh_host_keys` to production; host private keys need Linux file
permissions such as `0600`, and bind mounts from some hosts can expose them as
too open for OpenSSH.

Open `https://softapp.vietsov.com.vn:9999/admin/keys` to manage your own key.
The main `/debug-sessions` page links to this page. In AD mode, admins can
request a reload from `/admin/operators`.
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

Experimental native C++ client build:

```powershell
c_client\build.bat
```

This uses `c_client\CMakeLists.txt`, reads `.env`, and writes
`build\client_debug_agent_cpp.exe` and `build\client_debug_agent_cpp_dev.exe`.

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
