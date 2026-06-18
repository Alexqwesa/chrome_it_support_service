#!/bin/sh
set -eu

mkdir -p /run/sshd /home/debug-tunnel/.ssh /etc/ssh/host_keys

if [ ! -s /etc/ssh/host_keys/ssh_host_ed25519_key ]; then
  ssh-keygen -t ed25519 -f /etc/ssh/host_keys/ssh_host_ed25519_key -N ''
fi

if [ ! -s /etc/ssh/host_keys/ssh_host_rsa_key ]; then
  ssh-keygen -t rsa -b 4096 -f /etc/ssh/host_keys/ssh_host_rsa_key -N ''
fi

touch /home/debug-tunnel/.ssh/authorized_keys
chown -R debug-tunnel:debug-tunnel /home/debug-tunnel/.ssh
chmod 700 /home/debug-tunnel/.ssh
chmod 600 /home/debug-tunnel/.ssh/authorized_keys
chmod 600 /etc/ssh/host_keys/ssh_host_*_key
chmod 644 /etc/ssh/host_keys/ssh_host_*_key.pub

exec /usr/sbin/sshd -D -e
