#!/usr/bin/env bash
# ===============================================================
# Script:   docker-backup.sh
# Version:  1.0.0
# Date:     2026-09-24
# Purpose:  Nightly backup of a Docker Compose host into one verified
#           .tar.gz. Every folder under BACKUP_SOURCE (default /opt) is
#           included automatically; each Compose stack inside STACK_ROOTS
#           is stopped, copied and restarted on its own so its databases
#           are captured in a consistent state. Alerts via ntfy and/or
#           email on any failure.
# Usage:    docker-backup.sh [--dry-run]
#           --dry-run  print what would be stopped, copied live, skipped
#                      and excluded, then exit without touching anything.
# Config:   /etc/docker-toolkit.conf (see config/*.example)
# License:  MIT
#
# Design notes (each one learned from a real failure):
# - New folders are picked up with no script edit: BACKUP_SOURCE is scanned
#   every run. The size-growth warning is the safety net for that -- a new
#   folder without the right excludes shows up as a sudden jump instead of
#   silently bloating every tarball forever.
# - Only stacks that were running get stopped and restarted; a stack that
#   was down stays down.
# - Containers left PAUSED by some other job (e.g. a SnapRAID sync that
#   failed to unpause) are found and unpaused first. `compose ps --status
#   running` never sees paused containers, so without this they'd be copied
#   frozen and left paused forever. `docker unpause <ids>` is used rather
#   than `docker compose unpause`, which fails if any sibling isn't paused.
# - `docker compose start` honours `depends_on: condition: service_healthy`
#   and gives up if a slow dependency (e.g. a database reopening many
#   shards) isn't healthy in time, leaving the dependent service stopped. So
#   start is retried, and the health poll keeps re-issuing it (it's a no-op
#   for running containers) until every container is running and healthy.
# - Health checks are HEALTHCHECK-aware: a container with a healthcheck must
#   report "healthy", not just "running".
# - A lock file stops overlapping runs. If the script dies mid-run (crash,
#   kill, timeout), the EXIT trap restarts any stack it had stopped and sends
#   an urgent alert, instead of leaving services down with no one told.
# - Every error is collected and sent as ONE consolidated alert at the end.
# ===============================================================
set -u

CONF="${DOCKER_TOOLKIT_CONF:-/etc/docker-toolkit.conf}"
DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    "") ;;
    -h|--help) awk '/^# Usage:/{p=1} /^# Config:/{p=0} p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

# --- Defaults (overridden by $CONF) ---
STACK_ROOTS=(/opt/stacks)
NTFY_URL=""; NTFY_TOKEN=""; EMAIL_TO=""; MSMTP_ACCOUNT="default"
HOST_LABEL="$(hostname)"
BACKUP_SOURCE="/opt"
BACKUP_DEST="/mnt/backup/docker"
BACKUP_PREFIX="$(hostname)-docker_backup"
BACKUP_KEEP=14
BACKUP_LOG="/var/log/docker-backup.log"
BACKUP_SKIP=(containerd docker-runtime)
LIVE_BACKUP_STACKS=()
NAMED_VOLUME_BACKUPS=()
BACKUP_GLOBAL_EXCLUDES=('*/cache/*' '*/Cache/*' '*/.cache/*' '*.log*' '*/tmp/*' '*.bak' '*.sock')
STACK_EXCLUDES=()
BACKUP_GROWTH_WARN_PERCENT=10
KUMA_MAINTENANCE=()
KUMA_HELPER="/usr/local/bin/kuma-maintenance.py"
KUMA_CREDENTIALS_FILE="/root/.config/kuma.env"
LOCK_FILE="/var/lock/docker-backup.lock"

# Health polling: 120 x 5s = 10 minutes per stack; start retries: 60 x 5s.
HEALTH_MAX_RETRIES=120
HEALTH_RETRY_DELAY=5
START_RETRIES=60
START_RETRY_DELAY=5

# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF"

# Normalise paths so "/opt/stacks/" and "/opt/stacks" both match.
BACKUP_SOURCE="${BACKUP_SOURCE%/}"
for i in "${!STACK_ROOTS[@]}"; do STACK_ROOTS[$i]="${STACK_ROOTS[$i]%/}"; done

