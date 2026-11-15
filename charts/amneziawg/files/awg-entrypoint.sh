#!/bin/bash
# Brings up the userspace AmneziaWG interface. Peers are not configured here: the portal
# container owns them and pushes them over the UAPI socket.
set -euo pipefail

IFACE="${IFACE:-awg0}"

mkdir -p /dev/net
[[ -c /dev/net/tun ]] || mknod /dev/net/tun c 10 200

amneziawg-go -f "$IFACE" &
pid=$!

sock=""
for _ in $(seq 1 50); do
  for dir in /var/run/amneziawg /var/run/wireguard; do
    [[ -S "$dir/$IFACE.sock" ]] && sock="$dir/$IFACE.sock"
  done
  [[ -n "$sock" ]] && break
  kill -0 "$pid" 2>/dev/null || { echo "amneziawg-go exited" >&2; exit 1; }
  sleep 0.2
done
[[ -n "$sock" ]] || { echo "no UAPI socket for $IFACE" >&2; exit 1; }
# Do not chmod the socket: amneziawg-go watches it and removes it on any attribute change.
# The portal container therefore runs as the same user (root, with every capability dropped).

# The socket file appears a moment before the device answers on it.
configured=""
for _ in $(seq 1 25); do
  if awg setconf "$IFACE" /etc/awg/awg0.conf 2>/dev/null; then configured=1; break; fi
  sleep 0.2
done
[[ -n "$configured" ]] || awg setconf "$IFACE" /etc/awg/awg0.conf
ip address add "$AWG_ADDRESS" dev "$IFACE"
ip link set dev "$IFACE" mtu "$AWG_MTU" up
echo "$IFACE up: $AWG_ADDRESS, udp/$(awg show "$IFACE" listen-port)"

trap 'kill "$pid" 2>/dev/null || true' TERM INT
wait "$pid"
