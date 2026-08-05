#!/bin/bash
# Kali Web v2 — fully self-contained VNC+noVNC stack inside the container.
# We do NOT rely on the image's VNC/noVNC (wrong port / password issues):
# we start our OWN Xvfb + x11vnc (NO password) + websockify on 6080,
# then open a temporary Cloudflare tunnel to 6080.
set -e

echo "[*] Kali Web v2 setup (container)"

TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT="${TELEGRAM_CHAT_ID:-}"
send_telegram() {
  [ -n "$TOKEN" ] && [ -n "$CHAT" ] && \
  curl -s -f -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT}" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
send_telegram "Kali Web v2 starting (fixed VNC)..."

# --- cloudflared ---
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[*] installing cloudflared"
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cf
  chmod +x /tmp/cf
  mv /tmp/cf /usr/local/bin/cloudflared
fi

# --- kill the image's own VNC/noVNC to avoid port & password conflicts ---
echo "[*] cleaning old vnc/novnc processes"
pkill -f x11vnc 2>/dev/null || true
pkill -f websockify 2>/dev/null || true
pkill -f novnc_proxy 2>/dev/null || true
sleep 2

# --- ensure an X display ---
export DISPLAY=:0
if [ ! -S /tmp/.X11-unix/X0 ]; then
  echo "[*] starting Xvfb on :0"
  Xvfb :0 -screen 0 1600x1000x24 &>/tmp/xvfb.log &
  sleep 3
fi

# --- x11vnc with NO PASSWORD on port 5901 ---
echo "[*] starting x11vnc (no password) on :5901"
x11vnc -display :0 -forever -shared -nopw -rfbport 5901 -bg -o /tmp/x11vnc.log || \
x11vnc -display :0 -forever -shared -nopw -rfbport 5901 -o /tmp/x11vnc.log &
sleep 3

# --- locate noVNC web files ---
NOVNC=""
for d in /usr/share/novnc /opt/noVNC /usr/share/noVNC /usr/share/novnc-noVNC; do
  [ -f "$d/vnc.html" ] && NOVNC=$d && break
done
if [ -z "$NOVNC" ]; then
  NOVNC=$(find / -maxdepth 5 -name vnc.html -not -path "*/proc/*" 2>/dev/null | head -1 | xargs -r dirname)
fi
echo "[*] noVNC web dir: ${NOVNC:-NOT FOUND}"

# --- websockify: serve noVNC page AND proxy websocket to :5901 (same port!) ---
echo "[*] starting websockify on :6080 -> localhost:5901"
if command -v websockify >/dev/null 2>&1; then
  websockify --web="${NOVNC:-/usr/share/novnc}" 6080 localhost:5901 &>/tmp/ws.log &
elif python3 -c "import websockify" 2>/dev/null; then
  python3 -m websockify --web="${NOVNC:-/usr/share/novnc}" 6080 localhost:5901 &>/tmp/ws.log &
else
  echo "[*] installing novnc + websockify"
  apt-get update -yq >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -yq novnc websockify >/dev/null 2>&1 || true
  websockify --web="${NOVNC:-/usr/share/novnc}" 6080 localhost:5901 &>/tmp/ws.log &
fi
sleep 4

# --- verify ---
echo "[*] service check:"
(ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null) | grep -E ':(5901|6080)' || echo "!! ports not listening"
curl -s -o /dev/null -w "vnc.html HTTP %{http_code}\n" http://127.0.0.1:6080/vnc.html || true

# --- Cloudflare quick tunnel -> 6080 ---
echo "[*] starting cloudflare tunnel"
cloudflared tunnel --url http://127.0.0.1:6080 --no-autoupdate &>/tmp/cf.log &
for i in $(seq 1 90); do
  URL=$(grep -oE "https://[a-z0-9.-]+\.trycloudflare\.com" /tmp/cf.log 2>/dev/null | head -1)
  if [ -n "$URL" ]; then
    echo "############ KALI IS UP ############"
    echo "##  LINK: ${URL}/vnc.html?autoconnect=1&resize=scale&reconnect=1"
    echo "##  No password - auto connects"
    echo "####################################"
    send_telegram "Kali is UP (no password, auto-connect)
Link: ${URL}/vnc.html?autoconnect=1&resize=scale&reconnect=1"
    break
  fi
  sleep 2
done

echo "[*] keep-alive (stop the run to end)"
wait