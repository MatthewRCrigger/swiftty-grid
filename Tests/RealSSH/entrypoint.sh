#!/bin/sh
set -eu
echo "rst:${RST_PASSWORD}" | chpasswd
if [ -n "${RST_AUTHORIZED_KEY:-}" ]; then
  echo "$RST_AUTHORIZED_KEY" > /home/rst/.ssh/authorized_keys
  chown rst:rst /home/rst/.ssh/authorized_keys
  chmod 600 /home/rst/.ssh/authorized_keys
fi
# sshd strips the environment; bake the bridge address into the helper.
sed -i "s|\${RST_BRIDGE:-192.168.64.1:51400}|${RST_BRIDGE}|" /usr/local/libexec/swifttyd
mkdir -p /home/rst/files && chown rst:rst /home/rst/files
cat /etc/ssh/ssh_host_ed25519_key.pub > /tmp/hostkey.pub
exec /usr/sbin/sshd -D -e