if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root." >&2
    exit 1
fi

DATE_STAMP="$(date '+%y%m%d_%H%M%S')"
BACKUP_FILENAME="${BACKUP_PREFIX}-${DATE_STAMP}.tar.gz"
# Staging lives inside BACKUP_SOURCE (same, usually large, filesystem) as a
# hidden folder, which the scan below always skips.
TEMP_DIR="${BACKUP_SOURCE}/.docker-backup-staging-${DATE_STAMP}"

FAILED_ERRORS=()
STOPPED_STACKS=()
kuma_maintenance_active=0

# --- Helpers ---
contains_element() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
    return 1
}

has_compose_file() {
    local d="$1"
    [ -f "$d/compose.yaml" ] || [ -f "$d/compose.yml" ] \
        || [ -f "$d/docker-compose.yaml" ] || [ -f "$d/docker-compose.yml" ]
}

log_message() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "$*"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [BACKUP] $*" | tee -a "$BACKUP_LOG"
    fi
}

# notify "Title" "Body (\n escapes allowed)" priority tags
notify() {
    local subject="$1" body priority="$3" tags="$4"
    body="$(printf '%b' "$2")"
    if [ -n "$EMAIL_TO" ]; then
        printf 'Subject: %s\n\n%s\n' "$subject" "$body" | msmtp -a "$MSMTP_ACCOUNT" "$EMAIL_TO" \
            || log_message "WARNING: msmtp failed to send '$subject'."
    fi
    if [ -n "$NTFY_URL" ]; then
        local auth=()
        [ -n "$NTFY_TOKEN" ] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
        curl -s -o /dev/null -H "Title: $subject" -H "Priority: $priority" \
            -H "Tags: $tags" "${auth[@]}" -d "$body" "$NTFY_URL" \
            || log_message "WARNING: ntfy publish failed for '$subject'."
    fi
}

# Enter/exit every configured Kuma maintenance window. Failing to ENTER is
# only logged (worst case: a false-positive Kuma alert). Failing to EXIT is
# alerted on, because a stuck window silently suppresses real alerts.
kuma_maintenance() {
    local action="$1" ok=1 entry url id
    [ "${#KUMA_MAINTENANCE[@]}" -gt 0 ] || return 0
    if [ ! -f "$KUMA_CREDENTIALS_FILE" ] || [ ! -x "$KUMA_HELPER" ]; then
        log_message "WARNING: Kuma helper or credentials missing; skipping maintenance $action."
        return 0
    fi
    # shellcheck disable=SC1090
    source "$KUMA_CREDENTIALS_FILE"
    for entry in "${KUMA_MAINTENANCE[@]}"; do
        IFS='|' read -r url id <<< "$entry"
        KUMA_PASSWORD="$KUMA_PASSWORD" "$KUMA_HELPER" "$action" --url "$url" --user "$KUMA_USER" --id "$id" >>"$BACKUP_LOG" 2>&1 || ok=0
    done
    [ "$ok" -eq 1 ]
}

kuma_maintenance_enter() {
    [ "${#KUMA_MAINTENANCE[@]}" -gt 0 ] || return 0
    # Mark active even on partial failure so cleanup exits whichever
    # instance(s) DID enter, rather than leaving one stuck on.
    kuma_maintenance_active=1
    if kuma_maintenance enter; then
        log_message "Entered Kuma maintenance window(s)."
    else
        log_message "WARNING: Failed to enter one or more Kuma maintenance windows; Kuma may alert during the stop/restart cycle."
    fi
}

kuma_maintenance_exit() {
    if kuma_maintenance exit; then
        log_message "Exited Kuma maintenance window(s)."
        return 0
    fi
    notify "Docker Backup KUMA MAINTENANCE STUCK ($HOST_LABEL)" \
        "Failed to exit one or more Uptime Kuma maintenance windows after the docker-backup run on $HOST_LABEL. Clear maintenance mode manually in the Kuma UI -- until then, real alerts for the affected monitors are suppressed." \
        "5" "rotating_light"
    return 1
}

