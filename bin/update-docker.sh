#!/usr/bin/env bash
# ===============================================================
# Script:   update-docker.sh
# Version:  1.0.0
# Date:     2026-09-24
# Purpose:  Interactive review-then-apply updater for Docker Compose
#           stacks. Scans every stack (running or stopped), pulls its
#           images, shows per-service Running vs New version, date and
#           digest, then asks: update ALL, EXCLUDE some, or CANCEL.
#           Running stacks are recreated with `up -d --wait`; stacks that
#           were stopped are only pulled and left stopped.
# Usage:    update-docker.sh [--check]
#           --check  scan and report only: no prompt, nothing recreated
#                    (images are still pulled). Exit 0 = all up to date,
#                    10 = updates available, 1 = a pull failed.
#           Re-runs itself with sudo when not already root.
# Config:   /etc/docker-toolkit.conf (see config/*.example)
# License:  MIT
#
# Design notes:
# - Update detection compares image IDs with `docker inspect`, never
#   `docker compose up --dry-run`, which in some Compose versions (seen in
#   5.4.0) performs a REAL recreate despite the flag.
# - "Running" is read from the image the existing container uses, not the
#   tag, which may already point at a pulled-but-not-applied image.
# - Short digests are shown next to versions: some images republish the
#   same version label with new content, which would otherwise look
#   identical.
# - A stack that was stopped at scan time is never started: being down
#   may be intentional.
# - Docker's own multi-line pull progress can't be reliably collapsed back
#   to one line, so pull output is hidden and a single status line with a
#   spinner shows progress; on failure the captured output is printed.
# - Enter at the prompt means ALL; Ctrl-C at any prompt cancels without
#   touching anything.
# ===============================================================
set -u

CHECK_ONLY=0
case "${1:-}" in
    --check) CHECK_ONLY=1 ;;
    "") ;;
    -h|--help) awk '/^# Usage:/{p=1} /^# Config:/{p=0} p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    exec sudo --preserve-env=DOCKER_TOOLKIT_CONF "$0" "$@"
fi

CONF="${DOCKER_TOOLKIT_CONF:-/etc/docker-toolkit.conf}"
STACK_ROOTS=(/opt/stacks); EXTRA_STACKS=(/opt/dockge)
UPDATE_WAIT_TIMEOUT=120
# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF"

for cmd in docker jq; do
    if ! command -v "$cmd" > /dev/null; then
        echo "Error: $cmd not found. Install it first (e.g. apt install $cmd)." >&2
        exit 1
    fi
done

trap 'printf "\n\nCancelled. No containers were touched.\n"; exit 130' INT

