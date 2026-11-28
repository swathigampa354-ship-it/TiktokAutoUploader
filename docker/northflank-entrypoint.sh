#!/usr/bin/env bash
# Single-process-tree boot for the Northflank / Docker image.
#
# Reuses the existing novnc/ stack (Xvfb + fluxbox + x11vnc + websockify) so
# `python3 cli.py login -n <account>` can be completed from a remote browser.
# Optionally starts the existing scheduler (`python -m scheduler.main`) so
# `cli.py upload -sc` keeps working without Redis/RabbitMQ/Celery.
set -euo pipefail

cd /app

# Allow `docker run IMAGE python3 cli.py ...` for verification without
# replacing the default long-running noVNC process.
if [ "$#" -gt 0 ] && [ "$1" != "novnc" ]; then
    exec "$@"
fi

mkdir -p \
    "${TIKTOK_COOKIES_DIR:-/app/CookiesDir}" \
    "${TIKTOK_VIDEOS_DIR:-/app/VideosDirPath}" \
    "${TIKTOK_OUTPUT_DIR:-/app/output}" \
    "$(dirname "${TIKTOK_API_DB_PATH:-/app/data/tiktok.db}")"

# Stale X11 locks from a previous crash would block Xvfb.
rm -f /tmp/.X*-lock /tmp/.X11-unix/X${DISPLAY#:}

echo "[entrypoint] starting Xvfb ${DISPLAY} (${SCREEN_GEOMETRY})"
Xvfb "${DISPLAY}" -screen 0 "${SCREEN_GEOMETRY}" -nolisten tcp &
sleep 1

# Window manager so Chromium is usable inside noVNC.
fluxbox >/dev/null 2>&1 &

# -nopw: this image is for a single test account; do not put TikTok passwords
# in the environment. Restrict the Northflank port if the URL is public.
x11vnc -display "${DISPLAY}" -forever -shared -nopw -rfbport 5900 -quiet >/dev/null 2>&1 &

if [ "${START_SCHEDULER:-1}" = "1" ]; then
    echo "[entrypoint] starting existing scheduler (python -m scheduler.main)"
    python -m scheduler.main &
fi

echo "[entrypoint] noVNC listening on 0.0.0.0:6080"
echo "[entrypoint] open /vnc.html?autoconnect=1&resize=scale then run:"
echo "             python3 cli.py login -n <account_name>"

# Foreground process (PID 1 after exec). Health checks hit this port.
exec websockify --web=/usr/share/novnc 6080 localhost:5900
