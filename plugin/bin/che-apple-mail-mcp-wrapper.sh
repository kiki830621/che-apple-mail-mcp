#!/bin/bash
# Version-aware auto-download wrapper for CheAppleMailMCP.
#
# Design:
# - Reads desired version from plugin.json (plugin's intended binary version)
# - Compares against ~/bin/.CheAppleMailMCP.version sidecar
# - Re-downloads when plugin has been updated but binary is stale
# - Atomic file swap (unique mktemp + mv) so partial or concurrent downloads
#   never break things (#392: fixed-name .tmp was a TOCTOU window)
# - Downloads are sha256-verified against the release's own asset list (#392).
#   Verification fails CLOSED: the only unverified install is a release that
#   genuinely publishes no .sha256 asset. Being unable to COMPUTE a digest is a
#   refusal, not a downgrade (#398 round 2).
# - Falls back to releases/latest ONLY on a definitive pinned-tag 404; a
#   transient API failure keeps the installed binary and retries next spawn
#
# THE degraded_pin INVARIANT (#398 round 2). `degraded_pin` is written to
# runtime state if and only if a `.fallback-tried` marker was written for the
# same pin. It means "this pin is known-bad upstream and re-downloading it is
# pointless until the TTL lapses" — the session-start hook reads it (and
# re-validates the marker itself) to suppress a kill it could never fix.
# Every OTHER degraded outcome — transient API failure, download error, digest
# fetch failure, rename failure — deliberately leaves it EMPTY, because for
# those the hook's kill IS the retry trigger: it makes Claude Code respawn us,
# and the next spawn re-attempts the download. Round 1 stamped degraded_pin on
# the transient path too, which suppressed the only respawn trigger and turned
# "retries next spawn" into "never retries".
#
# State files in ~/bin (all prefixed .CheAppleMailMCP.):
#     .version         — sidecar: ACTUAL installed binary tag (#77)
#     .runtime.json    — pid/started_at/version_at_spawn (+degraded_pin) for the
#                        session-start staleness hook (#76/#393)
#     .fallback-tried  — "<pin> <epoch> <miss|verify>": a pin found definitively
#                        missing (miss) or failing digest verification (verify)
#                        upstream; suppresses re-download for RETRY_TTL seconds
#                        or until the pin changes (#392).
#                        Deleting the file forces an immediate retry.

set -u

REPO="PsychQuant/che-apple-mail-mcp"
BINARY_NAME="CheAppleMailMCP"
INSTALL_DIR="$HOME/bin"
BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"
FALLBACK_MARKER="$INSTALL_DIR/.${BINARY_NAME}.fallback-tried"
RUNTIME_FILE="$INSTALL_DIR/.${BINARY_NAME}.runtime.json"
RETRY_TTL=86400        # retry a marked-unavailable pin at most once a day
META_TIMEOUT=30        # API / digest calls: small bodies, fail fast
BINARY_TIMEOUT=300     # the binary is ~18 MB — 30s hard-fails slow links (#398 R2)