# Polls the current (pushd'd-into) compose project until every container is
# running and, if it has a HEALTHCHECK, healthy. Re-issues the idempotent
# `docker compose start` whenever something is still stopped, so a service
# blocked on a slow dependency is started the moment that dependency clears.
# Prints 1 on success, 0 on timeout.
wait_for_healthy_stack() {
    local attempt=1 success=0
    while [ "$attempt" -le "$HEALTH_MAX_RETRIES" ]; do
        local ids
        ids="$(docker compose ps -a -q 2>/dev/null)"
        if [ -n "$ids" ]; then
            local all_good=1 any_not_running=0 status health
            while IFS='|' read -r status health; do
                [ "$status" != "running" ] && any_not_running=1
                if [ "$status" != "running" ] || [ "$health" = "unhealthy" ] || [ "$health" = "starting" ]; then
                    all_good=0
                fi
            done < <(docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $ids 2>/dev/null)
            if [ "$all_good" -eq 1 ]; then
                success=1
                break
            fi
            [ "$any_not_running" -eq 1 ] && docker compose start >/dev/null 2>&1
        fi
        sleep "$HEALTH_RETRY_DELAY"
        attempt=$((attempt + 1))
    done
    echo "$success"
}

# One line per container (final status + health), for failure alerts.
stack_state_summary() {
    local id
    for id in $(docker compose ps -a -q 2>/dev/null); do
        docker inspect --format '  - {{.Name}}: status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null
    done
}

# rsync --exclude args for one stack: global excludes + its STACK_EXCLUDES.
build_excludes() {
    local name="$1" p entry
    EXCLUDE_ARGS=()
    for p in "${BACKUP_GLOBAL_EXCLUDES[@]}"; do EXCLUDE_ARGS+=(--exclude="$p"); done
    for entry in "${STACK_EXCLUDES[@]}"; do
        [ "${entry%%|*}" = "$name" ] && EXCLUDE_ARGS+=(--exclude="${entry#*|}")
    done
}

