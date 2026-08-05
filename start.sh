#!/bin/bash
# Kali Web v5 — install EVERYTHING we need (the image lacks Xvfb/x11vnc/XFCE):
#   xvfb + x11vnc + xfce4 via apt, then own stack on :1 -> 5901 -> websockify 6080 -> tunnel
set -e

echo "[*] Kali Web v5 setup (container)"

TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT="${TELEGRAM_CHAT_ID:-}"
send_telegram() {
  [ -n "$TOKEN" ] && [ -n "$CHAT" ] && \
  curl -s -f -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT}" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
send_telegram "Kali Web v5 starting (full apt install)..."

# --- cloudflared ---
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[*] installing cloudflared"
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cf
  chmod +x /tmp/cf
  mv /tmp/cf /usr/local/bin/cloudflared
fi

# --- kill old vnc/novnc processes (free ports) ---
echo "[*] cleaning old processes"
pkill -f x11vnc 2>/dev/null || true
pkill -f Xvfb 2>/dev/null || true
pkill -f websockify 2>/dev/null || true
pkill -f tightvncserver 2>/dev/null || true
pkill -f Xvnc 2>/dev/null || true
sleep 2

# --- INSTALL missing tools (the image lacks them) ---
export DEBIAN_FRONTEND=noninteractive
echo "[*] apt update"
apt-get update -yq >/dev/null 2>&1 || apt-get update -yq

echo "[*] installing xvfb x11vnc xfce4 (this can take a few minutes)"
apt-get install -yq --no-install-recommends \
  xvfb x11vnc xfce4 xfce4-terminal dbus-x11 \
  >/tmp/apt.log 2>&1 || apt-get install -yq --no-install-recommends \
  xvfb x11vnc xfce4 xfce4-terminal \
  >/tmp/apt.log 2>&1 || { echo "[!] apt install failed"; tail -15 /tmp/apt.log; }

# verify tools exist
for t in Xvfb x11vnc websockify startxfce4; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "[!] $t NOT available"
  else
    echo "[*] $t OK"
  fi
done

# --- our own X server on :1 ---
export DISPLAY=:1
echo "[*] starting Xvfb on :1 (1600x1000x24)"
Xvfb :1 -screen 0 1600x1000x24 -nolisten tcp &>/tmp/xvfb.log &
sleep 4
[ -S /tmp/.X11-unix/X1 ] && echo "  Xvfb OK" || { echo "  !! Xvfb failed"; cat /tmp/xvfb.log | tail -5; }

# --- XFCE desktop on :1 (with dbus) ---
echo "[*] starting XFCE desktop"
if command -v dbus-run-session >/dev/null 2>&1; then
  dbus-run-session -- startxfce4 &>/tmp/xfce.log &
else
  startxfce4 &>/tmp/xfce.log &
fi
sleep 8

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
websockify --web="${NOVNC:-/usr/share/novnc}" 6080 localhost:5901 &>/tmp/ws.log &
sleep 4

# --- VERIFY BOTH PORTS before tunneling ---
echo "[*] service check:"
PORTS=$( (ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null) | grep -E ':(5901|6080)' || true)
echo "$PORTS"
if ! echo "$PORTS" | grep -q ':5901'; then
  echo "[!] VNC port 5901 is NOT listening - aborting tunnel"
  send_telegram "VNC setup FAILED - port 5901 not listening. Check action log."
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