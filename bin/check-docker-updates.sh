#!/usr/bin/env bash
# ===============================================================
# Script:   check-docker-updates.sh
# Version:  1.0.0
# Date:     2026-09-24
# Purpose:  Non-interactive, CHECK-ONLY scan for Docker image updates
#           across every running Compose stack. Pulls each stack's images,
#           compares the image each container is actually running with the
#           freshly pulled one, and sends a report only when updates are
#           available or a pull failed. Never restarts or recreates
#           anything; apply updates with update-docker.sh.
# Config:   /etc/docker-toolkit.conf (see config/*.example)
# License:  MIT
#
# Design notes:
# - Detection compares image IDs (`docker inspect`), never
#   `docker compose up --dry-run`: in some Compose versions (seen in 5.4.0)
#   --dry-run is NOT dry and performs a real container recreate when it
#   decides one is needed.
# - The "before" version comes from the image the RUNNING CONTAINER uses,
#   not from the tag: a previous pull may already have moved the tag to a
#   newer image that isn't applied yet.
# - `--ignore-buildable` skips services built locally (`build:` with no
#   registry image), which would otherwise be reported as pull failures.
# - Pulling refreshes local tags, but running containers are untouched
#   until you apply the update.
# ===============================================================
set -u

CONF="${DOCKER_TOOLKIT_CONF:-/etc/docker-toolkit.conf}"

STACK_ROOTS=(/opt/stacks); EXTRA_STACKS=(/opt/dockge)
NTFY_URL=""; NTFY_TOKEN=""; EMAIL_TO=""; MSMTP_ACCOUNT="default"
HOST_LABEL="$(hostname)"
UPDATE_CHECK_LOG="/var/log/check-docker-updates.log"

# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$UPDATE_CHECK_LOG"
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root." >&2
    exit 1
fi
for cmd in docker jq; do
    if ! command -v "$cmd" > /dev/null; then
        log "ERROR: $cmd not found, aborting."
        echo "Error: $cmd not found." >&2
        exit 1
    fi
done

has_compose_file() {
    local d="$1"
    [ -f "$d/compose.yaml" ] || [ -f "$d/compose.yml" ] \
        || [ -f "$d/docker-compose.yaml" ] || [ -f "$d/docker-compose.yml" ]
}

# Checks one stack. Prints pipe-delimited result lines for the caller:
#   FAIL_PULL|stack|exit_code
#   UPDATE|stack|dir
#   SERVICE|name|old_version|old_date|new_version|new_date
check_stack() {
    local dir="$1"
    local stack_name svc_image_pairs pull_status
    local svc_name svc_image raw old_version old_date new_version new_date
    local container_id running_image_id old_image_id new_image_id
    local stack_has_update=0 service_output=""
    declare -A pre_version pre_date pre_image_id

    stack_name="$(basename "$dir")"
    cd "$dir" || return 0

    svc_image_pairs="$(docker compose config --format json 2>/dev/null \
        | jq -r '.services | to_entries[] | select(.value.image != null) | "\(.key)|\(.value.image)"')"

    while IFS='|' read -r svc_name svc_image; do
        [ -z "$svc_name" ] && continue
        raw=""; running_image_id=""
        container_id="$(docker compose ps -q "$svc_name" 2>/dev/null)"
        if [ -n "$container_id" ]; then
            running_image_id="$(docker inspect "$container_id" --format '{{.Image}}' 2>/dev/null)"
            [ -n "$running_image_id" ] && raw="$(docker image inspect --format '{{.Created}}||{{index .Config.Labels "org.opencontainers.image.version"}}' "$running_image_id" 2>/dev/null)"
        fi
        pre_date["$svc_name"]="${raw%%||*}"
        pre_version["$svc_name"]="${raw##*||}"
        pre_image_id["$svc_name"]="$running_image_id"
    done <<< "$svc_image_pairs"

    docker compose pull --ignore-buildable > /dev/null 2>&1
    pull_status=$?
    if [ "$pull_status" -ne 0 ]; then
        echo "FAIL_PULL|$stack_name|$pull_status"
        return 0
    fi

    while IFS='|' read -r svc_name svc_image; do
        [ -z "$svc_name" ] && continue
        new_image_id="$(docker inspect --format '{{.Id}}' "$svc_image" 2>/dev/null)"
        old_image_id="${pre_image_id[$svc_name]:-}"
        if [ -n "$new_image_id" ] && [ "$old_image_id" != "$new_image_id" ]; then
            stack_has_update=1
            raw="$(docker inspect --format '{{.Created}}||{{index .Config.Labels "org.opencontainers.image.version"}}' "$svc_image" 2>/dev/null)"
            new_date="${raw%%||*}"; new_version="${raw##*||}"
            old_version="${pre_version[$svc_name]:-}"; old_date="${pre_date[$svc_name]:-}"
            [ -z "$old_version" ] && old_version="(unversioned)"
            [ -z "$new_version" ] && new_version="(unversioned)"
            service_output+="SERVICE|$svc_name|$old_version|${old_date:0:10}|$new_version|${new_date:0:10}"$'\n'
        fi
    done <<< "$svc_image_pairs"

    if [ "$stack_has_update" -eq 1 ]; then
        echo "UPDATE|$stack_name|$dir"
        printf '%s' "$service_output"
    fi
}

