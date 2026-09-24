# docker-toolkit

Bash scripts and systemd units for looking after a Docker Compose host (the kind of box running Dockge, Portainer stacks, or plain `compose.yaml` folders under `/opt/stacks`):

- **Back it up every night**, with databases stopped cleanly and everything brought back up and health-checked afterwards.
- **Find out weekly** which stacks have image updates, without anything being changed.
- **Review and apply updates by hand**, seeing exactly which version and image each container is moving from and to.

Every script here exists because something simpler failed in practice. The design notes in each script's header explain the specific failure it guards against.

## What's included

| Script | Runs | What it does |
|---|---|---|
| [`bin/docker-backup.sh`](docs/docker-backup.md) | nightly (timer) | Backs up everything under `/opt` into one verified `.tar.gz`. Each running stack is stopped, copied and restarted on its own; stacks you list are copied live instead. It then waits until every container is running and, if it has a healthcheck, healthy. It also recovers containers left paused by another job, and restarts anything it stopped if it's killed mid-run. It skips bulky rebuildable data (caches, thumbnails, models, logs) and prunes old backups. It warns when a backup suddenly grows, and sends one alert listing everything that went wrong. `--dry-run` shows the plan without touching anything. |
| [`bin/check-docker-updates.sh`](docs/check-docker-updates.md) | weekly (timer) | **Check-only.** Pulls every running stack's images and compares what each container actually runs with what's now available. It sends a report only when something has an update or a pull failed. It never restarts or recreates anything. |
| [`bin/update-docker.sh`](docs/update-docker.md) | by hand | Interactive updater. Scans every stack, running or stopped, and shows each service's **Running vs New** version, build date and image digest. Then choose: update **all**, **exclude** some, or **cancel**. Running stacks are recreated and waited on until healthy; stopped stacks only get the new image and stay stopped. `--check` scans and reports without prompting. |
| `bin/kuma-maintenance.py` | optional | Puts [Uptime Kuma](https://github.com/louislam/uptime-kuma) monitors into maintenance while stacks are stopped for the backup, so you don't get false alerts. |

Notifications go to [ntfy](https://ntfy.sh) and/or email via `msmtp`, using the same four settings as my other repos. Setup for both is covered in [homelab-notifications](https://github.com/pinoybear/homelab-notifications).

Each script has its own page with the full details, including **how to restore** a backup: see [**docs/**](docs/README.md).

## Two things other scripts get wrong

- **`docker compose up --dry-run` is not always dry.** In some Compose versions (seen in 5.4.0), when it decides a container needs recreating, it actually recreates it. A "check for updates" script built on it will quietly apply updates. These scripts never use it: they pull, then compare image IDs with `docker inspect`, which can't change anything.
- **The image tag lies about what's running.** Once a newer image has been pulled, the tag points at it, even though the container still runs the old one. So "current version" has to be read from the container's own image, not from the tag. Otherwise a pending update looks like no update at all.

## Requirements

- Docker with the Compose plugin (`docker compose`), `bash` ≥ 4.4, `jq`, `rsync`, `curl`, GNU `tar`/`gzip`/`find`
- systemd, for the timers
- Optional: `msmtp` (email), `python3` + the `uptime-kuma-api` package (Kuma helper)

## Quick start

**1. Install**

```bash
git clone https://github.com/pinoybear/docker-toolkit.git
cd docker-toolkit
sudo install -m 755 bin/* /usr/local/bin/
sudo install -m 644 systemd/* /etc/systemd/system/
sudo install -m 600 config/docker-toolkit.conf.example /etc/docker-toolkit.conf
```

**2. Configure.** In `/etc/docker-toolkit.conf`, at minimum:

```bash
BACKUP_DEST="/mnt/backup/docker"                 # where tarballs go (ideally another disk or machine)
NTFY_URL="https://ntfy.sh/your-private-topic"    # and/or EMAIL_TO="you@example.com"
LIVE_BACKUP_STACKS=(uptime-kuma)                 # stacks to copy without stopping (optional)
```

The defaults assume Dockge's layout: one folder per stack under `/opt/stacks`, plus `/opt/dockge`. If yours differs, change `STACK_ROOTS` and `EXTRA_STACKS`.

**3. See what the backup would do**, before it stops anything:

```bash
sudo docker-backup.sh --dry-run
```

```
FOLDER                       ACTION                   EXTRA EXCLUDES / VOLUMES
dockge                       stop+copy+start
immich                       stop+copy+start
jellyfin                     stop+copy+start          */config/data/metadata/*  */config/cache/*  ...
nextcloud                    stop+copy+start          */previews/*  */backups/*
uptime-kuma                  copy live
telegraf                     copy (no stack)
```

Check that nothing large is included that shouldn't be. Add per-stack excludes with `STACK_EXCLUDES+=("mystack|*/thumbnails/*")`.

**4. Run one backup by hand, then turn on the timers**

```bash
sudo systemctl daemon-reload
sudo systemctl start --no-block docker-backup.service && sudo tail -f /var/log/docker-backup.log
sudo systemctl enable --now docker-backup.timer check-docker-updates.timer
```

**5. Updating stacks**

```bash
update-docker.sh            # re-runs itself with sudo; review, then choose All / Exclude / Cancel
update-docker.sh --check    # report only
```

```
[immich]      Update available
[jellyfin]    No update needed
...
 1. immich
    Path: /opt/stacks/immich
    Services:
      immich-server         ghcr.io/immich-app/immich-server:release
        Running: v1.140.0             (2026-09-10 14:02 MDT) [3f2a9c1b7d44]
        New:     v1.141.1             (2026-09-22 09:15 MDT) [5c1e7a90b2f3]

Update ALL (a), EXCLUDE specific stacks (e), or CANCEL (c)? [A/e/c]:
```

## Configuration reference

Everything lives in `/etc/docker-toolkit.conf`, a bash file shared by all three scripts. Point a script at a different file with `DOCKER_TOOLKIT_CONF=/path`. See [`config/docker-toolkit.conf.example`](config/docker-toolkit.conf.example) for every option with comments. The main ones:

| Setting | Default | Meaning |
|---|---|---|
| `STACK_ROOTS` | `(/opt/stacks)` | Folders whose subfolders are each one Compose project |
| `EXTRA_STACKS` | `(/opt/dockge)` | Individual project folders outside those roots |
| `BACKUP_SOURCE` | `/opt` | Everything under here is backed up |
| `BACKUP_DEST` / `BACKUP_KEEP` | `/mnt/backup/docker` / `14` | Where tarballs go, and how many to keep |
| `LIVE_BACKUP_STACKS` | `()` | Stacks copied while running (monitoring, MQTT, reverse proxy, webhook receivers) |
| `NAMED_VOLUME_BACKUPS` | `()` | `"stack:volume"`: named volumes to include (bind mounts are covered automatically) |
| `STACK_EXCLUDES` | common apps | `"stack\|pattern"`: per-stack rsync excludes |
| `BACKUP_SKIP` | `(containerd docker-runtime)` | Folder names never backed up |
| `KUMA_MAINTENANCE` | `()` | `"kuma_url\|maintenance_id"`: optional Kuma maintenance windows |
| `NTFY_URL` `NTFY_TOKEN` `EMAIL_TO` `MSMTP_ACCOUNT` | empty | Notifications; see [homelab-notifications](https://github.com/pinoybear/homelab-notifications) |

## Good to know

- **Pulling is not applying.** Both update scripts pull images, which downloads them and moves the local tags, but no running container changes until you apply with `update-docker.sh`.
- **A stopped stack stays stopped.** The backup won't start it, and `update-docker.sh` only refreshes its image.
- **Restore** is plain `tar`. The archive holds one folder per stack (and per other `/opt` folder), stored as `./<name>`. For a stack: `sudo tar -xzf <backup>.tar.gz -C /opt/stacks ./<stack>`, then `docker compose up -d` in that folder. Folders that lived directly under `/opt` go back with `-C /opt`. Named volumes are saved inside their stack's folder as `<volume>_volume/`; copy them back into `/var/lib/docker/volumes/<volume>/_data/` before starting the stack.
- **The backup runs as root** (it has to read every stack's files), so email alerts use root's msmtp config.

## License

MIT
