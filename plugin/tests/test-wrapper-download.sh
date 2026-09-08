#!/bin/bash
# Tests for bin/che-apple-mail-mcp-wrapper.sh download-chain integrity (#392, #393).
# Round-2 suite (#398 verify round 1): HTTP-code-aware mock, definitive-404-only
# marker with TTL, transient-keeps-installed, degraded_pin runtime field + hook
# suppression, sidecar-absent honesty, legacy no-binary_version semantics.
#
# Mock strategy:
# - PATH-shim `curl` routes by URL against per-case scenario files:
#     $SCEN/<ep>.body  — response body (ep: api_pinned / api_latest / sha / binary)
#     $SCEN/<ep>.code  — HTTP status (default: 200 if body exists, else 404;
#                        "000" simulates a transport failure: prints 000, exit 6)
#   The wrapper reads status via `-w '%{http_code}'`, exactly like real curl.
# - HOME override puts INSTALL_DIR / sidecar / runtime / marker under $TEST_DIR.
# - The installed "binary" is a tiny sh script printing a token, so
#   `exec "$BINARY"` terminates the subshell run cleanly.

set -u

TEST_DIR=$(mktemp -d -t test-wrapper-download.XXXXXX)
PASS=0
FAIL=0
FAIL_DETAIL=""

cleanup() {
    for pid in $(cat "$TEST_DIR/mock_pids" 2>/dev/null); do
        kill -KILL "$pid" 2>/dev/null || true
    done
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
REAL_WRAPPER="$BIN_DIR/che-apple-mail-mcp-wrapper.sh"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
REAL_HOOK="$HOOK_DIR/session-start.sh"
[ -f "$REAL_WRAPPER" ] || { echo "ERROR: wrapper not found" >&2; exit 2; }
[ -f "$REAL_HOOK" ] || { echo "ERROR: hook not found" >&2; exit 2; }

FAKE_PLUGIN="$TEST_DIR/fake-plugin"
mkdir -p "$FAKE_PLUGIN/bin" "$FAKE_PLUGIN/hooks" "$FAKE_PLUGIN/.claude-plugin"
cp "$REAL_WRAPPER" "$FAKE_PLUGIN/bin/che-apple-mail-mcp-wrapper.sh"
cp "$REAL_HOOK" "$FAKE_PLUGIN/hooks/session-start.sh"
chmod +x "$FAKE_PLUGIN/bin/che-apple-mail-mcp-wrapper.sh" "$FAKE_PLUGIN/hooks/session-start.sh"

SCEN="$TEST_DIR/scenario"
SHIM="$TEST_DIR/shim"
mkdir -p "$SCEN" "$SHIM"

cat > "$SHIM/curl" <<'SHIMEOF'
#!/bin/bash
SCEN="${WRAPPER_TEST_SCEN:?}"
url=""; out=""; want_code=""; prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && out="$a"
    [ "$prev" = "-w" ] && want_code="yes"
    case "$a" in https://*) url="$a" ;; esac
    prev="$a"
done
ep="binary"
case "$url" in
    *"/releases/tags/"*)  ep="api_pinned" ;;
    *"/releases/latest"*) ep="api_latest" ;;
    *.sha256)             ep="sha" ;;
esac
# Record the timeout the wrapper asked for. Without this the mock silently
# accepts any --max-time, and #398 R2's verified regression (the 18 MB binary
# download collapsed onto the metadata call's 30s budget, so a slow link could
# never finish a fresh install) is invisible to the entire suite.
mt=""; prev2=""
for a in "$@"; do [ "$prev2" = "--max-time" ] && mt="$a"; prev2="$a"; done
[ -n "${WRAPPER_TEST_TIMEOUT_LOG:-}" ] && printf '%s %s\n' "$ep" "$mt" >> "$WRAPPER_TEST_TIMEOUT_LOG"
body="$SCEN/$ep.body"
codef="$SCEN/$ep.code"
if [ -f "$codef" ]; then code=$(cat "$codef"); elif [ -f "$body" ]; then code=200; else code=404; fi
if [ "$code" = "000" ]; then
    [ -n "$want_code" ] && printf '000'
    exit 6
fi
if [ -f "$body" ]; then
    if [ -n "$out" ]; then cp "$body" "$out"; else cat "$body"; fi
fi
[ -n "$want_code" ] && printf '%s' "$code"
exit 0
SHIMEOF
chmod +x "$SHIM/curl"

RUN_PATH="$SHIM:/usr/bin:/bin"
TEST_HOME="$TEST_DIR/home"

RUNTIME="$TEST_HOME/bin/.CheAppleMailMCP.runtime.json"
SIDECAR="$TEST_HOME/bin/.CheAppleMailMCP.version"
MARKER="$TEST_HOME/bin/.CheAppleMailMCP.fallback-tried"

write_plugin_json() {
    printf '{"name":"test","version":"9.9.9","binary_version":"%s"}\n' "$1" \
        > "$FAKE_PLUGIN/.claude-plugin/plugin.json"
}
write_plugin_json_legacy() {
    printf '{"name":"test","version":"%s"}\n' "$1" \
        > "$FAKE_PLUGIN/.claude-plugin/plugin.json"
}
DL_PREFIX="https://github.com/PsychQuant/che-apple-mail-mcp/releases/download"

