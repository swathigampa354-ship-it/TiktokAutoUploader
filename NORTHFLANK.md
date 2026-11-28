# Northflank deployment (single service)

This fork deploys as **one** combined service. The existing CLI uploader,
cookie-file login, and SQLite scheduler are unchanged. Redis, RabbitMQ,
Celery, and extra databases are not used.

The image starts the existing noVNC virtual display so the documented login
command (`python3 cli.py login -n <account_name>`) can be completed remotely.

## Build

| Setting | Value |
|---|---|
| Dockerfile path | `Dockerfile` (repository root) |
| Build context | repository root (`.`) |
| Build command (local) | `docker build -t tiktok-autouploader .` |

Northflank: create a **combined** service from this GitHub repo. Leave the
Dockerfile path as `Dockerfile` and the build context as `/` (repo root).

## Networking

| Port | Protocol | Public? | Purpose |
|---|---|---|---|
| `6080` | HTTP | yes (during login) | noVNC web client (`/vnc.html`) |

Northflank detects `EXPOSE 6080`. Make it a public HTTP port.

noVNC URL after deploy:

```
https://<northflank-port-host>/vnc.html?autoconnect=1&resize=scale
```

The VNC session has no password (same as the existing `novnc/entrypoint.sh`).
Keep the port private or pause public access after the first login if you do
not want the desktop exposed.

## Startup command

Use the image default (do not override):

```
/app/docker/northflank-entrypoint.sh
```

Override only if you need a one-off shell. Do not replace this with a new
uploader process.

## Environment variables

None are required. Defaults match `config.txt` when `WORKDIR` is `/app`.

| Variable | Default | Purpose |
|---|---|---|
| `TIKTOK_LOGIN_URL` | `https://www.tiktok.com/login` | CLI / browser login page |
| `TIKTOK_CONFIG_PATH` | `/app/config.txt` | Existing config file |
| `TIKTOK_COOKIES_DIR` | `./CookiesDir` → `/app/CookiesDir` | Session pickles |
| `TIKTOK_VIDEOS_DIR` | `./VideosDirPath` → `/app/VideosDirPath` | Source videos |
| `TIKTOK_OUTPUT_DIR` | `./output` (post-process path override) | Generated files |
| `TIKTOK_API_DB_PATH` | `/app/data/tiktok.db` | Existing scheduler queue (SQLite already in this repo) |
| `SCHEDULER_POLL_SECONDS` | `30` | Existing scheduler poll interval |
| `START_SCHEDULER` | `1` | Set `0` to disable the background scheduler |
| `DISPLAY` | `:99` | Xvfb display used by CLI login |
| `SCREEN_GEOMETRY` | `1920x1080x24` | Virtual desktop size |

Do **not** set TikTok usernames or passwords as environment variables.
Login is interactive and the session is stored under `CookiesDir`.

## Persistent volumes

Mount these paths (one Northflank volume may expose several mount points):

| Mount path | Required | Contents |
|---|---|---|
| `/app/CookiesDir` | **yes** | `tiktok_session-<name>.cookie` — survives restarts |
| `/app/VideosDirPath` | recommended | Source / downloaded videos |
| `/app/output` | recommended | Generated files |
| `/app/data` | recommended | Existing scheduler SQLite file |

Single-volume alternative: mount one volume at `/data` and set:

```
TIKTOK_COOKIES_DIR=/data/CookiesDir
TIKTOK_VIDEOS_DIR=/data/VideosDirPath
TIKTOK_OUTPUT_DIR=/data/output
TIKTOK_API_DB_PATH=/data/tiktok.db
```

`/app/CookiesDir` is the path that must persist for “login once, reuse session”.

## Health check

| Setting | Value |
|---|---|
| Type | HTTP |
| Port | `6080` |
| Path | `/` |
| Expected | `200` |
| Start period | 20–30 seconds |

The image also defines a Docker `HEALTHCHECK` against `http://127.0.0.1:6080/`.

## Shared memory (Chromium)

Set container `/dev/shm` to **512 MB** or more (Northflank service →
Resources / advanced storage → shared memory). The Chrome wrapper also passes
`--disable-dev-shm-usage` so login still works if shm is small.

## Resources (one TikTok account, testing)

Keep this as low as practical. Chromium during login is the heavy part;
uploads after login are HTTP requests.

| Resource | Minimum | Notes |
|---|---|---|
| vCPU | `1` | `0.5` is tight while Chromium is open |
| RAM | `2 GB` | `1 GB` often OOMs on the TikTok login page |
| Instances | `1` | Do not scale out — sessions are files on one volume |
| Ephemeral disk | `4 GB` | Image + Playwright browser + one test video |

## Verify the container (local)

```bash
docker build -t tiktok-autouploader .

docker run --rm -d --name tiktok-nf \
  -p 6080:6080 \
  --shm-size=512m \
  -v tiktok-cookies:/app/CookiesDir \
  -v tiktok-videos:/app/VideosDirPath \
  -v tiktok-output:/app/output \
  -v tiktok-data:/app/data \
  tiktok-autouploader

# Image + CLI entry points
docker exec tiktok-nf python3 cli.py -h
docker exec tiktok-nf python3 cli.py login -h
docker exec tiktok-nf python3 cli.py upload -h
docker exec tiktok-nf python3 cli.py show -h
docker exec tiktok-nf python3 -c "from scheduler.main import main; from tiktok_uploader import tiktok; print('ok')"

# noVNC
curl -fsS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:6080/vnc.html
```

On Northflank, run the same `python3 cli.py ...` commands from the service
shell / exec tab.

## First TikTok login

1. Open noVNC: `https://<host>/vnc.html?autoconnect=1&resize=scale`
2. In the service shell:

```bash
python3 cli.py login -n testaccount
```

3. Complete the TikTok login in the noVNC desktop. The CLI saves
   `/app/CookiesDir/tiktok_session-testaccount.cookie` and exits.
4. Confirm:

```bash
python3 cli.py show -u
```

Restart the service and run `show -u` again — the account must still appear.

## Copy a test video in

```bash
# local → running container
docker cp ./myclip.mp4 tiktok-nf:/app/VideosDirPath/myclip.mp4

# already on Northflank volume
# place the file at /app/VideosDirPath/myclip.mp4
```

## Test upload (immediate)

```bash
python3 cli.py upload --users testaccount -v myclip.mp4 -t "Northflank test upload"
```

(`-u` is an alias for `--users`. The video path is relative to `VideosDirPath`.)

## Scheduled test upload

This uses the repository’s existing scheduler (SQLite + `python -m scheduler.main`),
not a new job system.

```bash
python3 cli.py upload --users testaccount -v myclip.mp4 -t "Scheduled Northflank test" -sc 120
python3 cli.py schedule list
```

`-sc` is seconds from now. The worker polls every `SCHEDULER_POLL_SECONDS`
(default 30) and uploads when due.

## What this image does not do

- It does not store TikTok passwords.
- It does not add authentication, proxies, or bot-detection bypasses.
- It does not rewrite `tiktok_uploader`.
- It does not require Redis, RabbitMQ, Celery, or Kubernetes add-ons.