# Every temp this script makes, removed on any exit path. Unique names (#392)
# closed a TOCTOU window but gave up the old fixed-name file's one virtue: it
# could not accumulate. Without this trap an interrupted spawn leaks ~18 MB
# into ~/bin, unbounded (#398 round 2).
TEMPS=()
cleanup_temps() {
    [[ ${#TEMPS[@]} -gt 0 ]] && rm -f "${TEMPS[@]}" 2>/dev/null
    return 0
}
trap cleanup_temps EXIT INT TERM
# Result lands in $NEW_TEMP rather than on stdout: `X=$(new_temp ...)` would run
# the function in a SUBSHELL, so the registration would be discarded and the
# trap would have nothing to clean — the leak this exists to prevent, hidden
# behind a function that looks like it is doing the job.
NEW_TEMP=""
new_temp() {
    NEW_TEMP=$(mktemp "$1") || return 1
    TEMPS+=("$NEW_TEMP")
    return 0
}

# Locate plugin root via wrapper's own path (more reliable than $CLAUDE_PLUGIN_ROOT
# which isn't guaranteed in MCP spawn env). Wrapper lives at PLUGIN_ROOT/bin/*.sh.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

# Read desired BINARY version from plugin.json. Prefer the explicit
# `binary_version` field (introduced for #77 — disambiguates from the
# plugin shell's own `version`). Fall back to `version` for plugins that
# haven't migrated yet — they pay the existing silent-skip risk for
# binary-only releases (documented in #77).
DESIRED_VERSION=""
HAS_BINARY_VERSION=false
if [[ -f "$PLUGIN_JSON" ]]; then
    DESIRED_VERSION=$(grep -oE '"binary_version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
        | head -1 | cut -d'"' -f4 || true)
    if [[ -n "$DESIRED_VERSION" ]]; then
        HAS_BINARY_VERSION=true
    else
        DESIRED_VERSION=$(grep -oE '"version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
            | head -1 | cut -d'"' -f4 || true)
    fi
fi

# Read currently installed version from sidecar (empty string if file missing/unreadable).
INSTALLED_VERSION=""
[[ -f "$VERSION_FILE" ]] && INSTALLED_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)

# --- helpers ------------------------------------------------------------------

# GET $1, body to $2, with a $3-second ceiling (default META_TIMEOUT).
# Echoes the HTTP status code ("000" on transport failure).
# Deliberately NOT -f: distinguishing a definitive 404 from rate-limits /
# timeouts / 5xx is the whole point (#392 round 1: conflating them let one
# transient outage pin the user to the wrong binary permanently).
http_get() {
    local code
    code=$(curl -sL --proto '=https' --max-redirs 3 --max-time "${3:-$META_TIMEOUT}" \
        -o "$2" -w '%{http_code}' "$1" 2>/dev/null) || code="000"
    printf '%s' "${code:-000}"
}

# The download URL for the asset named exactly $1, from the API body $2.
#
# Every browser_download_url is put on its own line FIRST, so correctness no
# longer depends on the API pretty-printing one asset per line — against a
# minified response the old greedy sed returned the LAST url on the line, i.e.
# the wrong asset (#398 round 2).
#
# The URL is then validated STRUCTURALLY, not by string prefix. Round 2 used
# `[[ "$u" == "$prefix"* ]]` plus a basename compare, and round 3 proved that
# is not a pin at all — it validates a string while curl fetches a DIFFERENT
# resource, because curl normalises the path before requesting it:
#
#   .../che-apple-mail-mcp/releases/download/../../../../attacker-org/evil-repo/releases/download/v1/CheAppleMailMCP
#     string starts with the prefix  ✓   basename is CheAppleMailMCP  ✓
#     curl actually GETs → https://github.com/attacker-org/evil-repo/releases/download/v1/CheAppleMailMCP
#
# and because the .sha256 is chosen by the same rule it comes from the same
# attacker path, so verification PASSES and the wrapper reports
# "(sha256 verified)" while exec'ing someone else's binary. A `#fragment` is
# likewise dropped before the request, so the basename check can be satisfied
# by text the server never sees.
#
# Hence: exactly two path components after /download/, no query, no fragment,
# and no component that is a dot-segment in any spelling.
asset_url() {
    local want="$1" body="$2"
    local re="^https://github\.com/${REPO}/releases/download/([^/?#]+)/([^/?#]+)\$"
    grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' "$body" 2>/dev/null \
        | cut -d'"' -f4 \
        | while IFS= read -r u; do
            [[ "$u" =~ $re ]] || continue
            local tag="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}"
            # `..` survives [^/?#]+ but is exactly what curl collapses away.
            # Percent-encoded spellings are rejected too: curl leaves them
            # literal, but then the path is still not the one this check
            # claims to have validated — and an origin that DOES decode them
            # would resolve elsewhere.
            # Case-insensitive by enumeration, NOT by ${x,,} — the shebang
            # here is /bin/bash, which on macOS is 3.2, where that expansion
            # is a runtime "bad substitution". `bash -n` parses it happily,
            # so this class of mistake is invisible until the suite runs
            # (#398 round 3: it went 0/76 and looked like a logic bug).
            is_dot_segment() {
                case "$1" in
                    .|..) return 0 ;;
                    %2[eE]|%2[eE]%2[eE]|.%2[eE]|%2[eE].) return 0 ;;
                    *) return 1 ;;
                esac
            }
            is_dot_segment "$tag" && continue
            is_dot_segment "$name" && continue
            [[ "$name" == "$want" ]] && printf '%s\n' "$u"
          done \
        | head -1
}