# --- Build the list of folders to back up ---
# Every folder under BACKUP_SOURCE, except hidden ones and BACKUP_SKIP.
# Folders that are STACK_ROOTS are replaced by their children, so each
# stack inside gets its own stop/copy/restart.
ITEMS=()
for entry in "$BACKUP_SOURCE"/*; do
    [ -d "$entry" ] || continue
    name="$(basename "$entry")"
    [[ $name == .* ]] && continue
    contains_element "$name" "${BACKUP_SKIP[@]}" && continue
    if contains_element "$entry" "${STACK_ROOTS[@]}"; then
        for sub in "$entry"/*; do
            [ -d "$sub" ] || continue
            sname="$(basename "$sub")"
            [[ $sname == .* ]] && continue
            contains_element "$sname" "${BACKUP_SKIP[@]}" && continue
            ITEMS+=("$sub")
        done
    else
        ITEMS+=("$entry")
    fi
done

# --- Dry run: describe the plan and exit ---
if [ "$DRY_RUN" -eq 1 ]; then
    echo "docker-backup.sh --dry-run (config: $CONF)"
    if ! docker info > /dev/null 2>&1; then
        echo "NOTE: can't reach Docker as $(id -un); running/stopped status below is unknown. Re-run with sudo for an accurate plan."
    fi
    echo "Source: $BACKUP_SOURCE   Destination: $BACKUP_DEST/$BACKUP_FILENAME   Keep: $BACKUP_KEEP"
    echo
    printf '%-28s %-24s %s\n' "FOLDER" "ACTION" "EXTRA EXCLUDES / VOLUMES"
    for item in "${ITEMS[@]}"; do
        name="$(basename "$item")"
        if ! has_compose_file "$item"; then
            action="copy (no stack)"
        elif contains_element "$name" "${LIVE_BACKUP_STACKS[@]}"; then
            action="copy live"
        elif [ -n "$(docker compose --project-directory "$item" ps --status paused -q 2>/dev/null)" ]; then
            action="unpause+stop+copy+start"
        elif [ -n "$(docker compose --project-directory "$item" ps --status running -q 2>/dev/null)" ]; then
            action="stop+copy+start"
        else
            action="copy (stopped)"
        fi
        extras=""
        for e in "${STACK_EXCLUDES[@]}"; do [ "${e%%|*}" = "$name" ] && extras+="${e#*|}  "; done
        for nv in "${NAMED_VOLUME_BACKUPS[@]}"; do [ "${nv%%:*}" = "$name" ] && extras+="+volume:${nv#*:}  "; done
        printf '%-28s %-24s %s\n' "$name" "$action" "$extras"
    done
    echo
    echo "Skipped entirely: ${BACKUP_SKIP[*]:-(none)}"
    echo "Global excludes:  ${BACKUP_GLOBAL_EXCLUDES[*]}"
    echo "Kuma maintenance: ${#KUMA_MAINTENANCE[@]} window(s)"
    echo "Notifications:    ntfy=${NTFY_URL:-off}  email=${EMAIL_TO:-off}"
    exit 0
fi

# --- Lock file (before the trap, so "already running" doesn't remove the other run's lock) ---
if [ -e "$LOCK_FILE" ]; then
    existing_pid="$(cat "$LOCK_FILE" 2>/dev/null)"
    if [ -n "$existing_pid" ] && [ -d "/proc/$existing_pid" ]; then
        log_message "Another docker-backup run is already in progress (PID $existing_pid). Exiting."
        exit 1
    fi
    log_message "Stale lock file found (no process at that PID); removing."
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"

# --- Cleanup trap ---
cleanup() {
    rm -f "$LOCK_FILE"

    # Only non-empty if we're exiting mid-cycle (crash/kill) with a stack
    # still stopped: try to bring it back and tell someone.
    if [ "${#STOPPED_STACKS[@]}" -gt 0 ]; then
        log_message "WARNING: Exiting with ${#STOPPED_STACKS[@]} stack(s) still stopped; attempting emergency restart..."
        local notes=() s sname
        for s in "${STOPPED_STACKS[@]}"; do
            sname="$(basename "$s")"
            pushd "$s" > /dev/null || continue
            if docker compose start; then
                log_message "[$sname] Emergency restart succeeded."
                notes+=("[$sname] Left stopped by an interrupted run; emergency 'docker compose start' succeeded -- verify it's healthy.")
            else
                log_message "ERROR: [$sname] Emergency restart FAILED."
                notes+=("[$sname] Left stopped by an interrupted run; emergency 'docker compose start' ALSO FAILED -- needs manual attention.")
            fi
            popd > /dev/null
        done
        notify "Docker Backup INTERRUPTED ($HOST_LABEL, $DATE_STAMP)" \
            "docker-backup.sh exited abnormally mid-run with stacks stopped. Emergency recovery on exit:\n\n$(printf '%s\n\n' "${notes[@]}")" \
            "5" "rotating_light"
    fi

    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR" || log_message "WARNING: could not remove staging folder $TEMP_DIR"
    fi

    if [ "$kuma_maintenance_active" -eq 1 ]; then
        kuma_maintenance_exit
    fi
}
trap cleanup EXIT
# Turn signals into a normal exit, so bash finishes the command in progress
# (e.g. a `docker compose stop`) and then runs cleanup in a consistent state.
trap 'log_message "Received SIGTERM; cleaning up..."; exit 143' TERM
trap 'log_message "Received SIGINT; cleaning up..."; exit 130' INT
trap 'log_message "Received SIGHUP; cleaning up..."; exit 129' HUP

# --- Preparation ---
mkdir -p "$BACKUP_DEST" "$TEMP_DIR"
log_message "Starting Docker backup on $HOST_LABEL (${#ITEMS[@]} folders)..."

# Previous tarball size, for the growth check at the end.
PREV_BACKUP="$(find "$BACKUP_DEST" -maxdepth 1 -name "${BACKUP_PREFIX}-*.tar.gz" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
PREV_SIZE=0
[ -n "$PREV_BACKUP" ] && [ -f "$PREV_BACKUP" ] && PREV_SIZE="$(stat -c %s "$PREV_BACKUP")"

# Before the first stack is stopped (the monitoring stack itself may be one).
kuma_maintenance_enter

# --- Back up each folder ---
for stack_path in "${ITEMS[@]}"; do
    stack_name="$(basename "$stack_path")"
    pushd "$stack_path" > /dev/null || continue
    WAS_RUNNING=0

    if ! has_compose_file "$stack_path"; then
        log_message "[$stack_name] No compose file; plain copy."
    else
        # Recover containers left paused by something else.
        paused="$(docker compose ps --status paused -q 2>/dev/null)"
        if [ -n "$paused" ]; then
            log_message "[$stack_name] Found $(wc -w <<< "$paused") paused container(s); unpausing..."
            if docker unpause $paused > /dev/null; then
                if [ "$(wait_for_healthy_stack)" -eq 1 ]; then
                    log_message "[$stack_name] Unpaused container(s) are healthy."
                else
                    log_message "ERROR: [$stack_name] Unpaused container(s) failed to become healthy."
                    FAILED_ERRORS+=("[$stack_name] Unpaused container(s) failed to become healthy.\nContainer states:\n$(stack_state_summary)\n\nLogs:\n$(docker compose logs --tail=15 2>/dev/null)")
                fi
            else
                log_message "ERROR: [$stack_name] 'docker unpause' failed."
                FAILED_ERRORS+=("[$stack_name] Found paused container(s) but 'docker unpause' failed.")
            fi
        fi

        if contains_element "$stack_name" "${LIVE_BACKUP_STACKS[@]}"; then
            log_message "[$stack_name] Live copy (not stopped)."
        elif [ -n "$(docker compose ps --status running -q 2>/dev/null)" ]; then
            WAS_RUNNING=1
            # Recorded BEFORE stopping: if the script is killed while the stop
            # is in progress, the exit trap must still know to restart it.
            STOPPED_STACKS+=("$stack_path")
            log_message "[$stack_name] Stopping for backup..."
            if ! docker compose stop; then
                log_message "ERROR: [$stack_name] 'docker compose stop' failed; copying anyway (may be inconsistent)."
                FAILED_ERRORS+=("[$stack_name] 'docker compose stop' failed -- its backed-up data may be inconsistent.")
            fi
        else
            log_message "[$stack_name] Not running; copying without stop."
        fi
    fi

    log_message "[$stack_name] Copying files..."
    build_excludes "$stack_name"
    if ! rsync -a "${EXCLUDE_ARGS[@]}" "$stack_path" "$TEMP_DIR/"; then
        log_message "ERROR: [$stack_name] rsync failed."
        FAILED_ERRORS+=("[$stack_name] rsync file copy failed.")
    fi

    for nv in "${NAMED_VOLUME_BACKUPS[@]}"; do
        nv_stack="${nv%%:*}"; nv_volume="${nv#*:}"
        [ "$nv_stack" = "$stack_name" ] || continue
        if [ -d "/var/lib/docker/volumes/${nv_volume}/_data" ]; then
            log_message "[$stack_name] Copying named volume $nv_volume..."
            mkdir -p "$TEMP_DIR/$stack_name/${nv_volume}_volume"
            if ! rsync -a "/var/lib/docker/volumes/${nv_volume}/_data/" "$TEMP_DIR/$stack_name/${nv_volume}_volume/"; then
                FAILED_ERRORS+=("[$stack_name] rsync of named volume $nv_volume failed.")
            fi
        else
            log_message "WARNING: [$stack_name] Named volume $nv_volume not found; skipped."
            FAILED_ERRORS+=("[$stack_name] Named volume $nv_volume listed in NAMED_VOLUME_BACKUPS was not found.")
        fi
    done

    if [ "$WAS_RUNNING" -eq 1 ]; then
        log_message "[$stack_name] Restarting and checking health..."
        start_ok=0
        for ((attempt = 1; attempt <= START_RETRIES; attempt++)); do
            if docker compose start; then start_ok=1; break; fi
            log_message "WARNING: [$stack_name] 'docker compose start' failed (attempt $attempt/$START_RETRIES), likely a slow dependency; retrying in ${START_RETRY_DELAY}s..."
            sleep "$START_RETRY_DELAY"
        done
        [ "$start_ok" -eq 0 ] && log_message "ERROR: [$stack_name] 'docker compose start' failed after $START_RETRIES attempts."

        if [ "$(wait_for_healthy_stack)" -eq 1 ]; then
            log_message "[$stack_name] Restarted and healthy."
        else
            log_message "ERROR: [$stack_name] Not healthy after restart."
            FAILED_ERRORS+=("[$stack_name] Not healthy after restart.\nContainer states:\n$(stack_state_summary)\n\nLogs:\n$(docker compose logs --tail=15 2>/dev/null)")
        fi

        # Restart attempted either way: no longer the trap's job.
        remaining=()
        for s in "${STOPPED_STACKS[@]}"; do [ "$s" != "$stack_path" ] && remaining+=("$s"); done
        STOPPED_STACKS=("${remaining[@]}")
    fi
    popd > /dev/null
done

# All stacks are back; compression is plain file I/O, so end maintenance now.
# If this fails, cleanup() tries again at exit.
if [ "$kuma_maintenance_active" -eq 1 ]; then
    kuma_maintenance_exit && kuma_maintenance_active=0
fi

# --- Archive + verify ---
log_message "Compressing..."
if ! tar --use-compress-program="gzip -9" -cf "$BACKUP_DEST/$BACKUP_FILENAME" -C "$TEMP_DIR" .; then
    log_message "ERROR: Compression failed."
    FAILED_ERRORS+=("[Overall] Compression (tar/gzip) failed.")
fi

log_message "Verifying archive..."
if ! tar -tzf "$BACKUP_DEST/$BACKUP_FILENAME" > /dev/null 2>&1; then
    log_message "ERROR: Archive verification failed (corrupt or truncated)."
    FAILED_ERRORS+=("[Overall] Archive verification failed (corrupt or truncated tarball).")
fi
rm -rf "$TEMP_DIR"

# --- Size-growth warning ---
if [ -f "$BACKUP_DEST/$BACKUP_FILENAME" ] && [ "$PREV_SIZE" -gt 0 ]; then
    NEW_SIZE="$(stat -c %s "$BACKUP_DEST/$BACKUP_FILENAME")"
    GROWTH_PCT=$(( (NEW_SIZE - PREV_SIZE) * 100 / PREV_SIZE ))
    if [ "$GROWTH_PCT" -ge "$BACKUP_GROWTH_WARN_PERCENT" ]; then
        PREV_MB=$(( PREV_SIZE / 1024 / 1024 )); NEW_MB=$(( NEW_SIZE / 1024 / 1024 ))
        log_message "WARNING: Backup grew ${GROWTH_PCT}% (${PREV_MB}MB -> ${NEW_MB}MB)."
        notify "Docker Backup Size Warning ($HOST_LABEL)" \
            "The new backup is ${GROWTH_PCT}% larger than the previous one (${PREV_MB} MB -> ${NEW_MB} MB).\n\nThis usually means a new folder under ${BACKUP_SOURCE} without the right excludes (a cache, model or log directory). Run 'docker-backup.sh --dry-run' to see what's included." \
            "3" "warning,chart_with_upwards_trend"
    fi
fi

# --- Prune old backups ---
mapfile -t all_backups < <(find "$BACKUP_DEST" -maxdepth 1 -name "${BACKUP_PREFIX}-*.tar.gz" -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
if [ "${#all_backups[@]}" -gt "$BACKUP_KEEP" ]; then
    for ((i = BACKUP_KEEP; i < ${#all_backups[@]}; i++)); do rm -f "${all_backups[$i]}"; done
fi

# --- Result ---
if [ "${#FAILED_ERRORS[@]}" -gt 0 ]; then
    log_message "Finished with ${#FAILED_ERRORS[@]} error(s); sending alert."
    notify "Docker Backup FAILED ($HOST_LABEL, $DATE_STAMP)" \
        "The Docker backup on $HOST_LABEL finished with errors:\n\n$(printf '%s\n\n' "${FAILED_ERRORS[@]}")" \
        "4" "warning"
    exit 1
fi
log_message "Backup completed and verified: $BACKUP_DEST/$BACKUP_FILENAME"
exit 0