write_api() {
    # $1 endpoint (api_pinned/api_latest), $2 version tag, $3 with_sha (yes/no)
    # $4 (optional) "compact" — emit MINIFIED JSON, one line, no whitespace.
    #
    # Round 1's mock was reshaped to one-asset-per-line to accommodate a
    # line-based parser; #398 round 2 hardened the parser instead, so the
    # fixture is free to look like the real thing. URLs carry the real
    # release-download prefix because the wrapper now pins host+path — a
    # fixture on a made-up host would test a code path users never hit.
    if [ "${4:-}" = "compact" ]; then
        {
            printf '{"tag_name":"v%s","assets":[' "$2"
            printf '{"name":"CheAppleMailMCP","browser_download_url":"%s/v%s/CheAppleMailMCP"}' "$DL_PREFIX" "$2"
            if [ "$3" = "yes" ]; then
                printf ',{"name":"CheAppleMailMCP.sha256","browser_download_url":"%s/v%s/CheAppleMailMCP.sha256"}' "$DL_PREFIX" "$2"
            fi
            printf '],"tarball_url":"https://api.github.com/repos/PsychQuant/che-apple-mail-mcp/tarball/v%s","zipball_url":"https://api.github.com/repos/PsychQuant/che-apple-mail-mcp/zipball/v%s"}\n' "$2" "$2"
        } > "$SCEN/$1.body"
        return
    fi
    {
        printf '{"assets": [\n'
        printf '  {"name": "CheAppleMailMCP", "browser_download_url": "%s/v%s/CheAppleMailMCP"},\n' "$DL_PREFIX" "$2"
        if [ "$3" = "yes" ]; then
            printf '  {"name": "CheAppleMailMCP.sha256", "browser_download_url": "%s/v%s/CheAppleMailMCP.sha256"},\n' "$DL_PREFIX" "$2"
        fi
        printf ']}\n'
    } > "$SCEN/$1.body"
}
write_mock_binary_content() {
    printf '#!/bin/sh\necho %s\nexit 0\n' "$1" > "$SCEN/binary.body"
}
write_matching_sha() {
    shasum -a 256 "$SCEN/binary.body" | awk '{print $1}' > "$SCEN/sha.body"
}
seed_installed() {
    mkdir -p "$TEST_HOME/bin"
    printf '#!/bin/sh\necho %s\nexit 0\n' "$1" > "$TEST_HOME/bin/CheAppleMailMCP"
    chmod +x "$TEST_HOME/bin/CheAppleMailMCP"
    if [ "$2" != "NONE" ]; then printf '%s\n' "$2" > "$SIDECAR"; fi
}
run_wrapper() {
    HOME="$TEST_HOME" PATH="$RUN_PATH" WRAPPER_TEST_SCEN="$SCEN" \
        WRAPPER_TEST_TIMEOUT_LOG="$TEST_DIR/curl-timeouts.log" \
        bash "$FAKE_PLUGIN/bin/che-apple-mail-mcp-wrapper.sh" \
        > "$TEST_DIR/out.txt" 2> "$TEST_DIR/err.txt"
    echo $? > "$TEST_DIR/exit_code"
}
reset_state() {
    : > "$TEST_DIR/curl-timeouts.log"
    rm -rf "$TEST_HOME" "$SCEN"
    mkdir -p "$TEST_HOME" "$SCEN"
    : > "$TEST_DIR/out.txt"; : > "$TEST_DIR/err.txt"
}
assert() {
    local name="$1" condition="$2"
    if eval "$condition"; then
        PASS=$((PASS+1)); printf "  PASS  %s\n" "$name"
    else
        FAIL=$((FAIL+1))
        FAIL_DETAIL="${FAIL_DETAIL}\n  FAIL  ${name}\n        cond: ${condition}\n        out: $(cat "$TEST_DIR/out.txt" 2>/dev/null)\n        err: $(cat "$TEST_DIR/err.txt" 2>/dev/null)"
        printf "  FAIL  %s\n" "$name"
    fi
}

# ============================================================
echo "Case 1: fresh install, pinned tag found, sha256 verified (asset-list URL)"
# ============================================================
reset_state
write_plugin_json "2.99.0"
write_api api_pinned "2.99.0" yes
write_mock_binary_content "MOCK-RUN-299"
write_matching_sha
run_wrapper
assert "exec'd installed binary" "grep -q MOCK-RUN-299 $TEST_DIR/out.txt"
assert "sidecar = actual tag" "[ \"\$(cat $SIDECAR)\" = 2.99.0 ]"
assert "runtime = actual" "grep -q '\"version_at_spawn\":\"2.99.0\"' $RUNTIME"
assert "degraded_pin empty" "grep -q '\"degraded_pin\":\"\"' $RUNTIME"
assert "no marker" "[ ! -f $MARKER ]"
assert "no unverified note" "! grep -q unverified $TEST_DIR/err.txt"
# #398 R2 (verified regression): unifying the curl calls behind one helper put
# the 18 MB binary on the metadata call's 30-second budget, so a
# normal-but-slow link could never finish a fresh install — it hard-failed
# with exit 1 and no MCP server at all. The mock ignores timeouts, so without
# these two asserts the whole suite is blind to it.
assert "binary download gets the long timeout, not the metadata one" "grep -q '^binary 300$' $TEST_DIR/curl-timeouts.log"
assert "metadata calls keep the short timeout" "grep -q '^api_pinned 30$' $TEST_DIR/curl-timeouts.log"