if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'; CLEAR_LINE=$'\r\033[K'
else
    GREEN=""; RED=""; RESET=""; CLEAR_LINE=""
fi

has_compose_file() {
    local d="$1"
    [ -f "$d/compose.yaml" ] || [ -f "$d/compose.yml" ] \
        || [ -f "$d/docker-compose.yaml" ] || [ -f "$d/docker-compose.yml" ]
}

stack_has_running_container() {
    [ -n "$(docker compose --project-directory "$1" ps --status running -q 2>/dev/null)" ]
}

# "YYYY-MM-DD HH:MM TZ" from an ISO timestamp, or just the date part.
fmt_date() {
    local raw="$1"
    [ -z "$raw" ] && { echo "unknown date"; return; }
    date -d "$raw" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "${raw:0:10}"
}

# Overwrite the current line with "[stack]  text", padded so text lines up.
status_line()      { printf '%s%-*s %s' "$CLEAR_LINE" "$COL_WIDTH" "[$1]" "$2"; }
status_line_done() { printf '%s%-*s %s\n' "$CLEAR_LINE" "$COL_WIDTH" "[$1]" "$2"; }
status_line_color() {
    local pad=$(( COL_WIDTH - ${#1} - 2 )); [ "$pad" -lt 0 ] && pad=0
    printf '%s%s[%s]%s%*s %s\n' "$CLEAR_LINE" "$3" "$1" "$RESET" "$pad" "" "$2"
}

# --- 1. Find stacks (running or stopped) ---
CANDIDATES=()
for d in "${EXTRA_STACKS[@]}"; do CANDIDATES+=("${d%/}"); done
for root in "${STACK_ROOTS[@]}"; do
    [ -d "$root" ] || continue
    for d in "${root%/}"/*/; do CANDIDATES+=("${d%/}"); done
done

STACK_DIRS=(); STOPPED_STACKS=()
for dir in "${CANDIDATES[@]}"; do
    [[ $(basename "$dir") == .* ]] && continue
    has_compose_file "$dir" || continue
    STACK_DIRS+=("$dir")
    stack_has_running_container "$dir" || STOPPED_STACKS+=("$(basename "$dir")")
done

if [ "${#STACK_DIRS[@]}" -eq 0 ]; then
    echo "No Docker Compose stacks found (STACK_ROOTS: ${STACK_ROOTS[*]}; EXTRA_STACKS: ${EXTRA_STACKS[*]:-none})."
    exit 0
fi
if [ "${#STOPPED_STACKS[@]}" -gt 0 ]; then
    echo "Note: ${#STOPPED_STACKS[@]} stack(s) are stopped and will only be pulled, not started, if updated: ${STOPPED_STACKS[*]}"
fi

echo "Checking for image updates across ${#STACK_DIRS[@]} stacks. This may take a moment..."
echo "--------------------------------------------------"

COL_WIDTH=0
for dir in "${STACK_DIRS[@]}"; do
    n=$(basename "$dir"); [ ${#n} -gt "$COL_WIDTH" ] && COL_WIDTH=${#n}
done
COL_WIDTH=$((COL_WIDTH + 2))

UPDATES_AVAILABLE=()   # stack dirs with updates
UPDATE_DETAILS=()      # per stack: service lines joined with \x1f
FAILED_PULL=()
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# --- 2. Check each stack ---
for dir in "${STACK_DIRS[@]}"; do
    stack_name="$(basename "$dir")"
    pushd "$dir" > /dev/null || continue

    mapfile -t svc_image_pairs < <(docker compose config --format json 2>/dev/null \
        | jq -r '.services | to_entries[] | select(.value.image != null) | "\(.key)|\(.value.image)"' 2>/dev/null)

    # Snapshot what each existing container (running or stopped) actually uses.
    declare -A pre_version=() pre_date=() pre_id=()
    for pair in "${svc_image_pairs[@]}"; do
        svc="${pair%%|*}"
        cid="$(docker compose ps -a -q "$svc" 2>/dev/null | head -1)"
        img_id=""; raw=""
        if [ -n "$cid" ]; then
            img_id="$(docker inspect "$cid" --format '{{.Image}}' 2>/dev/null)"
            [ -n "$img_id" ] && raw="$(docker image inspect --format '{{.Created}}||{{index .Config.Labels "org.opencontainers.image.version"}}' "$img_id" 2>/dev/null)"
        fi
        if [ -n "$raw" ]; then
            pre_date[$svc]="${raw%%||*}"; pre_version[$svc]="${raw##*||}"
        else
            pre_date[$svc]=""; pre_version[$svc]="(not previously pulled)"
        fi
        pre_id[$svc]="$img_id"
    done

    # Pull in the background so the spinner can animate.
    pull_log="$(mktemp)"
    docker compose pull --ignore-buildable > "$pull_log" 2>&1 &
    pull_pid=$!
    i=0; start_ts=$(date +%s)
    if [ -t 1 ]; then
        while kill -0 "$pull_pid" 2>/dev/null; do
            status_line "$stack_name" "Pulling images... ${SPIN[i % 10]} ($(( $(date +%s) - start_ts ))s)"
            i=$((i + 1)); sleep 0.15
        done
    fi
    wait "$pull_pid"; pull_status=$?

    if [ "$pull_status" -ne 0 ]; then
        status_line_done "$stack_name" "Pull failed (exit $pull_status)"
        sed 's/^/      /' "$pull_log"
        FAILED_PULL+=("$stack_name")
        rm -f "$pull_log"; popd > /dev/null; continue
    fi
    rm -f "$pull_log"

    [ -t 1 ] && status_line "$stack_name" "Checking for changes..."
    lines=()
    for pair in "${svc_image_pairs[@]}"; do
        svc="${pair%%|*}"; image="${pair#*|}"
        new_id="$(docker inspect --format '{{.Id}}' "$image" 2>/dev/null)"
        old_id="${pre_id[$svc]:-}"
        [ -n "$new_id" ] && [ "$old_id" != "$new_id" ] || continue
        raw="$(docker inspect --format '{{.Created}}||{{index .Config.Labels "org.opencontainers.image.version"}}' "$image" 2>/dev/null)"
        new_version="${raw##*||}"; [ -z "$new_version" ] && new_version="(unversioned)"
        old_version="${pre_version[$svc]:-}"; [ -z "$old_version" ] && old_version="(unversioned)"
        lines+=("$svc|$image|$old_version|$(fmt_date "${pre_date[$svc]:-}")|$new_version|$(fmt_date "${raw%%||*}")|$old_id|$new_id")
    done

    if [ "${#lines[@]}" -gt 0 ]; then
        status_line_color "$stack_name" "Update available" "$GREEN"
        UPDATES_AVAILABLE+=("$dir")
        UPDATE_DETAILS+=("$(IFS=$'\x1f'; echo "${lines[*]}")")
    else
        status_line_done "$stack_name" "No update needed"
    fi
    unset pre_version pre_date pre_id
    popd > /dev/null
done

# --- 3. Summary ---
if [ "${#FAILED_PULL[@]}" -gt 0 ]; then
    echo "--------------------------------------------------"
    echo "Warning: these stacks were skipped because their image pull failed:"
    printf '  - %s\n' "${FAILED_PULL[@]}"
fi

if [ "${#UPDATES_AVAILABLE[@]}" -eq 0 ]; then
    echo "--------------------------------------------------"
    if [ "${#FAILED_PULL[@]}" -gt 0 ]; then
        echo "No updates among the stacks checked, but some were skipped (see above)."
        exit 1
    fi
    echo "All containers are up to date."
    exit 0
fi

echo "--------------------------------------------------"
echo "Updates are available for these stacks:"
echo
for idx in "${!UPDATES_AVAILABLE[@]}"; do
    dir="${UPDATES_AVAILABLE[$idx]}"
    printf '%2d. %s\n    Path: %s\n    Services:\n' "$((idx + 1))" "$(basename "$dir")" "$dir"
    IFS=$'\x1f' read -r -a svc_lines <<< "${UPDATE_DETAILS[$idx]}"
    for line in "${svc_lines[@]}"; do
        IFS='|' read -r svc image ov od nv nd oid nid <<< "$line"
        od_short="${oid#sha256:}"; od_short="${od_short:0:12}"; [ -z "$od_short" ] && od_short="none"
        nd_short="${nid#sha256:}"; nd_short="${nd_short:0:12}"
        printf '      %-20s  %s\n' "$svc" "$image"
        printf '        Running: %-20s (%s) [%s]\n' "$ov" "$od" "$od_short"
        printf '        New:     %-20s (%s) [%s]\n' "$nv" "$nd" "$nd_short"
    done
    echo
done
echo "--------------------------------------------------"

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "--check: nothing was recreated. Run without --check to apply."
    exit 10
fi

# --- 4. Choose ---
read -r -p "Update ALL (a), EXCLUDE specific stacks (e), or CANCEL (c)? [A/e/c]: " choice || { echo; echo "Cancelled. No containers were touched."; exit 130; }
TO_UPDATE=()
case "$choice" in
    ""|a|A) TO_UPDATE=("${UPDATES_AVAILABLE[@]}") ;;
    e|E)
        read -r -p "Numbers of the stacks to EXCLUDE (space-separated, e.g. 1 3): " exclusions || { echo; echo "Cancelled. No containers were touched."; exit 130; }
        read -r -a ex_list <<< "$exclusions"
        for ex in "${ex_list[@]}"; do
            if ! [[ $ex =~ ^[0-9]+$ ]]; then echo "Warning: '$ex' is not a number, ignoring."
            elif [ "$ex" -lt 1 ] || [ "$ex" -gt "${#UPDATES_AVAILABLE[@]}" ]; then echo "Warning: $ex is out of range (1-${#UPDATES_AVAILABLE[@]}), ignoring."
            fi
        done
        for idx in "${!UPDATES_AVAILABLE[@]}"; do
            if [[ " ${ex_list[*]} " == *" $((idx + 1)) "* ]]; then
                echo "Skipping: $(basename "${UPDATES_AVAILABLE[$idx]}")"
            else
                TO_UPDATE+=("${UPDATES_AVAILABLE[$idx]}")
            fi
        done
        ;;
    *) echo "Cancelled. No containers were touched."; exit 0 ;;
esac

if [ "${#TO_UPDATE[@]}" -eq 0 ]; then
    echo "No stacks were selected for updating."
    exit 0
fi

# --- 5. Apply ---
trap - INT
SUCCEEDED=(); FAILED=()
echo
echo "Applying updates to selected stacks..."
for dir in "${TO_UPDATE[@]}"; do
    stack_name="$(basename "$dir")"
    echo "--------------------------------------------------"
    if [[ " ${STOPPED_STACKS[*]} " == *" $stack_name "* ]]; then
        echo "  ↷ [$stack_name] Was stopped -- image pulled, left stopped (not started)."
        SUCCEEDED+=("$stack_name"); continue
    fi
    echo "→ [$stack_name] Updating..."
    # --wait blocks until containers are healthy (or running, if they have no
    # healthcheck) and fails if that doesn't happen within the timeout.
    pushd "$dir" > /dev/null || { FAILED+=("$stack_name"); continue; }
    docker compose up -d --remove-orphans --wait --wait-timeout "$UPDATE_WAIT_TIMEOUT"
    up_status=$?
    popd > /dev/null
    if [ "$up_status" -eq 0 ]; then
        echo "  ${GREEN}✓${RESET} [$stack_name] Updated and healthy."
        SUCCEEDED+=("$stack_name")
    else
        echo "  ${RED}✗${RESET} [$stack_name] Update failed or not healthy within ${UPDATE_WAIT_TIMEOUT}s."
        FAILED+=("$stack_name")
    fi
done

echo
echo "Cleaning up dangling images..."
docker image prune -f | grep "Total reclaimed space"

echo "--------------------------------------------------"
if [ "${#FAILED[@]}" -eq 0 ]; then
    echo "Update completed successfully (${#SUCCEEDED[@]} stack(s))."
    exit 0
fi
echo "Update completed with failures:"
echo "  Succeeded (${#SUCCEEDED[@]}): ${SUCCEEDED[*]:-none}"
echo "  Failed (${#FAILED[@]}): ${FAILED[*]}"
exit 1
