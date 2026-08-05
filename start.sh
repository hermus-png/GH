#!/bin/bash
# Kali Web environment for GitHub Actions runner (Ubuntu).
# Sets up XFCE desktop + noVNC, then exposes it via a temporary Cloudflare tunnel.
set -e

echo "[*] Setup start (runner)"

# --- Optional Telegram notification ---
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
send_telegram() {
  [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] && \
  curl -s -f -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
send_telegram "Kali Web starting... tunnel URL will be posted soon."

# --- install packages (Ubuntu) ---
export DEBIAN_FRONTEND=noninteractive
echo "[*] apt update"
apt-get update -yq >/dev/null 2>&1
echo "[*] apt install desktop + VNC + noVNC + cloudflared"
apt-get install -yq --no-install-recommends \
  xvfb x11vnc xfce4 xfce4-terminal firefox \
  novnc websockify curl wget net-tools >/dev/null 2>&1 || \
apt-get install -yq --no-install-recommends \
  xvfb x11vnc xfce4 xfce4-terminal novnc websockify curl wget net-tools >/dev/null 2>&1

# cloudflared (latest) — GitHub is generally reachable
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[*] Installing cloudflared"
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi

# --- Start X display + desktop ---
echo "[*] Starting Xvfb"
export DISPLAY=:99
rm -f /tmp/.X99-lock
Xvfb :99 -screen 0 1440x900x24 &

sleep 2
echo "[*] Starting wm + desktop"
export HOME=/root
startxfce4 &> /tmp/xfce.log &

# --- x11vnc (no password) ---
echo "[*] Starting x11vnc (no password)"
x11vnc -display :99 -forever -nopw -shared -rfbport 5900 -o /tmp/x11vnc.log &

# --- noVNC on 6080 ---
sleep 2
echo "[*] Starting noVNC websockify on 6080"
websockify --web=/usr/share/novnc/ 6080 localhost:5900 &
sleep 2

echo "[*] Starting Cloudflare quick tunnel -> http://127.0.0.1:6080"
# Run tunnel in background; capture URL from stderr
cloudflared tunnel --url http://127.0.0.1:6080 --no-autoupdate \
  > /tmp/cf.log 2>&1 &

# Wait for the .trycloudflare.com URL to appear, then print + notify
for i in $(seq 1 120); do
  URL=$(grep -oE "https://[a-z0-9.-]+\.trycloudflare\.com" /tmp/cf.log 2>/dev/null | head -1)
  if [ -n "$URL" ]; then
    echo "############################################"
    echo "####  VNC URL: ${URL}/vnc.html  ####"
    echo "############################################"
    send_telegram "Kali is UP (no password)
VNC: ${URL}/vnc.html"
    break
  fi
  sleep 2
done

echo "[*] Keep-alive. Ctrl-C / stop the run to end."
# Keep the runner alive while tunnel is up
wait