# ============================================================
echo "Case 2: sha mismatch — refuse, keep old, marker guards re-download"
# ============================================================
reset_state
seed_installed "OLD-RUN-298" "2.98.0"
write_plugin_json "2.99.0"
write_api api_pinned "2.99.0" yes
write_mock_binary_content "EVIL-RUN"
printf '0000000000000000000000000000000000000000000000000000000000000000\n' > "$SCEN/sha.body"
run_wrapper
assert "mismatch named" "grep -q 'sha256 MISMATCH' $TEST_DIR/err.txt"
assert "tampering is named as such, not as a generic failure" "grep -q 'may have been tampered with' $TEST_DIR/err.txt"
assert "old binary runs" "grep -q OLD-RUN-298 $TEST_DIR/out.txt"
assert "sidecar untouched" "[ \"\$(cat $SIDECAR)\" = 2.98.0 ]"
assert "runtime = old actual (#393)" "grep -q '\"version_at_spawn\":\"2.98.0\"' $RUNTIME"
assert "verify marker written" "grep -q '^2.99.0 .* verify' $MARKER"
assert "degraded_pin recorded" "grep -q '\"degraded_pin\":\"2.99.0\"' $RUNTIME"
assert "no stray tmp files" "! ls $TEST_HOME/bin/CheAppleMailMCP.tmp.* 2>/dev/null | grep -q ."
# spawn 2: marker suppresses the 18MB re-download loop
rm -rf "$SCEN"; mkdir -p "$SCEN"
: > "$TEST_DIR/out.txt"; : > "$TEST_DIR/err.txt"
run_wrapper
# The marker's third field (miss|verify) was written but never read, so a
# verification failure was reported as "unavailable upstream" (#398 R2).
assert "spawn2: no re-download (marker guard)" "grep -q 'failed sha256 verification' $TEST_DIR/err.txt"
assert "spawn2: does NOT misreport tampering as an upstream outage" "! grep -q 'was unavailable upstream' $TEST_DIR/err.txt"
assert "spawn2: old binary still runs" "grep -q OLD-RUN-298 $TEST_DIR/out.txt"

# ============================================================
echo "Case 3: release publishes no .sha256 (absent from asset list) — approved unverified path"
# ============================================================
reset_state
write_plugin_json "2.99.0"
write_api api_pinned "2.99.0" no
write_mock_binary_content "MOCK-RUN-299"
run_wrapper
assert "unverified disclosed" "grep -q 'publishes no .sha256' $TEST_DIR/err.txt"
assert "installed + runs" "grep -q MOCK-RUN-299 $TEST_DIR/out.txt"
assert "sidecar recorded" "[ \"\$(cat $SIDECAR)\" = 2.99.0 ]"

# ============================================================
echo "Case 4: sha asset EXISTS but fetch fails — verification failure, NOT unverified install"
# ============================================================
reset_state
seed_installed "OLD-RUN-298" "2.98.0"
write_plugin_json "2.99.0"
write_api api_pinned "2.99.0" yes
write_mock_binary_content "MOCK-RUN-299"
printf '500\n' > "$SCEN/sha.code"
run_wrapper
assert "refuses unverified install" "grep -q 'refusing unverified install' $TEST_DIR/err.txt"
assert "old binary kept + runs" "grep -q OLD-RUN-298 $TEST_DIR/out.txt"
assert "NO marker (transient)" "[ ! -f $MARKER ]"
# spawn 2 with sha healthy: retry succeeds
rm -f "$SCEN/sha.code"; write_matching_sha
: > "$TEST_DIR/out.txt"; : > "$TEST_DIR/err.txt"
run_wrapper
assert "spawn2 retry installs" "grep -q MOCK-RUN-299 $TEST_DIR/out.txt"
assert "spawn2 sidecar updated" "[ \"\$(cat $SIDECAR)\" = 2.99.0 ]"

# ============================================================
echo "Case 5: binary download fails — keep old, runtime honest (#393)"
# ============================================================
reset_state
seed_installed "OLD-RUN-298" "2.98.0"
write_plugin_json "2.99.0"
write_api api_pinned "2.99.0" yes
printf '404\n' > "$SCEN/binary.code"
write_matching_sha 2>/dev/null || printf 'deadbeef\n' > "$SCEN/sha.body"
run_wrapper
assert "download-failed warning" "grep -q 'download failed' $TEST_DIR/err.txt"
assert "old binary runs" "grep -q OLD-RUN-298 $TEST_DIR/out.txt"
assert "runtime = old actual (#393 core)" "grep -q '\"version_at_spawn\":\"2.98.0\"' $RUNTIME"

# ============================================================
echo "Case 6: pin definitively 404 — fallback to latest ONCE, marker + degraded_pin"
# ============================================================
reset_state
write_plugin_json "2.99.0"
printf '404\n' > "$SCEN/api_pinned.code"
write_api api_latest "3.0.0" yes
write_mock_binary_content "MOCK-RUN-300"
write_matching_sha
run_wrapper
assert "latest installed" "grep -q MOCK-RUN-300 $TEST_DIR/out.txt"
assert "sidecar = latest tag" "[ \"\$(cat $SIDECAR)\" = 3.0.0 ]"
assert "miss marker with epoch" "grep -q '^2.99.0 [0-9]* miss' $MARKER"
assert "degraded_pin = missing pin" "grep -q '\"degraded_pin\":\"2.99.0\"' $RUNTIME"
# spawn 2: zero network, guard message
rm -rf "$SCEN"; mkdir -p "$SCEN"
: > "$TEST_DIR/out.txt"; : > "$TEST_DIR/err.txt"
run_wrapper
assert "spawn2 guard note" "grep -q 'unavailable upstream' $TEST_DIR/err.txt"
assert "spawn2 runs installed" "grep -q MOCK-RUN-300 $TEST_DIR/out.txt"
assert "spawn2 degraded_pin persists" "grep -q '\"degraded_pin\":\"2.99.0\"' $RUNTIME"

