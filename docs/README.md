# Documentation

One page per script: what it does step by step, its options, what the output means, and what to do when it alerts.

| Page | Runs | Summary |
|---|---|---|
| [docker-backup](docker-backup.md) | nightly (`docker-backup.timer`) | Backs up every stack and folder under `/opt` into one verified tarball. Includes **how to restore**. |
| [check-docker-updates](check-docker-updates.md) | weekly (`check-docker-updates.timer`) | Reports which running stacks have image updates. Never changes anything. |
| [update-docker](update-docker.md) | by hand | Shows Running vs New for every stack with an update, then applies the ones you choose. |

`bin/kuma-maintenance.py` is shared with [snapraid-mergerfs-toolkit](https://github.com/pinoybear/snapraid-mergerfs-toolkit); its page is [there](https://github.com/pinoybear/snapraid-mergerfs-toolkit/blob/main/docs/kuma-maintenance.md).

## Shared behavior

- **Config:** all three scripts read `/etc/docker-toolkit.conf` (bash syntax). Point them at another file with `DOCKER_TOOLKIT_CONF=/path`. Every option is documented in [`config/docker-toolkit.conf.example`](../config/docker-toolkit.conf.example).
- **Which folders are stacks:** every subfolder of each `STACK_ROOTS` entry (default `/opt/stacks`), plus each `EXTRA_STACKS` folder (default `/opt/dockge`), that contains `compose.yaml`, `compose.yml`, `docker-compose.yaml` or `docker-compose.yml`. Folders starting with `.` are ignored.
- **Notifications:** ntfy (`NTFY_URL`, optional `NTFY_TOKEN`) and/or email via msmtp (`EMAIL_TO`, `MSMTP_ACCOUNT`). An empty setting turns that channel off. The scripts run as root, so email uses **root's** msmtp config. Setup for both: [homelab-notifications](https://github.com/pinoybear/homelab-notifications).
- **Root:** all three need root. `docker-backup.sh` and `check-docker-updates.sh` refuse to run without it; `update-docker.sh` re-runs itself with `sudo`.
