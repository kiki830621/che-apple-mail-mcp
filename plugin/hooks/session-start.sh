#!/bin/bash
# che-apple-mail-mcp SessionStart hook — detect stale MCP binary, kill PID for respawn.
#
# Resolves PsychQuant/che-apple-mail-mcp#76: wrapper version-check only fires at
# spawn; in-memory binary never re-checks plugin.json. This hook compares wrapper-
# written runtime state against current plugin.json version; if they differ and
# the recorded PID is alive, SIGTERM (then SIGKILL after grace) so Claude Code
# respawns MCP via wrapper, picking up the new binary.
#
# Failure mode: every dependency missing or unexpected → silent exit 0. Worst
# case is no-op (current pre-fix behavior); never break session start.

set -u

# Dependencies — graceful skip if missing.
command -v jq >/dev/null 2>&1 || exit 0
command -v ps >/dev/null 2>&1 || exit 0

BINARY_NAME="CheAppleMailMCP"
INSTALL_DIR="$HOME/bin"
RUNTIME_FILE="$INSTALL_DIR/.${BINARY_NAME}.runtime.json"

# Locate plugin root via hook's own path (PLUGIN_ROOT/hooks/session-start.sh).
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

# ---- First-run Full Disk Access assist (mail#355) -----------------------------
#
# The setup window has existed since mail#213/#214 — live FDA status, a button
# that opens the right System Settings pane, a button that copies the binary
# path — and NOTHING on the install path ever opened it. The wrapper only
# compares versions, this hook only killed stale processes, and the README
# mentioned `--setup` in a reference section you had to already know to look
# for. So the convenient way to grant FDA was reachable only by people who
# already knew it existed.
#
# This must run BEFORE the staleness block below: that block exits early when
# $RUNTIME_FILE is absent, which is precisely the state of a brand-new install —
# the first run, the only run this assist cares about.
#
# Deliberate constraints:
#   - offered ONCE per machine (marker), never a recurring nag
#   - only when FDA is actually missing
#   - the window is launched DETACHED; it runs a GUI runloop and would otherwise
#     block session start forever
#   - the marker is written BEFORE launching, so a failure cannot loop
#   - old binaries are skipped by version: they parse `--check-fda --quiet` as
#     plain `--check-fda`, which PRINTS and opens System Settings — exactly the
#     nagging this is written to avoid
first_run_fda_assist() {
    local binary="$INSTALL_DIR/$BINARY_NAME"
    [ -x "$binary" ] || return 0

    local marker_dir="${XDG_STATE_HOME:-$HOME/.local/state}/che-apple-mail-mcp"
    local marker="$marker_dir/fda-setup-offered"
    [ -f "$marker" ] && return 0

    # `--check-fda --quiet` (status only, no output, no pane) landed in binary
    # 2.28.0. Anything older: skip rather than risk the loud path.
    local bin_ver
    bin_ver=$("$binary" --version 2>/dev/null | tr -d '[:space:]')
    [ -z "$bin_ver" ] && return 0
    [ "$(printf '%s\n2.28.0\n' "$bin_ver" | sort -V | head -1)" = "2.28.0" ] || return 0

    # Silent probe. 0 = granted → nothing to offer.
    "$binary" --check-fda --quiet >/dev/null 2>&1 && return 0

    mkdir -p "$marker_dir" 2>/dev/null || return 0
    : > "$marker" 2>/dev/null || return 0

    echo "che-apple-mail-mcp: Full Disk Access is not granted — opening the setup window." >&2
    echo "  It shows live status and links straight to the right System Settings pane." >&2
    echo "  (Shown once. Re-open any time with: $binary --setup)" >&2

    # Detached: the window owns a GUI runloop and must not block session start.
    ( "$binary" --setup >/dev/null 2>&1 & ) >/dev/null 2>&1

    return 0
}
first_run_fda_assist

# Both files required.
[ -f "$RUNTIME_FILE" ] || exit 0
[ -f "$PLUGIN_JSON" ] || exit 0

# Read versions. Runtime state records BINARY tag (per #77 fix to wrapper).
# Plugin.json has two fields since #77: .version (plugin shell) and
# .binary_version (binary tag). Hook must compare against .binary_version
# when present, falling back to .version for plugins not yet migrated.
# Without this fallback chain, the hook compares runtime binary tag against
# plugin shell version and triggers spurious kill every session (see #73).
RUNTIME_VERSION=$(jq -r '.version_at_spawn // ""' "$RUNTIME_FILE" 2>/dev/null)
PLUGIN_VERSION=$(jq -r '.binary_version // .version // ""' "$PLUGIN_JSON" 2>/dev/null)

[ -z "$RUNTIME_VERSION" ] && exit 0
[ -z "$PLUGIN_VERSION" ] && exit 0

