#!/bin/sh
set -eu

mkdir -p /run/sshd /home/debug-tunnel/.ssh /etc/ssh/host_keys

if [ ! -s /etc/ssh/host_keys/ssh_host_ed25519_key ]; then
  ssh-keygen -t ed25519 -f /etc/ssh/host_keys/ssh_host_ed25519_key -N ''
fi

if [ ! -s /etc/ssh/host_keys/ssh_host_rsa_key ]; then
  ssh-keygen -t rsa -b 4096 -f /etc/ssh/host_keys/ssh_host_rsa_key -N ''
fi

chmod 600 /etc/ssh/host_keys/ssh_host_*_key
chmod 644 /etc/ssh/host_keys/ssh_host_*_key.pub

echo "Starting ssh-relay."
echo "Authorized keys file: /data/authorized_keys"
if [ -f /data/authorized_keys ]; then
  key_count="$(grep -E '^[[:space:]]*(restrict |no-|command=|ssh-|ecdsa-|sk-)' /data/authorized_keys 2>/dev/null | wc -l | tr -d ' ')"
  echo "Authorized keys present: $key_count"
else
  echo "WARNING: /data/authorized_keys is missing or is not a file."
fi
echo "Host key permissions:"
ls -l /etc/ssh/host_keys/ssh_host_*_key
echo "Validating sshd configuration."
/usr/sbin/sshd -t -f /etc/ssh/sshd_config

/usr/sbin/sshd -D -e &
sshd_pid="$!"
echo "sshd started with pid $sshd_pid"

stop_sshd() {
  kill "$sshd_pid" 2>/dev/null || true
  wait "$sshd_pid" 2>/dev/null || true
}

trap stop_sshd INT TERM

if [ -n "${SSHD_RELOAD_SIGNAL_FILE:-}" ]; then
  mkdir -p "$(dirname "$SSHD_RELOAD_SIGNAL_FILE")"
  echo "Watching sshd reload marker: $SSHD_RELOAD_SIGNAL_FILE"
  last_reload_marker="$(stat -c %Y "$SSHD_RELOAD_SIGNAL_FILE" 2>/dev/null || echo 0)"
  while kill -0 "$sshd_pid" 2>/dev/null; do
    current_reload_marker="$(stat -c %Y "$SSHD_RELOAD_SIGNAL_FILE" 2>/dev/null || echo 0)"
    if [ "$current_reload_marker" != "$last_reload_marker" ]; then
      last_reload_marker="$current_reload_marker"
      echo "Reload marker changed; sending SIGHUP to sshd pid $sshd_pid"
      kill -HUP "$sshd_pid" 2>/dev/null || true
    fi
    sleep 2
  done
fi

wait "$sshd_pid"
