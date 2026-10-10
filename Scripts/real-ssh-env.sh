#!/bin/sh
# Real OpenSSH + real swifttyd environment, reusable by several test drivers
# without touching this Mac's SSH setup.
#
#   Scripts/real-ssh-env.sh start [state-dir]   # prints the env file path
#   Scripts/real-ssh-env.sh stop  <state-dir>
#
# `start` brings up, and leaves running in the background:
#  - a real SwiftMux service with roaming (`swiftmux-agent --roaming-config`) on this Mac (QUIC on 127.0.0.1:<quic port>);
#  - an apple/container Linux VM running OpenSSH (sshd, sftp-server) as user
#    `rst` with a random password and authorized Ed25519 key. Its fixed
#    helper path /usr/local/libexec/swifttyd relays `bootstrap --stdio` over
#    TCP to a bridge here, which forwards to the agent's control socket
#    (swifttyd itself is macOS-only and cannot run in the VM);
#  - a loopback relay 127.0.0.1:<ssh port> to the VM's sshd through
#    `container exec`. macOS Local Network privacy can refuse non-system
#    binaries a route to the VM subnet (EHOSTUNREACH); loopback is always
#    reachable, including from the iOS simulator, which shares it.
#
# It writes `<state-dir>/env`, a sourceable file of exports:
#   RST_REAL_SSH_HOST RST_REAL_SSH_PORT RST_REAL_SSH_USER
#   RST_REAL_SSH_PASSWORD RST_REAL_SSH_HOSTKEY RST_REAL_SSH_FINGERPRINT
#   RST_REAL_SSH_KEY_HEX RST_REAL_SSH_QUIC_PORT RST_REAL_SSH_ENV_DIR
# and prints its path as the only line on stdout (progress goes to stderr).
# `stop` kills the background processes and removes the VM.
set -eu
usage() { echo "usage: $0 start [state-dir] | stop <state-dir>" >&2; exit 2; }
[ "$#" -ge 1 ] || usage
repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)

stop() {
  dir=$1
  [ -d "$dir" ] || return 0
  for f in relay bridge host; do
    if [ -s "$dir/$f.pid" ]; then
      kill "$(cat "$dir/$f.pid")" 2>/dev/null || true
      rm -f "$dir/$f.pid"
    fi
  done
  if [ -s "$dir/container.name" ]; then
    container rm -f "$(cat "$dir/container.name")" >/dev/null 2>&1 || true
    rm -f "$dir/container.name"
  fi
}

case $1 in
  stop) [ "$#" -eq 2 ] || usage; stop "$2"; exit 0 ;;
  start) ;;
  *) usage ;;
esac

command -v container >/dev/null || { echo "apple/container required" >&2; exit 1; }
workspace=${2:-$(mktemp -d /tmp/rstr.XXXXXX)}
mkdir -p "$workspace"
workspace=$(CDPATH= cd "$workspace" && pwd)
name="swiftty-rst-ssh-$$"
echo "Workspace: $workspace" >&2
fail() {
  echo "$*" >&2
  stop "$workspace"
  exit 1
}
trap 'stop "$workspace"' INT TERM

container build --progress plain -t swiftty-rst-ssh:test \
  -f "$repository_root/Tests/RealSSH/Containerfile" \
  "$repository_root/Tests/RealSSH" >"$workspace/build.log" 2>&1 \
  || fail "container build failed; see $workspace/build.log"

(cd "$repository_root" && mise exec -- swift build --product swiftmux-agent && mise exec -- swift build --product swmux-launcher && mise exec -- swift build --product swifttyd >"$workspace/swift-build.log" 2>&1) \
  || fail "swifttyd build failed; see $workspace/swift-build.log"
bin_dir="$(cd "$repository_root" && mise exec -- swift build --show-bin-path)"
host_bin="$bin_dir/swiftmux-agent"
# RST_QUIC_PORT / RST_SSH_PORT pin ports, e.g. for router port forwarding.
quic_port=${RST_QUIC_PORT:-$((51500 + $$ % 400))}
# RST_PUBLIC_HOST=<this Mac's LAN address> serves physical devices: swifttyd
# and the SSH relay listen on all interfaces and grants advertise that
# address. Default: loopback only (simulators and local tests).
public_host=${RST_PUBLIC_HOST:-}
if [ -n "$public_host" ]; then
  bind_address=0.0.0.0; advertised=$public_host; relay_bind=0.0.0.0
else
  bind_address=127.0.0.1; advertised=127.0.0.1; relay_bind=127.0.0.1
fi
printf '{"bindAddress":"%s","advertisedHost":"%s","port":%s,"stateDirectory":"%s/state"}' \
  "$bind_address" "$advertised" "$quic_port" "$workspace" >"$workspace/config.json"
"$host_bin" --mach-service "com.chr33s.swiftty.swiftmux.test.$$" --launcher "$bin_dir/swmux-launcher" --roaming-config "$workspace/config.json" </dev/null >/dev/null 2>"$workspace/host.log" &
echo $! >"$workspace/host.pid"

