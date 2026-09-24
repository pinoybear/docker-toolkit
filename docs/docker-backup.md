# docker-backup.sh

Backs up a Docker Compose host into one compressed, verified tarball per night. Every folder under `BACKUP_SOURCE` (default `/opt`) is included automatically, so new stacks are covered without editing anything. Each running stack is stopped while it's copied, so databases are captured in a consistent state, then restarted and health-checked.

**Runs from:** `docker-backup.timer` → `docker-backup.service` (00:35 nightly by default). Run by hand with `sudo docker-backup.sh`, or preview with `sudo docker-backup.sh --dry-run`.

## What it does, in order

1. **Lock check.** Exits if another backup is already running. A lock left behind by a dead process is removed.
2. **Build the list.** Every folder under `BACKUP_SOURCE`, except hidden folders and names in `BACKUP_SKIP`. Folders that are `STACK_ROOTS` (e.g. `/opt/stacks`) are opened up, so each stack inside is handled on its own.
3. **Kuma maintenance** (only if `KUMA_MAINTENANCE` is set): enters each maintenance window before anything is stopped.
4. **For each folder:**
   - **Not a stack** (no compose file): copied as-is.
   - **Has paused containers** (e.g. left paused by another job): unpaused first and checked for health, then handled like any other running stack.
   - **In `LIVE_BACKUP_STACKS`:** copied while it keeps running.
   - **Running:** `docker compose stop` → copy → `docker compose start` → wait until healthy (see below).
   - **Not running:** copied, and left stopped.
   - Copies use `rsync` with `BACKUP_GLOBAL_EXCLUDES` plus that stack's `STACK_EXCLUDES`. Any `NAMED_VOLUME_BACKUPS` for the stack are copied into its folder as `<volume>_volume/`.
5. **Kuma maintenance ends** as soon as every stack is back up, before compression, since the rest is just file work.
6. **Compress and verify:** `tar` + `gzip -9` into `BACKUP_DEST/<BACKUP_PREFIX>-YYMMDD_HHMMSS.tar.gz`, then a full read-back with `tar -tzf` to catch a corrupt or truncated file.
7. **Size check:** if the new tarball is `BACKUP_GROWTH_WARN_PERCENT` (default 10%) or more bigger than the previous one, it sends a warning.
8. **Prune:** keeps the newest `BACKUP_KEEP` tarballs with that prefix and deletes older ones.
9. **Report:** one alert listing every error from the run, or nothing if all went well.

### "Healthy" means

A stack counts as back up when every container is `running` and, if it defines a Docker `HEALTHCHECK`, reports `healthy`. The script checks every 5 seconds for up to 10 minutes. `docker compose start` itself is retried for up to 5 minutes. While any container is still stopped, the start is re-issued on each check: a service with `depends_on: condition: service_healthy` can otherwise stay stopped if its dependency (say, a database reopening lots of files) takes longer than Compose is willing to wait.

### If the script is killed

If the backup is stopped mid-run (`systemctl stop`, a timeout, a reboot, Ctrl-C), it first finishes the command in progress. It then restarts every stack it had stopped and sends an **INTERRUPTED** alert saying whether each restart worked. The lock file and the half-built staging folder are removed.

## Preview with --dry-run

```bash
sudo docker-backup.sh --dry-run
```

```
FOLDER                       ACTION                   EXTRA EXCLUDES / VOLUMES
dockge                       stop+copy+start
immich                       stop+copy+start
nextcloud                    stop+copy+start          */previews/*  */backups/*
paperless                    stop+copy+start          +volume:paperless_data
uptime-kuma                  copy live
vaultwarden                  unpause+stop+copy+start
telegraf                     copy (no stack)
```

Nothing is stopped, copied or written. Run it with `sudo`; without Docker access it can't tell running from stopped stacks, and says so.

## Configuration

In `/etc/docker-toolkit.conf`:

