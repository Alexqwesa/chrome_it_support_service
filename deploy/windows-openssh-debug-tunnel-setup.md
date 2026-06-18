# Windows OpenSSH debug-tunnel setup

Use this when the relay server runs on Windows and operators connect with:

```powershell
ssh -p 2222 -N -L 9333:127.0.0.1:41000 debug-tunnel@softapp.vietsov.com.vn
```

## Setup `debug-tunnel` user:

Yes. Windows OpenSSH authenticates real Windows users. Create a dedicated local
user only for SSH forwarding:

- Do not add it to `Administrators`.
- Do not use it for RDP or normal login.
- Disable password login in OpenSSH.
- Add one SSH public key per operator.

## Install OpenSSH Server

Run PowerShell as Administrator:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic
Start-Service sshd
```

Open TCP port `2222`:

```powershell
New-NetFirewallRule `
  -Name "VSP Debug Tunnel SSH 2222" `
  -DisplayName "VSP Debug Tunnel SSH 2222" `
  -Enabled True `
  -Direction Inbound `
  -Protocol TCP `
  -Action Allow `
  -LocalPort 2222
```

## Create the local user

Create a random password even though SSH password login will be disabled:

```powershell
$password = [System.Web.Security.Membership]::GeneratePassword(32, 8)
$securePassword = ConvertTo-SecureString $password -AsPlainText -Force

New-LocalUser `
  -Name "debug-tunnel" `
  -Password $securePassword `
  -Description "SSH local-forward only account for Chrome debug relay" `
  -PasswordNeverExpires
```

Confirm it is not an administrator:

```powershell
Get-LocalGroupMember Administrators | Where-Object Name -like "*debug-tunnel*"
```

The command above should return nothing.

## Generate operator SSH keys on the operator PC

Generate one keypair per operator while logged in as the operator's normal
Windows account. Do not log in locally as `debug-tunnel` for this step:

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\vsp_debug_tunnel_ed25519" -C "vsp-debug-tunnel-$env:USERNAME"
```

This creates:

```text
%USERPROFILE%\.ssh\vsp_debug_tunnel_ed25519
%USERPROFILE%\.ssh\vsp_debug_tunnel_ed25519.pub
```

`%USERPROFILE%` is the current operator user's profile, for example
`C:\Users\ivan\.ssh\...`. It is not `C:\Users\debug-tunnel`.

Keep the private key on the operator PC under the operator's user profile. Copy
only the `.pub` line to the relay server.

Optional operator-side SSH config:

```sshconfig
Host softapp-relay
    HostName softapp.vietsov.com.vn
    Port 2222
    User debug-tunnel
    IdentityFile ~/.ssh/vsp_debug_tunnel_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ExitOnForwardFailure yes
```

Purpose: this tells the operator's SSH client which private key to use and only
shortens operator commands. It does not belong in `C:\Users\debug-tunnel` on the
server. With it, an operator can run:

```powershell
ssh -N -L 9333:127.0.0.1:41000 softapp-relay
```

Without it, use the full command:

```powershell
ssh -p 2222 -i "$env:USERPROFILE\.ssh\vsp_debug_tunnel_ed25519" -N -L 9333:127.0.0.1:41000 debug-tunnel@softapp.vietsov.com.vn
```

## Add operator public keys

On the relay server, create the `.ssh` directory for the remote `debug-tunnel`
account:

```powershell
$sshDir = "C:\Users\debug-tunnel\.ssh"
New-Item -ItemType Directory -Force $sshDir | Out-Null
New-Item -ItemType File -Force "$sshDir\authorized_keys" | Out-Null
```

Append each operator public key to the remote `debug-tunnel` account:

```text
C:\Users\debug-tunnel\.ssh\authorized_keys
```

Example from the server, after receiving the public key text:

```powershell
Add-Content `
  -Path "C:\Users\debug-tunnel\.ssh\authorized_keys" `
  -Value "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... vsp-debug-tunnel-operator"
```

Add each operator public key as a separate line. Do not put private keys on the
server and do not generate operator private keys under `C:\Users\debug-tunnel`.

Fix ACLs so OpenSSH accepts the file:

```powershell
$profileDir = "C:\Users\debug-tunnel"
$sshDir = "$profileDir\.ssh"
$authorizedKeys = "$sshDir\authorized_keys"

icacls $sshDir /inheritance:r
icacls $sshDir /grant "debug-tunnel:(OI)(CI)F" "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F"

icacls $authorizedKeys /inheritance:r
icacls $authorizedKeys /grant "debug-tunnel:F" "SYSTEM:F" "Administrators:F"
```

## Configure sshd

Edit:

```text
C:\ProgramData\ssh\sshd_config
```

Set the listener port near the top:

```sshconfig
Port 2222
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
```

Append this block at the end:

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
    X11Forwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    GatewayPorts no
    ForceCommand C:\Windows\System32\cmd.exe /c exit 1
```

Important points:

- `AllowTcpForwarding local` allows `ssh -L` and blocks remote forwarding.
- `PermitOpen` restricts the destination to relay ports only.
- `PermitOpen` usually does not support numeric ranges, so every port is listed.
- `PermitTTY no` prevents interactive terminal allocation.
- `ForceCommand ... exit 1` makes shell/session commands fail. `ssh -N -L ...`
  still works because it does not request a session.

Restart OpenSSH:

```powershell
Restart-Service sshd
```

Check logs if authentication fails:

```powershell
Get-WinEvent -LogName OpenSSH/Operational -MaxEvents 50 |
  Select-Object TimeCreated, Id, LevelDisplayName, Message
```

## Verify

Allowed:

```powershell
ssh -p 2222 -N -L 9333:127.0.0.1:41000 debug-tunnel@softapp.vietsov.com.vn
```

Then open:

```text
http://127.0.0.1:9333/json/version
```

Should fail, no shell:

```powershell
ssh -p 2222 debug-tunnel@softapp.vietsov.com.vn
```

Should fail, destination outside relay range:

```powershell
ssh -p 2222 -N -L 9333:127.0.0.1:22 debug-tunnel@softapp.vietsov.com.vn
```

Should fail, remote forwarding:

```powershell
ssh -p 2222 -N -R 9000:127.0.0.1:41000 debug-tunnel@softapp.vietsov.com.vn
```

## Optional Windows logon hardening

For stricter hardening, deny interactive logon for `debug-tunnel` in Local
Security Policy:

```text
secpol.msc
  Local Policies
    User Rights Assignment
      Deny log on locally
      Deny log on through Remote Desktop Services
```

Add `debug-tunnel` to both policies. Keep SSH public-key login working before
and after this change.