# ============================================================
echo "Case 7: pin TRANSIENTLY unreachable + binary installed — keep installed, no marker, converge later (H1)"
# ============================================================
reset_state
seed_installed "OLD-RUN-300" "3.0.0"
write_plugin_json "2.99.0"
printf '503\n' > "$SCEN/api_pinned.code"
run_wrapper
assert "transient disclosed" "grep -q 'transient failure resolving pinned' $TEST_DIR/err.txt"
assert "keeps installed" "grep -q OLD-RUN-300 $TEST_DIR/out.txt"
assert "NO marker written" "[ ! -f $MARKER ]"
# #398 R2 (reproduced): stamping degraded_pin here made the hook suppress the
# kill, and the kill is the ONLY thing that makes Claude Code respawn us — so
# "will retry next spawn" became "never retries". Transient degradation must
# leave the field empty. See THE degraded_pin INVARIANT in the wrapper.
assert "degraded_pin EMPTY so the hook's kill can trigger the retry" "grep -q '\"degraded_pin\":\"\"' $RUNTIME"
# spawn 2: pinned healthy again -> converges to the pin (pre-patch parity)
rm -f "$SCEN/api_pinned.code"
write_api api_pinned "2.99.0" yes
write_mock_binary_content "MOCK-RUN-299"
write_matching_sha
: > "$TEST_DIR/out.txt"; : > "$TEST_DIR/err.txt"
run_wrapper
assert "spawn2 converges to pin (H1 fixed)" "grep -q MOCK-RUN-299 $TEST_DIR/out.txt"
assert "spawn2 sidecar = pin" "[ \"\$(cat $SIDECAR)\" = 2.99.0 ]"
assert "spawn2 degraded cleared" "grep -q '\"degraded_pin\":\"\"' $RUNTIME"

# ============================================================
echo "Case 8: pin transient + NO binary — latest fallback installs, no marker"
# ============================================================
reset_state
write_plugin_json "2.99.0"
printf '000\n' > "$SCEN/api_pinned.code"
write_api api_latest "3.0.0" yes
write_mock_binary_content "MOCK-RUN-300"
write_matching_sha
run_wrapper
assert "latest installed (must run something)" "grep -q MOCK-RUN-300 $TEST_DIR/out.txt"
assert "no marker on transient" "[ ! -f $MARKER ]"

# ============================================================
echo "Case 9: marker TTL expired — retry fires and converges, marker cleared"
# ============================================================
reset_state
seed_installed "OLD-RUN-300" "3.0.0"
write_plugin_json "2.99.0"
printf '2.99.0 %s miss\n' "$(( $(date +%s) - 172800 ))" > "$MARKER"
write_api api_pinned "2.99.0" yes
write_mock_binary_content "MOCK-RUN-299"
write_matching_sha
run_wrapper
assert "TTL-expired retry downloads pin" "grep -q MOCK-RUN-299 $TEST_DIR/out.txt"
assert "marker cleared on success" "[ ! -f $MARKER ]"
assert "sidecar = pin" "[ \"\$(cat $SIDECAR)\" = 2.99.0 ]"

# ============================================================
echo "Case 10: sidecar ABSENT + download fails — runtime says unknown, not the pin"
# ============================================================
reset_state
seed_installed "OLD-RUN-XXX" "NONE"
write_plugin_json "2.99.0"
write_api api_pinned "2.99.0" yes
printf '404\n' > "$SCEN/binary.code"
run_wrapper
assert "old binary still runs" "grep -q OLD-RUN-XXX $TEST_DIR/out.txt"
assert "runtime = unknown (not desired)" "grep -q '\"version_at_spawn\":\"unknown\"' $RUNTIME"

# ============================================================
echo "Case 11: legacy plugin.json without binary_version keeps DESIRED semantics (#73 trap)"
# ============================================================
reset_state
seed_installed "OLD-RUN-LEG" "1.0.0"
write_plugin_json_legacy "9.9.9"
printf '404\n' > "$SCEN/api_pinned.code"
printf '404\n' > "$SCEN/api_latest.code"
run_wrapper
assert "legacy: old binary runs" "grep -q OLD-RUN-LEG $TEST_DIR/out.txt"
assert "legacy: runtime = shell version (old semantics)" "grep -q '\"version_at_spawn\":\"9.9.9\"' $RUNTIME"

