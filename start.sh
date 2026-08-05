#!/bin/bash
# Kali Web v4 — COMPLETELY self-owned stack: Xvfb + XFCE + x11vnc (no password)
# on port 5901, websockify (noVNC) on 6080, Cloudflare quick tunnel to 6080.
# Does not depend on the image's VNC/display/auth at all.
set -e

echo "[*] Kali Web v4 setup (container)"

TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT="${TELEGRAM_CHAT_ID:-}"
send_telegram() {
  [ -n "$TOKEN" ] && [ -n "$CHAT" ] && \
  curl -s -f -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT}" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
send_telegram "Kali Web v4 starting (self-owned stack)..."

# --- cloudflared ---
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[*] installing cloudflared"
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cf
  chmod +x /tmp/cf
  mv /tmp/cf /usr/local/bin/cloudflared
fi

# --- kill any old vnc/novnc/xvfb to free ports ---
echo "[*] cleaning old processes"
pkill -f x11vnc 2>/dev/null || true
pkill -f Xvfb 2>/dev/null || true
pkill -f websockify 2>/dev/null || true
pkill -f tightvncserver 2>/dev/null || true
pkill -f Xvnc 2>/dev/null || true
sleep 2

# --- our own X server on :1 ---
export DISPLAY=:1
echo "[*] starting Xvfb on :1 (1600x1000x24)"
Xvfb :1 -screen 0 1600x1000x24 -nolisten tcp &>/tmp/xvfb.log &
sleep 4
[ -S /tmp/.X11-unix/X1 ] && echo "  Xvfb OK (socket exists)" || { echo "  !! Xvfb failed"; cat /tmp/xvfb.log | tail -5; }

# --- desktop (XFCE) on :1 ---
echo "[*] starting XFCE desktop"
export DISPLAY=:1
if command -v startxfce4 >/dev/null 2>&1; then
  startxfce4 &>/tmp/xfce.log &
elif [ -f /etc/xdg/xfce4/xinitrc ] || [ -f /etc/X11/xinit/xinitrc ]; then
  xfce4-session &>/tmp/xfce.log &
else
  echo "  !! no XFCE found - will install"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -yq >/dev/null 2>&1 || true
  apt-get install -yq --no-install-recommends xfce4 xfce4-terminal xfce4-session >/dev/null 2>&1 || true
  startxfce4 &>/tmp/xfce.log &
fi
sleep 6

# --- install x11vnc if missing ---
if ! command -v x11vnc >/dev/null 2>&1; then
  echo "[*] installing x11vnc"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -yq >/dev/null 2>&1 || true
  apt-get install -yq x11vnc >/dev/null 2>&1 || apt-get install -yq --no-install-recommends x11vnc >/dev/null 2>&1 || true
fi

# --- x11vnc NO PASSWORD on :1, port 5901 ---
echo "[*] starting x11vnc (no password) on $DISPLAY :5901"
x11vnc -display "$DISPLAY" -forever -shared -nopw -rfbport 5901 -bg -o /tmp/x11vnc.log 2>&1 || \
x11vnc -display "$DISPLAY" -forever -shared -nopw -rfbport 5901 -o /tmp/x11vnc.log &
sleep 4
echo "  x11vnc log:"; tail -3 /tmp/x11vnc.log 2>/dev/null || true

# --- locate noVNC web files ---
NOVNC=""
for d in /usr/share/novnc /opt/noVNC /usr/share/noVNC; do
  [ -f "$d/vnc.html" ] && NOVNC=$d && break
done
[ -z "$NOVNC" ] && NOVNC="$(find / -maxdepth 6 -name vnc.html -not -path '*/proc/*' 2>/dev/null | head -1 | xargs -r dirname)"
echo "[*] noVNC web dir: ${NOVNC:-/usr/share/novnc}"

# --- websockify: noVNC page + proxy websocket to :5901 ---
echo "[*] starting websockify on :6080 -> localhost:5901"
if command -v websockify >/dev/null 2>&1; then
  websockify --web="${NOVNC:-/usr/share/novnc}" 6080 localhost:5901 &>/tmp/ws.log &
elif python3 -c "import websockify" 2>/dev/null; then
  python3 -m websockify --web="${NOVNC:-/usr/share/novnc}" 6080 localhost:5901 &>/tmp/ws.log &
else
  echo "[*] installing novnc websockify"
  apt-get update -yq >/dev/null 2>&1 || true
  apt-get install -yq novnc websockify >/dev/null 2>&1 || true
  websockify --web="${NOVNC:-/usr/share/novnc}" 6080 localhost:5901 &>/tmp/ws.log &
fi
sleep 4

# --- VERIFY both ports before tunneling ---
echo "[*] service check:"
PORTS=$( (ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null) | grep -E ':(5901|6080)' || true)
echo "$PORTS"
if ! echo "$PORTS" | grep -q ':5901'; then
  echo "[!] VNC port 5901 is NOT listening - aborting tunnel"
  send_telegram "VNC setup FAILED - port 5901 not listening. Check the action log."
  exit 1
fi
curl -s -o /dev/null -w "  vnc.html HTTP %{http_code}\n" http://127.0.0.1:6080/vnc.html || true

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