# GH — Kali Linux Web (noVNC + Cloudflare Tunnel)

A **Kali-Linux-style web desktop** that spins up on a GitHub Actions runner and is exposed through a **temporary Cloudflare tunnel** — accessible from any browser, **no password**.

## How to use

1. Open this repo → **Actions** tab
2. Select the **Kali Web (noVNC + Cloudflare Tunnel)** workflow
3. Click **Run workflow** → **Run**
4. The tunnel URL is printed in the workflow logs, and (if configured) sent to your Telegram:
   `https://<random>.trycloudflare.com/vnc.html`
5. Open the URL in any browser — done.

## What's inside

- XFCE4 desktop + Firefox
- noVNC (browser-based VNC client)
- x11vnc (no password)
- Temporary Cloudflare quick tunnel

## Optional Telegram notification

Set these **repo secrets** to get the URL directly in Telegram:

| Secret | Value |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Your bot token from @BotFather |
| `TELEGRAM_CHAT_ID` | Your numeric chat ID |

## ⚠️ Warning

- This is a **temporary environment** on GitHub's free runners. Everything is wiped when the run ends.
- The tunnel URL is public and **unauthenticated** — anyone with the link can use the desktop.
  Do **not** put sensitive data on it, and **stop the run** when you're done.
- For a real persistent Kali setup, run Kali on your own VPS/server instead.
