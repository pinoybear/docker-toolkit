# update-docker.sh

The hands-on updater. It checks every stack for newer images, shows you exactly what would change, and applies only what you approve.

**Runs:** by hand, whenever you want to update (for example after [check-docker-updates](check-docker-updates.md) reports something). It re-runs itself with `sudo` if you're not root.

```bash
update-docker.sh            # scan, review, then choose
update-docker.sh --check    # scan and report only
```

## What it does

1. **Finds every stack**, running **or** stopped, in `STACK_ROOTS` and `EXTRA_STACKS`. Stopped stacks are listed up front: they'll get new images but won't be started.
2. **For each stack:**
   - Records the image each existing container is **actually using**. This comes from the container, not the tag, because the tag may already point at a newer image that was pulled but never applied.
   - Pulls the stack's images (`docker compose pull --ignore-buildable`; services built locally are skipped). Docker's own progress output is hidden, and a single status line with a spinner shows it's working. If the pull fails, its output is printed and the stack is skipped.
   - Compares image IDs. Any service whose freshly pulled image differs from what its container runs has an update.
3. **Shows the updates**, per stack and per service, then asks what to do.
4. **Applies your choice:**
   - **Running stack:** `docker compose up -d --remove-orphans --wait --wait-timeout <UPDATE_WAIT_TIMEOUT>`. This recreates the changed containers and waits until they're healthy (or running, if they have no healthcheck).
   - **Stopped stack:** nothing more. The new image is already pulled, and the stack stays stopped. It may be down on purpose.
5. **Cleans up** with `docker image prune -f`. This removes **dangling** images (old layers no tag points to any more) across the whole host, not just the updated stacks.

## Reading the output

```
Checking for image updates across 24 stacks. This may take a moment...
--------------------------------------------------
[dockge]      No update needed
[immich]      Update available
[jellyfin]    No update needed
[paperless]   Pull failed (exit 1)
      Error response from daemon: manifest unknown
--------------------------------------------------
Updates are available for these stacks:

 1. immich
    Path: /opt/stacks/immich
    Services:
      immich-server         ghcr.io/immich-app/immich-server:release
        Running: v1.140.0             (2026-09-10 14:02 MDT) [3f2a9c1b7d44]
        New:     v1.141.1             (2026-09-22 09:15 MDT) [5c1e7a90b2f3]
```

- **Running / New:** the version comes from the image's `org.opencontainers.image.version` label. It shows `(unversioned)` when the image doesn't set one, which is common for official images like `redis` or `mariadb`.
- **Date:** when the image was built.
- **`[3f2a9c1b7d44]`:** the first 12 characters of the image ID. **Always compare these.** Some images get rebuilt under the same version label (for security fixes, for example), so Running and New can show the same version while the digests differ. That's still a real update. `none` means the service has no existing container yet.
- **Pull failed:** often a typo in the image name, a tag that no longer exists, a registry login problem, or a rate limit. Other stacks are still checked.

## Choosing

```
Update ALL (a), EXCLUDE specific stacks (e), or CANCEL (c)? [A/e/c]:
```

| Answer | Effect |
|---|---|
| **Enter** or `a` | Update every listed stack |
| `e` | Then type the numbers to **skip**, e.g. `2 5`; everything else is updated |
| `c` (or anything else) | Cancel; nothing is recreated |
| **Ctrl-C** at any prompt | Cancel; nothing is recreated |

Declined updates stay pulled. Next time you run it they'll be listed again, because the containers still run the old images.

## --check

Scans and prints the same report, then stops without asking. Nothing is recreated. Useful in scripts:

```bash
update-docker.sh --check > /dev/null; echo $?     # 10 = updates waiting
```

Like the interactive mode (and like [check-docker-updates](check-docker-updates.md)), `--check` **does pull** the new images. Pulling downloads images and moves local tags, but running containers don't change until an update is applied.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Everything up to date, all selected updates applied, or cancelled with `c` |
| `1` | A pull failed and there were no updates, or at least one update failed or wasn't healthy in time |
| `2` | Unknown option |
| `10` | `--check` only: updates are available |
| `130` | Cancelled with Ctrl-C |

## Configuration

| Setting | Default | Meaning |
|---|---|---|
| `STACK_ROOTS` | `(/opt/stacks)` | Folders whose subfolders are each one stack |
| `EXTRA_STACKS` | `(/opt/dockge)` | Individual stack folders |
| `UPDATE_WAIT_TIMEOUT` | `120` | Seconds to wait for a recreated stack to become healthy |

A stack that isn't healthy within `UPDATE_WAIT_TIMEOUT` is reported as failed, but it isn't rolled back. Check it with `docker compose ps` and `docker compose logs` in its folder. Slow-starting apps (large databases, Nextcloud) may need a longer timeout.