| Setting | Default | Meaning |
|---|---|---|
| `BACKUP_SOURCE` | `/opt` | Everything under here is backed up |
| `STACK_ROOTS` | `(/opt/stacks)` | Folders whose subfolders are each one stack |
| `BACKUP_DEST` | `/mnt/backup/docker` | Where tarballs go. Ideally another disk or machine. Created if missing. |
| `BACKUP_PREFIX` | `<hostname>-docker_backup` | Tarball name prefix; also used to find old ones to prune |
| `BACKUP_KEEP` | `14` | Tarballs kept |
| `BACKUP_SKIP` | `(containerd docker-runtime)` | Folder names never backed up |
| `LIVE_BACKUP_STACKS` | `()` | Stacks copied without stopping |
| `NAMED_VOLUME_BACKUPS` | `()` | `"stack:volume"` entries |
| `BACKUP_GLOBAL_EXCLUDES` | caches, `*.log*`, `*/tmp/*`, `*.bak`, `*.sock` | Excluded everywhere |
| `STACK_EXCLUDES` | common apps | `"stack\|pattern"` entries |
| `BACKUP_GROWTH_WARN_PERCENT` | `10` | Size-jump warning threshold |
| `BACKUP_LOG` | `/var/log/docker-backup.log` | Run log |
| `KUMA_MAINTENANCE` / `KUMA_HELPER` / `KUMA_CREDENTIALS_FILE` | off | Optional Uptime Kuma integration |

### Which stacks to back up live

Stopping is the safe default: a database copied while it's writing can be unusable on restore. Copy a stack live only when it has **no database or state that changes during the backup**, *or* when stopping it causes more trouble than it prevents:
- **Monitoring** (Uptime Kuma): otherwise it alerts on everything else being stopped.
- **MQTT brokers, reverse proxies:** a brief outage breaks every client connected through them.
- **Webhook receivers:** webhooks that arrive while the receiver is stopped are usually lost, not retried.

### Finding what to exclude

The size warning usually means a new folder brought a cache, thumbnails or AI models with it. To see what's taking space in the latest backup:

```bash
tar -tzvf /mnt/backup/docker/<latest>.tar.gz | sort -k3 -n -r | head -30
```

Add a pattern for the culprit, check it with `--dry-run`, and the next backup will be back to normal:

```bash
STACK_EXCLUDES+=("myapp|*/thumbnails/*")
```

Patterns are rsync `--exclude` patterns matched against paths inside the stack's folder. `*/name/*` skips a folder's contents at any depth but keeps the (empty) folder itself.

### Named volumes

Bind mounts inside the stack's folder (`./data:/data`) are backed up automatically. **Docker named volumes are not**: they live in `/var/lib/docker/volumes/`. List the ones holding real data:

```bash
docker volume ls                        # find the name, usually <stack>_<volume>
NAMED_VOLUME_BACKUPS=("paperless:paperless_data" "paperless:paperless_media")
```

Leave out volumes that only hold things the app can rebuild (downloaded models, caches, app code). They'd just make every backup bigger.

## Example log

```
2026-09-24 00:35:00 - [BACKUP] Starting Docker backup on myserver (31 folders)...
2026-09-24 00:35:00 - [BACKUP] Entered Kuma maintenance window(s).
2026-09-24 00:35:01 - [BACKUP] [dockge] Stopping for backup...
2026-09-24 00:35:02 - [BACKUP] [dockge] Copying files...
2026-09-24 00:35:03 - [BACKUP] [dockge] Restarting and checking health...
2026-09-24 00:35:08 - [BACKUP] [dockge] Restarted and healthy.
2026-09-24 00:35:08 - [BACKUP] [uptime-kuma] Live copy (not stopped).
   ...
2026-09-24 00:41:52 - [BACKUP] Exited Kuma maintenance window(s).
2026-09-24 00:41:52 - [BACKUP] Compressing...
2026-09-24 00:44:10 - [BACKUP] Verifying archive...
2026-09-24 00:44:31 - [BACKUP] Backup completed and verified: /mnt/backup/docker/myserver-docker_backup-260924_003500.tar.gz
```

## Alerts

