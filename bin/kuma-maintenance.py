#!/usr/bin/env python3
# Title:        kuma-maintenance.py
# Version:      1.0.0
# Date:         2026-09-24
# License:      MIT
# Purpose:      CLI to drive an Uptime Kuma "Manual" strategy maintenance window
#               from automation scripts (e.g. docker-backup.sh), instead of a
#               fixed cron-scheduled window that under- or over-covers a job
#               whose duration varies.
# Requires:     pip install uptime-kuma-api   (a venv is recommended)
# Usage:
#   KUMA_PASSWORD=... kuma-maintenance.py enter --url http://HOST:3001 --user U --id ID
#   KUMA_PASSWORD=... kuma-maintenance.py exit  --url http://HOST:3001 --user U --id ID
#   kuma-maintenance.py set-monitors --url ... --user ... --id ID --monitors 1,2,3
#   kuma-maintenance.py set-manual   --url ... --user ... --id ID
#   (--password is also accepted, but the env var keeps it out of `ps` output.)
# Notes:
#   - Uptime Kuma's API keys ONLY protect the Prometheus /metrics REST route
#     (Kuma 2.x server source). The maintenance management surface is
#     socket.io-only and its 'login' event accepts username+password (+2FA)
#     exclusively, so this authenticates with username/password.
#   - 'enter'/'exit' map to Kuma's resume_maintenance/pause_maintenance calls,
#     which for a Manual-strategy entry are exactly its "under maintenance
#     now" on/off switch (manual entries have no time-window gating).
#   - 'enter'/'exit' re-fetch the maintenance record after the call and retry
#     (full reconnect+login each time) up to RETRIES times if the active flag
#     doesn't match, failing only once all attempts are exhausted. Reconnecting
#     per attempt, because observed flakiness was in the connect/login
#     handshake itself, not the maintenance call.
#   - 'set-monitors' fully REPLACES the maintenance's monitor list (Kuma's
#     addMonitorMaintenance socket event is a set, not an incremental add).
#   - Exits 0 on success, 1 on any failure.
import argparse
import os
import sys
import time

from uptime_kuma_api import UptimeKumaApi, MaintenanceStrategy

RETRIES = 5
RETRY_DELAY = 10


def attempt(args):
    """One full connect+login+action cycle. Returns True on confirmed
    success, False on a mismatched active flag (enter/exit only - other
    actions have no such flag to check), raises on any other error."""
    api = UptimeKumaApi(args.url, wait_events=1.0)
    try:
        api.login(args.user, args.password)

        if args.action == "enter":
            api.resume_maintenance(args.id)
            m = api.get_maintenance(args.id)
            return bool(m.get("active"))
        elif args.action == "exit":
            api.pause_maintenance(args.id)
            m = api.get_maintenance(args.id)
            return not bool(m.get("active"))
        elif args.action == "set-manual":
            api.edit_maintenance(args.id, strategy=MaintenanceStrategy.MANUAL)
            return True
        elif args.action == "set-monitors":
            if not args.monitors:
                print("ERROR: --monitors is required for set-monitors", file=sys.stderr)
                sys.exit(1)
            monitors = [{"id": int(x)} for x in args.monitors.split(",")]
            api.add_monitor_maintenance(args.id, monitors)
            return True
    finally:
        try:
            api.disconnect()
        except Exception:
            pass


def main():
    p = argparse.ArgumentParser(description="Toggle an Uptime Kuma manual maintenance window.")
    p.add_argument("action", choices=["enter", "exit", "set-monitors", "set-manual"])
    p.add_argument("--url", required=True, help="e.g. http://kuma.lan:3001")
    p.add_argument("--user", required=True, help="Uptime Kuma admin username")
    p.add_argument("--password", default=os.environ.get("KUMA_PASSWORD"),
                   help="Uptime Kuma admin password (default: $KUMA_PASSWORD)")
    p.add_argument("--id", type=int, required=True, help="Maintenance ID")
    p.add_argument("--monitors", help="Comma-separated monitor IDs (set-monitors only)")
    args = p.parse_args()
    if not args.password:
        p.error("no password: pass --password or set KUMA_PASSWORD")

    last_error = None
    for i in range(1, RETRIES + 1):
        try:
            if attempt(args):
                print(f"OK: {args.action} id={args.id} on {args.url}")
                return
            last_error = "active flag did not reflect the requested state after the call"
        except Exception as e:
            last_error = str(e) or repr(e)

        print(
            f"WARN: {args.action} id={args.id} on {args.url} failed on attempt "
            f"{i}/{RETRIES} ({last_error}), retrying..." if i < RETRIES else
            f"ERROR: {args.action} id={args.id} on {args.url} failed after "
            f"{RETRIES} attempts ({last_error})",
            file=sys.stderr,
        )
        if i < RETRIES:
            time.sleep(RETRY_DELAY)

    sys.exit(1)


if __name__ == "__main__":
    main()
