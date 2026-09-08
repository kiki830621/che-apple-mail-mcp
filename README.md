# che-apple-mail-mcp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![MCP](https://img.shields.io/badge/MCP-Compatible-green.svg)](https://modelcontextprotocol.io/)

**The most comprehensive Apple Mail MCP server** - 53 tools with SQLite-powered millisecond search across 250K+ emails.

[English](README.md) | [繁體中文](README_zh-TW.md)

---

## Why che-apple-mail-mcp?

| Feature | Other MCPs | che-apple-mail-mcp |
|---------|------------|-------------------|
| Total Tools | ~20 | **53** |
| Language | Python | **Swift (Native)** |
| Search Speed | Seconds (AppleScript) | **Milliseconds (SQLite)** |
| Search Fields | Subject/Sender | **Subject/Sender/Recipient/Date** |
| Batch Operations | No | **Up to 50 emails per call** |
| Mailbox Management | Basic | Full CRUD |
| Email Colors | No | 7 flag colors + background |
| VIP Management | No | Yes |
| Rule Management | Partial | Full CRUD |
| Signatures | No | Yes |
| Raw Headers/Source | No | Yes |

---

## Quick Start

Install the **plugin**. It brings the signed binary, the `/archive-mail` command
family, the safety rules, and the staleness hook as one unit:

```bash
claude plugin marketplace add PsychQuant/che-apple-mail-mcp
claude plugin install che-apple-mail-mcp@che-apple-mail-mcp
```

Then grant permissions — the setup window shows live status and links straight
to the right System Settings pane:

```bash
~/bin/CheAppleMailMCP --setup
```

> **💡 Full Disk Access** is what makes the fast SQLite read path and
> `batch_export_emails_markdown` work. Without it the tools still run but read
> little or nothing, which is easy to mistake for a bug rather than a
> permission. macOS does not let an app request FDA programmatically — it has to
> be ticked by hand — which is exactly what the setup window is there to make
> quick.

### Plugin vs MCP-only