| Title | Priority | When | What to do |
|---|---|---|---|
| `Docker Backup FAILED (<host>, <stamp>)` | 4 (high) | Anything went wrong: a stop, copy, restart, health check, compression or verification | The alert lists each problem. For a stack that didn't come back healthy, it includes each container's final state and its last 15 log lines. Fix the stack first (`docker compose ps`, `docker compose logs`); the backup itself may still be fine. |
| `Docker Backup INTERRUPTED (<host>, <stamp>)` | 5 (urgent) | The script was killed mid-run | Check the stacks it names are running. No tarball was written for that night. |
| `Docker Backup Size Warning (<host>)` | 3 | The tarball grew by the warning threshold or more | Usually a new folder without excludes; see [Finding what to exclude](#finding-what-to-exclude). Expected after adding a big stack. |
| `Docker Backup KUMA MAINTENANCE STUCK (<host>)` | 5 (urgent) | Leaving a Kuma maintenance window failed | Turn maintenance off in the Kuma UI. Until then Kuma hides real alerts for those monitors. |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Backup completed and verified, or `--dry-run` finished |
| `1` | Not root, another run in progress, or the run had errors (an alert was sent) |
| `2` | Unknown option |
| `129` / `130` / `143` | Stopped by SIGHUP / SIGINT / SIGTERM (cleanup ran, INTERRUPTED alert sent if stacks had been stopped) |

## Restoring

The tarball has one top-level folder per backed-up folder, stored as `./<name>`. Stacks and other `/opt` folders sit side by side:

```bash
tar -tzf myserver-docker_backup-260924_003500.tar.gz | grep -E '^\./[^/]+/$'
./dockge/
./immich/
./telegraf/
```

### One stack

```bash
cd /opt/stacks/immich && sudo docker compose down        # if it's still there and running
sudo mv /opt/stacks/immich /opt/stacks/immich.broken      # keep the old copy until you're sure
sudo tar -xzf /mnt/backup/docker/<backup>.tar.gz -C /opt/stacks ./immich
cd /opt/stacks/immich && sudo docker compose up -d
```

Folders that lived directly under `/opt` rather than `/opt/stacks` go back with `-C /opt` instead.

### A named volume

Named volumes are inside their stack's folder in the backup, as `<volume>_volume/`. Restore them **before** starting the stack:

```bash
sudo docker volume create paperless_data                  # only if it no longer exists
sudo tar -xzf <backup>.tar.gz -C /tmp ./paperless/paperless_data_volume
sudo rsync -a /tmp/paperless/paperless_data_volume/ /var/lib/docker/volumes/paperless_data/_data/
```

### A whole host (rebuilt machine)

1. Install Docker with the Compose plugin, and this toolkit.
2. Extract everything: `sudo tar -xzf <backup>.tar.gz -C /tmp/restore`, then move each folder to `/opt/stacks/<name>` (stacks) or `/opt/<name>` (everything else).
3. Restore named volumes as above.
4. Start each stack with `docker compose up -d`. Images are pulled fresh; they were never in the backup.

What's **not** in a backup, by design: container images, anything under `BACKUP_SKIP` or excluded, named volumes you didn't list, and data stored outside `BACKUP_SOURCE` (such as media on a separate disk). Back those up separately.

## Troubleshooting

- **`status=203/EXEC` when the timer fires:** systemd couldn't start the script. Check it's executable (`chmod 755`). On SELinux systems, also check its label with `stat -c %C /usr/local/bin/docker-backup.sh`: it should be `bin_t`. Note that `restorecon` **won't** give you that here. Default SELinux policy labels anything matching `/usr/local/bin/docker*` as Docker's own runtime (`container_runtime_exec_t`), which would run the backup in Docker's security domain. Set it explicitly with `sudo chcon -t bin_t /usr/local/bin/docker-backup.sh`.
- **A stack is left stopped every night:** it failed to start, and the FAILED alert shows why. Common causes: a `depends_on` service that never becomes healthy, or a healthcheck that's always failing, even before the backup.
- **"Another docker-backup run is already in progress":** a run is still going (large backups over slow network shares can take a while). If you're sure none is, the lock is `/var/lock/docker-backup.lock`; the next run clears it by itself once the PID in it is gone.
