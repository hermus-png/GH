#!/bin/bash
# Kali Web — wires noVNC + Cloudflare tunnel inside the kali-novnc container.
# The container image already runs XFCE + VNC(5900) + noVNC(8080 or 6080).
# We detect the live noVNC port, then open a temporary Cloudflare tunnel to it.
set -e

echo "[*] Kali Web setup (container)"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
send_telegram() {
  [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] && \
  curl -s -f -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
send_telegram "Kali Web container starting..."

# --- cloudflared (tunnel client) ---
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[*] installing cloudflared"
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cf
  chmod +x /tmp/cf
  mv /tmp/cf /usr/local/bin/cloudflared
fi

# --- wait for VNC/noVNC services (image boots them via supervisor) ---
echo "[*] waiting for VNC :5900"
for i in $(seq 1 60); do
  (ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null) | grep -q ':5900' && { echo "VNC up"; break; }
  sleep 2
done

echo "[*] looking for noVNC port (6080 or 8080)"
NOVNC_PORT=""
for p in 6080 8080 6901; do
  if (ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null) | grep -q ":$p"; then
    NOVNC_PORT=$p
    echo "noVNC found on :$p"
    break
  fi
done

# If no noVNC service is running, start one pointing at VNC 5900
if [ -z "$NOVNC_PORT" ]; then
  echo "[*] no noVNC running — starting websockify on 6080"
  apt-get update -yq >/dev/null 2>&1 || true
  apt-get install -yq novnc websockify >/dev/null 2>&1 || true
  # If websockify isn't available, use the noVNC python module
  if command -v websockify >/dev/null 2>&1; then
    websockify --web=/usr/share/novnc/ 6080 localhost:5900 &>/tmp/novnc.log &
  else
    python3 -m websockify --web=/usr/share/novnc/ 6080 localhost:5900 &>/tmp/novnc.log &
  fi
  NOVNC_PORT=6080
  sleep 3
fi

# --- Cloudflare quick tunnel to the noVNC port ---
echo "[*] starting Cloudflare tunnel -> :$NOVNC_PORT"
cloudflared tunnel --url "http://127.0.0.1:$NOVNC_PORT" --no-autoupdate &>/tmp/cf.log &
for i in $(seq 1 90); do
  URL=$(grep -oE "https://[a-z0-9.-]+\.trycloudflare\.com" /tmp/cf.log 2>/dev/null | head -1)
  if [ -n "$URL" ]; then
    echo "############ KALI IS UP ############"
    echo "##  VNC: ${URL}/vnc.html"
    echo "##  No password required"
    echo "####################################"
    send_telegram "Kali is UP (no password)
VNC: ${URL}/vnc.html"
    break
  fi
  sleep 2
done

echo "[*] keep-alive (stop the run to end)"
wait