Registering the MCP server by itself is a supported advanced path, but it is a
**strictly smaller** install. Choose it knowingly — nothing at runtime will tell
you these are missing (#353):

| Shipped by the plugin | Present with MCP-only |
|---|---|
| All 53 MCP tools | ✅ yes |
| `/archive-mail` + `-migrate` / `-rebuild-threads` / `-repair-synthetic-ids` / `-view` | ❌ the archiving SOP does not exist |
| `rules/compose-wrapper-free.md` — what the cite-block was, and what a refused compose call means | ⚠️ background: since [#304](https://github.com/PsychQuant/che-apple-mail-mcp/issues/304) the wrapper is structurally impossible, so this rule now explains the six refusal reasons and their recipes rather than guarding against a silent fallback |
| `rules/confirmation-triggers.md`, `rules/false-positive-detection.md` | ❌ no confirmation discipline on destructive operations |
| `hooks/session-start.sh` — staleness kill | ❌ a session can keep running a stale binary after an upgrade |
| Developer ID **signed + notarized** binary | ❌ a self-built binary is ad-hoc signed; on macOS 26 TCC cannot reliably hold FDA/Automation for it, so permissions appear to be granted and then stop working ([#211](https://github.com/PsychQuant/che-apple-mail-mcp/issues/211)) |
| Version sidecar → `--self-update` + the #303 staleness self-check | ❌ no sidecar next to a hand-built binary, so that check is permanently silent |

<details>
<summary><strong>Advanced: register the MCP server only</strong> (development, or you want no plugin)</summary>

```bash
git clone https://github.com/PsychQuant/che-apple-mail-mcp.git
cd che-apple-mail-mcp
swift build -c release

# --scope user     : available across all projects (stored in ~/.claude.json)
# --transport stdio: local binary execution via stdin/stdout
# --               : separator between claude options and the command
mkdir -p ~/bin
cp .build/release/CheAppleMailMCP ~/bin/
claude mcp add --scope user --transport stdio che-apple-mail-mcp -- ~/bin/CheAppleMailMCP
```

Install the binary to a local directory like `~/bin/`. Avoid cloud-synced
folders (Dropbox, iCloud, OneDrive) — sync activity causes MCP connection
timeouts.

For a self-built binary to hold TCC permissions across rebuilds, sign it with a
Developer ID; see [Signing & Notarization](#signing--notarization). Otherwise
expect to re-grant permissions after every build.

</details>

---

## Recent Releases

For full details see [CHANGELOG.md](CHANGELOG.md).

### v2.7.2 (2026-05-10) — `attachmentFragment` cluster + fallback parity
- Hardened `attachmentFragment` indent across all 3 callers + removed dead `MailController.attachmentScript` helper that bypassed v2.7.0's race-mitigation delays ([#61](https://github.com/PsychQuant/che-apple-mail-mcp/issues/61), [#62](https://github.com/PsychQuant/che-apple-mail-mcp/issues/62))
- Attachment count cap (50) + env-configurable delays via `CHE_MAIL_ATTACHMENT_DELAY_BETWEEN` / `_TRAILING` ([#63](https://github.com/PsychQuant/che-apple-mail-mcp/issues/63), [#64](https://github.com/PsychQuant/che-apple-mail-mcp/issues/64))
- `get_email_metadata` SQLite path now falls back to AppleScript on error — last read-tool gap closed; all 8 SQLite-first read tools now have parity fallback ([#71](https://github.com/PsychQuant/che-apple-mail-mcp/issues/71))

### v2.7.1 (2026-05-09) — base64 fix + `.partial.emlx` + observability
- **Critical**: RFC822 header/body split was returning a relative array index instead of an absolute `Data` index, causing `html_body` to begin with `"sion: 1.0\n\n<base64>"` for some Android Gmail messages — raw base64 leaked into LLM context and triggered AUP false-positives downstream ([#72](https://github.com/PsychQuant/che-apple-mail-mcp/issues/72))
- `save_attachment` now reads from `Attachments/<rowId>/<part_id>/<filename>` cache when `.partial.emlx` body is empty — no more silent 0-byte writes for IMAP messages with stripped binaries ([#66](https://github.com/PsychQuant/che-apple-mail-mcp/issues/66))
- SQLite fast-path failures now log to stderr (`SQLite ... fast path failed for rowId=...; falling through to AppleScript`) ([#69](https://github.com/PsychQuant/che-apple-mail-mcp/issues/69))

### v2.7.0 (2026-05-04) — Mail.app race mitigation
- Multi-attachment AppleScript paced with 0.3s between + 0.5s trailing delays to mitigate Mail.app silently dropping attachments under fast IPC ([#60](https://github.com/PsychQuant/che-apple-mail-mcp/issues/60))

### v2.6.0 (2026-05-03) — Security & validation hardening (8 PRs, 16 issues)
- `forward_email` plain mode now embeds RFC 3676 `> ` quoted original (parity with `reply_email`'s #43 fix) ([#44](https://github.com/PsychQuant/che-apple-mail-mcp/issues/44))
- Hard-fail on tool param type mismatch — `bool` / `[String]` no longer silently coerced ([#35](https://github.com/PsychQuant/che-apple-mail-mcp/issues/35))
- Recipient email validation rejects header injection (control chars, missing/multiple `@`) ([#41](https://github.com/PsychQuant/che-apple-mail-mcp/issues/41))
- `cc_additional` deduplicates case-insensitively ([#34](https://github.com/PsychQuant/che-apple-mail-mcp/issues/34))
- Attachment path deny-list (`~/.ssh`, Keychains, TCC db, browser cookies) + symlink-resolved + new `MAIL_MCP_ATTACHMENT_ROOTS` env allow-list ([#38](https://github.com/PsychQuant/che-apple-mail-mcp/issues/38))
- All 17 id-taking tools hard-validate `id` as Int at handler boundary — defeats AppleScript predicate injection ([#50](https://github.com/PsychQuant/che-apple-mail-mcp/issues/50))
- Gated integration tests for `reply_email` runtime ([#37](https://github.com/PsychQuant/che-apple-mail-mcp/issues/37), [#45](https://github.com/PsychQuant/che-apple-mail-mcp/issues/45)) + smoke matrix templates ([#46](https://github.com/PsychQuant/che-apple-mail-mcp/issues/46), [#47](https://github.com/PsychQuant/che-apple-mail-mcp/issues/47))

### v2.5.0 (2026-04-17) — Composing `format` parameter
- All 4 composing tools (`compose_email` / `create_draft` / `reply_email` / `forward_email`) gain `format: "plain" | "markdown" | "html"` param (closes [#14](https://github.com/PsychQuant/che-apple-mail-mcp/issues/14), [#15](https://github.com/PsychQuant/che-apple-mail-mcp/issues/15))
- New `message-composition` capability spec

---

## All 53 Tools

<details>
<summary><b>Accounts (2)</b></summary>

| Tool | Description |
|------|-------------|
| `list_accounts` | List all mail accounts |
| `get_account_info` | Get account details |

</details>

<details>
<summary><b>Mailboxes (4)</b></summary>

| Tool | Description |
|------|-------------|
| `list_mailboxes` | List all mailboxes (folders) |
| `create_mailbox` | Create a new mailbox |
| `delete_mailbox` | Delete a mailbox |
| `get_special_mailboxes` | Get special mailbox names (inbox, drafts, sent, trash, junk, outbox) |

</details>

<details>
<summary><b>Emails (7)</b></summary>

| Tool | Description |
|------|-------------|
| `list_emails` | List emails in a mailbox |
| `get_email` | Get full email content |
| `search_emails` | Search by subject/content |
| `get_unread_count` | Get unread count |
| `get_email_headers` | Get all email headers |
| `get_email_source` | Get raw email source |
| `get_email_metadata` | Get metadata (forwarded, replied, size) |

</details>

<details>
<summary><b>Actions (8)</b></summary>

| Tool | Description |
|------|-------------|
| `mark_read` | Mark as read/unread |
| `flag_email` | Flag/unflag email |
| `set_flag_color` | Set flag color (7 colors) |
| `set_background_color` | Set email background color |
| `mark_as_junk` | Mark as junk/not junk |
| `move_email` | Move to another mailbox |
| `copy_email` | Copy to another mailbox |
| `delete_email` | Delete email (to trash) |

</details>

<details>
<summary><b>Compose (5)</b></summary>

| Tool | Description |
|------|-------------|
| `compose_email` | Send new email (supports cc/bcc/attachments — bare addresses only: a display-name recipient in any list is refused on a send, use `create_draft` ([#404](https://github.com/PsychQuant/che-apple-mail-mcp/issues/404)); `format`: `plain` only since [#304](https://github.com/PsychQuant/che-apple-mail-mcp/issues/304); optional `from_address` for multi-account sender selection — see [#131](https://github.com/PsychQuant/che-apple-mail-mcp/issues/131), clean path supported via the verified From popup, [#219](https://github.com/PsychQuant/che-apple-mail-mcp/issues/219)). Bodies always come from Mail's own editor — see [#175](https://github.com/PsychQuant/che-apple-mail-mcp/issues/175) / `check_accessibility`; a call that cannot run cleanly FAILS with a named reason and creates nothing ([#304](https://github.com/PsychQuant/che-apple-mail-mcp/issues/304)) |
| `reply_email` | Reply to email. Optional: `cc_additional`, `attachments`, `save_as_draft`, `format` (since v2.4.0). Plain mode embeds RFC 3676 `> ` quoted original (since v2.5.0 / #43). The new body is pasted into Mail's native reply ([#218](https://github.com/PsychQuant/che-apple-mail-mcp/issues/218)); a non-`plain` `format` or a missing Accessibility grant FAILS instead of falling back ([#304](https://github.com/PsychQuant/che-apple-mail-mcp/issues/304)) |
| `forward_email` | Forward email. Optional `body` + `format`. Plain mode embeds RFC 3676 `> ` quoted original (since v2.5.0+ / #44). A bodyless forward assigns nothing and needs no Accessibility grant; with a body, same rules as `reply_email` ([#218](https://github.com/PsychQuant/che-apple-mail-mcp/issues/218) / [#304](https://github.com/PsychQuant/che-apple-mail-mcp/issues/304)) |
| `redirect_email` | Redirect email (keeps original sender) |
| `open_mailto` | Open mailto URL |

#### Reply-as-draft example (v2.4.0+)

Reply to a thread, add extra CC, attach files, and save as a draft for human review before sending:

```
reply_email(
    id="<message id from search_emails>",
    mailbox="INBOX",
    account_name="iCloud",
    body="Reply text",
    cc_additional=["x@y.com"],
    attachments=["/path/to/file.pdf"],
    save_as_draft=true
)
```

</details>

<details>
<summary><b>Drafts (3)</b></summary>

| Tool | Description |
|------|-------------|
| `list_drafts` | List draft emails — each entry carries `subject` + numeric `id` ([#276](https://github.com/PsychQuant/che-apple-mail-mcp/issues/276), additive; feeds `update_draft.draft_id` / `delete_email.id`) |
| `create_draft` | Create a draft (supports attachments; optional `from_address` for multi-account sender selection — see [#131](https://github.com/PsychQuant/che-apple-mail-mcp/issues/131), clean path supported via the verified From popup, [#219](https://github.com/PsychQuant/che-apple-mail-mcp/issues/219)). Bodies always come from Mail's own editor — see [#175](https://github.com/PsychQuant/che-apple-mail-mcp/issues/175) / `check_accessibility`; a call that cannot run cleanly FAILS with a named reason and creates nothing ([#304](https://github.com/PsychQuant/che-apple-mail-mcp/issues/304)). Display-name recipients (`Name <addr>`) in `to` / `cc` / `bcc` are filled through the compose window's AX-addressed fields with a token read-back before the save; a hidden Bcc field is revealed and left visible (`bcc_field_revealed: true`); cc/bcc addresses are re-read after the save (`recipients_verified: true|false` + `recipients_diff`, draft always kept) — [#277](https://github.com/PsychQuant/che-apple-mail-mcp/issues/277) / [#404](https://github.com/PsychQuant/che-apple-mail-mcp/issues/404) |
| `update_draft` | Replace an existing draft (upsert, [#276](https://github.com/PsychQuant/che-apple-mail-mcp/issues/276)): locate by `draft_id` or exact `subject_match` → create replacement (inherits `create_draft` eligibility + disclosure) → delete old. Deliberately create-THEN-delete with a post-create receipt (failure always leans toward keeping drafts — worst case both MAY exist, never neither); 0 or >1 matches always refuse (candidates listed). Replacement gets a NEW id. Display-name `to` / `cc` / `bcc` supported as on `create_draft` ([#404](https://github.com/PsychQuant/che-apple-mail-mcp/issues/404)) |

</details>

<details>
<summary><b>Attachments (2)</b></summary>

| Tool | Description |
|------|-------------|
| `list_attachments` | List email attachments |
| `save_attachment` | Save attachment to disk |

</details>

<details>
<summary><b>VIP (1)</b></summary>

| Tool | Description |
|------|-------------|
| `list_vip_senders` | List VIP senders |

</details>

<details>
<summary><b>Rules (5)</b></summary>

| Tool | Description |
|------|-------------|
| `list_rules` | List mail rules |
| `get_rule_details` | Get rule details |
| `create_rule` | Create a new rule |
| `delete_rule` | Delete a rule |
| `enable_rule` | Enable/disable a rule |

</details>

<details>
<summary><b>Signatures (2)</b></summary>

| Tool | Description |
|------|-------------|
| `list_signatures` | List email signatures |
| `get_signature` | Get signature content |

</details>

<details>
<summary><b>SMTP (1)</b></summary>

| Tool | Description |
|------|-------------|
| `list_smtp_servers` | List SMTP servers |

</details>

<details>
<summary><b>Sync (2)</b></summary>

| Tool | Description |
|------|-------------|
| `check_for_new_mail` | Check for new mail |
| `synchronize_account` | Sync IMAP account |

</details>

<details>
<summary><b>Batch (4)</b></summary>

| Tool | Description |
|------|-------------|
| `get_emails_batch` | Get up to 50 emails in one call (per-item errors) |
| `list_attachments_batch` | List attachments for up to 50 emails |
| `batch_export_emails_markdown` | Server-side bulk export to verbatim markdown + attachments (frozen frontmatter manifest; concurrency-serialized per output_dir — [#193](https://github.com/PsychQuant/che-apple-mail-mcp/issues/193) / [#236](https://github.com/PsychQuant/che-apple-mail-mcp/issues/236)) |
| `export_emails_markdown` | **DEPRECATED** — renamed to `batch_export_emails_markdown` ([#233](https://github.com/PsychQuant/che-apple-mail-mcp/issues/233)); alias removed no earlier than v3.0 |

</details>

<details>
<summary><b>Utilities (4)</b></summary>

| Tool | Description |
|------|-------------|
| `extract_name_from_address` | Extract name from email address |
| `extract_address` | Extract email from full address |
| `get_mail_app_info` | Get Mail.app info |
| `import_mailbox` | Import mailbox from file |

</details>

<details>
<summary><b>Diagnostics (3)</b></summary>

| Tool | Description |
|------|-------------|
| `check_fda` | Check Full Disk Access status (SQLite fast-path availability) |
| `check_accessibility` | Check Accessibility permission (the compose/reply GUI paths; without it those tools refuse) |
| `check_automation` | Check Automation permission (Apple Events to Mail) — non-prompting probe, four states with remediation ([#293](https://github.com/PsychQuant/che-apple-mail-mcp/issues/293)); the binary holds its OWN grant, osascript working ≠ binary authorized ([#288](https://github.com/PsychQuant/che-apple-mail-mcp/issues/288)) |

</details>

### Response shape: `search_emails` / `list_emails`

Both tools return an **envelope object** `{ results, returned, limit, truncated }` — **not** a bare array (changed in [v2.14.0](CHANGELOG.md), [#204](https://github.com/PsychQuant/che-apple-mail-mcp/issues/204)). Read the matches from `.results`:

| Field | Meaning |
|-------|---------|
| `results` | Array of result objects (per-object fields unchanged from the pre-envelope shape). `search_emails` objects carry `id`, `subject`, `sender`, `date_received`, `account_name`, `mailbox`, `to`, plus `account_id` when the account UUID is resolvable. `list_emails` objects carry `id`, `subject`, `sender`. |
| `returned` | Number of objects in `results` |
| `limit` | Effective `limit` applied to the query |
| `truncated` | `true` when more results are available than were returned — **raise `limit` or narrow the query** to retrieve the rest (definitive on the SQLite fast path; a best-effort heuristic on the AppleScript fallback — see below) |

`truncated` is **definitive** on the SQLite fast path (it fetches `limit + 1` internally); on the AppleScript fallback it is a best-effort `returned == limit` heuristic. Any "enumerate → batch process" consumer should check `truncated` before assuming it has the full set.

---

## Installation

> **Start with [Quick Start](#quick-start)** — installing the plugin is the
> supported path and gives you the commands, safety rules, staleness hook and a
> signed binary. Everything below is the **advanced / development** route: it
> registers the MCP server alone, which is a strictly smaller install (see
> [Plugin vs MCP-only](#plugin-vs-mcp-only) for what is missing, since nothing
> at runtime will tell you).

### Requirements

- macOS 13.0+
- Xcode Command Line Tools (for the build-it-yourself route below)
- Apple Mail with at least one account configured

### Step 1: Build

```bash
git clone https://github.com/PsychQuant/che-apple-mail-mcp.git
cd che-apple-mail-mcp
swift build -c release
```

### Step 2: Configure

#### For Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "che-apple-mail-mcp": {
      "command": "/full/path/to/che-apple-mail-mcp/.build/release/CheAppleMailMCP"
    }
  }
}
```

#### For Claude Code (CLI)

```bash
# Copy to ~/bin and register (user scope = available in all projects)
mkdir -p ~/bin
cp .build/release/CheAppleMailMCP ~/bin/
claude mcp add --scope user --transport stdio che-apple-mail-mcp -- ~/bin/CheAppleMailMCP
```

### Step 3: Grant Permissions

The fastest route is the setup window, which shows live Full Disk Access /
Automation / Accessibility status, re-checks as you grant, and opens the right
System Settings pane for you:

```bash
~/bin/CheAppleMailMCP --setup
```

To do it by hand instead:

**Automation** (control Mail.app):

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
```

1. Find **CheAppleMailMCP** and enable permission for **Mail.app**
2. If using Claude Code, also add **Terminal** or **iTerm**

**Full Disk Access** (the SQLite fast path + `export_emails_markdown` read `~/Library/Mail`):

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
```

macOS grants Full Disk Access to the **responsible process** — the app that *launched* this server — not to the binary itself. For an MCP server run by **Claude Code inside a terminal**, that responsible process is the **terminal** (Ghostty / Terminal / iTerm), so add **your terminal app** here and enable it. One grant on the terminal covers every MCP server it launches. (If you instead run the binary directly, or use the **Claude Desktop** bundle, add that binary — `~/bin/CheAppleMailMCP` — since it is then its own responsible process.) The FDA-denied error message names these candidates for you — it does **not** auto-resolve the one exact app, because macOS exposes no reliable in-process API for that (#214). Without Full Disk Access, read tools silently fall back to the slower AppleScript path and SQLite-only features (`projection`, `export_emails_markdown`) fail. For the direct-launch path, a Developer ID-signed build makes the grant survive version bumps — see [Signing & Notarization](#signing--notarization).

**Guided setup** (#213) — instead of the manual steps above, the binary ships setup helpers:

- **`CheAppleMailMCP --setup`** opens a small window with **live** Full Disk Access status (re-checked on a timer, flips to "Ready ✅" the moment you grant) plus an **on-demand** Automation check, and "Open Full Disk Access settings" / "Copy binary path" buttons.
- **`CheAppleMailMCP --check-fda`** prints the status headlessly (and opens the pane when access is **denied**) — handy from a terminal or script.
- The **`check_fda` MCP tool** reports the same status to Claude on demand (call it when a SQLite-only feature errors).

None of these can remove the single manual toggle (Apple puts FDA in the manual-only bucket alongside Accessibility / Screen Recording), but they make "what do I do?" obvious and give live feedback the instant you flip it on.

**Accessibility (compose, #175/#304)** — a *separate, optional* grant from Full Disk Access. Mail.app wraps any AppleScript-injected outgoing-message body in `<blockquote type="cite">`, which some mobile clients render as a quotation of your own text — and which the sender cannot see locally, because the wrapper's inline style has no border. Since [#304](https://github.com/PsychQuant/che-apple-mail-mcp/issues/304) **the code that produces it no longer exists**: every composing tool takes its body from Mail's own editor — a `mailto:` hand-off for `compose_email` / `create_draft`, the native reply/forward verb plus paste for `reply_email` / `forward_email` — and drives save/send/attach with keyboard shortcuts, which needs **Accessibility** (System Settings → Privacy & Security → Accessibility), granted to the same responsible process as FDA (your terminal / Claude Desktop). The **`check_accessibility` MCP tool** and the `--setup` window's **Accessibility** row report the status. **Without it these tools now FAIL rather than fall back** — there is no second path to fall back to, so a call that cannot run cleanly returns a named error and creates nothing. The error points at `open_mailto`, which needs no TCC grant at all (it cannot carry attachments; you save or send the window yourself). Exactly six conditions refuse a call: a non-`plain` `format`; an empty subject; Accessibility not granted; a `from_address` that is not a bare addr-spec; an attachment path containing non-ASCII characters ([#220](https://github.com/PsychQuant/che-apple-mail-mcp/issues/220)); and a recipient carrying a display name that this path cannot fill (cc/bcc always; `to` on a send — a draft's `to` display name is filled through the GUI, [#277](https://github.com/PsychQuant/che-apple-mail-mcp/issues/277)). For a clean body from a **non-default account**, pass `from_address`: the GUI selects it in Mail's From popup and reads the selection back, aborting rather than risk the wrong sender ([#219](https://github.com/PsychQuant/che-apple-mail-mcp/issues/219)). **Removed with the legacy path**: `format: "markdown"` / `"html"` — no path shipped today delivers rich text without the body assignment that was deleted. That is what exists, not a proof of impossibility ([#310](https://github.com/PsychQuant/che-apple-mail-mcp/issues/310)): the paste path (#218) is a second wrapper-free route and `NSPasteboard` can carry rich flavors, but the MIME it produces is unverified — [#306](https://github.com/PsychQuant/che-apple-mail-mcp/issues/306) settles it; [#308](https://github.com/PsychQuant/che-apple-mail-mcp/issues/308) / [#309](https://github.com/PsychQuant/che-apple-mail-mcp/issues/309) are alternatives, the `require_wrapper_free` and `sanitize_links` parameters, and the `CHE_MAIL_DISABLE_MAILTO_COMPOSE` / `CHE_MAIL_DISABLE_PASTE_REPLY` escape hatches. Two capabilities go with them, stated plainly: composing **without a visible window** (the hatches' original purpose) is no longer possible, and `compose_email` can no longer **send** to `Name <addr>` — use `create_draft` and send the draft yourself.

### Automation TCC (-1743) and the zero-TCC escape hatch

If AppleScript-backed tools fail with `AppleScript error (-1743): Not authorized to send
Apple events to Mail`, the Automation permission is missing **for this binary**. The
signed MCP binary holds its OWN Automation grant — its TCC identity is keyed to the
binary's signing identity (the #211 FDA lesson, Automation axis), separate from your
terminal's. Empirically verified: `osascript` controlling Mail from your shell does NOT
mean the binary is authorized. Grant it under **System Settings → Privacy & Security →
Automation** — find the entry for the binary / its host (Claude Desktop extension:
under **Claude.app**) and enable Mail. If no entry exists, a previous denial is being
remembered and macOS will not re-prompt: run `tccutil reset AppleEvents`, then retry a
Mail tool to retrigger the prompt. Grants are per-install, and a binary update can
invalidate the entry (#211).

Until the grant is in place, `open_mailto` still works: it goes through LaunchServices
(zero TCC, #287) and opens a cite-block-free compose window in the system default mail
client. mailto cannot carry attachments (RFC 6068) — drag files in manually.

### Step 4: Restart Claude

```bash
# For Claude Desktop
osascript -e 'quit app "Claude"' && sleep 2 && open -a "Claude"

# For Claude Code - start a new session
claude
```

---

## Usage Examples

### Natural Language (Claude Desktop)

```
"List all my mail accounts"
"Show unread emails in Gmail inbox"
"Search for emails about 'quarterly report'"
"Send an email to john@example.com about the meeting"
"Flag important emails in red"
"Create a rule to move newsletters to a folder"
```

### Direct Tool Calls (Claude Code)

```
"Use list_accounts to show my accounts"
"Use search_emails to find emails containing 'invoice'"
"Use set_flag_color to mark email ID 12345 as blue"
"Use check_for_new_mail to refresh"
```

---

## Flag & Background Colors

### Flag Colors (`set_flag_color`)

| Index | Color |
|-------|-------|
| 0 | Red |
| 1 | Orange |
| 2 | Yellow |
| 3 | Green |
| 4 | Blue |
| 5 | Purple |
| 6 | Gray |
| -1 | Clear |

### Background Colors (`set_background_color`)

`blue`, `gray`, `green`, `none`, `orange`, `purple`, `red`, `yellow`

---

## Performance & Storage

### SQLite + .emlx fast path

Most read tools prefer Apple Mail's local Envelope Index (SQLite) and on-disk `.emlx` message files over AppleScript IPC, with transparent AppleScript fallback when the SQLite path can't satisfy a request:

| Tool | SQLite/.emlx path | AppleScript fallback |
|------|------------------|----------------------|
| `get_email` | ✓ | ✓ on any error |
| `get_emails_batch` | ✓ (per item) | ✓ (per item) |
| `get_email_headers` | ✓ | ✓ on any error |
| `get_email_source` | ✓ | ✓ on any error |
| `search_emails` | ✓ | ✓ when reader unavailable |
| `list_attachments` | ✓ | ✓ on any error |
| `save_attachment` | ✓ | ✓ on any error |
| `get_email_metadata` | ✓ | ✓ on any error (since [#71](https://github.com/PsychQuant/che-apple-mail-mcp/issues/71)) |

For `save_attachment`'s read path the fast path is **10–100× faster** than AppleScript (per [#12](https://github.com/PsychQuant/che-apple-mail-mcp/issues/12) measurements). Other tools' speedup ratios depend on request shape; in general, large bulk reads see the biggest gain.

The fast path requires:

- Full Disk Access granted to the host process (System Settings → Privacy & Security → Full Disk Access)
- Apple Mail's local store at `~/Library/Mail/V10/...`
- Message has been synced to local `.emlx` storage

### EWS / Exchange accounts intentionally bypass the fast path

Exchange (EWS) accounts in Apple Mail **do not materialize `.emlx` files** — message bodies live on the server and are fetched on demand. For these accounts, all 8 read tools (including `get_email_metadata` since [#71](https://github.com/PsychQuant/che-apple-mail-mcp/issues/71)) transparently degrade to AppleScript IPC (which is correct but slower). Symptoms:

- A bulk fetch of 500 EWS messages will be noticeably slower than 500 IMAP/Gmail messages
- This is **not a bug** — it's an Apple Mail storage architecture constraint (see [#9](https://github.com/PsychQuant/che-apple-mail-mcp/issues/9))

### Diagnosing fast-path bypass

When the fast path fails for a non-EWS account, the failure is logged to stderr (since [#69](https://github.com/PsychQuant/che-apple-mail-mcp/issues/69)). Run the binary in a terminal and watch stderr to distinguish:

- `EnvelopeIndexReader init failed: ...` — DB unreachable (commonly: Full Disk Access missing)
- `SQLite get_email fast path failed for rowId=N: ...` — per-message failure (e.g., `.partial.emlx` only, malformed MIME, file not yet synced)

Both cases transparently fall through to AppleScript with `... falling through to AppleScript` in the log line, so behavior is preserved while observability is restored.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Server disconnected | Rebuild with `swift build -c release` |
| Not allowed to send Apple events | Add permissions in System Settings > Automation |
| Mail.app not responding | Ensure Mail.app is running with configured accounts |
| Commands timing out | Large mailboxes take longer; try specific searches |
| Bulk fetch slower than expected | Watch stderr for `... falling through to AppleScript` lines. EWS/Exchange accounts always fall back (see [Performance & Storage](#performance--storage)); other accounts logging fallback indicate a fixable .emlx issue |
| `save_attachment` fails with `-1728 "Can't get account"` or `-1719 "Invalid mailbox index"` | Since [#173](https://github.com/PsychQuant/che-apple-mail-mcp/issues/173) both errors come back with an actionable hint naming the failing reference (account / mailbox / message). Common causes: two Mail.app accounts share the same `display_name`, or an email-form `account_name` maps to several accounts — see [Account Disambiguation](#account-disambiguation) below. |

---

## Account Disambiguation

Mail.app's AppleScript `account "<display_name>"` selector is **not unique** when two accounts share the same `display_name` — a common pattern when an iCloud catch-all alias forwards a Gmail address back to itself, or when Google Workspace + personal Gmail overlap. Any AppleScript-routed tool (`save_attachment` fallback, `get_email`, `mark_read`, etc.) will then non-deterministically pick the wrong account → `-1728 / -1719` errors.

**The fix**: pass `account_id` (Mail.app's globally-unique UUID) alongside `account_name`. When provided, `save_attachment` uses Mail.app's `account id "<UUID>"` selector instead, bypassing the ambiguity:

```jsonc
// Tool call: save_attachment with account_id
{
    "id": "273214",
    "mailbox": "[Gmail]/全部郵件",
    "account_name": "alice@example.com",
    "account_id": "C38E0583-47F8-4468-BE70-43155C15549D",  // ← disambiguates
    "attachment_name": "report.pdf",
    "save_path": "/tmp/report.pdf"
}
```

**Discovering `account_id`**:

- **From `search_emails` results** — each object in the `results` array (a `SearchResult`) carries an `account_id` field alongside `account_name` (populated by decoding the account UUID from the SQLite `mailboxes.url` authority via `MailboxURL.decode` — Mail.app's storage convention encodes the account UUID in the mailbox URL authority; there is no direct `SELECT mailboxes.account_id`). Recommended: pass it through directly.
- **Manually** — read `~/Library/Mail/V10/MailData/Signatures/AccountsMap.plist`. The top-level keys are the UUIDs; the `AccountURL` value contains the matching email address percent-encoded in the authority.
- **In AppleScript** — `tell application "Mail" to get id of every account` returns the UUID list.

**Backward compatibility**: `account_id` is **optional**. When omitted (or empty), tools fall back to the legacy `account "<display_name>"` path — behavior identical to pre-#101 — **with one `save_attachment` exception** ([#173](https://github.com/PsychQuant/che-apple-mail-mcp/issues/173)): when `account_name` contains `@` (email-shaped, the form SQLite-path tools like `search_emails` emit), `save_attachment` first reverse-looks-it-up in AccountsMap and silently upgrades to the `account id "<UUID>"` selector (the upgrade is logged to stderr). Exactly one match → that UUID; several accounts behind one address (iCloud catch-all + Gmail) → an actionable error listing every candidate instead of a raw `-1728`; no match → the legacy display-name path, unchanged. Edge: a Mail account whose *description* legitimately contains `@` and happens to equal another account's email now resolves in the email namespace first — pass `account_id` explicitly to pin the selector. Other tools keep the strict pre-#101 fallback (the cross-tool sweep is [#176](https://github.com/PsychQuant/che-apple-mail-mcp/issues/176)).

**Scope**: `account_id` is accepted across the AppleScript-routed tools that reference mail by account. It began with `save_attachment` ([#101](https://github.com/PsychQuant/che-apple-mail-mcp/issues/101)); the [#104](https://github.com/PsychQuant/che-apple-mail-mcp/issues/104) sweep then added the 13 single-message / movement / relay / mailbox tools below:

- `save_attachment` ([#101](https://github.com/PsychQuant/che-apple-mail-mcp/issues/101)) — the precursor
- **PR-A** — 5 single-message mutation tools: `mark_read`, `flag_email`, `set_flag_color`, `set_background_color`, `mark_as_junk`
- **PR-B** — 3 movement/destruction tools: `move_email`, `copy_email`, `delete_email`
- **PR-C** — 3 message-relay tools: `reply_email`, `forward_email`, `redirect_email`
- **PR-D** — 2 mailbox CRUD tools: `create_mailbox`, `delete_mailbox`

The surface has since expanded beyond the #104 set:

- **[#176](https://github.com/PsychQuant/che-apple-mail-mcp/issues/176)** — generalized the email→UUID `resolveAccountIdForTool` chokepoint across all 14 AppleScript-routed write handlers (so an email-form `account_name` resolves to the UUID selector, not just an accepted `account_id`).
- **[#180](https://github.com/PsychQuant/che-apple-mail-mcp/issues/180)** — threaded `account_id` through the read-tool AppleScript fallbacks (`list_emails` / `search_emails` / `get_email` / headers / source / metadata / attachments / `get_unread_count`) via `resolveMailboxRef` / `resolveMsgRef` (the PR-E that was previously deferred is now done).
- **[#179](https://github.com/PsychQuant/che-apple-mail-mcp/issues/179)** — `get_special_mailboxes` accepts `account_id` / `account_name` for per-account special-mailbox real names.
- **[#191](https://github.com/PsychQuant/che-apple-mail-mcp/issues/191)** — the account-level action tools `check_for_new_mail` and `synchronize_account` gained the `account_id` escape hatch (`synchronize_account` accepts `account_id` alone).

Still **not** covered by `account_id` (tracked): `get_account_info` / `list_mailboxes` ([#202](https://github.com/PsychQuant/che-apple-mail-mcp/issues/202)).

`compose_email` / `create_draft` do **not** exhibit the display_name-collision defect — they `make new outgoing message` rather than referencing existing mail by account, so they never emit an `account "<display_name>"` selector. Multi-account sender selection is now available via the optional `from_address` parameter ([#131](https://github.com/PsychQuant/che-apple-mail-mcp/issues/131)) — pass any one of your configured Mail.app email addresses (`"alice@example.com"` or RFC 5322 form `"Alice <alice@example.com>"`) to set the `sender` of the outgoing message; omit to use Mail.app's default account. Use `list_accounts` to discover the addresses configured on the running Mac.

**Cross-account move/copy is not supported via `account_id`** ([#129](https://github.com/PsychQuant/che-apple-mail-mcp/issues/129) — from #127 verify). `move_email` and `copy_email` accept a single `account_id`, which is threaded through **both** the source `msgRef` and the destination `mailboxRef`. The architectural choice is correct (movement stays within one account, because Mail.app's AppleScript verb `move msg to <mailboxRef>` requires the destination mailbox to be expressed relative to a single account context). Mail.app's UI permits cross-account move via drag-and-drop, but the AppleScript-routed `move_email` / `copy_email` tools cannot replicate that — calling `move_email` with `account_id` of one account while expecting the destination `to_mailbox` to be resolved against a different account silently picks the wrong account's mailbox of that name (if both accounts happen to have one) or raises `-1719 "Invalid mailbox index"`. If you need a copy of the message's contents under a different account, you can manually rebuild it via `save_attachment` + `compose_email` — note this is **not** a true move/copy: original metadata (Message-ID, received-date, flags, labels) and message identity are not preserved.

---

## Technical Details

- **Framework**: [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) v0.10.0
- **Read path**: SQLite (Envelope Index) + `.emlx` file parser, with AppleScript fallback for EWS / unparseable `.emlx`
- **Write/state path**: AppleScript via `NSAppleScript`
- **Transport**: stdio
- **Platform**: macOS 13.0+ (Ventura and later)

---

## Signing & Notarization

The distributed binary is **Developer ID-signed and notarized**, and that is not cosmetic. The fast read path needs **Full Disk Access (FDA)**, and macOS TCC keys an FDA grant to the binary's *designated requirement*. For an ad-hoc binary that requirement is the **cdhash**, so every version bump invalidated the grant and you had to re-add the binary to the Full Disk Access list after each release. A stable Developer ID signature keys the grant to the **signing identity** instead, so it survives version bumps (#211) — that signature, not notarization, is what delivers the persistence.

Notarization matters for **quarantined-launch** paths: a browser download or the `.mcpb` (Claude Desktop) install, where Gatekeeper assesses the binary on first launch. The plugin wrapper's `curl` + `exec` path sets no quarantine attribute, so Gatekeeper never fires there. We notarize anyway so the published release asset is safe to run by any means.

> **The first grant is still manual.** FDA (`kTCCServiceSystemPolicyAllFiles`) has no programmatic request API — an app can only deep-link you to the settings pane. Signing makes that first grant *permanent*, not automatic.

### One-time setup (maintainers)

```bash
# 1. Developer ID Application cert in your login keychain (needs an Apple Developer account)
security find-identity -p codesigning -v        # find your identity

# 2. notarytool keychain profile (prompts for an app-specific password — never pass it on the CLI)
xcrun notarytool store-credentials <profile-name> \
  --apple-id <your-apple-id> --team-id <your-team-id>

# 3. Export both for the signed targets
export DEVELOPER_ID='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='<profile-name>'
```

### Dev install on your own machine (fast — no notarization)

```bash
make install-signed     # build + Developer ID sign + copy to ~/bin
```

Use this to get a **stable FDA grant on your own Mac without waiting for Apple notarization**: your own cert launches fine locally, and the grant survives future rebuilds. Grant Full Disk Access once to `~/bin/CheAppleMailMCP` and you are done.

### Distribution release (signed + notarized + published)

```bash
make release-signed VERSION=vX.Y.Z      # wraps scripts/release.sh with REQUIRE_CODESIGN=1
```

This builds a **universal** (arm64 + x86_64) binary, signs it, notarizes it (1–15 min Apple round-trip), and uploads it to the GitHub release. Forks without certs can still cut an unsigned dev release with `SKIP_CODESIGN=1 ./scripts/release.sh vX.Y.Z`.

---

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Author

Created by **Che Cheng** ([@kiki830621](https://github.com/kiki830621))

If you find this useful, please consider giving it a star!
