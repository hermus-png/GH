#!/bin/bash
# Kali Web v3 — PROPER fix: the image's own VNC needs a password and uses port 5900.
# We install x11vnc, attach it to the container's X display with NO password on :5901,
# websockify serves noVNC page AND proxies to :5901, then tunnel to 6080.
set -e

echo "[*] Kali Web v3 setup (container)"

TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT="${TELEGRAM_CHAT_ID:-}"
send_telegram() {
  [ -n "$TOKEN" ] && [ -n "$CHAT" ] && \
  curl -s -f -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT}" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
send_telegram "Kali Web v3 starting (x11vnc fix)..."

# --- cloudflared ---
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[*] installing cloudflared"
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cf
  chmod +x /tmp/cf
  mv /tmp/cf /usr/local/bin/cloudflared
fi

# --- install x11vnc (the image lacks it!) ---
if ! command -v x11vnc >/dev/null 2>&1; then
  echo "[*] installing x11vnc"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -yq >/dev/null 2>&1 || true
  apt-get install -yq x11vnc >/dev/null 2>&1 || \
  apt-get install -yq --no-install-recommends x11vnc >/dev/null 2>&1 || true
fi
command -v x11vnc >/dev/null 2>&1 || true
if ! command -v x11vnc >/dev/null 2>&1; then
  echo "[!] x11vnc STILL not installed"; ls -la /usr/bin/x11* | grep -i vnc 2>/dev/null || true
fi

# --- find the live X display of the container's desktop ---
DISPLAY_C=""
for d in :0 :1 :99 :2; do
  if [ -S "/tmp/.X11-unix/X${d#:}" ] || [ -S "/tmp/.X11-unix/X${d/:}" ]; then
    DISPLAY_C=$d; echo "[*] found X display $d"; break
  fi
done
[ -z "$DISPLAY_C" ] && { DISPLAY_C=:0; echo "[*] defaulting X display $DISPLAY_C"; }

# --- kill the image's password-protected VNC on 5900 ---
echo "[*] stopping image's own VNC (password one)"
pkill -f tightvncserver 2>/dev/null || true
pkill -f Xvnc 2>/dev/null || true
pkill -f websockify 2>/dev/null || true
pkill -f novnc_proxy 2>/dev/null || true
sleep 2

# --- our own x11vnc, NO password, port 5901 ---
echo "[*] starting x11vnc on $DISPLAY_C :5901 (no password)"
x11vnc -display "$DISPLAY_C" -forever -shared -nopw -rfbport 5901 -bg -o /tmp/x11vnc.log 2>&1 || \
x11vnc -display "$DISPLAY_C" -forever -shared -nopw -rfbport 5901 -o /tmp/x11vnc.log &
sleep 4
echo "[*] x11vnc log:"; tail -5 /tmp/x11vnc.log 2>/dev/null || true

# --- locate noVNC web files ---
NOVNC=""
for d in /usr/share/novnc /opt/noVNC /usr/share/noVNC; do
  [ -d "$d" ] && [ -f "$d/vnc.html" ] && NOVNC=$d && break
done
[ -z "$NOVNC" ] && NOVNC="$(find / -maxdepth 6 -name vnc.html -not -path '*/proc/*' 2>/dev/null | head -1 | xargs -r dirname)"
echo "[*] noVNC web dir: ${NOVNC:-/usr/share/novnc}"

# --- websockify: serve noVNC page AND proxy websocket to :5901 ---
echo "[*] starting websockify on :6080 -> localhost:5901"
websockify --web="${NOVNC:-/usr/share/novnc}" 6080 localhost:5901 &>/tmp/ws.log &
[ $? -ne 0 ] && python3 -m websockify --web="${NOVNC:-/usr/share/novnc}" 6080 localhost:5901 &>/tmp/ws.log &
sleep 4

# --- verify both ports ---
echo "[*] service check:"
(ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null) | grep -E ':(5901|6080)' || echo "!! missing ports"
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