password=$(openssl rand -hex 12)
seed=$(openssl rand -hex 32)
cat >"$workspace/pubkey.swift" <<SWIFT
import CryptoKit
import Foundation
let hex = CommandLine.arguments[1]
var seed = [UInt8]()
var i = hex.startIndex
while i < hex.endIndex {
  let j = hex.index(i, offsetBy: 2)
  seed.append(UInt8(hex[i ..< j], radix: 16)!)
  i = j
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey
func field(_ b: [UInt8]) -> [UInt8] {
  let n = UInt32(b.count)
  return [UInt8(n >> 24), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] + b
}
let blob = field(Array("ssh-ed25519".utf8)) + field(Array(key.rawRepresentation))
print("ssh-ed25519 " + Data(blob).base64EncodedString())
SWIFT
xcrun swiftc -O "$workspace/pubkey.swift" -o "$workspace/pubkey" 2>"$workspace/pubkey.log" \
  || fail "pubkey helper build failed; see $workspace/pubkey.log"
authorized=$("$workspace/pubkey" "$seed")

# The VM reaches the host through the default network's gateway.
gateway=$(container network list | awk '$1=="default"{print $2}' | sed 's|\.0/24|.1|')
bridge_port=$((51900 + $$ % 90))
container run -d --name "$name" \
  -e RST_PASSWORD="$password" -e RST_AUTHORIZED_KEY="$authorized" \
  -e RST_BRIDGE="$gateway:$bridge_port" swiftty-rst-ssh:test >/dev/null \
  || fail "container run failed"
echo "$name" >"$workspace/container.name"

python3 -I - "$gateway" "$bridge_port" "$workspace/state/control.sock" \
  >"$workspace/bridge.log" 2>&1 <<'PY' &
import socket, sys, threading
host, port, path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
def pump(a, b):
    try:
        while (data := a.recv(65536)):
            b.sendall(data)
    finally:
        try: b.shutdown(socket.SHUT_WR)
        except OSError: pass
def serve(client):
    upstream = socket.socket(socket.AF_UNIX)
    upstream.connect(path)
    t = threading.Thread(target=pump, args=(client, upstream)); t.start()
    pump(upstream, client); t.join(); client.close(); upstream.close()
listener = socket.socket(); listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind((host, port)); listener.listen(8)
print("bridge ready", flush=True)
while True:
    c, _ = listener.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
PY
echo $! >"$workspace/bridge.pid"

i=0
until address=$(container inspect "$name" 2>/dev/null | python3 -I -c '
import sys, json
d = json.load(sys.stdin)[0]
print(d["status"]["networks"][0]["ipv4Address"].split("/")[0])' 2>/dev/null) && [ -n "$address" ] \
  && container exec "$name" test -s /tmp/hostkey.pub 2>/dev/null; do
  i=$((i + 1)); [ $i -lt 100 ] || fail "container did not start"
  sleep 0.2
done
hostkey=$(container exec "$name" cut -d' ' -f1,2 /tmp/hostkey.pub)
echo "$hostkey" >"$workspace/hostkey.pub"
fingerprint=$(ssh-keygen -lf "$workspace/hostkey.pub" | awk '{print $2}')

ssh_port=${RST_SSH_PORT:-$((52000 + $$ % 400))}
python3 -I - "$ssh_port" "$name" "$relay_bind" >"$workspace/relay.log" 2>&1 <<'PY' &
import socket, subprocess, sys, threading
port, name, bind = int(sys.argv[1]), sys.argv[2], sys.argv[3]
def serve(client):
    # Reach sshd through the container daemon, not the VM network.
    proc = subprocess.Popen(
        ["container", "exec", "-i", name, "socat", "STDIO", "TCP:127.0.0.1:22"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
    def up():
        try:
            while (data := client.recv(65536)):
                proc.stdin.write(data)
        except OSError:
            pass
        finally:
            try: proc.stdin.close()
            except OSError: pass
    t = threading.Thread(target=up); t.start()
    try:
        while (data := proc.stdout.read1(65536) if hasattr(proc.stdout, "read1") else proc.stdout.read(65536)):
            client.sendall(data)
    except OSError:
        pass
    try: client.shutdown(socket.SHUT_WR)
    except OSError: pass
    t.join(); proc.wait(); client.close()
listener = socket.socket(); listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind((bind, port)); listener.listen(16)
while True:
    c, _ = listener.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
PY
echo $! >"$workspace/relay.pid"
i=0
until nc -z 127.0.0.1 "$ssh_port" 2>/dev/null; do
  i=$((i + 1)); [ $i -lt 50 ] || fail "relay did not start"; sleep 0.1
done
echo "OpenSSH at $address:22 via 127.0.0.1:$ssh_port; bridge $gateway:$bridge_port; swifttyd QUIC $advertised:$quic_port" >&2

cat >"$workspace/env" <<ENV
export RST_REAL_SSH_HOST=$advertised
export RST_REAL_SSH_PORT=$ssh_port
export RST_REAL_SSH_USER=rst
export RST_REAL_SSH_PASSWORD=$password
export RST_REAL_SSH_HOSTKEY='$hostkey'
export RST_REAL_SSH_FINGERPRINT=$fingerprint
export RST_REAL_SSH_KEY_HEX=$seed
export RST_REAL_SSH_QUIC_PORT=$quic_port
export RST_REAL_SSH_ENV_DIR=$workspace
ENV
chmod 600 "$workspace/env"
trap - INT TERM
echo "$workspace/env"