# Match → no-op.
[ "$RUNTIME_VERSION" = "$PLUGIN_VERSION" ] && exit 0

# Mismatch — but a wrapper running in a DELIBERATE degraded state records the
# pin it could not honor (#392: pinned tag definitively missing upstream, or
# its download failed verification). Killing would only respawn into the same
# degraded state — an unbounded kill-at-every-session-start loop (#398 verify
# round 1). Leave it running; the wrapper retries on its own TTL / pin change.
#
# The runtime field alone is NOT sufficient evidence (#398 verify round 2):
# it is a snapshot from whenever the wrapper last ran, and the thing that
# actually expires — the marker's 24h TTL — is only ever evaluated by the
# wrapper, which cannot run again until something kills this process. Trusting
# the field on its own made the degraded state PERMANENT: at TTL+1h the hook
# still suppressed the kill, so the wrapper never re-ran, so the pin was never
# retried. Deleting the marker by hand did not help either, because the
# suppression did not consult it. So re-derive the decision from the marker
# itself here, and suppress only while it is genuinely live.
DEGRADED_PIN=$(jq -r '.degraded_pin // ""' "$RUNTIME_FILE" 2>/dev/null)
if [ -n "$DEGRADED_PIN" ] && [ "$DEGRADED_PIN" = "$PLUGIN_VERSION" ]; then
    MARKER_FILE="$INSTALL_DIR/.${BINARY_NAME}.fallback-tried"
    MARKER_LIVE=false
    if [ -f "$MARKER_FILE" ]; then
        MARKER_PIN=$(awk 'NR==1{print $1}' "$MARKER_FILE" 2>/dev/null)
        MARKER_EPOCH=$(awk 'NR==1{print $2}' "$MARKER_FILE" 2>/dev/null)
        MARKER_REASON=$(awk 'NR==1{print $3}' "$MARKER_FILE" 2>/dev/null)
        case "$MARKER_EPOCH" in
            ''|*[!0-9]*) MARKER_EPOCH=0 ;;
        esac
        NOW_EPOCH=$(date +%s)
        # 86400 == the wrapper's RETRY_TTL. Both sides read the same file;
        # if you change one, change the other.
        if [ "$MARKER_PIN" = "$PLUGIN_VERSION" ] \
           && [ "$MARKER_EPOCH" -gt 0 ] \
           && [ $((NOW_EPOCH - MARKER_EPOCH)) -lt 86400 ] \
           && [ $((MARKER_EPOCH - NOW_EPOCH)) -lt 300 ]; then
            MARKER_LIVE=true
        fi
    fi
    if [ "$MARKER_LIVE" = true ]; then
        case "$MARKER_REASON" in
            verify) WHY="failed sha256 verification" ;;
            *)      WHY="unavailable upstream" ;;
        esac
        echo "che-apple-mail-mcp: running v${RUNTIME_VERSION} in degraded mode — pinned v${PLUGIN_VERSION} ${WHY}; not killing (wrapper retries when the marker's 24h TTL lapses, or rm ${MARKER_FILE} to force)" >&2
        exit 0
    fi
    # Marker gone or expired: the degraded state is over as far as the wrapper
    # is concerned. Fall through to the normal stale-kill so the next spawn
    # actually retries the pin.
fi

# Mismatch — check if recorded PID is still alive.
PID=$(jq -r '.pid // empty' "$RUNTIME_FILE" 2>/dev/null)
[ -z "$PID" ] && exit 0

# `ps -p $PID -o pid=` returns empty if PID is dead. Also guard against
# matching the wrong process (e.g. PID reused by something else): require
# the running process command to contain BINARY_NAME.
ps -p "$PID" -o pid= >/dev/null 2>&1 || exit 0
PID_COMM=$(ps -p "$PID" -o command= 2>/dev/null)
case "$PID_COMM" in
    *"$BINARY_NAME"*) ;;
    *) exit 0 ;;
esac

echo "⚠ Killing stale ${BINARY_NAME} PID ${PID} (was v${RUNTIME_VERSION}, plugin now v${PLUGIN_VERSION}) — Claude Code will respawn with new binary." >&2

# SIGTERM, give 5s for graceful shutdown (SQLite WAL flush, etc).
kill -TERM "$PID" 2>/dev/null || true
for _ in 1 2 3 4 5; do
    ps -p "$PID" -o pid= >/dev/null 2>&1 || break
    sleep 1
done

# Still alive → SIGKILL.
if ps -p "$PID" -o pid= >/dev/null 2>&1; then
    echo "⚠ ${BINARY_NAME} PID ${PID} did not exit on SIGTERM, sending SIGKILL." >&2
    kill -KILL "$PID" 2>/dev/null || true
fi

exit 0