# Echoes a lowercase 64-hex digest, or nothing if no tool could produce one.
# Round 1 dispatched on `command -v shasum` alone, so a shasum that EXISTS but
# fails (Apple is sunsetting its perl runtime) skipped the openssl fallback
# entirely, and the caller then reported "no sha256 tool available" and
# installed anyway (#398 round 2).
sha256_of() {
    local out
    if command -v shasum >/dev/null 2>&1; then
        out=$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' | tr 'A-F' 'a-f')
        [[ "$out" =~ ^[0-9a-f]{64}$ ]] && { printf '%s' "$out"; return 0; }
    fi
    if command -v openssl >/dev/null 2>&1; then
        out=$(openssl dgst -sha256 -r "$1" 2>/dev/null | awk '{print $1}' | tr 'A-F' 'a-f')
        [[ "$out" =~ ^[0-9a-f]{64}$ ]] && { printf '%s' "$out"; return 0; }
    fi
    return 1
}

# Whether this machine can hash at all — "this release has no digest" and
# "this machine cannot verify" are different trust decisions and must not
# share a code path.
have_hash_tool() { command -v shasum >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1; }

# A 200 response can still carry an error page. sha256 is the real gate; this
# is a shape check for the one path where no digest is published, so an HTML
# body cannot be chmod'd and exec'd (#398 round 2).
looks_like_html() {
    local head
    head=$(head -c 512 "$1" 2>/dev/null | tr -d '\000')
    case "$head" in
        '<'*|*'<!DOCTYPE'*|*'<html'*|*'<HTML'*) return 0 ;;
        *) return 1 ;;
    esac
}

# JSON string escaping — NOT character deletion. Round 1 ran `tr -cd` over the
# version token, which silently DROPPED legal SemVer build metadata (`+build`);
# the hook then compared that mangled value against the raw plugin.json value,
# so the two could never match again (#398 round 2).
json_escape() {
    printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# --- decide whether to download ----------------------------------------------

NEED_DOWNLOAD=false
REASON=""
DEGRADED_PIN=""   # see THE degraded_pin INVARIANT above

# Read the marker defensively. An epoch that is not all-digits used to reach
# bash arithmetic directly, where `a[$(...)]` is evaluated as a command; a
# corrupt file also aborted the whole wrapper under `set -u` (#398 round 2).
MARKER_PIN=""
MARKER_EPOCH=0
MARKER_REASON=""
if [[ -f "$FALLBACK_MARKER" ]]; then
    read -r MARKER_PIN MARKER_EPOCH MARKER_REASON _ < "$FALLBACK_MARKER" 2>/dev/null || true
    MARKER_PIN=${MARKER_PIN:-}
    MARKER_REASON=${MARKER_REASON:-}
    if [[ ! "${MARKER_EPOCH:-}" =~ ^[0-9]{1,19}$ ]]; then
        MARKER_PIN=""   # unparseable marker == no marker
        MARKER_EPOCH=0
    fi
fi
NOW=$(date +%s)
# A future-dated epoch (clock skew, hand-edit) would otherwise suppress retries
# for as long as the skew lasts — years, in the pathological case.
if (( MARKER_EPOCH > NOW + 300 )); then
    MARKER_PIN=""
    MARKER_EPOCH=0
fi
# A marker for a pin we are no longer asking for is dead weight: without this
# it survives until its TTL and misleads the next diagnosis (#398 round 2).
if [[ -n "$MARKER_PIN" ]] && [[ -n "$DESIRED_VERSION" ]] && [[ "$MARKER_PIN" != "$DESIRED_VERSION" ]]; then
    rm -f "$FALLBACK_MARKER" 2>/dev/null
    MARKER_PIN=""
    MARKER_EPOCH=0
fi

if [[ ! -x "$BINARY" ]]; then
    NEED_DOWNLOAD=true
    REASON="binary not installed"
elif [[ -n "$DESIRED_VERSION" ]] && [[ "$INSTALLED_VERSION" != "$DESIRED_VERSION" ]]; then
    if [[ "$MARKER_PIN" == "$DESIRED_VERSION" ]] && (( NOW - MARKER_EPOCH < RETRY_TTL )); then
        # #392: this pin was definitively missing, or failed verification,
        # upstream within the TTL. Run what is installed; retry when the pin
        # changes, the TTL lapses, or the marker file is deleted by hand.
        # The marker's third field was written but never read, so a tampering
        # signal was reported as "unavailable upstream" (#398 round 2).
        case "$MARKER_REASON" in
            verify) WHY="failed sha256 verification" ;;
            *)      WHY="was unavailable upstream" ;;
        esac
        echo "$BINARY_NAME: pinned v${DESIRED_VERSION} ${WHY} — running installed v${INSTALLED_VERSION:-unknown}; retrying after $(( (MARKER_EPOCH + RETRY_TTL - NOW) / 3600 + 1 ))h or when the pin changes (rm $FALLBACK_MARKER to force)" >&2
        DEGRADED_PIN="$DESIRED_VERSION"
    else
        NEED_DOWNLOAD=true
        REASON="plugin wants v${DESIRED_VERSION}, installed is v${INSTALLED_VERSION:-unknown}"
    fi