# --- 1. Find running stacks ---
CANDIDATES=()
for d in "${EXTRA_STACKS[@]}"; do CANDIDATES+=("${d%/}"); done
for root in "${STACK_ROOTS[@]}"; do
    [ -d "$root" ] || continue
    for d in "${root%/}"/*/; do CANDIDATES+=("${d%/}"); done
done

STACK_DIRS=()
for dir in "${CANDIDATES[@]}"; do
    [[ $(basename "$dir") == .* ]] && continue
    has_compose_file "$dir" || continue
    [ -n "$(docker compose --project-directory "$dir" ps --status running -q 2>/dev/null)" ] && STACK_DIRS+=("$dir")
done

if [ "${#STACK_DIRS[@]}" -eq 0 ]; then
    log "No running stacks found, nothing to check."
    exit 0
fi
log "Checking ${#STACK_DIRS[@]} running stack(s) for updates."

# --- 2. Check each stack ---
UPDATES_BODY=""; FAILURES_BODY=""; UPDATE_COUNT=0; FAILURE_COUNT=0; UPDATED_NAMES=()
for dir in "${STACK_DIRS[@]}"; do
    while IFS='|' read -r kind a b c d e; do
        case "$kind" in
            FAIL_PULL) FAILURES_BODY+=$'\n'"  - $a: pull failed (exit $b)"; FAILURE_COUNT=$((FAILURE_COUNT + 1)) ;;
            UPDATE)    UPDATES_BODY+=$'\n'"$a ($b):"; UPDATE_COUNT=$((UPDATE_COUNT + 1)); UPDATED_NAMES+=("$a") ;;
            SERVICE)   UPDATES_BODY+=$'\n'"    $a: $b ($c) -> $d ($e)" ;;
        esac
    done < <(check_stack "$dir")
done
log "Done. $UPDATE_COUNT stack(s) with updates, $FAILURE_COUNT failure(s)."

# --- 3. Report only if there's something to say ---
if [ "$UPDATE_COUNT" -eq 0 ] && [ "$FAILURE_COUNT" -eq 0 ]; then
    log "No updates available, nothing to report."
    exit 0
fi

subject="Docker Updates: $HOST_LABEL"
body="Docker update check on $HOST_LABEL at $(date '+%Y-%m-%d %H:%M %Z')."
[ "$UPDATE_COUNT" -gt 0 ] && body+=$'\n\n'"Updates available ($UPDATE_COUNT stack(s)):$UPDATES_BODY"
[ "$FAILURE_COUNT" -gt 0 ] && body+=$'\n\n'"Failed checks ($FAILURE_COUNT stack(s)):$FAILURES_BODY"
body+=$'\n\n'"Nothing has been changed. Review and apply with: sudo update-docker.sh"

if [ -n "$EMAIL_TO" ]; then
    log "Sending email to $EMAIL_TO"
    printf 'Subject: %s\n\n%s\n' "$subject" "$body" | msmtp -a "$MSMTP_ACCOUNT" "$EMAIL_TO" \
        || log "WARNING: msmtp failed to send the update report."
fi

if [ -n "$NTFY_URL" ]; then
    # Short version for the lock screen; the full list is in the email/log.
    short="$UPDATE_COUNT stack(s) with updates"
    [ "$UPDATE_COUNT" -gt 0 ] && short+=": ${UPDATED_NAMES[*]}"
    [ "$FAILURE_COUNT" -gt 0 ] && short+=$'\n'"$FAILURE_COUNT stack(s) failed to check"
    priority=3; [ "$FAILURE_COUNT" -gt 0 ] && priority=4
    auth=()
    [ -n "$NTFY_TOKEN" ] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
    curl -s -o /dev/null -H "Title: $subject" -H "Priority: $priority" -H "Tags: package" \
        "${auth[@]}" -d "$short" "$NTFY_URL" || log "WARNING: ntfy publish failed."
fi

printf '%s\n' "$body" >> "$UPDATE_CHECK_LOG"
exit 0
