#!/usr/bin/env python3
"""
GPU worker control daemon — lets the in-cluster gpu-status app join/leave/shutdown
the on-demand GPU worker over the tailnet, WITHOUT SSH (the box runs Tailscale SSH in
interactive "check" mode, which a headless caller can't satisfy). Bound to the
Tailscale interface and gated by a bearer token shared with the cluster Secret.

Runs as root via systemd (needs systemctl / k3s-killall / poweroff). Dependency-free.

  GET  /healthz            -> {"ok": true, "agent": "<active|inactive|...>"}
  POST /join               -> systemctl enable --now k3s-agent
  POST /leave              -> systemctl disable --now k3s-agent ; k3s-killall.sh
  POST /shutdown           -> leave actions, then systemctl poweroff
Auth: Authorization: Bearer <token from /etc/gpu-controld/token>.
"""
import json, os, time, hmac, socket, subprocess, fcntl, struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN_FILE = "/etc/gpu-controld/token"
PORT = int(os.environ.get("GPU_CONTROLD_PORT", "9696"))
# Master Tailscale IP, for re-asserting the Harbor :443 bypass after a (re)join.
MASTER_IP = os.environ.get("GPU_MASTER_IP", "")

def _sh(cmd, timeout=180):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return {"cmd": " ".join(cmd) if isinstance(cmd, list) else cmd,
                "rc": r.returncode, "out": (r.stdout or "")[-800:], "err": (r.stderr or "")[-800:]}
    except Exception as e:
        return {"cmd": " ".join(cmd) if isinstance(cmd, list) else cmd, "rc": 1, "err": str(e)}

def _fix_harbor_bypass():
    # Registry pulls resolve Harbor to MASTER_IP (= Traefik's LoadBalancer IP). While joined,
    # kube-proxy DNATs :443→that IP into the Traefik pod over VXLAN-over-Tailscale, whose
    # ~1228B path MTU drops large TLS flights → image pulls hang ("TLS handshake timeout").
    # A RETURN before KUBE-SERVICES sends them to the master's host Traefik (single-encap).
    # kube-proxy re-prepends its OUTPUT jump on every agent (re)start, so re-assert ours on top.
    if not MASTER_IP:
        return {"cmd": "harbor-bypass", "skipped": "GPU_MASTER_IP unset"}
    return _sh(["bash", "-c",
                f"for i in 1 2 3; do iptables -t nat -D OUTPUT -d {MASTER_IP}/32 -p tcp --dport 443 -j RETURN 2>/dev/null || break; done; "
                f"iptables -t nat -I OUTPUT 1 -d {MASTER_IP}/32 -p tcp --dport 443 -j RETURN"])

def act_join():
    res = [_sh(["systemctl", "enable", "--now", "k3s-agent"])]
    time.sleep(8)  # let kube-proxy place its OUTPUT jump, then put our bypass above it
    res.append(_fix_harbor_bypass())
    return res

def act_leave():
    return [_sh(["systemctl", "disable", "--now", "k3s-agent"]),
            _sh(["/usr/local/bin/k3s-killall.sh"])]

def act_shutdown():
    return act_leave() + [_sh(["systemctl", "poweroff"], timeout=20)]

HANDLERS = {"join": act_join, "leave": act_leave, "shutdown": act_shutdown}

def _token():
    with open(TOKEN_FILE) as f:
        return f.read().strip()

def _tailscale_ip():
    # Bind only to the tailnet so the daemon isn't exposed on the home LAN.
    try:
        s = fcntl.ioctl(socket.socket(socket.AF_INET, socket.SOCK_DGRAM).fileno(),
                        0x8915, struct.pack('256s', b'tailscale0'))  # SIOCGIFADDR
        return socket.inet_ntoa(s[20:24])
    except Exception:
        return "0.0.0.0"  # fall back; token still gates access

def _agent_state():
    r = subprocess.run(["systemctl", "is-active", "k3s-agent"], capture_output=True, text=True)
    return r.stdout.strip() or "unknown"

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _authed(self):
        got = self.headers.get("Authorization", "")
        want = "Bearer " + _token()
        return len(got) == len(want) and hmac.compare_digest(got, want)

    def do_GET(self):
        if self.path == "/healthz":
            return self._send(200, {"ok": True, "agent": _agent_state()})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._authed():
            return self._send(401, {"error": "unauthorized"})
        action = self.path.strip("/")
        if action not in HANDLERS:
            return self._send(404, {"error": "unknown action", "valid": list(HANDLERS)})
        results = HANDLERS[action]()
        # Every step must succeed, except a poweroff/killall whose host teardown can race
        # the reply (rc!=0 there is not a real failure).
        ok = all(r.get("rc", 1) == 0 or "poweroff" in r.get("cmd", "") or "killall" in r.get("cmd", "")
                 for r in results if "skipped" not in r)
        self._send(200 if ok else 500, {"action": action, "ok": ok, "agent": _agent_state(), "results": results})

if __name__ == "__main__":
    ThreadingHTTPServer((_tailscale_ip(), PORT), H).serve_forever()