# ============================================================
echo "Case 12: hook honors degraded_pin — no kill loop; negative control still kills"
# ============================================================
reset_state
mkdir -p "$TEST_HOME/bin"
( exec -a CheAppleMailMCP-mock sleep 1000 ) >/dev/null 2>&1 &
MOCK_PID=$!
echo "$MOCK_PID" >> "$TEST_DIR/mock_pids"
sleep 0.2
write_plugin_json "2.99.0"
printf '{"pid":%d,"started_at":1,"version_at_spawn":"3.0.0","degraded_pin":"2.99.0"}\n' "$MOCK_PID" > "$RUNTIME"
# The runtime field alone is no longer sufficient evidence: the hook re-derives
# the decision from the marker, because the TTL that ends the degraded state is
# only ever evaluated by the wrapper — which cannot run again until a kill
# respawns it (#398 R2).
printf '2.99.0 %s miss\n' "$(date +%s)" > "$MARKER"
HOME="$TEST_HOME" "$FAKE_PLUGIN/hooks/session-start.sh" 2> "$TEST_DIR/err.txt"
HOOK_EXIT=$?
assert "hook exits 0" "[ \"\$HOOK_EXIT\" = 0 ]"
assert "degraded note printed" "grep -q 'degraded mode' $TEST_DIR/err.txt"
assert "no kill message" "! grep -q 'Killing stale' $TEST_DIR/err.txt"
assert "PID survives" "ps -p $MOCK_PID -o pid= >/dev/null 2>&1"
# negative control: same mismatch WITHOUT degraded_pin -> kill fires
printf '{"pid":%d,"started_at":1,"version_at_spawn":"3.0.0","degraded_pin":""}\n' "$MOCK_PID" > "$RUNTIME"
: > "$TEST_DIR/err.txt"
HOME="$TEST_HOME" "$FAKE_PLUGIN/hooks/session-start.sh" 2> "$TEST_DIR/err.txt"
sleep 0.5
assert "control: kill fires without degraded_pin" "grep -q 'Killing stale' $TEST_DIR/err.txt"
assert "control: PID killed" "! ps -p $MOCK_PID -o pid= >/dev/null 2>&1"

# ============================================================
echo "Case 13 (#398 R2): an EXPIRED marker lifts the hook's suppression"
# ============================================================
# Codex R2 HIGH: the hook trusted degraded_pin unconditionally, so at TTL+1h it
# still suppressed the kill -> the wrapper never re-ran -> the TTL it was
# waiting for was never evaluated. Permanently degraded, and deleting the
# marker by hand did not help either because nothing consulted it.
reset_state
mkdir -p "$TEST_HOME/bin"
( exec -a CheAppleMailMCP-mock sleep 1000 ) >/dev/null 2>&1 &
MOCK_PID=$!
echo "$MOCK_PID" >> "$TEST_DIR/mock_pids"
sleep 0.2
write_plugin_json "2.99.0"
printf '{"pid":%d,"started_at":1,"version_at_spawn":"3.0.0","degraded_pin":"2.99.0"}\n' "$MOCK_PID" > "$RUNTIME"
printf '2.99.0 %s miss\n' "$(( $(date +%s) - 172800 ))" > "$MARKER"   # 48h old
: > "$TEST_DIR/err.txt"
HOME="$TEST_HOME" "$FAKE_PLUGIN/hooks/session-start.sh" 2> "$TEST_DIR/err.txt"
sleep 0.5
assert "expired marker: kill fires so the pin gets retried" "grep -q 'Killing stale' $TEST_DIR/err.txt"
assert "expired marker: no degraded note" "! grep -q 'degraded mode' $TEST_DIR/err.txt"
kill -KILL "$MOCK_PID" 2>/dev/null || true

# ============================================================
echo "Case 14 (#398 R2): a hand-deleted marker lifts the suppression immediately"
# ============================================================
reset_state
mkdir -p "$TEST_HOME/bin"
( exec -a CheAppleMailMCP-mock sleep 1000 ) >/dev/null 2>&1 &
MOCK_PID=$!
echo "$MOCK_PID" >> "$TEST_DIR/mock_pids"
sleep 0.2
write_plugin_json "2.99.0"
printf '{"pid":%d,"started_at":1,"version_at_spawn":"3.0.0","degraded_pin":"2.99.0"}\n' "$MOCK_PID" > "$RUNTIME"
rm -f "$MARKER"     # the escape hatch the message advertises
: > "$TEST_DIR/err.txt"
HOME="$TEST_HOME" "$FAKE_PLUGIN/hooks/session-start.sh" 2> "$TEST_DIR/err.txt"
sleep 0.5
assert "rm marker: the documented escape hatch actually works" "grep -q 'Killing stale' $TEST_DIR/err.txt"
kill -KILL "$MOCK_PID" 2>/dev/null || true

# ============================================================
echo "Case 15 (#398 R2): MINIFIED API JSON still selects the right asset"
# ============================================================
# The old parser was line-based with a greedy sed, so a single-line response
# returned the LAST url on the line. Nothing in the GitHub API contract
# promises pretty-printing; round 1 reshaped the FIXTURE to fit the parser
# instead of hardening it.
reset_state
write_plugin_json "2.99.0"
write_api api_pinned "2.99.0" yes compact
write_mock_binary_content "MOCK-RUN-COMPACT"
write_matching_sha
run_wrapper
assert "compact JSON: the BINARY asset was installed, not the .sha256 or the zipball" "grep -q MOCK-RUN-COMPACT $TEST_DIR/out.txt"
assert "compact JSON: verified, not silently unverified" "grep -q 'sha256 verified' $TEST_DIR/err.txt"
assert "compact JSON: sidecar = pin" "[ \"\$(cat $SIDECAR)\" = 2.99.0 ]"

# ============================================================
echo "Case 16 (#398 R2): an asset URL on a foreign host is refused"
# ============================================================
# asset_url pins host+path to this repo's own release downloads, so a spoofed
# or tampered API body cannot redirect the install elsewhere.
reset_state
write_plugin_json "2.99.0"
{
    printf '{"assets": [\n'
    printf '  {"name": "CheAppleMailMCP", "browser_download_url": "https://evil.example.com/releases/download/v2.99.0/CheAppleMailMCP"}\n'
    printf ']}\n'
} > "$SCEN/api_pinned.body"
write_mock_binary_content "EVIL-HOST-RUN"
run_wrapper
assert "foreign host: nothing installed" "! grep -q EVIL-HOST-RUN $TEST_DIR/out.txt"
assert "foreign host: refused with a reason" "grep -q 'no download URL found' $TEST_DIR/err.txt"

