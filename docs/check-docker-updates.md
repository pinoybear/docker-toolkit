# check-docker-updates.sh

A weekly "what's new" report. It checks every running stack for image updates and tells you, **without changing anything**. Apply updates with [update-docker](update-docker.md) when it suits you.

**Runs from:** `check-docker-updates.timer` → `check-docker-updates.service` (Thursdays 16:00 by default, and on the next boot if a run was missed). Run by hand with `sudo check-docker-updates.sh`.

## What it does

1. **Finds running stacks** in `STACK_ROOTS` and `EXTRA_STACKS`. Stacks with no running container are skipped; `update-docker.sh` covers those.
2. **For each stack:** records the image each container is actually running, pulls the stack's images (`--ignore-buildable`, so locally built services are skipped), and compares image IDs.
3. **Reports only when there's something to say**: at least one update, or at least one failed pull. A week with nothing new produces no notification, just a line in the log.

It detects updates by comparing image IDs, never with `docker compose up --dry-run`, which in some Compose versions really does recreate containers. Pulling downloads the new images and moves local tags, but running containers don't change.

## The report

**Email** (subject `Docker Updates: <host>`): the full list.

```
Docker update check on myserver at 2026-09-24 16:00 MDT.

Updates available (2 stack(s)):
immich (/opt/stacks/immich):
    immich-server: v1.140.0 (2026-09-10) -> v1.141.1 (2026-09-22)
nextcloud (/opt/stacks/nextcloud):
    nextcloud-db: 10.11.19 (2026-09-08) -> 10.11.19 (2026-09-08)

Failed checks (1 stack(s)):
  - paperless: pull failed (exit 1)

Nothing has been changed. Review and apply with: sudo update-docker.sh
```

A line with the **same version and date on both sides**, like `nextcloud-db` above, is still a real update: the image was rebuilt under the same label. `update-docker.sh` shows the image digests that tell them apart.

**ntfy:** a short version for the lock screen, e.g. `2 stack(s) with updates: immich nextcloud` plus `1 stack(s) failed to check`. Priority 3, or 4 if any check failed.

The full report is also appended to `UPDATE_CHECK_LOG`.

## Configuration

| Setting | Default | Meaning |
|---|---|---|
| `STACK_ROOTS` / `EXTRA_STACKS` | `(/opt/stacks)` / `(/opt/dockge)` | Where stacks are |
| `UPDATE_CHECK_LOG` | `/var/log/check-docker-updates.log` | Run log and reports |
| `NTFY_URL` `NTFY_TOKEN` `EMAIL_TO` `MSMTP_ACCOUNT` | empty | Notifications; see [homelab-notifications](https://github.com/pinoybear/homelab-notifications) |

To change the schedule, edit `OnCalendar=` in `check-docker-updates.timer` (e.g. `Mon *-*-* 09:00:00`), then run `sudo systemctl daemon-reload`.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Check completed, whether or not updates were found |
| `1` | Not root, or `docker`/`jq` missing |

A failed pull for one stack doesn't fail the run. It's included in the report instead.

## Troubleshooting

- **No report ever arrives:** that's normal in a quiet week. Check the log's last lines to confirm it ran: `sudo tail /var/log/check-docker-updates.log`. If the log is empty or old, check the service: `systemctl status check-docker-updates.service`.
- **`status=203/EXEC` in the service status:** systemd couldn't run the script at all. Check it's executable (`chmod 755`). On SELinux systems (Fedora, RHEL), a script copied in through `/tmp` can keep a temp-file label that blocks it: fix with `sudo restorecon -v /usr/local/bin/check-docker-updates.sh`, or `sudo chcon -t bin_t` on the file.
