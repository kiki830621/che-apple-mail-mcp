# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> ⚠ This file was bootstrapped by `changelog-tools:changelog-init` from the
> `plugin.json` description field. Section categorization is best-effort —
> review and refine `Added` / `Changed` / `Fixed` etc. as needed.

## [Unreleased]

### Fixed

- **The binary download chain verifies what it installs — and a degraded state
  can now end**
  ([#392](https://github.com/PsychQuant/che-apple-mail-mcp/issues/392),
  [#393](https://github.com/PsychQuant/che-apple-mail-mcp/issues/393)).
  Downloads are sha256-verified against the release's own asset list, and
  verification **fails closed**: the only unverified install is a release that
  genuinely publishes no digest. Being unable to *compute* one — no hash tool,
  or a `shasum` that exists but is broken — is a refusal, not a downgrade, and
  the `openssl` fallback is now actually reachable in that case. The asset is
  selected by exact basename from a URL list pinned to this repo's own release
  downloads, so neither a minified API response nor a spoofed body can install
  the wrong file or point elsewhere. Temps are unique (no shared-`.tmp` TOCTOU)
  and now removed by a trap, so an interrupted spawn no longer leaks ~18 MB
  into `~/bin`. The installed mode is set explicitly, and a failed `chmod` does
  not install.

  **The retry story, which round 1 got backwards.** A definitive pinned-tag 404
  falls back to latest exactly once and records a marker with a 24h TTL;
  transient failures (403 rate-limits, timeouts, 5xx) keep the installed binary
  untouched. Runtime state records the version ACTUALLY installed (read from the
  sidecar; `unknown` when it is missing — never the wishful pin), so the
  session-start hook can finally see a failed download. `degraded_pin` tells
  that hook when a mismatch is deliberate — but **only when a marker backs it**,
  and the hook now re-validates that marker (existence, pin, TTL, clock skew)
  instead of trusting the field. Round 1 trusted it blindly, which made the
  degraded state permanent: the TTL is only ever evaluated by the wrapper, and
  the wrapper cannot run again until a kill respawns it, so at TTL+1h the hook
  was still suppressing the kill and the pin was never retried — deleting the
  marker by hand did not help either, because nothing consulted it. Round 1 also
  stamped `degraded_pin` on transient failures, suppressing the one thing that
  triggers a retry. The invariant is now stated in the wrapper and locked by
  tests: `degraded_pin` is set **if and only if** a marker was written.

  Binary downloads get a 300-second budget again — unifying the curl calls
  behind one helper had put the 18 MB binary on the metadata call's 30 seconds,
  which hard-fails a fresh install on any normal-but-slow link. Legacy plugins
  without `binary_version` keep the old semantics (the #73 spurious-kill trap
  stays closed). A corrupt or hand-edited marker is ignored rather than fatal,
  and its epoch can no longer reach bash arithmetic, where a crafted value is
  executed as a command. The marker's reason field is finally read, so a digest
  mismatch is reported as a possible tampering signal instead of "unavailable
  upstream".

  **The asset-URL host pin was not a pin.** Round 2 validated the URL as a
  string (`starts with https://github.com/<repo>/releases/download/`) and then
  handed it to curl, which normalises the path *before* requesting it. Verified
  with `curl -w '%{url_effective}'`: a URL beginning with the correct prefix but
  carrying `../../../..` resolves to `github.com/attacker-org/evil-repo/...`,
  and because the `.sha256` is chosen by the same rule it comes from the same
  attacker path — so verification PASSES and the wrapper prints
  `(sha256 verified)` while exec'ing someone else's binary. A `#fragment` is
  likewise dropped before the request, so the basename check can be satisfied
  by text the server never sees. The URL is now validated structurally: exactly
  two path components after `/download/`, no query, no fragment, and no
  dot-segment in any spelling.

  Test suite: **95 asserts across 28 mock-curl scenarios**. Round 3 audited the
  round-2 claim that "every fix was mutation-tested" and found it **false**:
  five fixes shipped with no regression coverage at all (the stale-marker
  clearing, the HTML-error-page refusal — an explicit acceptance item of #392's
  own diagnosis — the `openssl` fallback for a present-but-broken `shasum`,
  SemVer build metadata surviving `json_escape`, and the future-dated-epoch
  guard), plus the hook's `verify` branch, which every existing case avoided by
  writing `miss` markers. All now have cases.

  Nine mutations run, nine caught — **after** two of the new cases were
  themselves caught testing nothing: the dot-segment payload was stopped by the
  component-count regex before it ever reached the dot-segment check, and the
  stale-marker case had the download succeed, so the post-install cleanup
  cleared the marker whether or not the branch under test existed. Both were
  rewritten to exercise the code they name. A ninth case now greps for
  bash-4-only syntax: the shebang is `/bin/bash`, which is 3.2 on macOS, where
  `${x,,}` parses cleanly under `bash -n` and fails at expansion time — this
  round shipped exactly that and the suite went to 0/76 with a failure that
  read like a logic bug.

### Changed

- `binary_version` 2.27.0 → **2.28.0**，讓 v2.46.0 的 first-run FDA assist（mail#355）真正生效。該 hook 從落地起就是 **no-op**：它以版本閘擋住 2.28.0 以前的 binary，因為更舊的版本會把 `--check-fda --quiet` 當成普通 `--check-fda` 解析、印出訊息並打開系統設定 —— 正是它要避免的騷擾。binary v2.28.0 已發布（signed + notarized），閘門現在開了。

  同版本一併到位的 binary 修復：QP 內文解碼（mail#339，19/28 封信曾寫成不可讀）、`list_attachments` 對自寄信件回 `[]` 的靜默漏抓（mail#365）、`.mcpb` 改由簽章 universal binary 打包（mail#323 —— 在此之前 Desktop 安裝拿到的是 ad-hoc binary，**結構上無法**被授予 Full Disk Access）。

### Added

- **Coverage Audit 新增 8d 方向覆蓋（direction balance）** —— 稽核查得出「已知的信有沒有完整落地」，卻查不出「整批只有一半的對話」（mail#350）。實證：四個學會的歸檔庫 **266 封全部 `direction: received`、零寄件**，8a/8b 每次報綠燈；對其中一個補跑 Step 3 recipe (2) 的 Sent-scoped recipient 搜尋，撈出 **10 封從未歸檔的寄件**，最早回溯 2024-07 —— 「來回協商」的 thread 裡只剩對方講的話。

  根因是分母的來源：8a 比對已歸檔信的附件、8b 比對已歸檔 subject 的兄弟，**兩軸的分母都來自 archive 內部已有的東西**，沒有任何一軸能看見「應該存在但從未被搜到」的一整邊。方向分布是唯一從 archive 內部就看得出「搜尋策略漏了一邊」的訊號 —— 它不問「這封信完整嗎」，問「這批信的形狀對嗎」。

  8d 純讀磁碟 frontmatter，封閉列舉三條判定：零寄件且 ≥10 封 → 警告；同上且 corpus 內有回覆串證據（`in_reply_to` 非空或 `Re:`/`Fwd:` 主旨）→ 升級為強訊號；有 `direction_inferred: true` 的封數 → 註明該數不可當方向統計的可信基礎（mail#351）。**單向本身可以是正確的**（純電子報／公告訂閱），所以門檻以下與 `sent > 0` 都明確不發話，且三條都只報告、不阻擋 run。警告一併輸出可直接複製的補救指令。
- **First-run Full Disk Access assist**（session-start hook，mail#355）—— `--setup` 視窗自 mail#213/#214 就做好了（live FDA 狀態、開啟對的系統設定頁面、複製 binary 路徑），但**安裝路徑上沒有任何一個環節會打開它**：wrapper 只比對版本、本 hook 只殺 stale process、README 只在深處的參考章節提過 `--setup`。等於那顆「方便按」的按鈕只有已經知道它在哪的人按得到。

  hook 現在在第一次啟動時，若 FDA 未授權就替使用者打開該視窗。刻意的四個限制：**每台機器只提一次**（marker，不做重複騷擾）；**只在真的缺授權時**；視窗以 **detached** 方式啟動（它跑 GUI runloop，否則會把 session start 卡死）；marker 在啟動**之前**寫入，所以失敗不會變成迴圈。

  這段必須放在 staleness 區塊**之前** —— 那個區塊在 `$RUNTIME_FILE` 不存在時就 early exit，而那正是全新安裝的狀態，也就是本功能唯一在意的那一次。

  舊 binary 以版本閘跳過（需 binary **2.28.0+**）：更舊的版本會把 `--check-fda --quiet` 當成普通 `--check-fda` 解析，那會**印出訊息並打開系統設定** —— 正是本功能要避免的騷擾。在 2.28.0 發布前，這段一律 no-op。

## [2.44.1] - 2026-08-05

### Fixed
- **`binary_version` pin 與 v2.44.0 自身的 CHANGELOG 相矛盾** —— v2.44.0 的 archive-mail Step 5.0 條目明載該 SOP 需要 **binary v2.26.0+**（伺服器端依 sender identity 逐信判定 `direction`，mail#316），但同一個 release 的 `plugin.json` 仍 pin `binary_version: 2.25.0`，`marketplace.json` 更落後到 `2.24.0`（三方不一致）。wrapper 依 pin 下載，使用者實際跑的是**沒有該修復**的 binary：照新 SOP 走（整批送、不傳 `mailbox`）會讓整批 `direction` 全標成 `received` —— 2026-08-05 一次 51 封的實跑中 24 封自寄信被誤標，需事後逐檔更正。失效是安靜的：manifest `errors: 0`、無 `direction_inferred` 訊號（那是 v2.26.0 才有的負向欄位），SOP 的版本邊界判準因此也無從觸發。

  現同步三處到 `2.26.0`。使用者一併取得 v2.26.0 的其餘修復：mail#313（APFS 大小寫檔名碰撞導致的**靜默資料遺失** —— manifest 回報兩檔 written、磁碟只有一個）、mail#320（SIGPIPE 不再殺掉 server）、mail#317（SQLite mailbox filter 不再把 caller 字串當 LIKE pattern）。

  無 SOP 內容變更 —— v2.44.0 的 shell 本來就是照 v2.26.0 寫的，本次只是讓 pin 追上它。

## [2.44.0] - 2026-08-02

### Fixed
- **archive-mail: Step 5.0 no longer partitions the corpus into direction batches — the server derives `direction` per email from sender identity** (mail#316, binary v2.26.0+). The old discipline derived direction from "which mailbox the message lives in" (a whole-batch `mailbox`-substring label plus a client-side two-batch split), which is structurally wrong for Gmail: sent mail lives in `[Gmail]/全部郵件`, a bidirectional superset that carries no direction information — self-sent messages archived from All Mail were persisted as `direction: received`. Step 5.0 is now a single whole-corpus call (no `mailbox` param, no partition, no `mailbox: "Sent"` literal trick); the SOP documents the `direction_inferred: true` fail-open disclosure (EWS-only setups) with a Step 7 reporting rule and a version boundary for pre-v2.26.0 binaries. Step 5.1's frontmatter spec gains the explicit sender-identity rule (sender ∈ union of all accounts' own addresses → `sent`), replacing the removed — and false — claim that the per-email path could recover direction from the message's own mailbox; the mail#261 All-Mail warning now names the direction consequence too.
- **archive-mail: synthetic `message_id` placeholders are now forbidden, detected, and repairable** (mail#319). The frontmatter spec's `message_id` was the only frozen field with no missing-value rule, and a past session improvised `synthetic:<timestamp>` placeholders — whose run-time timestamps made every re-run see the same email as new (84 placeholder files, 12 silent duplicates in one run, every gate green). Now: missing Message-ID → refetch via `get_email_headers`, else `message_id: ""` + `message_id_missing: true` (surfaces via Step 8.5's unparseable branch); placeholders explicitly forbidden; Step 8.5 Phase 1 gains a `synthetic_placeholder` classification (own report line, never folded into verified/repaired); all dates must carry a timezone offset (naive-local-as-UTC was 8h off in the same cohort). New one-off `/archive-mail-repair-synthetic-ids` command re-keys existing placeholder files conservatively (exact-match ladder, never merges on ambiguity, quarantines duplicates instead of deleting).
- **archive-mail: Step 8a attachment audit is content-aware** (mail#314). The audit compared file COUNTS only, so 0-byte attachments passed as 100% complete for ~11 weeks. 8a.1/8a.2 now stat every file and flag `0-byte attachment (download appears to have failed silently)` alongside the existing count warnings; the 8c report lists them; a one-off `find … -size 0` remediation sweep is documented. Pairs with the server-side fix (mail PR #330): `save_attachment` now stat-verifies its own successes and reports `(N bytes)`.

## [2.43.0] - 2026-08-01

### Added
- Imported `rules/compose-wrapper-free.md` from the server repo (canonical copy lives there): the formal-mail cite-block discipline — wrapper-free eligibility for `compose_email`/`create_draft`, the mandatory `[legacy path — …]` disclosure, custom-sender / display-name-recipient / attachment recipes, and the TCC fallback ladder (`open_mailto` on -1743, never a silent wrapped body). Plugin users previously got none of this guidance.

### Changed
- `CLAUDE.md` lists the new rule under Rules.

### Added
- **`distributed_archives` config field — first-class capture-then-distribute** ([mail#285](https://github.com/PsychQuant/che-apple-mail-mcp/issues/285)). Generalizes Step 2.1's sibling-archive dedup (previously only symlinks physically under `output_dir`, #49) to an opt-in YAML list of arbitrary distribution-target archive dirs. Use case: a broad capture-layer `filter` config pulls all relevant mail into a staging dir; the user then moves each message belonging to a sub-project into that sub-project's own archive. Before, the next capture run re-pulled the already-distributed mail (it still matches the filter, and moving it dropped it from the capture `output_dir` + index → dedup saw "new"). Now Step 2.1 folds the `message_id` frontmatter of every dir listed in `distributed_archives:` into the same `EXTENDED_DEDUP_IDS` set, so distribution sticks with **no manual tombstone**. Read-only (find + head + awk, never mv/rm/>), bounded (`-maxdepth 2`), and — unlike the silent symlink scan — a **missing distributed dir WARNS** to stderr (a wrong path would silently miss dedup and re-pull, the exact pain being fixed). 100% backward compatible: unset `distributed_archives:` is a no-op, identical to v2.37.0. Closes #285.

### Fixed
- **archive-mail `last_updated` 計算對 RFC822 entry date 失效**（[mail#275](https://github.com/PsychQuant/che-apple-mail-mcp/issues/275)）。Step 6 / Step 8.5 的 max(date) 原以 `date[:10]` 字典序比較，只涵蓋 ISO 兩變體 — RFC822（`Thu, 25 Jun …`）切片後星期縮寫字典序恆大於數字，任一 RFC822 entry 都會贏過全部 ISO entry，`last_updated` 被寫成 `Wed, 01 Ju` 類無效值（並汙染 `dedup_strategy: last_archived` 的增量搜尋 date_from）。兩處計算改為 robust `to_ymd()`（ISO 快篩 + `email.utils.parsedate_to_datetime`，parse 失敗排除於 max 並在 reconcile 摘要揭露）；上游 enforcement：Step 5.1 明文 RFC822 Date header 必先轉 ISO 再寫 frontmatter，Step 8.5 Phase 1 孤兒補寫時將非 ISO date 正規化（歷史汙染的收斂點）。

## [2.20.0] - 2026-05-18

### Added
- **#76 + #84 Layer 2 corpus refinement** — six opt-in config fields for `/archive-mail` (`sender_includes` / `sender_excludes` / `recipient_includes` / `recipient_excludes` / `subject_includes` / `subject_excludes`) implementing a two-layer corpus model: `filters` defines Layer 1 search-time corpus; the six new fields are Layer 2 post-fetch refinement applied after Step 3 fetch and before Step 4 dedup. Thread-coherent (any message matching includes keeps the whole thread; any matching excludes drops it), case-insensitive substring matching with bare-value normalization (display name stripped for sender / recipient, `Re:` / `RE:` / `Fwd:` / `FW:` / `转发:` / `轉寄:` prefixes stripped for subject), excludes-precedence on the same axis (blacklist wins when both lists match the same email). New spec `openspec/specs/archive-mail-corpus-refinement/spec.md`. Step 4.5 Phase 2 preview gains a refinement statistics block (kept / dropped totals + per-category breakdown) when at least one field is non-empty; omitted entirely when all six unset. 100% backward compatible — unset and empty lists behave identically to v2.19.7. Closes #76 + #84.
- **Malformed refinement value detection** — Step 1 config parsing now validates the six refinement fields and aborts at parse time with `Error: <field> must be a YAML multi-line block-style sequence of strings ...` plus non-zero exit when a scalar or unsupported inline list (other than `[]`) is provided. Empty-string entries within a sequence (`sender_excludes: [""]`) are silently dropped at parse time and behave identically to `sender_excludes: []`.

### Changed
- **plugin.json description** — narrative re-led with the v2.20.0 corpus-refinement story; pre-v2.20.0 release history preserved verbatim.

## [2.19.6] - 2026-05-12

### Fixed
- **#73 hook compare prefers `.binary_version` over `.version`** — `hooks/session-start.sh` jq query 改 `'.binary_version // .version // ""'`,prefer binary tag(post-#77 two-field schema),fallback shell version 維持 backward compat。修掉 v2.18.0 ~ v2.19.5 期間每次 session start spurious SIGTERM(runtime `version_at_spawn` 是 binary tag e.g. `2.8.5`,但 hook 比對 `plugin.json.version` shell `2.19.5` 永遠 mismatch → kill MCP PID → respawn → +5s grace delay + `⚠ Killing stale CheAppleMailMCP PID ...` audit noise per session)。
- **Test coverage**: tests/test-session-start-hook.sh 加 Case 7(`binary_version` present + matches runtime → no kill)+ Case 8(`binary_version` absent → fallback `.version`)+ helper `write_plugin_json_with_binary`。TDD RED phase Case 7 在 fix 前 FAIL(stderr `Killing stale` + PID killed),GREEN 後 22/22 PASS。

### Notes
- Pure shell-only patch release;binary v2.8.5 不變
- 解 #77 fix 留下的 incomplete migration(wrapper 端已用 `binary_version`,hook 端沒同步)
- Auto-close trap meta-issue([PsychQuant/issue-driven-development#74](https://github.com/PsychQuant/issue-driven-development/issues/74))filed during close — anti-trailer warning text 含 literal `Closes #N` substring 觸發 GitHub auto-close,本 v2.19.6 incident 首次踩到
- 2 Low test-coverage gaps deferred to [psychquant-claude-plugins#67](https://github.com/PsychQuant/psychquant-claude-plugins/issues/67):Case 9(new-schema mismatch kill path)+ Case 10(empty-string binary_version edge)
- Refs PsychQuant/psychquant-claude-plugins#73 #74

## [2.19.5] - 2026-05-11

### Added
- **#16 nested markdown lists** — depth-aware `<ul>`/`<ol>` rendering for nested list structures
- **#17 markdown tables** — `<table>`/`<thead>`/`<tbody>` rendering with per-column alignment
- **#89 `list_emails` SQLite fallback** — AppleScript path retained for compat, but new SQLite fast-path delivers 3× IPC reduction

### Fixed
- **#26 malformed multipart throws** — handler fallback for missing/corrupt MIME boundary parts no longer crashes `get_email`

### Notes
- Binary v2.8.4 → v2.8.5;swift test 313 → **342 (+29 tests over v2.8.0 series)**
- Refs PsychQuant/che-apple-mail-mcp#16 #17 #22 #26 #28 #89

## [2.19.4] - 2026-05-11

### Added
- **#28 `crossValidateAttachments` helper** — extracted from inline filter closure shared between `list_attachments` and `list_attachments_batch`;6 unit tests covering filter behavior (matching / empty / missing-name / non-String-name / all-fields-preserved)
- **#22 Item D — code fence language hint** — emits `class="language-<hint>"` on `<pre><code>` per CommonMark recommended pattern

### Documentation
- **#22 Items A/B/C** — documented in `spec.md` as Foundation parser limitations with workarounds (already-fixed indent / U+001E vanishingly improbable / bold-in-link Foundation limitation)

### Notes
- Binary v2.8.3 → v2.8.4;swift test 321 → 329 (+8 tests)
- Refs PsychQuant/che-apple-mail-mcp#22 #28

## [2.19.3] - 2026-05-11

### Removed
- **#82** — 4 dead AppleScript `script` variable declarations
- **#83** — 3 deprecated `text(_:metadata:)` MCP SDK calls migrated to current API

### Changed
- **#84** — Retrofitted 31 lenient `XCTAssertTrue(script.contains)` assertions to `assertOrdered` for property-in-tell-block enforcement

### Notes
- Binary v2.8.2 → v2.8.3;pure cleanup,zero behavior change,swift test 321/0/8 unchanged
- Refs PsychQuant/che-apple-mail-mcp#82 #83 #84

## [2.19.2] - 2026-05-11

### Added
- **#87 `sanitize_links` hardening grab-bag** — 5 hygiene items:
  - Allowlist tripwire test pinning `{http, https, mailto, tel}`
  - 6 bypass-class regression tests
  - `htmlEscape` defense-in-depth on `href` interpolation
  - Empty-scheme behavior documented in 4 schema descriptions
  - Payload-scaling latency test on synthesized 10×5MB fixture

### Notes
- Binary v2.8.1 → v2.8.2;zero behavior change,swift test 313 → 321 (+8 tests)
- Refs PsychQuant/che-apple-mail-mcp#87

## [2.19.1] - 2026-05-11

### Documentation
- **#86 `sanitize_links` schema description consistency** — XSS rationale + mode-restriction qualifier repeated across `create_draft` / `reply_email` / `forward_email` / `compose_email` (fixes tool-selecting LLM blindspot from cluster A)

### Notes
- Binary v2.8.0 → v2.8.1;pure schema text change,no behavior impact,swift test 313/0/8 unchanged
- Refs PsychQuant/che-apple-mail-mcp#86

## [2.19.0] - 2026-05-11

### Added
- **#19 `sanitize_links` opt-in URL scheme allowlist for markdown mode** — defends against `[click](javascript:alert('xss'))` and `data:`/`file:`/`vbscript:` URLs via closed allowlist `{http, https, mailto, tel}`;default `false` preserves backwards compat
- **#85 formal spec.md Requirement+Scenarios** — codifies the `sanitize_links` contract + builder-layer wiring contract tests pinning `sanitizeLinks` forwarding across the 4 script-builder functions
- **#73 `extractHTMLBody` base64+UTF-8-QP decoding fixes** — multipart HTML with quoted-printable + UTF-8 nested transfer encodings now decode correctly

### Changed
- **#20** — dead spec scenario delete + count-free CHANGELOG + `assertOrdered` helper
- **#21** — reply/forward AppleScript-html-denial documentation
- **#25** — `list_attachments_batch` SQLite+`.emlx` cross-validation parity
- **#27 + #32** — `attachmentNames` <200ms latency budget test + parity invariant

### Notes
- Binary v2.7.2 → v2.8.0;47 → **48 tools** (sanitize_links param surface);swift test 309 → 313 / 0 failures / 8 skipped
- Refs PsychQuant/che-apple-mail-mcp#19 #85 #73

## [2.18.1] - 2026-05-10

### Fixed
- **#77 wrapper sidecar tracks actual binary tag** (not plugin shell version) — two-part fix:
  1. `plugin.json` adds explicit `binary_version` field (e.g. `"2.7.2"`),disambiguating from plugin shell's own `version` (e.g. `"2.18.1"`)。Wrapper reads it preferentially;falls back to `version` for plugins that haven't migrated。
  2. Wrapper writes the **actual downloaded binary tag** to the sidecar,parsed from the GitHub release URL path between `/releases/download/` and the next `/`。即便 `DESIRED` 寫錯(legacy 走 shell `version` 的 plugin),sidecar 仍誠實反映 disk 上實際版本 — 下次 compare honest,不再 structurally lying

### Notes
- Binary v2.7.1 → v2.7.2 (#71 fallback parity + cluster #61-64 hardening);smoke tested wrapper bash syntax + plugin.json validity + binary_version field extraction + URL tag parser
- Refs PsychQuant/che-apple-mail-mcp#77

## [2.18.0] - 2026-05-10

### Added
- **Staleness Detection (Refs PsychQuant/che-apple-mail-mcp#76)**:wrapper 在 `exec binary` 前 atomic-write `~/bin/.CheAppleMailMCP.runtime.json` 紀錄 `{pid, started_at, version_at_spawn}`;新增 `hooks/session-start.sh`,Claude Code session 啟動時偵測 runtime state 與 `plugin.json` 的 version drift。Drift + PID alive + `command` field 含 `CheAppleMailMCP` 三條件成立 → SIGTERM(+5s grace,SIGKILL fallback)stale PID,讓 host respawn 取新 binary。
- **`hooks/session-start.sh`**(NEW,~70 行 bash)— 全 graceful-skip:`jq` / `ps` 缺、runtime file 缺、plugin.json 缺、PID 已死、PID command field 不含 `CheAppleMailMCP`(防 PID-reuse 誤殺)→ 全部 silent exit 0,never block session start。
- **`tests/test-session-start-hook.sh`**(NEW)— 6 case integration test(無 runtime file / version match / version mismatch+alive / mismatch+dead / jq missing / plugin.json missing),全部用 `exec -a CheAppleMailMCP-mock sleep` 模擬 MCP process。16/16 PASS。

### Changed
- `bin/che-apple-mail-mcp-wrapper.sh`:`exec binary` 前多一段 atomic write runtime state file;失敗 silent skip(`|| true`),never block spawn。Wrapper 既有 sidecar version-check 邏輯**不動**(remains first line of defense for spawn-time download)。

### Notes
- Plugin minor bump 2.17.0 → 2.18.0(new feature surface,additive,backward compat)。Plan 走 IDD `/idd-plan` approval gate,EnterPlanMode 已 user-approved。
- 解決今日 #72 incident 的 deployment 端 root cause:即使 binary v2.7.1 已 release + plugin shell 已 bump,user 當下 session 的 in-memory MCP 仍跑舊 v2.7.0 binary 直到 manual `kill <pid>` + 重啟 Claude Code。新 hook 把這條 staleness window 自動關掉。
- Sister issue split:[`PsychQuant/psychquant-claude-plugins#58`](https://github.com/PsychQuant/psychquant-claude-plugins/issues/58)— `plugin-tools:plugin-update` 結尾應主動警告 user(sender-side 補強),獨立 PR。
- Out-of-scope:**#77**(sidecar tracks shell version not binary version)、**#78**(server-side markdown export API)獨立評估。

## [2.17.0] - 2026-05-09

### Added
- **Workspace Layout Detection (#49)**:當 `output_dir` 既無 `$ARGUMENTS[1]` 也無 `${CONFIG_FILE}` 的 `output_dir:` 欄位給定時,probe 工作目錄按 `communications/email/` → `correspondence/emails/` → baseline default `communication/emails` 順序解析。Detection-first not prescriptive — adapt 到 user 既有 layout,不 push canonical convention。Existing user 有 explicit config 的 100% backward-compat(detection 不 fire)。
- **Sibling-archive dedup extension (#49)**:`${output_dir}` 下若有 symlinked subdirectory(transitioned-project pattern,e.g. `communications/email/application/` → `applications/completed/.../emails/`),自動讀其下 markdown 的 `message_id:` YAML frontmatter 併入 in-memory dedup set。`find -P -maxdepth 2`,read-only,never writes to symlink target。Composes with `dedup_strategy = index | both`(skip on `last_archived`)。
- **Ambiguity guard**:當 `communications/email/` 與 `correspondence/emails/` **同時存在且都有 `*.md`** 時,refuse to guess,abort with explicit pin recommendation(指 user 寫 `output_dir:` in config)。Mid-migration workspace 必須 explicit 指定避免 dedup-index split-brain。
- **Detection 透明度**:啟動時 `🔍 Detected output_dir: <path> (from layout probe)` log,以及 dedup extension 觸發時 `🔗 Extended dedup with N entries from sibling archives:` log,讓 verify / diagnose 能看到 path resolution 結果。
- **README Workspace Patterns section**(v2.17.0+):文件三種 layout、precedence(高→低:`$ARGUMENTS[1]` → config `output_dir:` → detection → default)、symlink coexistence pattern、ambiguity guard。

### Notes
- Plugin minor bump 2.16.1 → 2.17.0(new feature surface,additive,backward compat)。Plan 走 IDD `/idd-plan` approval gate,EnterPlanMode 已 user-approved 後才 chain 到 implement。
- Out-of-scope follow-ups filed:**#50** parallel `documents_dir` detection,**#51** companion-commands(`archive-mail-view` / `archive-mail-rebuild-threads` / `archive-mail-migrate`)detection consistency,Tier C' per-contact mode(deferred until N≥3 evidence)。
- Sister-bug observation during scout:v2.16.1 release(2026-05-09 commit `8089765`)沒寫 CHANGELOG entry — 屬 KAC sync drift,**留給 follow-up issue 補 backfill**(本 PR 不混進)。

## [2.16.1] - 2026-05-09

### Notes
- **Bump-only release** to ship binary v2.7.1 + catch up tool count drift in `plugin.json` / `marketplace.json` descriptions (44 → 47)。Shell 邏輯 v2.16.0 不變,本版本只更新 wrapper 拉取的 binary tag。Backfilled per **#52** (sister concern from #49) — original v2.16.1 commit `8089765` 漏寫此 entry,KAC invariant 要求 every released version 有 entry。
- Binary v2.7.1 ships:
  - **#72** base64 decoding fix — attachments with unusual MIME encoding now save correctly
  - **#69** SQLite fast-path stderr logging — silent fallback to AppleScript path now visible in logs
  - **#66** `.partial.emlx` attachment fix — incomplete download artifacts no longer crash get_email parsing
- Tool count drift catch-up (44 → 47): commit `8089765` 只 touched `plugin.json` + `marketplace.json` description fields(README 未變動)。per `tool-readme-sync` audit pattern,後續 release 應補做 README 同步檢查。

## [2.16.0] - 2026-05-07

### Changed
- **Config schema rename `.md` → `.yaml` (#47)**:`.claude/.mail/config.md` (v2.8.0–v2.15.0) 改名 `.claude/.mail/config.yaml`。原因:副檔名語意 ↔ 實際內容(YAML)一致;IDE 接 yaml-lsp;新 user 不被 `.md` 暗示「要寫 markdown body」誤導。
- 三處 mental model(spec / README / awk parser)統一稱「YAML config」,排除 「frontmatter」說法(parser 對 `---` boundary 自然 tolerant,因 `^---$` 不 match `^[a-z_]+:`)。

### Added
- **Auto-migrate `.md` → `.yaml`** in `archive-mail.md` Step 1.6 + `archive-mail-migrate` command。Silent rename,user 不需動手。順序:legacy `.claude/emails.md` (v2.7.0 ↓) → `.yaml`;then `.claude/.mail/config.md` (v2.8.0–v2.15.0) → `.yaml`。
- archive-mail.md `argument-hint` frontmatter + 使用方式 section 更新 path 引用。
- CLAUDE.md schema 段標題 `.claude/.mail/config.yaml Schema (v2.16.0+ #47)` + 路徑遷移說明。
- README archive-mail 段加 v2.16.0 highlight + File Layout `.yaml` 標示。

### Deprecated
- `.claude/.mail/config.md`:仍 work 為 fallback(parser 對舊檔自動相容),**v3.0 移除**。期間文件示範一律用 `.yaml`。

### Notes
- Plugin minor bump 2.15.0 → 2.16.0(new feature surface,backward compat;default behavior 對既有 `.md` user 透過 silent migration 不 break)。
- User decision (#issuecomment-4395581948):走 YAML 路線;選 Option C 漸進過渡(雙支援期 + v3.0 強制 `.yaml`)而非 Option A 立即 break。

## [2.15.0] - 2026-05-07

### Added
- **Inline `cid:` image preservation in `/archive-mail` (#45)**:resolves dogfood gap where 「Solution? (affine repre + Iverson's law of similarity)」 thread 11 封信中 1 張 CleanShot screenshot inline-embedded via `cid:` 完全 miss(因 `list_attachments` 不回 `Content-Disposition: inline` images)。
- **Step 5.5.0** (new) parses HTML body via regex `<img\s+...src="cid:..."...alt="...">` → extracts `(cid, alt_filename)` pairs → tries `save_attachment(attachment_name=alt, save_path=<stem>/inline/<alt>)`
- **Step 5.5.5** (new) fallback: if `save_attachment` doesn't recognize inline filename (binary-side limitation), writes cross-reference note `Inline images: - (cid:XXX — filename — binary unsupported; see Mail.app)` instead of silent skip
- **`Inline images:` section** in archive markdown (separate from `Attachments:`); image syntax `![alt](path)` for direct render in markdown viewers (vs link syntax for explicit attachments)
- **Folder layout**: `correspondence/attachments/<email_stem>/inline/<filename>` — sub-folder under existing stem dir; preserves semantic distinction between user-attached files vs inline illustrations
- **Step 8a Coverage Audit** updated: split into 8a.1 explicit + 8a.2 inline; report shows `explicit N/M + inline P/Q` format
- **Step 7 report** adds inline count line (only if any inline images present)

### Notes
- Skill-side workaround only;binary `save_attachment` 是否認得 inline filename **尚未驗證**(待實測,可能需要 follow-up upstream issue)
- 既有 archives 不會 retroactive process — inline 圖片仍是占位文字,user 手動補
- Plugin minor bump 2.14.0 → 2.15.0 (new feature surface,backward compat 預設行為不變)

## [2.14.0] - 2026-05-07

### Added
- **Opt-in `dedup_strategy` for `/archive-mail` (#18)**:resolves real-world observation that `.email_index.json` is rarely built / used — tatsuma project ran archive-mail for 3 years without producing one. New `.claude/.mail/config.md` field `dedup_strategy` with three values:
  - `index` (default,backward compat) — load + write `email_index.json` as before
  - `last_archived` — skip index entirely;use `last_archived` ISO-date as `date_from` for Step 3 search;requires `last_archived` field set in config (fail-fast if missing,prevents silent full-inbox scan)
  - `both` — load index AND apply date filter (Message-ID set ∪ date filter)
- Step 1.6 of archive-mail.md gains a strategy-resolve block;Step 2 conditionally skips index load;Step 4 dedup logic branches per strategy;Step 5/6 conditionally skip index write.
- CLAUDE.md schema docs updated with `dedup_strategy` + `last_archived` fields.

### Notes
- Default behavior unchanged from v2.13.0;existing archives continue with index-based dedup until user explicitly opts into `last_archived` or `both`.

## [2.13.0] - 2026-05-07

### Changed
- **BEHAVIOR CHANGE — `/archive-mail` Step 5 markdown template default simplified (#17)**: previously every archived email got a 4-section template (元數據表 + 信件內容 + 重點摘要 + 待辦事項). Real-world usage (tatsuma project, 50 historical archives) showed the elaborate sections are unused noise — AI summaries are unreliable and require manual review, breaking batch processing consistency. Default is now a simple template (frontmatter + 4-line `Subject/From/To/Date` header + body), matching the historical convention. Existing archives are NOT reprocessed (Message-ID dedup prevents). Users wanting the old elaborate template can opt in via `.claude/.mail/config.md` frontmatter `enrichment: summary+todos`.
- Plugin version bumped 2.12.0 → 2.13.0 (after #13 PR #39 landed at 2.12.0). Frontmatter still includes all 6 fields (`message_id` / `thread_key` / `in_reply_to` / `date` / `sender` / `direction`) — thread index reconstruction depends on these.

### Added
- `enrichment` field to `.claude/.mail/config.md` schema. Values: `none` (default, simple template) | `summary+todos` (4-section enriched template). Documented in plugin CLAUDE.md.

## [2.12.0] - 2026-05-07

### Added
- `/archive-mail` 零參數模式 (#13):當 `$ARGUMENTS` 為空時,從 `.claude/.mail/config.md` frontmatter 讀 `filters` / `output_dir` / `last_archived` / `exclude_mailboxes` 自動執行。命令列參數覆寫 config 維持 backward compat。空 config + 零參數會 fail-fast 提示而非靜默 archive 全 inbox(危險預防)。
- `argument-hint` frontmatter 改 `[email-filter] [output-dir]`,UI 正確標示 v2.12.0+ filter 為可選 (#21)。

## [2.10.3] - 2026-05-03

### Changed
- **Plugin shell bumped to notify binary v2.6.0** ([release notes](https://github.com/PsychQuant/che-apple-mail-mcp/releases/tag/v2.6.0)). Marathon release: 16 issues across 8 PRs landed in binary repo. Plugin shell version-aware wrapper auto-downloads new binary on next session start.

### Security
- Binary v2.6.0 ships: id injection guard ([#50](https://github.com/PsychQuant/che-apple-mail-mcp/issues/50)), attachment path deny-list + `MAIL_MCP_ATTACHMENT_ROOTS` allow-list ([#38](https://github.com/PsychQuant/che-apple-mail-mcp/issues/38)), email address validation ([#41](https://github.com/PsychQuant/che-apple-mail-mcp/issues/41)), type-strict handler params ([#35](https://github.com/PsychQuant/che-apple-mail-mcp/issues/35)), new `SECURITY.md` ([#48](https://github.com/PsychQuant/che-apple-mail-mcp/issues/48)).

### Fixed
- Binary v2.6.0 ships: `forward_email` plain mode embeds quoted original ([#44](https://github.com/PsychQuant/che-apple-mail-mcp/issues/44)) — mirrors v2.5.0 `reply_email` fix.

## [2.10.2] - 2026-05-03

### Changed
- **Plugin shell bumped to notify binary v2.5.0** ([release notes](https://github.com/PsychQuant/che-apple-mail-mcp/releases/tag/v2.5.0)).

### Fixed
- Binary v2.5.0 ships: `reply_email` plain mode embeds quoted original ([#43](https://github.com/PsychQuant/che-apple-mail-mcp/issues/43)) via Swift-side `composeReplyPlainText` helper. RFC 3676 `> ` prefix + CRLF normalization + empty-line `>` stuffing + pre-fetch graceful degrade. Pre-fix every plain-format `reply_email` call since `b8a4a89` (initial release) silently dropped the quoted original.

## [2.10.1] - 2026-05-02

### Changed
- **Plugin shell bumped to notify binary v2.4.1** ([release notes](https://github.com/PsychQuant/che-apple-mail-mcp/releases/tag/v2.4.1)).

### Fixed
- Binary v2.4.1 ships ([#33 verify findings A+B](https://github.com/PsychQuant/che-apple-mail-mcp/issues/33)): `reply_email` `save_as_draft=true` no longer pops Mail.app reply window; `replyEmail` validates attachment paths up-front mirroring `composeEmail` / `createDraft`.

## [2.10.0] - 2026-05-02

### Added
- **Plugin shell bumped to notify binary v2.4.0 reply-as-draft mode** ([issue #33](https://github.com/PsychQuant/che-apple-mail-mcp/issues/33)). `reply_email` gains 3 optional params: `cc_additional`, `attachments`, `save_as_draft`. Unblocks workflow: reply to existing thread + add CC + attach files + save as draft for human review before sending.

## [2.9.0] - 2026-05-01

### Changed
- Apple Mail MCP server — 44+ tools, IDD-style task enforcement + NSQL confirmation + .claude/.mail/ namespace (v2.9.0)。v2.9.0: archive-mail 與 confirmation-protocol skill Step 0 強制 TaskCreate bootstrap,靜默 skip = 違規。疊加 v2.8.0 namespace、v2.7.0 NSQL confirmation、v2.6.0 thread index、v2.5.0 composing format、v2.4.0 搜尋擴展。