# ============================================================
echo "Case 17 (#398 R2): digest published + no hash tool = refuse, not install"
# ============================================================
# #392's whole point. Round 1 treated "this machine cannot hash" the same as
# "this release has no digest" and installed anyway.
reset_state
NOHASH="$TEST_DIR/nohash-shim"
mkdir -p "$NOHASH"
ln -sf "$SHIM/curl" "$NOHASH/curl"
# cp is used by the mock curl itself — omitting it made the shim silently
# thinner than intended and the wrapper failed for the WRONG reason (it could
# not read the API body at all), which would have passed this case's negative
# asserts while testing nothing. Same shape as #399's make_shim_without gap.
for tool in grep sed awk mktemp date tr head cut cp mv rm chmod mkdir cat ls dirname printf sleep; do
    src=$(command -v "$tool" 2>/dev/null) || continue
    case "$src" in /*) ln -sf "$src" "$NOHASH/$tool" 2>/dev/null ;; esac
done
if ( PATH="$NOHASH"; command -v shasum >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1 )    || ! ( PATH="$NOHASH"; command -v curl >/dev/null 2>&1 && command -v cp >/dev/null 2>&1 ); then
    echo "  SKIP  Case 17: could not build a usable hash-tool-free PATH" >&2
else
    write_plugin_json "2.99.0"
    write_api api_pinned "2.99.0" yes
    write_mock_binary_content "MOCK-NOHASH"
    printf '%064d\n' 0 > "$SCEN/sha.body"
    : > "$TEST_DIR/out.txt"; : > "$TEST_DIR/err.txt"
    HOME="$TEST_HOME" WRAPPER_TEST_SCEN="$SCEN" PATH="$NOHASH" \
        "$FAKE_PLUGIN/bin/che-apple-mail-mcp-wrapper.sh" \
        > "$TEST_DIR/out.txt" 2> "$TEST_DIR/err.txt" || true
    assert "no hash tool: refused" "grep -q 'no sha256 tool' $TEST_DIR/err.txt"
    assert "no hash tool: nothing installed" "! grep -q MOCK-NOHASH $TEST_DIR/out.txt"
    assert "no hash tool: did NOT claim an unverified install" "! grep -q 'installing unverified' $TEST_DIR/err.txt"
fi

# ============================================================
echo "Case 18 (#398 R2): a corrupt marker is ignored, not fatal"
# ============================================================
# The epoch went straight into bash arithmetic, where `a[\$(cmd)]` is evaluated
# as a command, and a non-numeric value aborted the wrapper under set -u.
reset_state
seed_installed "OLD-RUN-298" "2.98.0"
write_plugin_json "2.99.0"
write_api api_pinned "2.99.0" yes
write_mock_binary_content "MOCK-RUN-299"
write_matching_sha
# The payload must contain NO whitespace and no backslash escape: `read -r a b c`
# splits the line on whitespace, so a spaced payload lands in three fields and
# never reaches arithmetic at all — which is how the first version of this case
# passed while testing nothing (caught by mutation-testing this suite against a
# wrapper with its epoch validation removed). ${IFS} is literal text to `read`
# and becomes a space only when the arithmetic evaluator runs the substitution.
printf '2.99.0 a[$(touch${IFS}%s/PWNED)] miss\n' "$TEST_DIR" > "$MARKER"
run_wrapper
assert "corrupt marker: no command executed from it" "[ ! -f $TEST_DIR/PWNED ]"
assert "corrupt marker: no raw bash arithmetic error leaked" "! grep -qiE 'syntax error|arithmetic' $TEST_DIR/err.txt"
assert "corrupt marker: wrapper still converges" "grep -q MOCK-RUN-299 $TEST_DIR/out.txt"

# ============================================================
echo "Case 19 (#398 R2): temps do not leak, and the installed mode is 755"
# ============================================================
reset_state
write_plugin_json "2.99.0"
write_api api_pinned "2.99.0" yes
write_mock_binary_content "MOCK-RUN-299"
write_matching_sha
run_wrapper
assert "no leaked binary temps" "! ls $TEST_HOME/bin/CheAppleMailMCP.tmp.* 2>/dev/null | grep -q ."
assert "no leaked meta/sha temps" "! ls $TEST_HOME/bin/.CheAppleMailMCP.meta.* $TEST_HOME/bin/.CheAppleMailMCP.sha.* 2>/dev/null | grep -q ."
assert "installed mode is 755" "[ \"\$(stat -f '%Lp' $TEST_HOME/bin/CheAppleMailMCP)\" = 755 ]"

# ============================================================
echo "Case 20 (#398 R3): dot-segment in the asset URL is refused"
# ============================================================
# Round 2 "pinned" the host with a string-prefix compare. Round 3 proved that
# is not a pin: curl NORMALISES the path before requesting, so a URL that
# starts with the right prefix can resolve anywhere on github.com. Verified
# with curl -w '%{url_effective}':
#   .../che-apple-mail-mcp/releases/download/../../../../attacker-org/evil-repo/releases/download/v1/CheAppleMailMCP
#   -> https://github.com/attacker-org/evil-repo/releases/download/v1/CheAppleMailMCP
# And because the .sha256 is selected by the SAME rule it comes from the same
# attacker path, so verification passes and the wrapper prints "sha256 verified"
# while exec'ing someone else's binary.
reset_state
write_plugin_json "2.99.0"
# Two payloads, because they are stopped by DIFFERENT checks and the first
# version of this case only exercised one of them (mutation-testing caught it:
# deleting is_dot_segment left the suite fully green).
#
#   (a) many components  -> stopped by the "exactly two path components" regex
#   (b) exactly two, one of which is `..` -> regex ACCEPTS it; only
#       is_dot_segment stops it. Verified with curl -w '%{url_effective}':
#       .../releases/download/../CheAppleMailMCP
#         -> https://github.com/PsychQuant/che-apple-mail-mcp/releases/CheAppleMailMCP
{
    printf '{"assets": [\n'
    printf '  {"name": "CheAppleMailMCP", "browser_download_url": "%s/../../../../attacker-org/evil-repo/releases/download/v1/CheAppleMailMCP"}\n' "$DL_PREFIX"
    printf ']}\n'
} > "$SCEN/api_pinned.body"
write_mock_binary_content "DOTSEG-PWNED"
run_wrapper
assert "dot-segment (many components): nothing installed" "! grep -q DOTSEG-PWNED $TEST_DIR/out.txt"
assert "dot-segment (many components): refused" "grep -q 'no download URL found' $TEST_DIR/err.txt"

reset_state
write_plugin_json "2.99.0"
{
    printf '{"assets": [\n'
    printf '  {"name": "CheAppleMailMCP", "browser_download_url": "%s/../CheAppleMailMCP"}\n' "$DL_PREFIX"
    printf ']}\n'
} > "$SCEN/api_pinned.body"
write_mock_binary_content "DOTSEG2-PWNED"
run_wrapper
assert "dot-segment (regex-shaped): nothing installed" "! grep -q DOTSEG2-PWNED $TEST_DIR/out.txt"
assert "dot-segment (regex-shaped): refused" "grep -q 'no download URL found' $TEST_DIR/err.txt"

# ============================================================
echo "Case 21 (#398 R3): a #fragment cannot satisfy the basename check"
# ============================================================
# curl drops the fragment before the request, so `${u##*/}` sees
# CheAppleMailMCP while the server is asked for `other-asset`.
reset_state
write_plugin_json "2.99.0"
{
    printf '{"assets": [\n'
    printf '  {"name": "CheAppleMailMCP", "browser_download_url": "%s/v2.99.0/other-asset#/CheAppleMailMCP"}\n' "$DL_PREFIX"
    printf ']}\n'
} > "$SCEN/api_pinned.body"
write_mock_binary_content "FRAG-PWNED"
run_wrapper
assert "fragment: nothing installed" "! grep -q FRAG-PWNED $TEST_DIR/out.txt"
assert "fragment: refused" "grep -q 'no download URL found' $TEST_DIR/err.txt"

# ============================================================
echo "Case 22 (#398 R3): an error PAGE on the no-digest path is refused"
# ============================================================
# This is an explicit acceptance item of #392's own diagnosis ("--fail 擋錯誤頁")
# that had NO test: Case 5 exercises the HTTP-status gate (404), never the
# body-shape gate. Removing looks_like_html entirely left the suite fully green.
reset_state
write_plugin_json "2.99.0"
write_api api_pinned "2.99.0" no          # no .sha256 -> the unverified path
printf '<!DOCTYPE html>\n<html><body>504 Gateway Timeout</body></html>\n' > "$SCEN/binary.body"
run_wrapper
assert "html body: refused, not chmod+exec'd" "grep -q 'HTML page, not a binary' $TEST_DIR/err.txt"
assert "html body: nothing claimed as installed" "! grep -q 'installed v' $TEST_DIR/err.txt"

# ============================================================
echo "Case 23 (#398 R3): a stale marker for a DIFFERENT pin is cleared"
# ============================================================
# Every other case writes marker pin == plugin pin (2.99.0), so the
# clearing branch was never entered; deleting it left the suite green.
# The installed version ALREADY equals the pin, so no download happens and the
# post-install `rm -f` never runs. Only the pre-clearing branch can remove the
# marker here. The first version of this case had installed != pin, so the
# success path cleared the marker either way and deleting the branch under test
# left the suite green (caught by mutation-testing).
reset_state
seed_installed "MOCK-RUN-299" "2.99.0"
write_plugin_json "2.99.0"
printf '2.50.0 %s miss\n' "$(date +%s)" > "$MARKER"   # marker for a pin we no longer want
run_wrapper
assert "no download needed (already at the pin)" "grep -q MOCK-RUN-299 $TEST_DIR/out.txt"
assert "stale marker for another pin was cleared" "[ ! -f $MARKER ]"

# ============================================================
echo "Case 24 (#398 R3): a FUTURE-dated marker epoch cannot suppress forever"
# ============================================================
# Clock skew or a hand-edit could park the epoch years ahead; without the
# guard the TTL comparison never lapses.
reset_state
seed_installed "OLD-RUN-298" "2.98.0"
write_plugin_json "2.99.0"
printf '2.99.0 %s miss\n' "$(( $(date +%s) + 315360000 ))" > "$MARKER"   # +10 years
write_api api_pinned "2.99.0" yes
write_mock_binary_content "MOCK-RUN-299"
write_matching_sha
run_wrapper
assert "future epoch ignored: the pin was retried" "grep -q MOCK-RUN-299 $TEST_DIR/out.txt"
assert "future epoch: converged to the pin" "[ \"\$(cat $SIDECAR)\" = 2.99.0 ]"

# ============================================================
echo "Case 25 (#398 R3): SemVer build metadata survives into runtime state"
# ============================================================
# Round 1 used `tr -cd` on the version token, which silently DROPPED `+build`;
# the hook then compared the mangled value against the raw plugin.json value,
# so they could never match again. No test used such a version.
reset_state
write_plugin_json "2.99.0+build.7"
write_api api_pinned "2.99.0+build.7" yes
write_mock_binary_content "MOCK-BUILDMETA"
write_matching_sha
run_wrapper
assert "build metadata: installed" "grep -q MOCK-BUILDMETA $TEST_DIR/out.txt"
assert "build metadata preserved in runtime state (not stripped)" "grep -q '\"version_at_spawn\":\"2.99.0+build.7\"' $RUNTIME"

# ============================================================
echo "Case 26 (#398 R3): a present-but-BROKEN shasum falls through to openssl"
# ============================================================
# Case 17 removes both tools. The fix was written for the other scenario --
# shasum exists but fails (Apple is sunsetting its perl runtime) -- and round 1
# dispatched on `command -v shasum` alone, so openssl was structurally
# unreachable and the caller reported "no sha256 tool available".
reset_state
BROKEN="$TEST_DIR/broken-shasum"
mkdir -p "$BROKEN"
printf '#!/bin/sh
exit 1
' > "$BROKEN/shasum"      # present, always fails
chmod +x "$BROKEN/shasum"
if ! command -v openssl >/dev/null 2>&1; then
    echo "  SKIP  Case 26: openssl not available to fall through to" >&2
else
    write_plugin_json "2.99.0"
    write_api api_pinned "2.99.0" yes
    write_mock_binary_content "MOCK-OPENSSL"
    openssl dgst -sha256 -r "$SCEN/binary.body" | awk '{print $1}' > "$SCEN/sha.body"
    : > "$TEST_DIR/out.txt"; : > "$TEST_DIR/err.txt"
    HOME="$TEST_HOME" PATH="$BROKEN:$RUN_PATH" WRAPPER_TEST_SCEN="$SCEN" \
        WRAPPER_TEST_TIMEOUT_LOG="$TEST_DIR/curl-timeouts.log" \
        "$FAKE_PLUGIN/bin/che-apple-mail-mcp-wrapper.sh" \
        > "$TEST_DIR/out.txt" 2> "$TEST_DIR/err.txt" || true
    assert "broken shasum: openssl fallback reached, install verified" "grep -q 'sha256 verified' $TEST_DIR/err.txt"
    assert "broken shasum: did NOT report 'no sha256 tool'" "! grep -q 'no sha256 tool' $TEST_DIR/err.txt"
fi

# ============================================================
echo "Case 27 (#398 R3): the hook names a VERIFY marker as possible tampering"
# ============================================================
# Cases 12/13/14 all write `miss` markers, so the hook's verify branch --
# the one that distinguishes a digest mismatch from an upstream outage --
# was never executed.
reset_state
mkdir -p "$TEST_HOME/bin"
( exec -a CheAppleMailMCP-mock sleep 1000 ) >/dev/null 2>&1 &
MOCK_PID=$!
echo "$MOCK_PID" >> "$TEST_DIR/mock_pids"
sleep 0.2
write_plugin_json "2.99.0"
printf '{"pid":%d,"started_at":1,"version_at_spawn":"3.0.0","degraded_pin":"2.99.0"}\n' "$MOCK_PID" > "$RUNTIME"
printf '2.99.0 %s verify\n' "$(date +%s)" > "$MARKER"
: > "$TEST_DIR/err.txt"
HOME="$TEST_HOME" "$FAKE_PLUGIN/hooks/session-start.sh" 2> "$TEST_DIR/err.txt"
assert "verify marker: hook names it as a verification failure" "grep -q 'failed sha256 verification' $TEST_DIR/err.txt"
assert "verify marker: does NOT call it an upstream outage" "! grep -q 'unavailable upstream' $TEST_DIR/err.txt"
kill -KILL "$MOCK_PID" 2>/dev/null || true

# ============================================================
echo "Case 28 (#398 R3): no bash-4-only syntax in shipped scripts"
# ============================================================
# The shebang is /bin/bash, which on macOS is 3.2. `${x,,}`, declare -A,
# mapfile and friends PARSE fine there (so `bash -n` is clean) and fail at
# expansion time. Round 3 shipped exactly that and the suite went 0/76 with a
# failure that looked like a logic bug. Grep the class, ignoring comments.
BASH4_HITS=0
for f in "$FAKE_PLUGIN/bin/che-apple-mail-mcp-wrapper.sh" "$FAKE_PLUGIN/hooks/session-start.sh"; do
    stripped=$(sed 's/[[:space:]]*#.*$//' "$f")
    if printf '%s' "$stripped" | grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?[,^]{1,2}\}|declare[[:space:]]+-A|local[[:space:]]+-A|\b(mapfile|readarray)\b'; then
        BASH4_HITS=$((BASH4_HITS + 1))
        echo "    bash-4 construct in $f" >&2
    fi
done
assert "shipped scripts are bash-3.2 clean" "[ $BASH4_HITS -eq 0 ]"

# ============================================================
echo ""
echo "============================================="
echo "Results: $PASS pass, $FAIL fail"
echo "============================================="
if [ "$FAIL" -gt 0 ]; then
    printf "%b\n" "$FAIL_DETAIL"
    exit 1
fi
exit 0