fi

if $NEED_DOWNLOAD; then
    echo "$BINARY_NAME: $REASON — downloading from $REPO..." >&2
    mkdir -p "$INSTALL_DIR"

    new_temp "${INSTALL_DIR}/.${BINARY_NAME}.meta.XXXXXX"
        META="$NEW_TEMP"
    URL=""
    SHA_URL=""
    PIN_DEFINITIVE_MISS=false
    PIN_TRANSIENT=false
    CODE=""

    if [[ -n "$DESIRED_VERSION" ]]; then
        CODE=$(http_get "https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION" "$META")
        if [[ "$CODE" == "200" ]]; then
            URL=$(asset_url "$BINARY_NAME" "$META")
            SHA_URL=$(asset_url "$BINARY_NAME.sha256" "$META")
            # Tag exists but carries no binary asset. Not a 404, but equally
            # definitive: no retry changes a published release's asset list.
            [[ -z "$URL" ]] && PIN_DEFINITIVE_MISS=true
        elif [[ "$CODE" == "404" ]]; then
            PIN_DEFINITIVE_MISS=true
        else
            PIN_TRANSIENT=true
        fi
    fi

    if [[ -n "$URL" ]]; then
        :   # pinned resolution succeeded
    elif [[ "$PIN_TRANSIENT" == true ]] && [[ -x "$BINARY" ]]; then
        # #392 round 1 (reproduced finding): a transient API failure must NOT
        # churn the install to latest or write a marker — keep what we have.
        # No degraded_pin: the hook's kill is what makes the retry happen
        # (see THE degraded_pin INVARIANT).
        echo "$BINARY_NAME: transient failure resolving pinned v${DESIRED_VERSION} (HTTP ${CODE:-000}) — keeping installed v${INSTALLED_VERSION:-unknown}, will retry next spawn" >&2
        NEED_DOWNLOAD=false
    else
        if [[ "$PIN_TRANSIENT" == true ]]; then
            # Fresh install + transient failure: substituting `latest` for the
            # pin is a real deviation, not a detail. Say so (#398 round 2).
            echo "$BINARY_NAME: WARNING — could not resolve pinned v${DESIRED_VERSION} (HTTP ${CODE:-000}) and no binary is installed; falling back to the latest release" >&2
        fi
        CODE2=$(http_get "https://api.github.com/repos/$REPO/releases/latest" "$META")
        if [[ "$CODE2" == "200" ]]; then
            URL=$(asset_url "$BINARY_NAME" "$META")
            SHA_URL=$(asset_url "$BINARY_NAME.sha256" "$META")
        fi
    fi

    if $NEED_DOWNLOAD; then
    if [[ -z "$URL" ]]; then
        if [[ -x "$BINARY" ]]; then
            echo "$BINARY_NAME: WARNING — no download URL found, keeping existing binary" >&2
        else
            echo "$BINARY_NAME: ERROR — no download URL found at $REPO. Install manually: https://github.com/$REPO/releases" >&2
            exit 1
        fi
    else
        # Unique temp per process (#392 round 1: a shared fixed .tmp let a
        # concurrent spawn swap content between verification and mv).
        new_temp "${BINARY}.tmp.XXXXXX"
        TMP="$NEW_TEMP"
        DL_CODE=$(http_get "$URL" "$TMP" "$BINARY_TIMEOUT")
        if [[ "$DL_CODE" == "200" ]] && [[ -s "$TMP" ]]; then
            # ---- sha256 verification (#392) --------------------------------
            INSTALL_OK=true
            VERIFIED=false
            if [[ -z "$SHA_URL" ]]; then
                # Definitively absent from the release's own asset list — the
                # one approved unverified path (old releases never shipped one).
                if looks_like_html "$TMP"; then
                    INSTALL_OK=false
                    echo "$BINARY_NAME: ERROR — the download returned an HTML page, not a binary, and this release publishes no .sha256 to check it against; refusing install" >&2
                else
                    echo "$BINARY_NAME: note — this release publishes no .sha256 asset; installing unverified" >&2
                fi
            elif ! have_hash_tool; then
                # A digest EXISTS and this machine cannot check it. Round 1
                # installed anyway; that is the fail-open #392 exists to close.
                INSTALL_OK=false
                echo "$BINARY_NAME: ERROR — this release publishes a .sha256 but no sha256 tool (shasum/openssl) is available to verify it; refusing unverified install" >&2
            else
                new_temp "${INSTALL_DIR}/.${BINARY_NAME}.sha.XXXXXX"
        SHA_TMP="$NEW_TEMP"
                SHA_CODE=$(http_get "$SHA_URL" "$SHA_TMP")
                EXPECTED_SHA=$(head -1 "$SHA_TMP" 2>/dev/null | awk '{print $1}' | tr 'A-F' 'a-f')
                rm -f "$SHA_TMP"
                ACTUAL_SHA=$(sha256_of "$TMP" || true)
                if [[ "$SHA_CODE" != "200" ]] || [[ ! "$EXPECTED_SHA" =~ ^[0-9a-f]{64}$ ]]; then
                    # The asset exists but we could not obtain a usable digest:
                    # that is a verification FAILURE, not "no asset" (#392
                    # round 1: fail-open here defeated the whole feature).
                    # Transient by nature — no marker; retry next spawn.
                    INSTALL_OK=false
                    echo "$BINARY_NAME: ERROR — could not fetch a usable .sha256 (HTTP ${SHA_CODE}); refusing unverified install" >&2
                elif [[ -z "$ACTUAL_SHA" ]]; then
                    # A hash tool is present but produced nothing usable. Fail
                    # closed: the digest exists, so "cannot verify" is a
                    # refusal, not a downgrade (#398 round 2).
                    INSTALL_OK=false
                    echo "$BINARY_NAME: ERROR — sha256 tool present but produced no usable digest; refusing unverified install" >&2
                elif [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
                    INSTALL_OK=false
                    echo "$BINARY_NAME: ERROR — sha256 MISMATCH on downloaded binary (expected ${EXPECTED_SHA}, got ${ACTUAL_SHA}); refusing install. If this persists the release asset may have been tampered with — verify at https://github.com/$REPO/releases before forcing a retry." >&2
                    # Persistent-mismatch guard: without a marker every spawn
                    # re-downloads 18 MB of the same rejected bytes (#398 R1).
                    if [[ -x "$BINARY" ]] && [[ -n "$DESIRED_VERSION" ]]; then
                        printf '%s %s verify\n' "$DESIRED_VERSION" "$NOW" > "$FALLBACK_MARKER" 2>/dev/null || true
                        DEGRADED_PIN="$DESIRED_VERSION"
                    fi
                else
                    VERIFIED=true
                fi
            fi
            if [[ "$INSTALL_OK" == true ]]; then
                # Explicit mode, and checked: mktemp creates 0600, so relying
                # on `chmod +x` alone silently changed the installed file's
                # permissions (#398 round 2). A failed chmod must not install.
                if ! chmod 755 "$TMP" 2>/dev/null; then
                    INSTALL_OK=false
                    echo "$BINARY_NAME: ERROR — could not make the downloaded file executable; refusing install" >&2
                fi
            fi
            if [[ "$INSTALL_OK" == true ]]; then
                if mv "$TMP" "$BINARY" 2>/dev/null; then
                    # Sidecar records the ACTUAL downloaded binary tag, parsed
                    # from the release URL — keeps the sidecar honest (#77).
                    # On a parse failure the honest value is "unknown": writing
                    # DESIRED here is exactly the #393 lie this file fixes.
                    ACTUAL_VERSION=$(printf '%s' "$URL" | sed -nE 's|.*/releases/download/v?([^/]+)/.*|\1|p')
                    new_temp "${VERSION_FILE}.XXXXXX"
        SC_TMP="$NEW_TEMP"
                    printf '%s\n' "${ACTUAL_VERSION:-unknown}" > "$SC_TMP" && mv "$SC_TMP" "$VERSION_FILE"
                    if [[ "$VERIFIED" == true ]]; then
                        echo "$BINARY_NAME: installed v${ACTUAL_VERSION:-unknown} (sha256 verified)" >&2
                    else
                        echo "$BINARY_NAME: installed v${ACTUAL_VERSION:-unknown} (unverified — no published digest)" >&2
                    fi
                    if [[ "$PIN_DEFINITIVE_MISS" == true ]] && [[ -n "$DESIRED_VERSION" ]]; then
                        # Definitive miss + successful fallback: remember it so
                        # the next spawns don't re-download; TTL + pin-change
                        # + manual rm all clear it (#392).
                        printf '%s %s miss\n' "$DESIRED_VERSION" "$NOW" > "$FALLBACK_MARKER" 2>/dev/null || true
                        DEGRADED_PIN="$DESIRED_VERSION"
                    else
                        rm -f "$FALLBACK_MARKER" 2>/dev/null
                    fi
                else
                    rm -f "$TMP"
                    if [[ -x "$BINARY" ]]; then
                        echo "$BINARY_NAME: WARNING — install rename failed, keeping existing binary" >&2
                    else
                        echo "$BINARY_NAME: ERROR — install rename failed" >&2
                        exit 1
                    fi
                fi
            else
                rm -f "$TMP"
                if [[ ! -x "$BINARY" ]]; then
                    echo "$BINARY_NAME: ERROR — verification failed and no existing binary to fall back to. Install manually: https://github.com/$REPO/releases" >&2
                    exit 1
                fi
            fi
        else
            rm -f "$TMP"
            if [[ -x "$BINARY" ]]; then
                echo "$BINARY_NAME: WARNING — download failed (HTTP ${DL_CODE}), keeping existing binary" >&2
            else
                echo "$BINARY_NAME: ERROR — download failed (HTTP ${DL_CODE})" >&2
                exit 1
            fi
        fi
    fi
    fi
fi

# Write runtime state (per #76 — let session-start hook detect mid-session staleness).
# Atomic write: mktemp + mv; failures silent (|| true) so they never block spawn.
#
# #393: version_at_spawn records the ACTUAL installed version (re-read from the
# sidecar, which #77 made honest) — NOT the DESIRED pin. Writing DESIRED meant a
# failed download that kept an old binary stamped the new version into runtime
# state and the staleness hook went false-negative forever. When the sidecar is
# missing/unreadable the honest value is "unknown", not the pin (#398 round 1).
# Legacy plugins without `binary_version` keep the old DESIRED semantics — for
# them the hook compares against the SHELL version, and an actual binary tag
# would re-open the #73 spurious-kill trap.
if [[ "$HAS_BINARY_VERSION" == true ]]; then
    RUNTIME_VERSION="unknown"
    if [[ -f "$VERSION_FILE" ]]; then
        SIDECAR_VALUE=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)
        [[ -n "$SIDECAR_VALUE" ]] && RUNTIME_VERSION="$SIDECAR_VALUE"
    fi
else
    RUNTIME_VERSION="${DESIRED_VERSION:-unknown}"
fi
{
    RT_TMP=$(mktemp "${RUNTIME_FILE}.XXXXXX") \
        && printf '{"pid":%d,"started_at":%d,"version_at_spawn":"%s","degraded_pin":"%s"}\n' \
            "$$" "$NOW" "$(json_escape "${RUNTIME_VERSION:-unknown}")" "$(json_escape "$DEGRADED_PIN")" \
            > "$RT_TMP" \
        && mv "$RT_TMP" "$RUNTIME_FILE"
} 2>/dev/null || true

cleanup_temps
exec "$BINARY" "$@"
