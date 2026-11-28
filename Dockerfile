# Single-service image for Northflank (and local `docker run`).
#
# Combines the existing CLI uploader, the existing SQLite scheduler, and the
# existing noVNC virtual-display stack so one container can:
#   - keep a TikTok login session on a volume
#   - expose Chromium over noVNC for the first interactive login
#   - run `python3 cli.py upload` / scheduled uploads without extra services
#
# Does not replace tiktok_uploader, does not add Redis/RabbitMQ/Celery, and
# does not store TikTok passwords.
FROM python:3.11-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NODE_MAJOR=20 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/playwright \
    PYTHONPATH=/app \
    DISPLAY=:99 \
    SCREEN_GEOMETRY=1920x1080x24 \
    TIKTOK_LOGIN_URL=https://www.tiktok.com/login \
    TIKTOK_CONFIG_PATH=/app/config.txt \
    TIKTOK_API_DB_PATH=/app/data/tiktok.db \
    SCHEDULER_POLL_SECONDS=30 \
    SCHEDULER_CONCURRENCY=1 \
    START_SCHEDULER=1

# System packages: Node 20, ffmpeg (moviepy/yt-dlp), Playwright/Chromium libs,
# system Chromium (CLI login via undetected-chromedriver), and the existing
# noVNC stack (Xvfb + x11vnc + websockify).
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg git \
        build-essential ffmpeg \
        libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 \
        libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 \
        libcairo2 libasound2 \
        fonts-liberation fonts-noto-cjk \
        xvfb x11vnc fluxbox \
        novnc websockify \
        chromium chromium-driver \
        net-tools \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# undetected-chromedriver / cli.py login look for google-chrome. Wrap Debian
# Chromium with the container-safe flags required when running as root and
# with a small /dev/shm (Northflank default). No uploader code change needed.
RUN printf '%s\n' \
        '#!/bin/sh' \
        'exec /usr/bin/chromium --no-sandbox --disable-dev-shm-usage --disable-gpu "$@"' \
        > /usr/local/bin/google-chrome \
    && chmod +x /usr/local/bin/google-chrome \
    && ln -sf /usr/local/bin/google-chrome /usr/local/bin/google-chrome-stable \
    && ln -sf /usr/local/bin/google-chrome /usr/bin/google-chrome \
    && ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install -r /app/requirements.txt

COPY tiktok_uploader /app/tiktok_uploader
COPY config.txt /app/config.txt
COPY cli.py /app/cli.py
COPY setup.py /app/setup.py
COPY api /app/api
COPY scheduler /app/scheduler
COPY novnc /app/novnc
COPY docker/northflank-entrypoint.sh /app/docker/northflank-entrypoint.sh
COPY .env.example /app/.env.example

WORKDIR /app/tiktok_uploader/tiktok-signature
# Skip playwright-chromium's npm postinstall download; install the browser
# in the next command so a failed CDN fetch fails the image build clearly.
RUN PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --omit=dev \
    && npx --yes playwright install chromium --with-deps

WORKDIR /app

# Persistent paths used by config.txt (./CookiesDir, ./VideosDirPath, ./output)
# when WORKDIR is /app. Also /app/data for the existing scheduler SQLite file.
RUN mkdir -p /app/CookiesDir /app/VideosDirPath /app/output /app/data \
    && chmod +x /app/docker/northflank-entrypoint.sh \
    && if [ ! -f /app/.env ]; then cp /app/.env.example /app/.env; fi

EXPOSE 6080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:6080/', timeout=4)"

ENTRYPOINT ["/app/docker/northflank-entrypoint.sh"]
