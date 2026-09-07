import Foundation
import Logging
import MCP
import MailSQLite

/// MCP Server for Apple Mail
class CheAppleMailMCPServer {
    private let server: Server
    private let transport: ShutdownOnWriteFailureTransport
    private let mailController = MailController.shared
    private let tools: [Tool]
    private let indexReader: EnvelopeIndexReader?

    init() async throws {
        self.tools = Self.defineTools()
        self.server = Server(
            name: "che-apple-mail-mcp",
            version: AppVersion.current,
            capabilities: .init(tools: .init())
        )
        // #349-B: a stdout write failure ends the session instead of leaving
        // the server executing mutations whose responses vanish.
        self.transport = ShutdownOnWriteFailureTransport(
            wrapping: StdioTransport(), logger: Logger(label: "che-apple-mail-mcp"))

        // Initialize SQLite reader (optional — falls back to AppleScript if unavailable)
        // Only open the DB connection here; account mapping is built lazily on first search
        // to avoid blocking server startup with AppleScript calls.
        //
        // Init failure surfaces to stderr so users can diagnose silent perf
        // degradation (#69 — without this log, every read tool silently
        // bypasses the SQLite + .emlx fast path with no observable cause).
        do {
            self.indexReader = try EnvelopeIndexReader(databasePath: EnvelopeIndexReader.defaultDatabasePath)
        } catch {
            let message = "EnvelopeIndexReader init failed: "
                + "\(error.localizedDescription)\n"
                + "All read tools will use the AppleScript fallback path "
                + "(slower; expected for EWS-only accounts, see README). "
                + "For local IMAP/POP accounts this usually means Full Disk Access "
                + "is missing — see the actionable steps above.\n"
            Diagnostics.emit(message)
            self.indexReader = nil
        }

        await registerHandlers()

        // Fire-and-forget: trigger Mail.app sync so Envelope Index is fresh.
        // If Mail.app isn't running, this starts it. IDLE/fetch takes over after.
        Task { try? await mailController.checkForNewMail() }
    }

    func run() async throws {
        // The server exists only now, so the shutdown hook is installed here.
        await transport.setOnWriteFailure { [server] in await server.stop() }
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Tool Definitions

    static func defineTools() -> [Tool] {
        [
            // Account Tools
            Tool(
                name: "list_accounts",
                description: "List all mail accounts configured in Apple Mail",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "check_fda",
                description: "Check whether Full Disk Access is granted (functionally probes the Apple Mail Envelope Index). Returns status plus the exact steps to grant it if not. Use when SQLite-only features (search_emails projection=ids/count, export_emails_markdown) fail with an 'unavailable' error.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "check_accessibility",
                description: "Check whether Accessibility (GUI-scripting) is granted via AXIsProcessTrusted(). Required for the #175 wrapper-free compose path (compose_email / create_draft use mailto + keystrokes so the body isn't wrapped in <blockquote type=\"cite\"> on mobile clients). Returns status plus steps to grant it. Separate grant from check_fda. If denied, compose still works but the body is wrapped in a quote on some mobile clients.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "check_automation",
                description: "Check whether Automation (Apple Events to Mail) is granted TO THIS BINARY — the third TCC axis after check_fda and check_accessibility (#293). Non-prompting probe (AEDeterminePermissionToAutomateTarget, askUserIfNeeded=false). Four states with remediation: granted / denied (recorded -1743 — macOS never re-prompts; System Settings entry or tccutil reset, #288) / not-determined (run any Mail tool to trigger the prompt) / Mail-not-running (open Mail.app first; the probe deliberately has no side effects). Note (#288): the binary holds its OWN grant — osascript working in your shell does NOT mean this binary is authorized. Zero-TCC compose fallback: open_mailto (#287).",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "get_account_info",
                description: "Get detailed information about a specific mail account",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account's display name OR email address. If an email-form name is ambiguous across accounts, also pass account_id.")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Mail.app's globally-unique account UUID (from list_accounts / search_emails `account_id`). Optional escape hatch when account_name is an email-form name or ambiguous display name (#202).")])
                    ]),
                    "required": .array([.string("account_name")])
                ])
            ),

            // Mailbox Tools
            Tool(
                name: "list_mailboxes",
                description: "List all mailboxes (folders) for an account",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account's display name OR email address (optional — lists all accounts' mailboxes if omitted). A name that resolves to no account is rejected, not silently expanded to every account.")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Mail.app's globally-unique account UUID (from list_accounts / search_emails `account_id`). Optional escape hatch when account_name is an email-form name or ambiguous display name (#202).")])
                    ])
                ])
            ),
            Tool(
                name: "create_mailbox",
                description: "Create a new mailbox (folder) in an account",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Name of the new mailbox")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The account to create the mailbox in")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID for disambiguation when multiple accounts share a display_name (see #101). From search_emails results.")])
                    ]),
                    "required": .array([.string("name"), .string("account_name")])
                ])
            ),
            Tool(
                name: "delete_mailbox",
                description: "Delete a mailbox (folder) from an account",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Name of the mailbox to delete")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The account containing the mailbox")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID for disambiguation when multiple accounts share a display_name (see #101). From search_emails results.")])
                    ]),
                    "required": .array([.string("name"), .string("account_name")])
                ])
            ),

            // Email Reading Tools
            Tool(
                name: "list_emails",
                description: "List emails in a mailbox. Returns an envelope object {results, returned, limit, truncated} (NOT a bare array): `truncated` is true when more emails matched than `limit` — raise `limit` or narrow the query to retrieve the rest. On the SQLite fast path `truncated` is definitive (limit+1 fetch); on the AppleScript fallback it is a best-effort `returned == limit` heuristic (#204).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name (e.g., 'INBOX')")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID (from search_emails / list_accounts) to disambiguate accounts that share a display_name (#101). Used only by the AppleScript fallback path; the SQLite fast path is account-agnostic (#180).")]),
                        "limit": .object(["type": .string("integer"), "description": .string("Maximum number of emails to return (default: 50)")])
                    ]),
                    "required": .array([.string("mailbox"), .string("account_name")])
                ])
            ),
            Tool(
                name: "get_email",
                description: "Get full content of a specific email. Returns HTML by default (preserving links), or plain text/raw source with format parameter.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID (numeric rowId). A rowId present in the Envelope Index is self-addressing — mailbox/account_name are then optional (#299).")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Optional since #299: mailbox name. Omit it for a numeric rowId — the Envelope Index resolves the account's REAL (localized, possibly nested) mailbox path itself, which is what lets the body-materialization nudge be reached from an id alone (export manifests and search summary/ids projections return no account). Supplying it keeps the pre-#299 selector verbatim; if a supplied pair fails AppleScript resolution the call retries once with the derived pair and logs the substitution to stderr.")]),
                        "account_name": .object(["type": .string("string"), "description": .string("Optional since #299: the mail account (display_name). Omit for a numeric rowId — the Envelope Index yields the account UUID, a strictly better selector (globally unique, so immune to the same-display_name collision of #101).")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID (from search_emails / list_accounts) to disambiguate accounts that share a display_name (#101). Used only by the AppleScript fallback path; the SQLite fast path is account-agnostic (#180). Takes precedence over both account_name and the #299 derived UUID.")]),
                        "format": .object(["type": .string("string"), "description": .string("Content format: 'html' (default, preserves links), 'text' (plain text), 'source' (full MIME)")])
                    ]),
                    "required": .array([.string("id")])
                ])
            ),
            Tool(
                name: "search_emails",
                description: "Search emails across ALL accounts and mailboxes using fast SQLite index (millisecond speed on 250K+ emails). Supports searching by subject, sender, recipient, or all fields. Results include `account_name` (display name) AND `account_id` (Mail.app's globally-unique UUID) — pass `account_id` through to `save_attachment` / other AppleScript-routed tools when the display_name is ambiguous (multi-account-same-display_name configurations — see #101). Returns an envelope object {results, returned, limit, truncated} (NOT a bare array): `truncated` is true when more emails matched than `limit` — raise `limit` or narrow the query to retrieve the rest. On the SQLite fast path `truncated` is definitive (limit+1 fetch); on the AppleScript fallback it is a best-effort `returned == limit` heuristic (#204). For BULK collection (e.g. feeding export_emails_markdown), use `projection: \"ids\"` to get just rowId strings (far smaller payload, no per-row recipient fetch) and `dedup: \"logical\"` to collapse Gmail mailbox duplicates server-side; `projection: \"count\"` returns just the total match count for scoping (#208).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string"), "description": .string("Search query string")]),
                        "field": .object(["type": .string("string"), "description": .string("Search field: 'subject', 'sender', 'recipient', or 'any' (default: 'any' — searches all fields)")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox to search in (optional — omit to search all mailboxes)")]),
                        "account_name": .object(["type": .string("string"), "description": .string("Mail account (optional — omit to search all accounts)")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID (from search_emails / list_accounts) to disambiguate accounts that share a display_name (#101). Used only by the AppleScript fallback path; the SQLite fast path is account-agnostic (#180).")]),
                        "date_from": .object(["type": .string("string"), "description": .string("Start date filter, ISO 8601 (e.g., '2026-01-01')")]),
                        "date_to": .object(["type": .string("string"), "description": .string("End date filter, ISO 8601 (e.g., '2026-03-31')")]),
                        "limit": .object(["type": .string("integer"), "description": .string("Maximum results (default: 50)")]),
                        "sort": .object(["type": .string("string"), "description": .string("Sort order by date: 'desc' (newest first, default) or 'asc' (oldest first)")]),
                        "projection": .object(["type": .string("string"), "description": .string("Result shape: 'full' (default, the {results,returned,limit,truncated} envelope of full objects), 'ids' (envelope whose `results` is an array of message rowId strings only — orders-of-magnitude smaller, for bulk collection feeding export_emails_markdown), 'summary' (envelope whose `results` elements are triage objects with only `id`/`date`/`sender`/`subject`/`mailbox` — between `ids` and `full`, for human triage without the full per-row cost), or 'count' (just {count}, the total matches ignoring `limit`, for scoping). 'ids'/'summary'/'count' require the SQLite index (#208/#177).")]),
                        "dedup": .object(["type": .string("string"), "description": .string("'none' (default) or 'logical'. 'logical' collapses mailbox-duplicate copies (same subject+sender+date_received, e.g. Gmail INBOX/Archive/All Mail) to one row server-side. Valid with projection 'ids', 'summary', or 'count' — not 'full' (#208/#177).")])
                    ]),
                    "required": .array([.string("query")])
                ])
            ),
            Tool(
                name: "get_unread_count",
                description: "Get the number of unread emails",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name (optional)")]),
                        "account_name": .object(["type": .string("string"), "description": .string("Account name (optional)")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID (from search_emails / list_accounts) to disambiguate accounts that share a display_name (#101). Used only by the AppleScript fallback path; the SQLite fast path is account-agnostic (#180).")])
                    ])
                ])
            ),

            // Email Action Tools
            Tool(
                name: "mark_read",
                description: "Mark an email as read or unread",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account (display_name)")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID for disambiguation when multiple accounts share a display_name (see #101). From search_emails results.")]),
                        "read": .object(["type": .string("boolean"), "description": .string("true=read, false=unread")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("read")])
                ])
            ),
            Tool(
                name: "flag_email",
                description: "Flag or unflag an email",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account (display_name)")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID for disambiguation when multiple accounts share a display_name (see #101). From search_emails results.")]),
                        "flagged": .object(["type": .string("boolean"), "description": .string("true=flag, false=unflag")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("flagged")])
                ])
            ),
            Tool(
                name: "move_email",
                description: "Move an email to another mailbox",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "from_mailbox": .object(["type": .string("string"), "description": .string("Source mailbox")]),
                        "to_mailbox": .object(["type": .string("string"), "description": .string("Destination mailbox")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account (display_name)")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID for disambiguation when multiple accounts share a display_name (see #101). From search_emails results.")])
                    ]),
                    "required": .array([.string("id"), .string("from_mailbox"), .string("to_mailbox"), .string("account_name")])
                ])
            ),
            Tool(
                name: "delete_email",
                description: "Delete an email (move to trash)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account (display_name)")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID for disambiguation when multiple accounts share a display_name (see #101). From search_emails results.")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name")])
                ])
            ),

            // Compose Tools
            Tool(
                name: "compose_email",
                description: "Compose and send a new email. The body always comes from Mail's own editor, never from an AppleScript body assignment — that assignment is what makes Mail wrap the whole letter in <blockquote type=\"cite\">, which the sender cannot see locally while Gmail and Outlook show it as quoted text (#304). When the clean path cannot run, the call FAILS with the reason and an alternative and creates/sends nothing. Exactly six reasons: format is not 'plain'; empty subject; Accessibility not granted (grant it, or use open_mailto — zero TCC, no attachments); from_address is not a bare addr-spec; an attachment path contains non-ASCII characters (create the draft without attachments and drag the file in, #220); a cc/bcc recipient carries a display name (use bare addresses; `to` display names are supported on drafts, #277). If the clean path fails AT the send-keystroke stage the tool does NOT retry (the mail may already be sent — a retry could send a duplicate): it returns an unknown-send-state error telling you to check Sent/Outbox before re-sending (#242).",

                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "to": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Recipient email addresses. Accepts bare addresses or RFC 5322 mailbox form (Name <a@b.c>, #251); a mailto URL carries addr-spec only (RFC 6068), so on create_draft / update_draft a list carrying ANY display name is filled through the compose window instead — the field is located by its AXIdentifier (Mail.toField / Mail.ccField / Mail.bccField), focused, pasted, Tab-committed, and its tokens are read back before saving (#277 to, #404 cc/bcc); a hidden Bcc field is revealed via View ▸ Bcc Address Field and left visible (result: bcc_field_revealed: true); after saving, cc/bcc addresses are re-read from the draft (result: recipients_verified: true|false + recipients_diff, draft kept either way). On compose_email (a SEND) any display name in to/cc/bcc is REFUSED — a fill that failed on a send would dispatch with missing recipients — use bare addresses, or create a draft and send it from Mail.")]),
                        "subject": .object(["type": .string("string"), "description": .string("Email subject")]),
                        "body": .object(["type": .string("string"), "description": .string("Email body content (interpreted according to 'format')")]),
                        "cc": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("CC recipients (optional). Accepts bare addresses or RFC 5322 mailbox form (Name <a@b.c>, #251); a mailto URL carries addr-spec only (RFC 6068), so on create_draft / update_draft a list carrying ANY display name is filled through the compose window instead — the field is located by its AXIdentifier (Mail.toField / Mail.ccField / Mail.bccField), focused, pasted, Tab-committed, and its tokens are read back before saving (#277 to, #404 cc/bcc); a hidden Bcc field is revealed via View ▸ Bcc Address Field and left visible (result: bcc_field_revealed: true); after saving, cc/bcc addresses are re-read from the draft (result: recipients_verified: true|false + recipients_diff, draft kept either way). On compose_email (a SEND) any display name in to/cc/bcc is REFUSED — a fill that failed on a send would dispatch with missing recipients — use bare addresses, or create a draft and send it from Mail.")]),
                        "bcc": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("BCC recipients (optional). Accepts bare addresses or RFC 5322 mailbox form (Name <a@b.c>, #251); a mailto URL carries addr-spec only (RFC 6068), so on create_draft / update_draft a list carrying ANY display name is filled through the compose window instead — the field is located by its AXIdentifier (Mail.toField / Mail.ccField / Mail.bccField), focused, pasted, Tab-committed, and its tokens are read back before saving (#277 to, #404 cc/bcc); a hidden Bcc field is revealed via View ▸ Bcc Address Field and left visible (result: bcc_field_revealed: true); after saving, cc/bcc addresses are re-read from the draft (result: recipients_verified: true|false + recipients_diff, draft kept either way). On compose_email (a SEND) any display name in to/cc/bcc is REFUSED — a fill that failed on a send would dispatch with missing recipients — use bare addresses, or create a draft and send it from Mail.")]),
                        "attachments": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Absolute file paths to attach (optional)")]),
                        "format": .object(["type": .string("string"), "enum": .array([.string("plain")]), "description": .string("Body format. \"plain\" is the ONLY supported value and the default when omitted: the body is delivered verbatim through Mail's own editor. \"markdown\" and \"html\" were removed in #304 — no path this server ships today can deliver rich text without assigning the AppleScript html-content property, and that is what wraps the whole letter in <blockquote type=\"cite\"> (invisible to the sender, shown as quoted text by Gmail and Outlook). That describes what EXISTS, not a proof of impossibility: whether a clipboard paste can carry rich text and stay wrapper-free is UNVERIFIED and is being settled in #306 (#310). Passing either value fails with that explanation; see #308 / #309 for alternative rich-text architectures.")]),
                        "from_address": .object(["type": .string("string"), "description": .string("Optional — email address (or 'Name <email>') of the account to send FROM. Must match one of your Mail.app accounts' addresses. Omit to use Mail.app's default account. Use list_accounts to discover available email addresses. Clean path supported (#219): the GUI selects this account via the compose window's From popup and READS BACK the selection, comparing addr-spec exactly — any mismatch aborts the call rather than risk sending from the wrong account. Needs Accessibility, and the address must be a bare addr-spec (a quoted local-part cannot be matched safely, so it is refused).")]),
                    ]),
                    "required": .array([.string("to"), .string("subject"), .string("body")])
                ])
            ),
            Tool(
                name: "reply_email",
                description: "Reply to an email. Mail's native reply verb builds the quoted original (correct threading headers and cite block) and only the NEW body is pasted in at the cursor. The body always comes from Mail's own editor, never from an AppleScript body assignment — that assignment is what makes Mail wrap the whole letter in <blockquote type=\"cite\">, which the sender cannot see locally while Gmail and Outlook show it as quoted text (#304). When the clean path cannot run, the call FAILS with the reason and an alternative and creates/sends nothing. Two reasons apply here: format is not 'plain'; Accessibility not granted. Optionally add extra CC, attach files, and save as draft instead of sending.",

                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID to reply to")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID for disambiguation when multiple accounts share a display_name (see #101). From search_emails results.")]),
                        "body": .object(["type": .string("string"), "description": .string("Reply content (interpreted according to 'format')")]),
                        "reply_all": .object(["type": .string("boolean"), "description": .string("Reply to all recipients (default: false)")]),
                        "cc_additional": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Extra CC recipients to add on top of those derived from 'reply_all'. Email addresses (RFC 5322 addr-spec). Also accepts RFC 5322 mailbox form (Name <a@b.c>, #251) - the reply paste path sets recipient names natively (no mailto involved, no path change).")]),
                        "attachments": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Absolute file paths to attach to the reply.")]),
                        "save_as_draft": .object(["type": .string("boolean"), "description": .string("If true, save the reply as a draft instead of sending it (default: false). Use when you want a human to review before send.")]),
                        "format": .object(["type": .string("string"), "enum": .array([.string("plain")]), "description": .string("Body format. \"plain\" is the ONLY supported value and the default when omitted: the body is delivered verbatim through Mail's own editor. \"markdown\" and \"html\" were removed in #304 — no path this server ships today can deliver rich text without assigning the AppleScript html-content property, and that is what wraps the whole letter in <blockquote type=\"cite\"> (invisible to the sender, shown as quoted text by Gmail and Outlook). That describes what EXISTS, not a proof of impossibility: whether a clipboard paste can carry rich text and stay wrapper-free is UNVERIFIED and is being settled in #306 (#310). Passing either value fails with that explanation; see #308 / #309 for alternative rich-text architectures.")]),
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("body")])
                ])
            ),
            Tool(
                name: "forward_email",
                description: "Forward an email. Mail's native forward verb builds the quoted original and only the NEW body is pasted in at the cursor. Body is optional — omit it for a bare forward, which assigns nothing at all and therefore needs no Accessibility grant. The body always comes from Mail's own editor, never from an AppleScript body assignment — that assignment is what makes Mail wrap the whole letter in <blockquote type=\"cite\">, which the sender cannot see locally while Gmail and Outlook show it as quoted text (#304). When the clean path cannot run, the call FAILS with the reason and an alternative and creates/sends nothing. When a body IS provided, exactly Two reasons can refuse the call: format is not 'plain'; Accessibility not granted.",

                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID to forward")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID for disambiguation when multiple accounts share a display_name (see #101). From search_emails results.")]),
                        "to": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Recipients to forward to")]),
                        "body": .object(["type": .string("string"), "description": .string("Optional message to add (interpreted according to 'format')")]),
                        "format": .object(["type": .string("string"), "enum": .array([.string("plain")]), "description": .string("Body format. \"plain\" is the ONLY supported value and the default when omitted: the body is delivered verbatim through Mail's own editor. \"markdown\" and \"html\" were removed in #304 — no path this server ships today can deliver rich text without assigning the AppleScript html-content property, and that is what wraps the whole letter in <blockquote type=\"cite\"> (invisible to the sender, shown as quoted text by Gmail and Outlook). That describes what EXISTS, not a proof of impossibility: whether a clipboard paste can carry rich text and stay wrapper-free is UNVERIFIED and is being settled in #306 (#310). Passing either value fails with that explanation; see #308 / #309 for alternative rich-text architectures.")]),
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("to")])
                ])
            ),

            // Draft Tools
            Tool(
                name: "list_drafts",
                description: "List all draft emails for one account. Each entry carries `subject` and the draft's numeric `id` (#276, additive) — the id feeds update_draft.draft_id and delete_email.id directly. Resolves the account's real drafts mailbox via Mail's unified drafts mailbox (works with localized/provider-specific names like Gmail's [Gmail]/草稿 — no hardcoded 'Drafts' lookup, see #174).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "account_name": .object(["type": .string("string"), "description": .string("Mail's AppleScript account name (the account description, e.g. 'Google') — often NOT the email address. Required; may mismatch or be ambiguous — prefer passing `account_id` alongside for reliable matching (mirrors the #101 pattern; account_name is ignored when account_id is non-empty).")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional: Mail.app account UUID, used alongside account_name. Discoverable from list_accounts or search_emails results (the `account_id` field). When non-empty, takes precedence over account_name.")])
                    ]),
                    "required": .array([.string("account_name")])
                ])
            ),
            Tool(
                name: "create_draft",
                description: "Create a new draft email. Display-name recipients (Name <email>) in to, cc AND bcc ride the clean path on DRAFTS: each list carrying a display name is omitted from the mailto URL and filled through the compose window — the field is located by its AXIdentifier (Mail.toField / Mail.ccField / Mail.bccField), focused, pasted from the clipboard, Tab-committed, and its tokens read back (count + display names) before the save (#277 to, #404 cc/bcc; needs Accessibility). A hidden Bcc field is revealed via View ▸ Bcc Address Field and deliberately left visible — the result says bcc_field_revealed: true. After the save, the draft's cc/bcc ADDRESSES are re-read and compared with the request: the result says recipients_verified: true, or recipients_verified: false with a recipients_diff — the draft is kept either way, never deleted. The body always comes from Mail's own editor, never from an AppleScript body assignment — that assignment is what makes Mail wrap the whole letter in <blockquote type=\"cite\">, which the sender cannot see locally while Gmail and Outlook show it as quoted text (#304). When the clean path cannot run, the call FAILS with the reason and an alternative and creates/sends nothing. Exactly six reasons: format is not 'plain'; empty subject; Accessibility not granted (grant it, or use open_mailto — zero TCC, no attachments); from_address is not a bare addr-spec; an attachment path contains non-ASCII characters (create the draft without attachments and drag the file in, #220); a to/cc/bcc recipient carries a display name on a SEND — never on a draft, where display names are GUI-filled (#277/#404).",

                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "to": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Recipient email addresses. Accepts bare addresses or RFC 5322 mailbox form (Name <a@b.c>, #251). On a DRAFT, display-name To recipients ride the clean (non-wrapped) path via GUI fill (#277, needs Accessibility) — verify To in the saved draft; without Accessibility, or on compose_email (send), display names route via the legacy path (name shown natively, body wrapped + disclosed).")]),
                        "cc": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Carbon copy recipients (optional). Accepts bare addresses or RFC 5322 mailbox form (Name <a@b.c>, #251). Display-name CC recipients ALWAYS route via the legacy path (name native, body wrapped) — the clean-path GUI fill is To-only because Mail's Cc field can be hidden and a blind paste would drop it (#277). Bare-address cc rides the clean path.")]),
                        "bcc": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Blind carbon copy recipients (optional)")]),
                        "subject": .object(["type": .string("string"), "description": .string("Email subject")]),
                        "body": .object(["type": .string("string"), "description": .string("Email body content (interpreted according to 'format')")]),
                        "attachments": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Absolute file paths to attach (optional)")]),
                        "format": .object(["type": .string("string"), "enum": .array([.string("plain")]), "description": .string("Body format. \"plain\" is the ONLY supported value and the default when omitted: the body is delivered verbatim through Mail's own editor. \"markdown\" and \"html\" were removed in #304 — no path this server ships today can deliver rich text without assigning the AppleScript html-content property, and that is what wraps the whole letter in <blockquote type=\"cite\"> (invisible to the sender, shown as quoted text by Gmail and Outlook). That describes what EXISTS, not a proof of impossibility: whether a clipboard paste can carry rich text and stay wrapper-free is UNVERIFIED and is being settled in #306 (#310). Passing either value fails with that explanation; see #308 / #309 for alternative rich-text architectures.")]),
                        "from_address": .object(["type": .string("string"), "description": .string("Optional — email address of the account to save the draft UNDER (sender selection). Must match one of your Mail.app accounts' addresses. Omit to use Mail.app's default account. Use list_accounts to discover available email addresses. Clean path supported (#219): the GUI selects this account via the compose window's From popup and READS BACK the selection, comparing addr-spec exactly — any mismatch aborts the call rather than risk sending from the wrong account. Needs Accessibility, and the address must be a bare addr-spec (a quoted local-part cannot be matched safely, so it is refused).")]),
                    ]),
                    "required": .array([.string("to"), .string("subject"), .string("body")])
                ])
            ),
            Tool(
                name: "update_draft",
                description: "Replace an existing draft (upsert): locate it by draft_id (from list_drafts) or an EXACT subject_match, create the replacement via the same mechanism and eligibility rules as create_draft, then delete the old draft. Order is deliberately create-THEN-delete with a post-create receipt — the failure direction is always toward keeping drafts (worst case both MAY exist, recoverable), never toward losing both; this is the reverse of the naive delete-first flow, chosen for data safety. Ambiguity always refuses: 0 matches (update requires an existing draft — use create_draft for a new one) or >1 matches (candidates {id, subject} are listed; retry with draft_id). Notes: Apple Mail drafts cannot be edited in place, so the replacement is a NEW draft with a NEW id (never reuse the old id); the replacement is created under create_draft's account semantics (default account unless from_address) which may differ from the old draft's account; the body inherits create_draft's refusal contract (#304) — the replacement is refused, and the OLD DRAFT LEFT UNTOUCHED, for any of the six reasons create_draft lists; on a draft a custom from_address (#219) and display-name to/cc/bcc recipients (#277/#404 — AX-addressed GUI fill with token read-back; a hidden Bcc field is revealed and left visible, reported as bcc_field_revealed: true) are supported when Accessibility is granted, and the replacement's cc/bcc addresses are re-read after the save (recipients_verified: true|false + recipients_diff in new_draft; the replacement is kept either way). Deletion moves the old draft to Trash (recoverable). The delete is double-gated: (a) a post-create RECEIPT re-lists the drafts and requires a NEW id to appear before the old draft is touched (a GUI-path phantom success keeps the old draft, reported as deleted_old:false / not confirmed); (b) the delete predicate conjoins id AND exact subject, so a cross-account id collision cannot delete another account's draft. If deletion fails after a confirmed create, the result reports deleted_old:false with a note matched to what is known (confirmed absent / state unknown / both MAY exist) — nothing is silently lost or over-claimed.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "draft_id": .object(["type": .string("string"), "description": .string("Numeric id of the draft to replace (from list_drafts). Exactly one of draft_id / subject_match is required.")]),
                        "subject_match": .object(["type": .string("string"), "description": .string("EXACT subject equality match (never substring/fuzzy — misfires would delete the wrong draft; must be non-empty — target an empty-subject draft via draft_id). Refuses when 0 or >1 drafts match. Exactly one of draft_id / subject_match is required.")]),
                        "account_name": .object(["type": .string("string"), "description": .string("Optional: scope the draft search to one account (Mail's AppleScript account name, e.g. 'Google'). Omit to search all accounts' drafts (same-subject drafts across accounts then refuse as ambiguous). Prefer account_id alongside for reliable matching.")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional: Mail.app account UUID (from list_accounts). When non-empty, takes precedence over account_name for scoping.")]),
                        "to": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Replacement draft recipients — same semantics as create_draft.to (RFC 5322 mailbox form allowed; since update_draft is a draft, display names in to/cc/bcc ride the clean non-wrapped path via AX-addressed GUI fill with Accessibility, #277/#404).")]),
                        "cc": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Replacement cc (optional) — same semantics as create_draft.cc (display names supported on drafts, #404).")]),
                        "bcc": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Replacement bcc (optional) — same semantics as create_draft.bcc (display names supported on drafts; a hidden Bcc field is revealed and left visible, #404).")]),
                        "subject": .object(["type": .string("string"), "description": .string("Replacement draft subject.")]),
                        "body": .object(["type": .string("string"), "description": .string("Replacement body content (interpreted according to 'format').")]),
                        "attachments": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Absolute file paths to attach to the replacement (optional).")]),
                        "format": .object(["type": .string("string"), "enum": .array([.string("plain")]), "description": .string("Body format. \"plain\" is the ONLY supported value and the default when omitted: the body is delivered verbatim through Mail's own editor. \"markdown\" and \"html\" were removed in #304 — no path this server ships today can deliver rich text without assigning the AppleScript html-content property, and that is what wraps the whole letter in <blockquote type=\"cite\"> (invisible to the sender, shown as quoted text by Gmail and Outlook). That describes what EXISTS, not a proof of impossibility: whether a clipboard paste can carry rich text and stay wrapper-free is UNVERIFIED and is being settled in #306 (#310). Passing either value fails with that explanation; see #308 / #309 for alternative rich-text architectures.")]),
                        "from_address": .object(["type": .string("string"), "description": .string("Optional — sender account for the REPLACEMENT draft. Same semantics as create_draft.from_address: verified From popup (#219, read-back gated — a mismatch aborts and leaves the old draft untouched); omit to use the default account.")])
                    ]),
                    "required": .array([.string("to"), .string("subject"), .string("body")])
                ])
            ),

            // Attachment Tools
            Tool(
                name: "list_attachments",
                description: "List attachments of an email. Each item carries `savable` (whether save_attachment can fulfill it from the local Mail store) and, when false, `savable_reason`: 'not_downloaded' (the content is server-side only — open the message in Mail to fetch it, #238) vs 'not_extractable'.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID (from search_emails / list_accounts) to disambiguate accounts that share a display_name (#101). Used only by the AppleScript fallback path; the SQLite fast path is account-agnostic (#180).")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name")])
                ])
            ),
            Tool(
                name: "save_attachment",
                description: "Save an email attachment to disk. Optionally accepts `account_id` (UUID) for disambiguation when multiple Mail.app accounts share the same `display_name` (e.g., iCloud catch-all alias + Gmail with the same address — #101). When provided, the AppleScript fallback path uses Mail.app's globally-unique `account id` selector; when omitted, falls back to the legacy `account_name` (display_name) form for backward compatibility.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account (display_name). Required, but may be ambiguous if multiple accounts share the same display_name — prefer passing `account_id` alongside for disambiguation.")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional: Mail.app account UUID for disambiguation. Discoverable from search_emails results (the `account_id` field) or from list_accounts (the `id` / `uuid` field). When non-empty, takes precedence over account_name in the AppleScript fallback path.")]),
                        "attachment_name": .object(["type": .string("string"), "description": .string("Name of the attachment to save")]),
                        "save_path": .object(["type": .string("string"), "description": .string("Full path where to save the file")]),
                        "download_if_missing": .object(["type": .string("boolean"), "description": .string("Optional (default false). BEST-EFFORT, NOT GUARANTEED (#272): when the attachment is server-side only (savable_reason 'not_downloaded'), first nudge Mail to fetch the full message, then re-attempt the save for up to ~30s. Mail exposes no real per-attachment download command, so this relies on materializing the message to pull its content — an undocumented, version-/account-dependent side effect that may not work (notably on accounts where the save simply errors). On timeout it fails honestly with the not_downloaded guidance (never a false success); if it does not help, open the message in Mail manually. Scope: effective only for accounts with local .emlx message storage (IMAP/POP) whose not_downloaded state was detected locally — it is a silent no-op on Exchange/EWS accounts (no .emlx) and when the local index is unavailable. Leave off for normal saves.")]),
                        "allow_empty": .object(["type": .string("boolean"), "description": .string("Optional (default false). Accept a 0-byte write as success, for an attachment that is GENUINELY empty (#347). Leave off unless you have positive reason to believe the attachment has no content: a 0-byte result is normally Mail failing to produce the bytes (#314), and that failure is invisible to a count-based archive audit — which is why it is rejected by default. Nothing in the envelope distinguishes the two cases (list_attachments carries no size), so this is your attestation, not a check. When it is used, the success string says so explicitly — 'Attachment saved to … (0 bytes — empty write accepted via allow_empty)' — so an archive manifest records which files were accepted this way. Does NOT relax anything else: a missing file or a non-regular save_path is still rejected.")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("attachment_name"), .string("save_path")])
                ])
            ),

            // VIP Tools
            Tool(
                name: "list_vip_senders",
                description: "List VIP senders",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),

            // Rule Tools
            Tool(
                name: "list_rules",
                description: "List all mail rules",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "enable_rule",
                description: "Enable or disable a mail rule",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Name of the rule")]),
                        "enabled": .object(["type": .string("boolean"), "description": .string("true=enable, false=disable")])
                    ]),
                    "required": .array([.string("name"), .string("enabled")])
                ])
            ),
            Tool(
                name: "get_rule_details",
                description: "Get detailed information about a mail rule",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Name of the rule")])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),
            Tool(
                name: "create_rule",
                description: "Create a new mail rule",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Name of the rule")]),
                        "conditions": .object(["type": .string("array"), "description": .string("Array of conditions with header, qualifier, expression")]),
                        "actions": .object(["type": .string("object"), "description": .string("Actions: move_message, mark_read, mark_flagged, delete_message")])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),
            Tool(
                name: "delete_rule",
                description: "Delete a mail rule",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Name of the rule to delete")])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),

            // Mail Check & Sync Tools
            Tool(
                name: "check_for_new_mail",
                description: "Trigger a check for new email",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "account_name": .object(["type": .string("string"), "description": .string("Account to check (optional, checks all if omitted)")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID (from list_accounts / search_emails) — takes precedence over account_name. Lets an email-form account_name resolve to the collision-free UUID selector instead of the account description, avoiding -1728 (#191).")])
                    ])
                ])
            ),
            Tool(
                name: "synchronize_account",
                description: "Synchronize an IMAP account with the server. Supply account_name (description) and/or account_id (UUID) — at least one is required.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "account_name": .object(["type": .string("string"), "description": .string("Account to synchronize (the Mail account description). Optional if account_id is supplied (#191).")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Account UUID (from list_accounts / search_emails) — takes precedence over account_name, and can be supplied alone. Lets an email-form account_name resolve to the collision-free UUID selector instead of the account description, avoiding -1728 (#191).")])
                    ])
                    // No `required`: at least one of account_name / account_id is enforced
                    // in the handler (#191 — account_id is a genuine standalone escape hatch).
                ])
            ),

            // Advanced Email Tools
            Tool(
                name: "copy_email",
                description: "Copy an email to another mailbox",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "from_mailbox": .object(["type": .string("string"), "description": .string("Source mailbox")]),
                        "to_mailbox": .object(["type": .string("string"), "description": .string("Destination mailbox")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account (display_name)")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID for disambiguation when multiple accounts share a display_name (see #101). From search_emails results.")])
                    ]),
                    "required": .array([.string("id"), .string("from_mailbox"), .string("to_mailbox"), .string("account_name")])
                ])
            ),
            Tool(
                name: "set_flag_color",
                description: "Set the flag color of an email (0=red, 1=orange, 2=yellow, 3=green, 4=blue, 5=purple, 6=gray, -1=clear)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account (display_name)")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID for disambiguation when multiple accounts share a display_name (see #101). From search_emails results.")]),
                        "color_index": .object(["type": .string("integer"), "description": .string("Flag color index (0-6, or -1 to clear)")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("color_index")])
                ])
            ),
            Tool(
                name: "set_background_color",
                description: "Set the background color of an email (blue, gray, green, none, orange, purple, red, yellow)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account (display_name)")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID for disambiguation when multiple accounts share a display_name (see #101). From search_emails results.")]),
                        "color": .object(["type": .string("string"), "description": .string("Background color: blue, gray, green, none, orange, purple, red, yellow")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("color")])
                ])
            ),
            Tool(
                name: "mark_as_junk",
                description: "Mark an email as junk or not junk",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account (display_name)")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID for disambiguation when multiple accounts share a display_name (see #101). From search_emails results.")]),
                        "is_junk": .object(["type": .string("boolean"), "description": .string("true=junk, false=not junk")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("is_junk")])
                ])
            ),
            Tool(
                name: "get_email_headers",
                description: "Get all headers of an email",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID (from search_emails / list_accounts) to disambiguate accounts that share a display_name (#101). Used only by the AppleScript fallback path; the SQLite fast path is account-agnostic (#180).")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name")])
                ])
            ),
            Tool(
                name: "get_email_source",
                description: "Get the raw source of an email",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID (from search_emails / list_accounts) to disambiguate accounts that share a display_name (#101). Used only by the AppleScript fallback path; the SQLite fast path is account-agnostic (#180).")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name")])
                ])
            ),
            Tool(
                name: "redirect_email",
                description: "Redirect an email (keeps original sender, different from forward)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID for disambiguation when multiple accounts share a display_name (see #101). From search_emails results.")]),
                        "to": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Recipients to redirect to. Accepts bare addresses or RFC 5322 mailbox form (Name <a@b.c>, #263) - redirect is pure AppleScript (no mailto involved), so the name is set natively with no path change.")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("to")])
                ])
            ),
            Tool(
                name: "get_email_metadata",
                description: "Get email metadata (was forwarded, replied, redirected, size)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID (from search_emails / list_accounts) to disambiguate accounts that share a display_name (#101). Used only by the AppleScript fallback path; the SQLite fast path is account-agnostic (#180).")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name")])
                ])
            ),

            // Signature Tools
            Tool(
                name: "list_signatures",
                description: "List all email signatures",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "get_signature",
                description: "Get the content of a signature",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Name of the signature")])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),

            // SMTP Server Tools
            Tool(
                name: "list_smtp_servers",
                description: "List all SMTP servers",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),

            // Special Mailboxes
            Tool(
                name: "get_special_mailboxes",
                description: "Get special mailbox names. Without account_id/account_name: the app-level unified names (inbox, drafts, sent, trash, junk, outbox). With an account selector: that account's per-account special-mailbox real (localized/provider) LEAF names (inbox, drafts, sent, trash, junk) — e.g. a Gmail account returns drafts \"草稿\", junk \"垃圾郵件\"; an Exchange account's inbox can localize (收件匣) (#179/#249). outbox stays unified-only. In the per-account mode each present type ALSO carries a `<type>_path` field with the FULL mailbox path (e.g. drafts_path \"[Gmail]/草稿\") derived from the Mail Envelope Index — the same representation `search_emails`'s `mailbox` field uses (#315; requires Full Disk Access). `<type>_path` is OMITTED whenever it cannot be resolved unambiguously: no index access (e.g. EWS accounts / missing FDA), an unknown leaf, or a leaf whose match cannot be corroborated. Corroboration matters because a unique leaf match is NOT proof of identity (#345): an ordinary `Projects/Drafts` folder matches the leaf `Drafts` uncontested when the real drafts mailbox is not in the index yet. A NESTED path is therefore returned only when another special mailbox of the same account resolves under the SAME parent container — which is what makes `[Gmail]/草稿` trustworthy (`[Gmail]` also holds sent/junk/trash) and `Projects/Drafts` not. Position is never used as evidence. Consumers MUST keep a leaf-based fallback for the absent-`_path` case — an absent path is an honest signal, not an error (the leaf `<type>` is always present when the mailbox exists). A present path equals the leaf exactly when the mailbox is genuinely top-level.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID (from list_accounts / search_emails). When supplied, returns this account's per-account special-mailbox real names instead of the unified names (#179).")]),
                        "account_name": .object(["type": .string("string"), "description": .string("Optional account selector. An email address is resolved to the account UUID; otherwise matched against Mail's account name (description). Supply account_id for unambiguous matching.")])
                    ])
                ])
            ),

            // Address Tools
            Tool(
                name: "extract_name_from_address",
                description: "Extract the name from a full email address (e.g., 'John Doe <john@example.com>' -> 'John Doe')",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "address": .object(["type": .string("string"), "description": .string("Full email address")])
                    ]),
                    "required": .array([.string("address")])
                ])
            ),
            Tool(
                name: "extract_address",
                description: "Extract the email address from a full address string (e.g., 'John Doe <john@example.com>' -> 'john@example.com')",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "address": .object(["type": .string("string"), "description": .string("Full email address")])
                    ]),
                    "required": .array([.string("address")])
                ])
            ),

            // Application Tools
            Tool(
                name: "get_mail_app_info",
                description: "Get Mail application information (version, fetch interval, background activity)",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "open_mailto",
                description: "Open a mailto URL in the system default mail client via LaunchServices — ZERO Automation TCC required (#287), so it works even when AppleScript tools fail with -1743 (Not authorized to send Apple events). The mailto compose window is inherently cite-block-free (#175). Cite-block-avoidance ladder: (a) create_draft clean path — needs Automation + Accessibility TCC, carries attachments; (b) THIS TOOL — zero TCC, no attachments (RFC 6068; drag files in manually), window opens in the default mail app which may not be Mail.app; (c) legacy AppleScript injection — body wrapped in blockquote type=cite, unacceptable for formal mail. When TCC is not granted (-1743), (b) is the correct path — never fall to (c).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "url": .object(["type": .string("string"), "description": .string("mailto URL (e.g., 'mailto:test@example.com?subject=Hello')")])
                    ]),
                    "required": .array([.string("url")])
                ])
            ),

            // Import Tools
            Tool(
                name: "import_mailbox",
                description: "Import a mailbox from a file",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string"), "description": .string("Path to the mailbox file to import")])
                    ]),
                    "required": .array([.string("path")])
                ])
            ),

            // Batch Tools
            Tool(
                name: "get_emails_batch",
                description: "Get full content of multiple emails in a single call. Much faster than calling get_email repeatedly. Returns results for each email, including errors for any that failed.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "emails": .object([
                            "type": .string("array"),
                            "description": .string("Array of email identifiers"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                                    "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                                    "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                                    "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID (from search_emails / list_accounts) to disambiguate accounts that share a display_name (#101). Used only by the AppleScript fallback path; the SQLite fast path is account-agnostic (#180).")])
                                ]),
                                "required": .array([.string("id"), .string("mailbox"), .string("account_name")])
                            ])
                        ]),
                        "format": .object(["type": .string("string"), "description": .string("Content format: 'html' (default), 'text', 'source'")])
                    ]),
                    "required": .array([.string("emails")])
                ])
            ),
            Tool(
                name: "list_attachments_batch",
                description: "List attachments for multiple emails in a single call. Returns attachment lists for each email, including errors for any that failed.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "emails": .object([
                            "type": .string("array"),
                            "description": .string("Array of email identifiers"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                                    "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                                    "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                                    "account_id": .object(["type": .string("string"), "description": .string("Optional account UUID (from search_emails / list_accounts) to disambiguate accounts that share a display_name (#101). Used only by the AppleScript fallback path; the SQLite fast path is account-agnostic (#180).")])
                                ]),
                                "required": .array([.string("id"), .string("mailbox"), .string("account_name")])
                            ])
                        ])
                    ]),
                    "required": .array([.string("emails")])
                ])
            ),
            Tool(
                name: "batch_export_emails_markdown",
                description: exportEmailsMarkdownDescription,
                inputSchema: exportEmailsMarkdownInputSchema
            ),
            Tool(
                name: "export_emails_markdown",
                description: "DEPRECATED — renamed to batch_export_emails_markdown; this alias will not be removed before the next major release (v3.0). "
                    + exportEmailsMarkdownDescription,
                inputSchema: exportEmailsMarkdownInputSchema
            ),
        ]
    }

    /// #233 — the canonical batch-export description, shared by the canonical
    /// name and the deprecated alias so the two registrations can never diverge.
    static let exportEmailsMarkdownDescription =
        "Export a batch of emails to verbatim markdown files server-side (frozen 6-field frontmatter + verbatim body), optionally with attachments, into an allowed-roots-validated output_dir. Returns a per-email manifest. Designed for large archive jobs: one call replaces per-email fetch + client-side transcription. Concurrency contract (#236): exports to the SAME output_dir are serialized via an advisory lock (.export.lock) — an overlapping call fails fast with a clear error instead of silently overwriting colliding filenames; wait for the other run and retry. Different output_dirs run freely in parallel. The lock serializes same-host runs on a local filesystem only (flock semantics) — two machines exporting to one cloud-synced folder are not coordinated."

    /// #233 — the shared input schema (see the description note above).
    static let exportEmailsMarkdownInputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "ids": .object([
                "type": .string("array"),
                "description": .string("Array of message id strings (SQLite rowIds)"),
                "items": .object(["type": .string("string")])
            ]),
            "mailbox": .object(["type": .string("string"), "description": .string("Optional mailbox name. Direction is derived per email from sender identity (sender matches one of your accounts' addresses → sent, else received); this label is only the fallback direction source when identity CANNOT be established for that email — its account resolves to no address (EWS accounts, whose AccountURL is an opaque store id), no own address resolved at all, or the From header does not parse. Those items carry direction_inferred: true in the manifest. KNOWN LIMIT (#343): the index maps each account to ONE address, so mail you sent from an ALIAS on a resolvable account matches nothing and is written 'received' WITHOUT direction_inferred — an absent direction_inferred therefore means 'no address of any configured account matched, and this email's account does contribute at least one address', not 'every address you own was considered'")]),
            "account_name": .object(["type": .string("string"), "description": .string("Optional mail account (accepted for consistency; the SQLite fast path is account-agnostic)")]),
            "output_dir": .object(["type": .string("string"), "description": .string("Directory to write .md files into. Must resolve under the user's home (path traversal and system directories are rejected).")]),
            "skip_message_ids_path": .object(["type": .string("string"), "description": .string("Optional dedup escape hatch (#177): path to a file listing already-archived RFC 5322 Message-IDs (one per line; blank lines and `#` comments ignored). Emails whose Message-ID is in the set are skipped (status 'skipped', counted in the manifest's `skipped`), not rewritten — so a re-run only writes new mail. Validated read-only under the same allowed-roots policy as output_dir; missing/unreadable file → no skips.")]),
            "opts": .object([
                "type": .string("object"),
                "description": .string("Optional export options"),
                "properties": .object([
                    "include_attachments": .object(["type": .string("boolean"), "description": .string("Also export each email's attachments (data extensions → output_dir/data/, others → output_dir/attachments/<stem>/)")]),
                    "skip_partial": .object(["type": .string("boolean"), "description": .string("Opt-in (#283): when an email's on-disk .emlx is a partial (Mail stores it as <rowid>.partial.emlx) AND the body the .md would carry is empty, do NOT write a header-only .md; record it as status 'header_only' with body_downloaded:false instead. Default false = still written but annotated (manifest item gets body_downloaded:false, summary gets body_not_downloaded count) so bulk archives are never silently header-only. With skip_partial:true the clean re-export loop is: re-fetch flagged ids via single get_email (its fallback nudges Mail to download the body), then re-run export for just those ids — nothing stale is on disk and the skipped email's filename slot is reserved, so the re-export lands on its original name. Under the DEFAULT mode that loop is NOT safe as-is: the header-only .md was really written, so a re-export collides into a -N-suffixed duplicate next to the stale file — delete each flagged item's written_path first (or use skip_partial:true from the start).")]),
                    "filename_template": .object(["type": .string("string"), "description": .string("Override filename with placeholders {date}/{subject}/{sender}/{message_id}")]),
                    "filenames": .object(["type": .string("object"), "description": .string("Per-id filename override map { id: name }")]),
                    "extra_frontmatter": .object(["type": .string("object"), "description": .string("Static key/value pairs appended to every file's frontmatter after the six core fields")])
                ])
            ])
        ]),
        "required": .array([.string("ids"), .string("output_dir")])
    ])

    // MARK: - Handler Registration

    private func registerHandlers() async {
        await server.withMethodHandler(ListTools.self) { [tools] _ in
            ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self = self else {
                return CallTool.Result(content: [.text(text: "Server unavailable", annotations: nil, _meta: nil)], isError: true)
            }
            return await self.handleToolCall(name: params.name, arguments: params.arguments ?? [:])
        }
    }

    // MARK: - Tool Call Handler

    private func handleToolCall(name: String, arguments: [String: Value]) async -> CallTool.Result {
        do {
            let result = try await executeToolCall(name: name, arguments: arguments)
            return CallTool.Result(content: [.text(text: result, annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private func executeToolCall(name: String, arguments: [String: Value]) async throws -> String {
        // Stable tool-name capture: several cases rebind `name` as a local
        // (`guard let name = arguments["name"]?...`), so `decodeAccountId`'s
        // diagnostics use `invokedTool` rather than the shadowed parameter.
        let invokedTool = name
        switch name {
        // Setup / diagnostics
        case "check_fda":
            let probe = FDAStatus.probe()
            switch probe {
            case .granted:
                // The probe reads the file; the SQLite open is a proxy, so phrase as
                // "should work" rather than asserting availability (#213 verify, DA #7).
                return "✅ " + FDAStatus.summary(probe)
                    + "\nThe SQLite fast path (search_emails projection, batch_export_emails_markdown) should now work."
            case .denied:
                return "⚠️ " + FDAStatus.summary(probe) + "\n\n"
                    + FullDiskAccessHelp.guidance(reason: "Full Disk Access is required for the SQLite fast path.")
            case .noMailData:
                // ENOENT is ambiguous (no Mail vs FDA-denied hiding the dir) — present
                // BOTH possibilities so an FDA-denied user isn't told the opposite of the fix.
                return "ℹ️ " + FDAStatus.summary(probe)
                    + "\nIf Apple Mail IS configured, this most likely means Full Disk Access is denied"
                    + " (a denial can hide ~/Library/Mail). Grant it:\n\n"
                    + FullDiskAccessHelp.guidance(reason: "If Full Disk Access is the cause:")
                    + "\n\nIf Mail genuinely isn't set up, add an account first, then re-check."
            case .undetermined:
                // An unexpected errno, not a clear TCC denial — offer the FDA steps conditionally.
                return "⚠️ " + FDAStatus.summary(probe)
                    + "\nThis is not a clear permission denial; retry first. If it persists and Full Disk"
                    + " Access might be the cause:\n\n"
                    + FullDiskAccessHelp.guidance(reason: "If Full Disk Access is the cause:")
            }

        case "check_accessibility":
            // #175: Accessibility is what lets compose_email / create_draft use
            // the wrapper-free mailto path (System Events keystrokes for save /
            // send / attach). Separate grant from Full Disk Access (check_fda).
            let probe = AccessibilityStatus.probe()
            switch probe {
            case .granted:
                return "✅ " + AccessibilityStatus.summary(probe)
                    + "\nEligible compose_email / create_draft calls (plain-text, a subject, a simple custom"
                    + " from_address rides the clean path via the verified From popup (#219), env hatch off) will"
                    + " attempt the wrapper-free mailto path (#175); other calls and any GUI-step failure fall back"
                    + " to the legacy path. Note: System Events keystrokes also rely on Automation (Apple Events)"
                    + " being allowed — this probe only checks Accessibility (AXIsProcessTrusted)."
            case .denied:
                return "⚠️ " + AccessibilityStatus.summary(probe) + "\n\n"
                    + AccessibilityStatus.guidance()
            case .unsupported:
                return "ℹ️ " + AccessibilityStatus.summary(probe)
            }

        // Account Tools
        case "check_automation":
            // #293: pure mapping unit-tested in AutomationStatusTests; the
            // probe is the thin live layer (attended residue).
            return AutomationStatus.report(for: AutomationStatus.probe())

        case "list_accounts":
            // Primary: AppleScript path — only way to resolve EWS display_name
            // (AccountsMap.plist has no email field, so SQLite/filesystem
            // fallback cannot recover the email for Exchange accounts).
            // See #11 for the full analysis.
            do {
                let accounts = try await mailController.listAccounts()
                return formatJSON(accounts)
            } catch {
                // Fallback: SQLite path, only if AppleScript fails (e.g., Mail.app
                // not running). Returns the same JSON schema but with empty
                // user_name / email_addresses for EWS accounts.
                if let reader = indexReader {
                    return formatJSON(reader.listAccounts())
                }
                throw error
            }

        case "get_account_info":
            guard let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("account_name is required")
            }
            // #202: resolve account_id (email→UUID upgrade / ambiguous-throw).
            let accountId = try resolveAccountIdForTool(accountId: decodeAccountId(arguments, tool: invokedTool), accountName: accountName, tool: invokedTool)
            if let reader = indexReader {
                let accounts = reader.listAccounts()
                // Match by resolved UUID when known (so an email-form account_name
                // works), else by name. Neither → the account doesn't exist; throw
                // rather than falling through to the AppleScript path's -1728.
                if let aid = accountId, !aid.isEmpty,
                   let acct = accounts.first(where: { ($0["id"] as? String) == aid }) {
                    return formatJSON(acct)
                }
                if let acct = accounts.first(where: { ($0["name"] as? String) == accountName }) {
                    return formatJSON(acct)
                }
                throw MailError.invalidParameter("account not found: \(accountName) — use list_accounts to see configured accounts (pass account_id to disambiguate an email-form name)")
            }
            let info = try await mailController.getAccountInfo(accountName: accountName, accountId: accountId)
            return formatJSON(info)

        // Mailbox Tools
        case "list_mailboxes":
            let accountName = arguments["account_name"]?.stringValue
            // #202: resolve account_id; an unresolvable name throws (in the reader
            // / resolveAccountIdForTool) instead of returning every account's boxes.
            let accountId = try resolveAccountIdForTool(accountId: decodeAccountId(arguments, tool: invokedTool), accountName: accountName ?? "", tool: invokedTool)
            if let reader = indexReader {
                let mailboxes = try reader.listMailboxes(accountName: accountName, accountId: accountId)
                return formatJSON(mailboxes)
            }
            let mailboxes = try await mailController.listMailboxes(accountName: accountName, accountId: accountId)
            return formatJSON(mailboxes)

        case "create_mailbox":
            guard let name = arguments["name"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("name and account_name are required")
            }
            let accountId = try resolveAccountIdForTool(accountId: decodeAccountId(arguments, tool: invokedTool), accountName: accountName, tool: invokedTool)
            return try await mailController.createMailbox(name: name, accountName: accountName, accountId: accountId)

        case "delete_mailbox":
            guard let name = arguments["name"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("name and account_name are required")
            }
            let accountId = try resolveAccountIdForTool(accountId: decodeAccountId(arguments, tool: invokedTool), accountName: accountName, tool: invokedTool)
            return try await mailController.deleteMailbox(name: name, accountName: accountName, accountId: accountId)

        // Email Reading Tools
        case "list_emails":
            guard let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("mailbox and account_name are required")
            }
            let limit = arguments["limit"]?.intValue ?? 50
            // #89: SQLite fast path is O(LIMIT) regardless of mailbox size
            // (proper LIMIT clause + indexed query on Envelope Index). The
            // AppleScript fallback below runs `count of messages of mb` +
            // `messages 1 thru limit` × 3 separate IPC calls — on Gmail
            // INBOX with 92k messages, the count operation alone can take
            // 14+ minutes (per #89 bug report on v2.1.0 pre-SQLite).
            //
            // Pre-#89: SQLite was already the default path but had NO
            // do/catch wrapper — a SQLite throw (corrupt row, schema drift)
            // would propagate to the caller instead of falling through to
            // the AppleScript path. Stderr log was also missing, so silent
            // SQLite failures had no observability.
            //
            // Post-#89: mirror the canonical pattern from save_attachment
            // (#12) / get_email_metadata (#71) — try SQLite, on throw log
            // to stderr + fall through to AppleScript. Matches the
            // "list_attachments emlx validation failed" pattern (#24).
            if let reader = indexReader {
                do {
                    let page = try reader.listEmailsPage(mailbox: mailbox, accountName: accountName, limit: limit)
                    return formatJSON(Self.resultEnvelope(results: page.results, limit: limit, truncated: page.truncated))
                } catch MailSQLiteError.mailboxNotResolvable(let name, let candidates) {
                    // #344 — this catch exists for INFRASTRUCTURE failure
                    // (corrupt row, schema drift), where retrying through
                    // AppleScript is the right move. A near-miss verdict is the
                    // opposite: the fast path succeeded and determined the name
                    // does not resolve. Falling through would hand AppleScript
                    // the same name and, on a miss, return the silent zero this
                    // diagnostic exists to abolish.
                    //
                    // BUT only when AppleScript could not have done better
                    // (#344 verify round 1). `listEmailsPage` takes no
                    // `account_id`: it resolves a display name to the FIRST
                    // matching UUID, so with two accounts sharing a name it can
                    // scan the wrong one, miss, and report a near-miss for a
                    // mailbox the caller never asked about — while the
                    // AppleScript path below, which DOES take `account_id`,
                    // would have resolved it correctly. Rethrowing there turns a
                    // working call into an error, so when the caller supplied an
                    // `account_id` the verdict is logged and the fallback runs.
                    if (decodeAccountId(arguments, tool: invokedTool) ?? "").isEmpty {
                        throw MailSQLiteError.mailboxNotResolvable(name: name, candidates: candidates)
                    }
                    Diagnostics.emit(
                        "list_emails: SQLite mailbox filter found no match for '\(name)' "
                        + "(near-miss: \(candidates.joined(separator: ", "))), but an account_id was "
                        + "supplied and the fast path cannot use it — falling through to "
                        + "AppleScript, which can (#344)\n")
                } catch {
                    let message = "SQLite list_emails fast path failed for "
                        + "mailbox='\(mailbox)' account='\(accountName)': "
                        + "\(error.localizedDescription); falling through to AppleScript\n"
                    Diagnostics.emit(message)
                }
            }
            let accountId = decodeAccountId(arguments, tool: invokedTool)
            let emails = try await mailController.listEmails(mailbox: mailbox, accountName: accountName, accountId: accountId, limit: limit)
            // Fallback can't fetch limit+1 cheaply; truncated is best-effort heuristic (#204).
            return formatJSON(Self.resultEnvelope(results: emails, limit: limit, truncated: emails.count == limit))

        case "get_email":
            let id = try requireMessageId(arguments)
            // #299: `mailbox` / `account_name` are OPTIONAL. A numeric rowId is
            // self-addressing — the Envelope Index maps it to the account UUID
            // and the account's real mailbox path, which is a STRICTLY better
            // selector than a caller-supplied display name (globally unique, so
            // immune to the #101/#176 collision class). This is what makes the
            // materialization nudge below reachable at all for callers who only
            // ever received an id: an export manifest item carries no account,
            // and `search_emails`' summary/ids projections omit it too, so the
            // documented re-fetch loop used to demand a value the pipeline never
            // handed out — a wrong guess failed resolution (-1719) and the nudge
            // was never delivered (#299). Supplying the pair explicitly keeps
            // the exact pre-#299 selector.
            let suppliedMailbox = arguments["mailbox"]?.stringValue
            let suppliedAccountName = arguments["account_name"]?.stringValue
            let format = arguments["format"]?.stringValue ?? "html"
            // Try SQLite/emlx first, fall back to AppleScript

            // #274: set when the fast path found only a partial .emlx with no
            // body — the AppleScript fallback below then doubles as the fetch
            // nudge, and its result is annotated if the body is STILL absent.
            var partialBodyFallback = false
            // #299: the rowId-derived addressing pair, captured from the same
            // index lookup the fast path already performs (no extra query).
            var derivedLocation: ResolvedMessageLocation?
            // #299 verify: retain the Tier-1 read so an unaddressable Tier 2
            // degrades to "headers + body_downloaded:false" instead of losing a
            // result we already have. Also track whether the rowId was indexed,
            // so the unaddressable error can name the real cause.
            var partialContent: EmailContent?
            var rowIdWasIndexed = false
            if let reader = indexReader, let rowId = Int(id) {
                do {
                    if let mailboxUrl = try reader.mailboxURL(forMessageId: rowId) {
                        rowIdWasIndexed = true
                        // #299: capture BEFORE the content read — the addressing
                        // is needed precisely on the path where that read
                        // succeeds-but-empty (the nudge case).
                        derivedLocation = resolveMessageLocation(fromMailboxURL: mailboxUrl)
                        let content = try EmlxParser.readEmail(rowId: rowId, mailboxURL: mailboxUrl, format: format)
                        if Self.partialBodyNotDownloaded(content: content, format: format) {
                            // #274: a partial .emlx with an empty body means
                            // "not downloaded", NOT "empty message" — returning
                            // it as success was the silent header-only path.
                            partialBodyFallback = true
                            partialContent = content
                            logFastPathFallthrough(tool: "get_email", rowId: rowId,
                                                   reason: .partialBodyNotDownloaded)
                        } else {
                            return formatJSON(Self.emailResultObject(id: id, content: content))
                        }
                    } else {
                        // `mailboxURL` returned nil (rowId not in the Envelope
                        // Index). #69 only logged the `catch` path — this
                        // `nil`-return fall-through was silent (#100).
                        logFastPathFallthrough(tool: "get_email", rowId: rowId, reason: .rowIdNotIndexed)
                    }
                } catch {
                    // Log the cause so silent fallbacks are observable, then
                    // fall through to AppleScript (#69 — mirrors the
                    // save_attachment fast-path logging at Server.swift:1003).
                    logFastPathFallthrough(tool: "get_email", rowId: rowId,
                                           reason: .error(error.localizedDescription))
                }
            }
            let accountId = decodeAccountId(arguments, tool: invokedTool)
            // #299: decide what the AppleScript fallback addresses with. A
            // COMPLETE caller-supplied pair wins verbatim; anything less uses
            // the whole rowId-derived pair (never a mix — see the atomicity
            // rationale on `resolveFallbackAddressing`).
            let derivedAddressing = Self.resolveFallbackAddressing(
                suppliedMailbox: nil, suppliedAccountId: nil,
                suppliedAccountName: nil, derived: derivedLocation)
            guard let addressing = Self.resolveFallbackAddressing(
                    suppliedMailbox: suppliedMailbox, suppliedAccountId: accountId,
                    suppliedAccountName: suppliedAccountName, derived: derivedLocation) else {
                // #299 verify: this input was IMPOSSIBLE before the relaxation
                // (the schema required the pair), so throwing here would be a
                // regression introduced by the relaxation itself. When Tier 1
                // already produced a usable header-only read, return it —
                // annotated — instead of losing it.
                if let partial = partialContent {
                    var result = Self.emailResultObject(id: id, content: partial)
                    result["body_downloaded"] = false
                    result["nudge_delivered"] = false
                    return formatJSON(result)
                }
                throw MailError.invalidParameter(Self.unaddressableMessageHint(
                    id: id, indexAvailable: indexReader != nil, rowIdIndexed: rowIdWasIndexed))
            }
            // #299 verify fix: the retry target is the derived pair, but only
            // when it selects a DIFFERENT target than the attempt about to run —
            // otherwise the retry is a byte-identical second Mail round-trip.
            var retryTarget: EmailFallbackAddressing?
            if let d = derivedAddressing, !Self.addressesSameTarget(d, addressing) {
                retryTarget = d
            }
            var email: [String: Any]
            var addressedViaDerived = addressing.usedDerived
            do {
                email = try await mailController.getEmail(
                    id: id, mailbox: addressing.mailbox, accountName: addressing.accountName,
                    accountId: addressing.accountId, format: format)
            } catch MailError.scriptFailed(let message, let code)
                        where shouldRetryWithDerivedLocation(code: code) && retryTarget != nil {
                // #299 verify fix: gate the retry on the derived pair selecting a
                // DIFFERENT target, not on provenance. The earlier `!usedDerived`
                // gate disarmed the retry for exactly the callers this change
                // exists to serve (a `summary` projection hands out a mailbox but
                // no account), and could re-run a byte-identical call when the
                // caller happened to supply the derived pair itself.
                let retry = retryTarget!   // non-nil per the where-clause
                // Log the substitution (rowId + code only — a mailbox path is
                // user data and these logs get pasted into issue reports).
                Diagnostics.emit((
                    "get_email: supplied mailbox/account failed AppleScript resolution "
                    + "(code \(code)) for rowId \(id); retrying with the pair derived from "
                    + "the Envelope Index (#299)\n"))
                do {
                    email = try await mailController.getEmail(
                        id: id, mailbox: retry.mailbox, accountName: retry.accountName,
                        accountId: retry.accountId, format: format)
                } catch {
                    // Keep the FIRST diagnosis — "your selector was wrong" is more
                    // actionable than whatever the retry hit.
                    throw MailError.scriptFailed(
                        message: "\(message) (derived-location retry also failed: "
                            + "\(error.localizedDescription))", code: code)
                }
                addressedViaDerived = true
            }
            // #299 verify: disclose a substituted selector IN THE RESULT, not
            // only on stderr — the repo's #237 precedent (`[legacy path — …]`)
            // exists because a caller who cannot see the substitution cannot
            // decide about it. A caller who scoped the read to a mailbox must be
            // able to tell that the answer came from somewhere else.
            if addressedViaDerived { email["addressed_via"] = "derived_from_rowid" }
            if partialBodyFallback,
               Self.fallbackBodyStillMissing((email["content"] as? String) ?? "", format: format) {
                // #274: the store had only a partial file AND the AppleScript
                // read still carries no body (format-aware: a header-only
                // source is non-empty but body-less — verify R1, Codex). The
                // fetch nudge hasn't landed (yet — the IMAP fetch may also be
                // asynchronous; a later re-read can succeed). Machine-readable
                // signal so "not downloaded" is never mistaken for "empty
                // message".
                email["body_downloaded"] = false
            }
            return formatJSON(email)

        case "search_emails":
            guard let query = arguments["query"]?.stringValue else {
                throw MailError.invalidParameter("query is required")
            }
            let mailbox = arguments["mailbox"]?.stringValue
            let accountName = arguments["account_name"]?.stringValue
            let limit = arguments["limit"]?.intValue ?? 50
            let sort = arguments["sort"]?.stringValue ?? "desc"
            let fieldStr = arguments["field"]?.stringValue ?? "any"
            let dateFromStr = arguments["date_from"]?.stringValue
            let dateToStr = arguments["date_to"]?.stringValue
            // #194: parse field + date bounds ONCE so BOTH the SQLite path and the
            // AppleScript fallback honor them (the fallback previously dropped all 3).
            let field = SearchField(rawValue: fieldStr) ?? .any
            let dateFrom = dateFromStr.flatMap { Self.parseDate($0) }
            let dateTo = dateToStr.flatMap { Self.parseDate($0) }

            // #208: projection / dedup for cheap bulk collection (ids feeds export_emails_markdown).
            // Validation extracted to a pure static helper so the spec's normative
            // "reject invalid combinations" contract is unit-testable.
            let (projection, dedup) = try Self.validateSearchProjection(
                projection: arguments["projection"]?.stringValue ?? "full",
                dedup: arguments["dedup"]?.stringValue ?? "none")

            // Use SQLite search if available
            if let reader = indexReader {
                let sortOrder = SortOrder(rawValue: sort) ?? .desc
                let params = SearchParameters(
                    query: query, field: field, accountName: accountName,
                    mailbox: mailbox, dateFrom: dateFrom, dateTo: dateTo,
                    sort: sortOrder, limit: limit
                )
                switch projection {
                case "ids":
                    let page = try reader.searchIds(params, dedup: dedup)
                    let ids = page.ids.map { String($0) }
                    return formatJSON([
                        "results": ids,
                        "returned": ids.count,
                        "limit": limit,
                        "truncated": page.truncated
                    ])
                case "count":
                    let count = try reader.searchCount(params, dedup: dedup)
                    return formatJSON(["count": count])
                case "summary":
                    // #177: triage shape — id/date/sender/subject/mailbox only.
                    let page = try reader.searchSummaryPage(params, dedup: dedup)
                    let formatted: [[String: Any]] = page.results.map(Self.formatSummaryResultForJSON)
                    return formatJSON(Self.resultEnvelope(results: formatted, limit: limit, truncated: page.truncated))
                default:
                    let page = try reader.searchPage(params)
                    let formatted: [[String: Any]] = page.results.map(Self.formatSearchResultForJSON)
                    return formatJSON(Self.resultEnvelope(results: formatted, limit: limit, truncated: page.truncated))
                }
            }

            // Fallback to AppleScript — SQLite-only projections cannot be served here.
            if projection != "full" {
                throw MailError.invalidParameter("projection '\(projection)' requires the SQLite envelope index, which is unavailable. " + FullDiskAccessHelp.unavailableSuffix())
            }
            let accountId = decodeAccountId(arguments, tool: invokedTool)
            let results = try await mailController.searchEmails(query: query, mailbox: mailbox, accountName: accountName, accountId: accountId, limit: limit, sort: sort, field: field, dateFrom: dateFrom, dateTo: dateTo)
            // Fallback can't fetch limit+1 cheaply; truncated is best-effort heuristic (#204).
            return formatJSON(Self.resultEnvelope(results: results, limit: limit, truncated: results.count == limit))

        case "get_unread_count":
            let mailbox = arguments["mailbox"]?.stringValue
            let accountName = arguments["account_name"]?.stringValue
            if let reader = indexReader {
                let count = try reader.getUnreadCount(mailbox: mailbox, accountName: accountName)
                return "Unread count: \(count)"
            }
            let accountId = decodeAccountId(arguments, tool: invokedTool)
            let count = try await mailController.getUnreadCount(mailbox: mailbox, accountName: accountName, accountId: accountId)
            return "Unread count: \(count)"

        // Email Action Tools
        case "mark_read":
            let id = try requireMessageId(arguments)
            guard let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let read = arguments["read"]?.boolValue else {
                throw MailError.invalidParameter("mailbox, account_name, and read are required")
            }
            let accountId = try resolveAccountIdForTool(accountId: decodeAccountId(arguments, tool: invokedTool), accountName: accountName, tool: invokedTool)
            return try await mailController.markRead(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName, read: read)

        case "flag_email":
            let id = try requireMessageId(arguments)
            guard let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let flagged = arguments["flagged"]?.boolValue else {
                throw MailError.invalidParameter("mailbox, account_name, and flagged are required")
            }
            let accountId = try resolveAccountIdForTool(accountId: decodeAccountId(arguments, tool: invokedTool), accountName: accountName, tool: invokedTool)
            return try await mailController.flagEmail(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName, flagged: flagged)

        case "move_email":
            let id = try requireMessageId(arguments)
            guard let fromMailbox = arguments["from_mailbox"]?.stringValue,
                  let toMailbox = arguments["to_mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("from_mailbox, to_mailbox, and account_name are required")
            }
            let accountId = try resolveAccountIdForTool(accountId: decodeAccountId(arguments, tool: invokedTool), accountName: accountName, tool: invokedTool)
            return try await mailController.moveEmail(id: id, fromMailbox: fromMailbox, toMailbox: toMailbox, accountName: accountName, accountId: accountId)

        case "delete_email":
            let id = try requireMessageId(arguments)
            guard let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("mailbox, and account_name are required")
            }
            let accountId = try resolveAccountIdForTool(accountId: decodeAccountId(arguments, tool: invokedTool), accountName: accountName, tool: invokedTool)
            return try await mailController.deleteEmail(id: id, mailbox: mailbox, accountName: accountName, accountId: accountId)

        // Compose Tools
        case "compose_email":
            guard let toArray = arguments["to"]?.arrayValue,
                  let subject = arguments["subject"]?.stringValue,
                  let body = arguments["body"]?.stringValue else {
                throw MailError.invalidParameter("to, subject, and body are required")
            }
            let to = toArray.compactMap { $0.stringValue }
            let cc = try optionalStringArray(arguments, key: "cc")
            let bcc = try optionalStringArray(arguments, key: "bcc")
            let attachments = try optionalStringArray(arguments, key: "attachments")
            let format = try parseBodyFormatArgument(arguments["format"])
            // #131: sender account selection. Optional — omit to use Mail.app's default account.
            let fromAddress = arguments["from_address"]?.stringValue
            return try await mailController.composeEmail(to: to, subject: subject, body: body, cc: cc, bcc: bcc, attachments: attachments, format: format, fromAddress: fromAddress)

        case "reply_email":
            let id = try requireMessageId(arguments)
            guard let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let body = arguments["body"]?.stringValue else {
                throw MailError.invalidParameter("mailbox, account_name, and body are required")
            }
            let accountId = try resolveAccountIdForTool(accountId: decodeAccountId(arguments, tool: invokedTool), accountName: accountName, tool: invokedTool)
            let replyAll = try requireBool(arguments, key: "reply_all", default: false)
            let ccAdditional = try optionalStringArray(arguments, key: "cc_additional")
            let replyAttachments = try optionalStringArray(arguments, key: "attachments")
            let saveAsDraft = try requireBool(arguments, key: "save_as_draft", default: false)
            let format = try parseBodyFormatArgument(arguments["format"])
            return try await mailController.replyEmail(id: id, mailbox: mailbox, accountName: accountName, body: body, replyAll: replyAll, ccAdditional: ccAdditional, attachments: replyAttachments, saveAsDraft: saveAsDraft, format: format, accountId: accountId)

        case "forward_email":
            let id = try requireMessageId(arguments)
            guard let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let toArray = arguments["to"]?.arrayValue else {
                throw MailError.invalidParameter("mailbox, account_name, and to are required")
            }
            let accountId = try resolveAccountIdForTool(accountId: decodeAccountId(arguments, tool: invokedTool), accountName: accountName, tool: invokedTool)
            let to = toArray.compactMap { $0.stringValue }
            let body = arguments["body"]?.stringValue
            let format = try parseBodyFormatArgument(arguments["format"])
            return try await mailController.forwardEmail(id: id, mailbox: mailbox, accountName: accountName, to: to, body: body, format: format, accountId: accountId)

        // Draft Tools
        case "list_drafts":
            guard let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("account_name is required")
            }
            // #174: optional UUID disambiguation, mirroring the #101 pattern.
            let accountId = try resolveAccountIdForTool(accountId: decodeAccountId(arguments, tool: invokedTool), accountName: accountName, tool: invokedTool)
            let drafts = try await mailController.listDrafts(accountName: accountName, accountId: accountId)
            return formatJSON(drafts)

        case "create_draft":
            guard let toArray = arguments["to"]?.arrayValue,
                  let subject = arguments["subject"]?.stringValue,
                  let body = arguments["body"]?.stringValue else {
                throw MailError.invalidParameter("to, subject, and body are required")
            }
            let to = toArray.compactMap { $0.stringValue }
            let cc = try optionalStringArray(arguments, key: "cc")
            let bcc = try optionalStringArray(arguments, key: "bcc")
            let attachments = try optionalStringArray(arguments, key: "attachments")
            let format = try parseBodyFormatArgument(arguments["format"])
            // #131: sender account selection (see compose_email).
            let fromAddress = arguments["from_address"]?.stringValue
            return try await mailController.createDraft(to: to, subject: subject, body: body, cc: cc, bcc: bcc, attachments: attachments, format: format, fromAddress: fromAddress)

        case "update_draft":
            // #276 — upsert: locate existing draft → create replacement →
            // delete old (create-then-delete; see MailController.updateDraft).
            guard let toArray = arguments["to"]?.arrayValue,
                  let subject = arguments["subject"]?.stringValue,
                  let body = arguments["body"]?.stringValue else {
                throw MailError.invalidParameter("to, subject, and body are required")
            }
            // Verify R4 (Codex R3): key-presence + type + value validation is
            // a pure static helper so the handler boundary is unit-testable
            // without spinning up the Server/transport.
            let (draftId, subjectMatch) = try Self.validateUpdateDraftSelectors(arguments)
            let to = toArray.compactMap { $0.stringValue }
            let cc = try optionalStringArray(arguments, key: "cc")
            let bcc = try optionalStringArray(arguments, key: "bcc")
            let attachments = try optionalStringArray(arguments, key: "attachments")
            let format = try parseBodyFormatArgument(arguments["format"])
            let fromAddress = arguments["from_address"]?.stringValue
            let accountId = decodeAccountId(arguments, tool: invokedTool)
            let result = try await mailController.updateDraft(
                draftId: draftId, subjectMatch: subjectMatch,
                accountName: arguments["account_name"]?.stringValue, accountId: accountId,
                to: to, subject: subject, body: body, cc: cc, bcc: bcc,
                attachments: attachments, format: format,
                fromAddress: fromAddress)
            return formatJSON(result)

        // Attachment Tools
        case "list_attachments":
            let id = try requireMessageId(arguments)
            guard let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("mailbox, and account_name are required")
            }
            if let reader = indexReader, let rowId = Int(id) {
                let sqliteAttachments = try reader.listAttachments(messageId: rowId)
                // Cross-validate SQLite metadata against actual .emlx contents
                // (issue #24): SQLite caches attachment rows even after Mail.app
                // strips the binary on Sent / IMAP lazy-load, leaving stale
                // entries that save_attachment then fails to extract. Filter
                // SQLite results to names actually present in the .emlx body.
                if let mailboxUrl = try reader.mailboxURL(forMessageId: rowId) {
                    do {
                        // #105: the savability keys ARE the validated names
                        // (== attachmentNames), so one .emlx parse yields both
                        // the cross-validation set and the savable field.
                        // #183: thread the SQLite attachment_id per name so the
                        // name-free part-dir probe can rescue degraded-disk-name
                        // false negatives; #238: a negative verdict carries a
                        // reason (not_downloaded vs not_extractable).
                        var partIds = [String: String]()
                        for entry in sqliteAttachments {
                            if let n = entry["name"] as? String,
                               let pid = entry["attachment_id"] as? String {
                                partIds[n] = pid
                            }
                        }
                        let detail = try EmlxParser.attachmentSavabilityDetail(
                            rowId: rowId,
                            mailboxURL: mailboxUrl,
                            partIds: partIds
                        )
                        let validated = crossValidateAttachments(
                            sqliteAttachments: sqliteAttachments,
                            realNames: Set(detail.keys),
                            savability: detail.mapValues(\.savable),
                            unsavableReasons: detail.compactMapValues { $0.reason?.rawValue }
                        )
                        // #115 observability: cross-validation silently
                        // dropping every SQLite row is the symptom users hit
                        // (list_attachments returns [] despite a visible
                        // paperclip). Surface it on stderr so a parser/name
                        // mismatch is diagnosable instead of invisible.
                        if validated.isEmpty && !sqliteAttachments.isEmpty {
                            let message = "WARN: list_attachments cross-validation dropped "
                                + "all \(sqliteAttachments.count) SQLite attachment row(s) "
                                + "for rowId=\(rowId): no SQLite name matched a .emlx-parsed "
                                + "attachment name (parsed names: "
                                + "\(Set(detail.keys).sorted())); returning []\n"
                            Diagnostics.emit(message)
                        }
                        return formatJSON(validated)
                    } catch {
                        // .emlx unreadable / parse failed — log and fall back
                        // to raw SQLite metadata (matches save_attachment's
                        // fallback pattern). Caller may still hit the same
                        // not-found error on save, but we don't degrade the
                        // pre-#24 behavior for callers whose .emlx layer is
                        // genuinely broken.
                        let message = "list_attachments emlx validation failed for "
                            + "rowId=\(rowId): \(error.localizedDescription); "
                            + "returning unvalidated SQLite metadata\n"
                        Diagnostics.emit(message)
                    }
                }
                return formatJSON(sqliteAttachments)
            }
            let accountId = decodeAccountId(arguments, tool: invokedTool)
            let attachments = try await mailController.listAttachments(id: id, mailbox: mailbox, accountName: accountName, accountId: accountId)
            return formatJSON(attachments)

        case "save_attachment":
            let id = try requireMessageId(arguments)
            guard let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let attachmentName = arguments["attachment_name"]?.stringValue,
                  let savePath = arguments["save_path"]?.stringValue else {
                throw MailError.invalidParameter("mailbox, account_name, attachment_name, and save_path are required")
            }
            // Optional #101 disambiguation parameter. When provided AND non-empty,
            // the Tier 2 AppleScript fallback uses Mail.app's `(account id "<UUID>")`
            // selector — globally unique — bypassing the display_name collision
            // that produces -1728 / -1719 errors. When absent, Tier 2 falls back
            // to the legacy `account "<display_name>"` form for backward compat.
            // Tier 1 fast path is unaffected (never touches account_name).
            // (#176: not wrapped here — save_attachment feeds resolveAccountIdForTool
            // explicitly below at the Tier 2 boundary.)
            let accountId = decodeAccountId(arguments, tool: invokedTool)
            // #272: opt-in best-effort recovery for a server-side-only attachment
            // (default off). Only consulted when BOTH tiers fail on the
            // not_downloaded / -10000 path below.
            let downloadIfMissing = arguments["download_if_missing"]?.boolValue ?? false
            let allowEmpty = arguments["allow_empty"]?.boolValue ?? false
            // #178: ensure the save_path's parent directory exists before EITHER
            // tier. Both fail on a missing parent — Tier 1's Data.write throws
            // (AttachmentExtractor.saveAttachment requires the parent to exist),
            // and Tier 2's Mail.app `save att in POSIX file` raises a misleading
            // -10000 reported as an IMAP-cache problem. Creating it up front makes
            // the missing-dir case vanish; an un-creatable path errors here with
            // an actionable message instead of the opaque -10000.
            try ensureSaveDestinationDirectory(savePath)
            // Tier 1: SQLite + .emlx fast path (see openspec/changes/save-attachment-fast-path).
            // Wraps in its own do/catch so any failure falls through to the
            // AppleScript tier in the trailing `mailController.saveAttachment`
            // call — matches the two-tier pattern used by get_email (#9's
            // lesson: never collapse the tiers into one catch).
            // #103: when Tier 1 throws `attachmentNotFound`, the MCP has *proved*
            // from local `.emlx` state that the binary is absent — thread that
            // into the Tier-2 -10000 hint so the message can be definitive.
            var localCopyConfirmedMissing = false
            var localCopyNotDownloaded = false
            if let reader = indexReader, let rowId = Int(id) {
                do {
                    if let mailboxUrl = try reader.mailboxURL(forMessageId: rowId) {
                        let destination = URL(fileURLWithPath: savePath)
                        // #183: thread the Envelope Index attachment_id so the
                        // name-free part-dir probe can rescue a degraded disk
                        // filename (best-effort lookup; nil keeps prior behavior).
                        let partId = (try? reader.listAttachments(messageId: rowId))?
                            .first { ($0["name"] as? String) == attachmentName }?["attachment_id"] as? String
                        try EmlxParser.saveAttachment(
                            rowId: rowId,
                            mailboxURL: mailboxUrl,
                            attachmentName: attachmentName,
                            destination: destination,
                            partId: partId
                        )
                        // #314: Tier 1 already guards emptiness pre-write
                        // (#66/#238), so this is defense-in-depth — and it adds
                        // the same `(N bytes)` suffix as the AppleScript tier,
                        // so both paths' success strings carry a size signal.
                        return try MailController.verifySavedAttachmentOnDisk(
                            "Attachment saved to \(savePath)", savePath: savePath,
                            allowEmpty: allowEmpty)
                    }
                } catch MailSQLiteError.attachmentEmpty(let name) where allowEmpty {
                    // #347 verify round 1 — `allow_empty` used to be inert on
                    // this, the ONLY path that can actually establish "genuinely
                    // empty". Tier 1 refuses an empty part before writing
                    // anything, so the flag only ever reached the post-write
                    // verifier — i.e. only when Tier 2 happened to run and
                    // happened to succeed. With Mail unavailable the attested
                    // override could not work at all.
                    //
                    // Honored here and nowhere broader: `attachmentEmpty` means
                    // a part with this name exists and is empty. A typo'd name
                    // still throws `attachmentNotFound` and can never be
                    // answered with a 0-byte file.
                    try Data().write(to: URL(fileURLWithPath: savePath))
                    Diagnostics.emit(
                        "save_attachment: '\(name)' is an empty MIME part; wrote 0 bytes "
                        + "under allow_empty (#347)\n")
                    return "Attachment saved to \(savePath) "
                        + "(0 bytes — empty write accepted via allow_empty)"
                } catch {
                    if case MailSQLiteError.attachmentNotFound = error {
                        localCopyConfirmedMissing = true
                    }
                    // #347 — without the override an empty part behaves exactly
                    // as it did when it threw `attachmentNotFound`: no local
                    // bytes, give AppleScript its turn.
                    if case MailSQLiteError.attachmentEmpty = error {
                        localCopyConfirmedMissing = true
                    }
                    // #238: local state PROVES the part was never fetched from
                    // the server. Still give AppleScript a turn (it may trigger
                    // a fetch — unverified, #238 (a)), but remember the proof so
                    // a Tier-2 failure surfaces the actionable message instead
                    // of the opaque -10000.
                    if case MailSQLiteError.attachmentNotDownloaded = error {
                        localCopyNotDownloaded = true
                    }
                    // Log the cause so silent fallbacks are observable,
                    // then fall through to the AppleScript fallback below.
                    let message = "SQLite save_attachment fast path failed: "
                        + "\(error.localizedDescription), "
                        + "falling through to AppleScript\n"
                    Diagnostics.emit(message)
                }
            }
            // Tier 2: AppleScript fallback. Use the #101 6-arg overload (preferring
            // account_id when provided) — when account_id is nil/empty, behavior
            // is identical to the legacy 5-arg path (display_name selector).
            // #173 → #176: normalize an email-form account_name to its account
            // UUID first — SQLite-path tools emit the AccountsMap email, which the
            // display_name selector can never match (-1728). Ambiguity throws an
            // actionable error; the upgrade is logged inside the resolver.
            let resolvedAccountId = try resolveAccountIdForTool(
                accountId: accountId, accountName: accountName, tool: invokedTool)
            do {
                return try await mailController.saveAttachment(
                    id: id,
                    mailbox: mailbox,
                    accountId: resolvedAccountId,
                    accountName: accountName,
                    attachmentName: attachmentName,
                    savePath: savePath,
                    allowEmpty: allowEmpty
                )
            } catch MailError.attachmentWriteUnverified(let path, let problem) {
                // #347 — the gate that never fired. #314's verifier threw the
                // generic `operationFailed`, which this `catch` (matching
                // `scriptFailed`) cannot see, so a 0-byte write propagated
                // straight past the recovery its own message recommended:
                // "try save_attachment with download_if_missing" — already on.
                //
                // No `notDownloaded` precondition here, unlike the -10000 arm
                // below: a reported-success-with-no-bytes IS the evidence that
                // the bytes are not local, so opt-in alone qualifies.
                guard shouldAttemptDownloadRetry(afterUnverifiedWrite: problem,
                                                 downloadIfMissing: downloadIfMissing) else {
                    throw MailError.attachmentWriteUnverified(path: path, problem: problem)
                }
                return try await mailController.saveAttachmentRetryingForDownload(
                    id: id,
                    mailbox: mailbox,
                    accountId: resolvedAccountId,
                    accountName: accountName,
                    attachmentName: attachmentName,
                    savePath: savePath,
                    allowEmpty: allowEmpty,
                    enteredAfterUnverifiedWrite: problem
                )
            } catch MailError.scriptFailed(let message, let code) {
                // #272: opt-in best-effort recovery. Local state proved the part
                // is server-side only AND both tiers failed on the generic
                // -10000 (unfetched-binary class) AND the caller asked for it —
                // nudge Mail to fetch, then poll-retry the save. Fails honestly
                // (not_downloaded) on timeout, so a non-opt-in caller and a
                // genuinely-unfetchable part behave exactly as before.
                if shouldAttemptDownloadRetry(
                    notDownloaded: localCopyNotDownloaded, scriptCode: code,
                    downloadIfMissing: downloadIfMissing) {
                    return try await mailController.saveAttachmentRetryingForDownload(
                        id: id,
                        mailbox: mailbox,
                        accountId: resolvedAccountId,
                        accountName: accountName,
                        attachmentName: attachmentName,
                        savePath: savePath,
                        allowEmpty: allowEmpty
                    )
                }
                // #238: local .emlx state proved the part is server-side only —
                // both tiers failing on the GENERIC AppleEvent failure (-10000,
                // the "not found"-class Mail raises for an unfetched binary)
                // means there is no local recovery path; say so instead of the
                // opaque -10000. Other codes (permissions, bad destination)
                // keep their own specific errors (#238 verify REQUIRED).
                if localCopyNotDownloaded && code == -10000 {
                    throw MailError.operationFailed(
                        MailSQLiteError.attachmentNotDownloaded(name: attachmentName)
                            .localizedDescription)
                }
                // #103: re-word the generic -10000 "AppleEvent handler failed"
                // into actionable recovery steps; any other code rethrows as-is.
                if let hint = saveAttachmentAppleEventHint(
                    code: code, accountName: accountName, rawMessage: message,
                    localCopyConfirmedMissing: localCopyConfirmedMissing) {
                    throw MailError.operationFailed(hint)
                }
                throw MailError.scriptFailed(message: message, code: code)
            }

        // VIP Tools
        case "list_vip_senders":
            if let reader = indexReader {
                let vips = reader.listVIPSenders()
                return formatJSON(vips)
            }
            let vips = try await mailController.listVIPSenders()
            return formatJSON(vips)

        // Rule Tools
        case "list_rules":
            let rules = try await mailController.listRules()
            return formatJSON(rules)

        case "enable_rule":
            guard let name = arguments["name"]?.stringValue,
                  let enabled = arguments["enabled"]?.boolValue else {
                throw MailError.invalidParameter("name and enabled are required")
            }
            return try await mailController.enableRule(name: name, enabled: enabled)

        case "get_rule_details":
            guard let name = arguments["name"]?.stringValue else {
                throw MailError.invalidParameter("name is required")
            }
            let details = try await mailController.getRuleDetails(name: name)
            return formatJSON(details)

        case "create_rule":
            guard let name = arguments["name"]?.stringValue else {
                throw MailError.invalidParameter("name is required")
            }
            let conditions = arguments["conditions"]?.arrayValue?.compactMap { value -> [String: String]? in
                guard let obj = value.objectValue else { return nil }
                var dict: [String: String] = [:]
                for (k, v) in obj {
                    if let str = v.stringValue {
                        dict[k] = str
                    }
                }
                return dict
            } ?? []
            // #140 — guard each condition's qualifier against the Apple Mail
            // RuleQualifier whitelist before delegating. Conditions missing
            // qualifier (or header / expression) are filtered out downstream
            // by the builder; only present-but-non-whitelisted values throw.
            for condition in conditions {
                if let qualifier = condition["qualifier"], !ruleQualifierWhitelist.contains(qualifier) {
                    throw MailError.invalidParameter(
                        "condition qualifier must be one of: begins with value, does contain value, "
                        + "does not contain value, ends with value, equal to value, less than value, "
                        + "greater than value, none (got: \"\(qualifier)\")")
                }
            }
            let actions = arguments["actions"]?.objectValue?.reduce(into: [String: Any]()) { result, pair in
                if let str = pair.value.stringValue {
                    result[pair.key] = str
                } else if let bool = pair.value.boolValue {
                    result[pair.key] = bool
                }
            } ?? [:]
            return try await mailController.createRule(name: name, conditions: conditions, actions: actions)

        case "delete_rule":
            guard let name = arguments["name"]?.stringValue else {
                throw MailError.invalidParameter("name is required")
            }
            return try await mailController.deleteRule(name: name)

        // Mail Check & Sync Tools
        case "check_for_new_mail":
            // #191: optional account_id escape hatch (mirrors #104/#176). Resolve only
            // when a selector is supplied so the check-all path (no account) is unchanged.
            let accountName = arguments["account_name"]?.stringValue
            let rawAccountId = decodeAccountId(arguments, tool: invokedTool)
            let resolvedAccountId = hasAccountSelector(accountId: rawAccountId, accountName: accountName)
                ? try resolveAccountIdForTool(accountId: rawAccountId, accountName: accountName ?? "", tool: invokedTool)
                : nil
            return try await mailController.checkForNewMail(accountName: accountName, accountId: resolvedAccountId)

        case "synchronize_account":
            // #191: account_id is a genuine standalone escape hatch — require AT LEAST
            // ONE of account_name / account_id (not account_name unconditionally), so a
            // caller holding only a UUID (e.g. from a search_emails round-trip, or an EWS
            // account whose AccountsMap stores the UUID) can sync without a dummy name.
            let syncAccountName = arguments["account_name"]?.stringValue
            let syncRawAccountId = decodeAccountId(arguments, tool: invokedTool)
            guard hasAccountSelector(accountId: syncRawAccountId, accountName: syncAccountName) else {
                throw MailError.invalidParameter("synchronize_account requires account_name or account_id")
            }
            // Resolve an email-form account_name to the collision-free UUID selector via
            // the shared #176 chokepoint (was a bare description selector → -1728).
            let syncResolvedAccountId = try resolveAccountIdForTool(
                accountId: syncRawAccountId, accountName: syncAccountName ?? "", tool: invokedTool)
            return try await mailController.synchronizeAccount(
                accountName: syncAccountName ?? "", accountId: syncResolvedAccountId)

        // Advanced Email Tools
        case "copy_email":
            let id = try requireMessageId(arguments)
            guard let fromMailbox = arguments["from_mailbox"]?.stringValue,
                  let toMailbox = arguments["to_mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("from_mailbox, to_mailbox, and account_name are required")
            }
            let accountId = try resolveAccountIdForTool(accountId: decodeAccountId(arguments, tool: invokedTool), accountName: accountName, tool: invokedTool)
            return try await mailController.copyEmail(id: id, fromMailbox: fromMailbox, toMailbox: toMailbox, accountName: accountName, accountId: accountId)

        case "set_flag_color":
            let id = try requireMessageId(arguments)
            guard let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let colorIndex = arguments["color_index"]?.intValue else {
                throw MailError.invalidParameter("mailbox, account_name, and color_index are required")
            }
            let accountId = try resolveAccountIdForTool(accountId: decodeAccountId(arguments, tool: invokedTool), accountName: accountName, tool: invokedTool)
            return try await mailController.setFlagColor(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName, colorIndex: colorIndex)

        case "set_background_color":
            let id = try requireMessageId(arguments)
            guard let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let color = arguments["color"]?.stringValue else {
                throw MailError.invalidParameter("mailbox, account_name, and color are required")
            }
            guard backgroundColorWhitelist.contains(color) else {
                throw MailError.invalidParameter(
                    "color must be one of: blue, gray, green, none, orange, purple, red, yellow (got: \"\(color)\")")
            }
            let accountId = try resolveAccountIdForTool(accountId: decodeAccountId(arguments, tool: invokedTool), accountName: accountName, tool: invokedTool)
            return try await mailController.setBackgroundColor(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName, color: color)

        case "mark_as_junk":
            let id = try requireMessageId(arguments)
            guard let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let isJunk = arguments["is_junk"]?.boolValue else {
                throw MailError.invalidParameter("mailbox, account_name, and is_junk are required")
            }
            let accountId = try resolveAccountIdForTool(accountId: decodeAccountId(arguments, tool: invokedTool), accountName: accountName, tool: invokedTool)
            return try await mailController.markAsJunk(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName, isJunk: isJunk)

        case "get_email_headers":
            let id = try requireMessageId(arguments)
            guard let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("mailbox, and account_name are required")
            }
            // Convert nested `try?` to do/catch so SQLite-path failures are
            // observable on stderr (#69 — pre-fix `try?` swallowed the cause
            // silently). Behavior is unchanged: any error still falls through
            // to AppleScript.
            if let reader = indexReader, let rowId = Int(id) {
                do {
                    if let mailboxUrl = try reader.mailboxURL(forMessageId: rowId) {
                        let headers = try EmlxParser.readHeaders(rowId: rowId, mailboxURL: mailboxUrl)
                        return headers
                    }
                } catch {
                    let message = "SQLite get_email_headers fast path failed for "
                        + "rowId=\(rowId): \(error.localizedDescription); "
                        + "falling through to AppleScript\n"
                    Diagnostics.emit(message)
                }
            }
            let accountId = decodeAccountId(arguments, tool: invokedTool)
            return try await mailController.getEmailHeaders(id: id, mailbox: mailbox, accountName: accountName, accountId: accountId)

        case "get_email_source":
            let id = try requireMessageId(arguments)
            guard let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("mailbox, and account_name are required")
            }
            // See get_email_headers above for #69 context — same try?-to-catch
            // refactor for stderr observability.
            if let reader = indexReader, let rowId = Int(id) {
                do {
                    if let mailboxUrl = try reader.mailboxURL(forMessageId: rowId) {
                        let source = try EmlxParser.readSource(rowId: rowId, mailboxURL: mailboxUrl)
                        return source
                    }
                } catch {
                    let message = "SQLite get_email_source fast path failed for "
                        + "rowId=\(rowId): \(error.localizedDescription); "
                        + "falling through to AppleScript\n"
                    Diagnostics.emit(message)
                }
            }
            let accountId = decodeAccountId(arguments, tool: invokedTool)
            return try await mailController.getEmailSource(id: id, mailbox: mailbox, accountName: accountName, accountId: accountId)

        case "redirect_email":
            let id = try requireMessageId(arguments)
            guard let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let toArray = arguments["to"]?.arrayValue else {
                throw MailError.invalidParameter("mailbox, account_name, and to are required")
            }
            let accountId = try resolveAccountIdForTool(accountId: decodeAccountId(arguments, tool: invokedTool), accountName: accountName, tool: invokedTool)
            let to = toArray.compactMap { $0.stringValue }
            return try await mailController.redirectEmail(id: id, mailbox: mailbox, accountName: accountName, to: to, accountId: accountId)

        case "get_email_metadata":
            let id = try requireMessageId(arguments)
            guard let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("mailbox, and account_name are required")
            }
            // Issue #71: hybrid fallback parity with the other 7 read tools.
            // Pre-fix, SQLite path throw escaped to caller without falling
            // through to AppleScript — the only read tool with this gap.
            // Surfaced by #69 (PR #70) verify (Codex CLI + Devil's Advocate
            // both flagged independently). Mirror canonical pattern from
            // save_attachment (#12) and the 6 other read tools.
            if let reader = indexReader, let rowId = Int(id) {
                do {
                    let metadata = try reader.getEmailMetadata(messageId: rowId)
                    return formatJSON(metadata)
                } catch {
                    let message = "SQLite get_email_metadata fast path failed for "
                        + "rowId=\(rowId): \(error.localizedDescription); "
                        + "falling through to AppleScript\n"
                    Diagnostics.emit(message)
                }
            }
            let accountId = decodeAccountId(arguments, tool: invokedTool)
            let metadata = try await mailController.getEmailMetadata(id: id, mailbox: mailbox, accountName: accountName, accountId: accountId)
            return formatJSON(metadata)

        // Signature Tools
        case "list_signatures":
            let signatures = try await mailController.listSignatures()
            return formatJSON(signatures)

        case "get_signature":
            guard let name = arguments["name"]?.stringValue else {
                throw MailError.invalidParameter("name is required")
            }
            let signature = try await mailController.getSignature(name: name)
            return formatJSON(signature)

        // SMTP Server Tools
        case "list_smtp_servers":
            let servers = try await mailController.listSMTPServers()
            return formatJSON(servers)

        // Special Mailboxes
        case "get_special_mailboxes":
            // #179: optional account selector → per-account special-mailbox real names.
            let rawAccountId = decodeAccountId(arguments, tool: invokedTool)
            let accountName = arguments["account_name"]?.stringValue
            let explicitAccountId = !(rawAccountId ?? "").isEmpty
            let hasSelector = explicitAccountId || !(accountName ?? "").isEmpty
            // Only resolve when a selector was actually supplied — the no-selector
            // path must stay byte-unchanged (no resolver step / side effects). When a
            // selector is present, resolve an email-form account_name to its UUID via
            // the shared chokepoint so matching uses the collision-free `account id`
            // selector, not the description namespace (same as the write tools, #176).
            let resolvedAccountId = hasSelector
                ? try resolveAccountIdForTool(accountId: rawAccountId, accountName: accountName ?? "", tool: invokedTool)
                : nil
            // The no-match/ambiguity hint must name the selector the builder matched
            // on, not a co-supplied one (#179 verify R4, findings 2/5): when an
            // explicit account_id is given the builder matches the UUID, so suppress
            // account_name in the hint; otherwise reference the account_name the user
            // typed (preserving the email→UUID non-laundering fix).
            let hintAccountName = specialMailboxesHintAccountName(explicitAccountId: explicitAccountId, accountName: accountName)
            var mailboxes = try await mailController.getSpecialMailboxes(accountId: resolvedAccountId, accountName: hintAccountName)
            // #315: derive `<type>_path` by joining each AppleScript-identified
            // LEAF against the account's Envelope-Index mailbox paths — the
            // same representation `search_emails`'s `mailbox` field carries
            // (`MailboxURL.mailboxPath`), from the source that was correct all
            // along. Replaces the #268 container walk, which succeeded
            // vacuously and emitted leaf-for-nested (4/5 types wrong on all 7
            // live accounts) without ever tripping its own fail-safes.
            // Fail-open at every step: no index (EWS / missing FDA), an
            // unknown leaf, or an AMBIGUOUS leaf (two mailboxes sharing it)
            // all OMIT the key — an absent `_path` is the honest, observable
            // signal the #268 design promised — while the leaf stays present.
            if hasSelector, let reader = indexReader,
               let matchedId = mailboxes["account_id"] as? String, !matchedId.isEmpty {
                let mailboxRows = (try? reader.listMailboxes(accountId: matchedId)) ?? []
                let mailboxEntries: [(path: String, components: [String])] = mailboxRows
                    .compactMap { row in
                        guard let name = row["name"] as? String else { return nil }
                        // Fall back to a single component only if the reader
                        // somehow omitted them — never re-split `name`, which
                        // is exactly the lossy step #344/#345 warn about.
                        let comps = (row["path_components"] as? [String]) ?? [name]
                        return (path: name, components: comps)
                    }
                // #345: resolve every leaf TOGETHER. A lone nested candidate is
                // not proof of identity — an ordinary `Projects/Drafts` matched
                // the leaf uncontested when the real drafts mailbox was missing
                // from the index. A nested path is now believed only when
                // another special mailbox shares its parent container.
                let leafPairs: [(key: String, leaf: String)] = perAccountSpecialMailboxes
                    .compactMap { special in
                        guard let leaf = mailboxes[special.key] as? String else { return nil }
                        return (key: special.key, leaf: leaf)
                    }
                for (key, path) in joinSpecialMailboxPaths(leaves: leafPairs,
                                                           mailboxes: mailboxEntries) {
                    mailboxes[key + "_path"] = path
                }
            }
            return formatJSON(mailboxes)

        // Address Tools
        case "extract_name_from_address":
            guard let address = arguments["address"]?.stringValue else {
                throw MailError.invalidParameter("address is required")
            }
            let name = try await mailController.extractNameFromAddress(address: address)
            return name

        case "extract_address":
            guard let address = arguments["address"]?.stringValue else {
                throw MailError.invalidParameter("address is required")
            }
            return try await mailController.extractAddressFrom(address: address)

        // Application Tools
        case "get_mail_app_info":
            let info = try await mailController.getMailAppInfo()
            return formatJSON(info)

        case "open_mailto":
            guard let url = arguments["url"]?.stringValue else {
                throw MailError.invalidParameter("url is required")
            }
            return try await mailController.openMailtoURL(url: url)

        // Import Tools
        case "import_mailbox":
            guard let path = arguments["path"]?.stringValue else {
                throw MailError.invalidParameter("path is required")
            }
            return try await mailController.importMailbox(path: path)

        // Batch Tools
        case "export_emails_markdown", "batch_export_emails_markdown":
            // #233: one dual-name case label — the canonical name and the
            // deprecated alias can never diverge in behavior. Old-name calls
            // get a one-line stderr deprecation warn; the result is identical.
            if name == "export_emails_markdown" {
                Diagnostics.emit(exportAliasDeprecationWarning())
            }
            guard let idsArray = arguments["ids"]?.arrayValue else {
                throw MailError.invalidParameter("ids array is required")
            }
            let exportIds = idsArray.compactMap { $0.stringValue }
            guard !exportIds.isEmpty else {
                throw MailError.invalidParameter("ids must be a non-empty array of message id strings")
            }
            guard exportIds.count <= 2000 else {
                throw MailError.invalidParameter("Batch size exceeds maximum of 2000 items")
            }
            guard let outputDir = arguments["output_dir"]?.stringValue else {
                throw MailError.invalidParameter("output_dir is required")
            }
            guard let exportReader = indexReader else {
                throw MailError.invalidParameter("batch_export_emails_markdown (alias: export_emails_markdown) requires the SQLite envelope index, which is unavailable. " + FullDiskAccessHelp.unavailableSuffix())
            }
            // #316 — direction is derived per email from sender identity: the
            // own-addresses set is the union of every configured account's
            // addresses resolvable from the local account mapping (IMAP-style
            // accounts map to an email-form name; EWS accounts resolve to a
            // UUID and contribute nothing — #9/#11). No AppleScript round-trip.
            // #343: normalise every set member through the SAME function the
            // sender goes through. A member is not guaranteed to be a bare
            // address — an AccountURL like `imap://Work%20%3Cuser%40x.com%3E/`
            // yields `Work <user@x.com>`, which could never match a parsed
            // sender and, because it kept the set non-empty, suppressed the
            // disclosure too. Members that still do not reduce to an address
            // are dropped rather than kept as permanently-unmatchable entries.
            let exportAccounts = exportReader.listAccounts()
            let exportOwnAddresses = ExportIdentity.ownAddresses(from: exportAccounts)
            // #351: which ACCOUNTS actually contributed an address. EWS accounts
            // contribute none (opaque AccountURL, #9), so mail sent from one can
            // never match — and without this per-account view the whole-set
            // emptiness test cannot see it while other accounts resolve.
            let exportResolvedAccountUUIDs = ExportIdentity.resolvedAccountUUIDs(from: exportAccounts)
            // Mailbox-label heuristic, demoted to the fail-open fallback used
            // only when no own address is resolvable (whole batch, disclosed
            // per item via `direction_inferred: true`).
            let exportMailbox = arguments["mailbox"]?.stringValue ?? ""
            let exportFallbackDirection = (exportMailbox.range(of: "sent", options: .caseInsensitive) != nil
                || exportMailbox.contains("寄件")) ? "sent" : "received"
            if exportOwnAddresses.isEmpty {
                Diagnostics.emit((
                    "batch_export_emails_markdown: no own email address resolvable from the "
                    + "account mapping — falling back to the mailbox-label direction heuristic "
                    + "for the whole batch (manifest items carry direction_inferred: true) (#316)\n"))
            }
            let exportOpts = arguments["opts"]?.objectValue ?? [:]
            let includeAttachments = exportOpts["include_attachments"]?.boolValue ?? false
            // #283: opt-in — keep header-only (partial-.emlx, body absent)
            // emails OUT of the corpus (status "header_only", not written)
            // instead of the default annotate-and-write.
            let skipPartial = exportOpts["skip_partial"]?.boolValue ?? false
            let filenameTemplate = exportOpts["filename_template"]?.stringValue
            var filenameOverrides: [String: String] = [:]
            if let fmap = exportOpts["filenames"]?.objectValue {
                for (k, v) in fmap { if let s = v.stringValue { filenameOverrides[k] = s } }
            }
            var extraFrontmatter: [(String, String)] = []
            if let extra = exportOpts["extra_frontmatter"]?.objectValue {
                for (k, v) in extra { if let s = v.stringValue { extraFrontmatter.append((k, s)) } }
            }
            // #197: validate output_dir. Default = anywhere under $HOME except the
            // home-relative denylist (~/Library, ~/.ssh, dotfiles, ~/bin, …). A
            // deployment can set CHE_MAIL_EXPORT_ALLOWED_ROOTS (`:`-separated
            // absolute paths) to opt into a strict allowlist — those roots then
            // REPLACE home as the allowed set (deny-by-default).
            let exportAllowedRoots = (ProcessInfo.processInfo.environment["CHE_MAIL_EXPORT_ALLOWED_ROOTS"] ?? "")
                .split(separator: ":").map(String.init)
            let validatedDir: URL
            do {
                validatedDir = try AllowedRootsValidator().validate(outputDir, allowedRoots: exportAllowedRoots)
            } catch {
                throw MailError.invalidParameter("output_dir rejected by write-safety check: \(error)")
            }
            // #177: optional dedup skip-set — a file (validated read-only under the
            // SAME allowed-roots policy as output_dir) listing already-archived
            // RFC 5322 Message-IDs, one per line; blank lines and `#` comments
            // ignored. Missing/unreadable → empty set (a first-ever archive has no
            // index yet); out-of-roots → write-safety error. The file is parsed only
            // as a Message-ID list and never echoed back.
            var skipMessageIds: Set<String> = []
            if let skipPath = arguments["skip_message_ids_path"]?.stringValue, !skipPath.isEmpty {
                let validatedSkip: URL
                do {
                    validatedSkip = try AllowedRootsValidator().validate(skipPath, allowedRoots: exportAllowedRoots)
                } catch {
                    throw MailError.invalidParameter("skip_message_ids_path rejected by write-safety check: \(error)")
                }
                // Read only a regular file ≤64MB (stat BEFORE open: a FIFO would
                // hang `String(contentsOf:)`, a huge file would OOM — neither is a
                // legit archive index). Any miss → empty skip-set + stderr note.
                let skipContents: String? = {
                    let fm = FileManager.default
                    guard let attrs = try? fm.attributesOfItem(atPath: validatedSkip.path),
                          (attrs[.type] as? FileAttributeType) == .typeRegular,
                          (attrs[.size] as? Int ?? Int.max) <= 64 * 1024 * 1024 else {
                        return nil
                    }
                    return try? String(contentsOf: validatedSkip, encoding: .utf8)
                }()
                if let contents = skipContents {
                    skipMessageIds = Self.parseSkipMessageIds(contents)
                } else {
                    Diagnostics.emit((
                        "export_emails_markdown: skip_message_ids_path not a readable regular file ≤64MB — "
                        + "treating as empty skip-set (#177)\n"))
                }
            }
            let exportManifest = try ExportEmailsMarkdown.run(
                ids: exportIds, outputDir: validatedDir,
                ownAddresses: exportOwnAddresses, fallbackDirection: exportFallbackDirection,
                includeAttachments: includeAttachments, filenameTemplate: filenameTemplate,
                filenameOverrides: filenameOverrides, extraFrontmatter: extraFrontmatter,
                identityResolvable: { id in
                    // Fail CLOSED: anything we cannot resolve to a known
                    // address-bearing account is "cannot tell" → disclosed,
                    // never silently resolved to `received` (#351).
                    guard let rowId = Int(id),
                          let url = try? exportReader.mailboxURL(forMessageId: rowId),
                          let mailbox = MailboxURL.decode(url) else { return false }
                    // Hex case carries no meaning in a UUID, and the rest of
                    // the reader already folds it (#343 verify) — a store that
                    // reports one case in the account map and the other in the
                    // mailbox URL would otherwise look unresolvable.
                    return exportResolvedAccountUUIDs.contains(mailbox.accountUUID.lowercased())
                },
                fetch: { id in
                    guard let rowId = Int(id) else {
                        throw MailError.invalidParameter("id '\(id)' is not a numeric rowId")
                    }
                    guard let mailboxUrl = try exportReader.mailboxURL(forMessageId: rowId) else {
                        throw MailError.invalidParameter("rowId \(rowId) is not in the envelope index")
                    }
                    return try EmlxParser.readEmail(rowId: rowId, mailboxURL: mailboxUrl, format: "text")
                },
                attachmentNamesFor: { id in
                    guard let rowId = Int(id),
                          let mailboxUrl = try exportReader.mailboxURL(forMessageId: rowId) else { return [] }
                    return Array(try EmlxParser.attachmentNames(rowId: rowId, mailboxURL: mailboxUrl))
                },
                attachmentData: { id, name in
                    guard let rowId = Int(id),
                          let mailboxUrl = try exportReader.mailboxURL(forMessageId: rowId) else {
                        throw MailError.invalidParameter("rowId not resolvable for attachment '\(name)'")
                    }
                    // #200: extract bytes only — ExportEmailsMarkdown owns the
                    // race-free write via RaceFreeFileWriter.
                    return try EmlxParser.attachmentData(rowId: rowId, mailboxURL: mailboxUrl, attachmentName: name)
                },
                skipMessageIds: skipMessageIds,
                skipPartial: skipPartial)
            return formatJSON(exportManifest.jsonObject)

        case "get_emails_batch":
            guard let emailsArray = arguments["emails"]?.arrayValue else {
                throw MailError.invalidParameter("emails array is required")
            }
            guard emailsArray.count <= 50 else {
                throw MailError.invalidParameter("Batch size exceeds maximum of 50 items")
            }
            let format = arguments["format"]?.stringValue ?? "html"
            var results: [[String: Any]] = []
            for emailVal in emailsArray {
                guard let obj = emailVal.objectValue,
                      let id = obj["id"]?.stringValue,
                      let mailbox = obj["mailbox"]?.stringValue,
                      let accountName = obj["account_name"]?.stringValue else {
                    results.append(["error": "Missing required fields (id, mailbox, account_name)"])
                    continue
                }
                // #180: per-item account_id (UUID) threads into the AppleScript
                // fallback so a Gmail / ambiguous display_name resolves via the
                // `account id` selector. Empty/absent → resolveAccountRef falls
                // back to account_name. SQLite fast path is account-agnostic.
                // Uses decodeAccountId (not raw obj["account_id"]) so a non-string
                // per-item account_id emits the same stderr warning as the single
                // tools (verify #192 LOW: warning parity) — `obj` is the per-item
                // [String: Value] dict, the shape decodeAccountId expects.
                let accountId = decodeAccountId(obj, tool: invokedTool)
                // Try SQLite/emlx first; on any failure, fall through to
                // AppleScript — mirrors the structure of `get_email` so both
                // tools behave identically when the filesystem-fast-path is
                // unavailable. See #9.
                if let reader = indexReader, let rowId = Int(id) {
                    do {
                        if let mailboxUrl = try reader.mailboxURL(forMessageId: rowId) {
                            let content = try EmlxParser.readEmail(rowId: rowId, mailboxURL: mailboxUrl, format: format)
                            var entry: [String: Any] = [
                                "id": id, "subject": content.subject, "sender": content.sender,
                                "date": content.date, "to": content.toRecipients, "cc": content.ccRecipients,
                                "message_id": content.messageId   // #177: parity with single get_email
                            ]
                            if let text = content.textBody { entry["text_body"] = text }
                            if let html = content.htmlBody { entry["html_body"] = html }
                            if let source = content.rawSource { entry["source"] = String(data: source, encoding: .utf8) ?? "" }
                            if Self.partialBodyNotDownloaded(content: content, format: format) {
                                // #274: batch stays on the direct-read fast path
                                // (a per-item AppleScript fallback would cost one
                                // Mail IPC round-trip per message) — annotate
                                // instead, so batch callers can re-fetch flagged
                                // ids via the single get_email (whose fallback
                                // nudges the download).
                                entry["body_downloaded"] = false
                            }
                            results.append(entry)
                            continue
                        } else {
                            // `mailboxURL` nil — same silent `nil`-return
                            // fall-through #69 missed, per item (#100).
                            logFastPathFallthrough(tool: "get_emails_batch", rowId: rowId,
                                                   reason: .rowIdNotIndexed, perItem: true)
                        }
                    } catch {
                        // Log per-item failure with rowId so partial-failure
                        // diagnostics are observable in batch fetches (#69 —
                        // an archive of N emails may have M legitimate EWS
                        // fallbacks vs K silent Gmail failures; without rowId
                        // logging users can't tell them apart).
                        logFastPathFallthrough(tool: "get_emails_batch", rowId: rowId,
                                               reason: .error(error.localizedDescription), perItem: true)
                    }
                }
                // Fallback to AppleScript
                do {
                    let email = try await mailController.getEmail(id: id, mailbox: mailbox, accountName: accountName, accountId: accountId, format: format)
                    results.append(email)
                } catch {
                    results.append(["id": id, "error": error.localizedDescription])
                }
            }
            return formatJSON(results)

        case "list_attachments_batch":
            guard let emailsArray = arguments["emails"]?.arrayValue else {
                throw MailError.invalidParameter("emails array is required")
            }
            guard emailsArray.count <= 50 else {
                throw MailError.invalidParameter("Batch size exceeds maximum of 50 items")
            }
            var results: [[String: Any]] = []
            for emailVal in emailsArray {
                guard let obj = emailVal.objectValue,
                      let id = obj["id"]?.stringValue,
                      let mailbox = obj["mailbox"]?.stringValue,
                      let accountName = obj["account_name"]?.stringValue else {
                    results.append(["error": "Missing required fields (id, mailbox, account_name)"])
                    continue
                }
                // #180: per-item account_id (UUID) threads into the AppleScript
                // fallback so a Gmail / ambiguous display_name resolves via the
                // `account id` selector. Empty/absent → resolveAccountRef falls
                // back to account_name. SQLite fast path is account-agnostic.
                // Uses decodeAccountId (not raw obj["account_id"]) so a non-string
                // per-item account_id emits the same stderr warning as the single
                // tools (verify #192 LOW: warning parity) — `obj` is the per-item
                // [String: Value] dict, the shape decodeAccountId expects.
                let accountId = decodeAccountId(obj, tool: invokedTool)
                // SQLite + .emlx fast path with #24 cross-validation: filter
                // out stale SQLite attachment rows that don't actually exist
                // in the .emlx body. Mirrors the single-message handler at
                // `case "list_attachments"` above. Per-message graceful
                // degradation — if .emlx parse fails for one message, fall
                // through to AppleScript for THAT message only, preserving
                // the rest of the batch (issue #25).
                if let reader = indexReader, let rowId = Int(id) {
                    do {
                        let sqliteAttachments = try reader.listAttachments(messageId: rowId)
                        var attachments = sqliteAttachments
                        if let mailboxUrl = try reader.mailboxURL(forMessageId: rowId) {
                            do {
                                // #105: one .emlx parse → cross-validation set
                                // (savability.keys) + the per-row `savable` field.
                                let savability = try EmlxParser.attachmentSavability(
                                    rowId: rowId,
                                    mailboxURL: mailboxUrl
                                )
                                attachments = crossValidateAttachments(
                                    sqliteAttachments: sqliteAttachments,
                                    realNames: Set(savability.keys),
                                    savability: savability
                                )
                                // #115 observability — see the single-message
                                // `list_attachments` path for rationale.
                                if attachments.isEmpty && !sqliteAttachments.isEmpty {
                                    let message = "WARN: list_attachments_batch cross-validation "
                                        + "dropped all \(sqliteAttachments.count) SQLite "
                                        + "attachment row(s) for rowId=\(rowId): no SQLite name "
                                        + "matched a .emlx-parsed attachment name (parsed names: "
                                        + "\(Set(savability.keys).sorted())); returning [] "
                                        + "for this item\n"
                                    Diagnostics.emit(message)
                                }
                            } catch {
                                let message = "list_attachments_batch emlx validation failed for "
                                    + "rowId=\(rowId): \(error.localizedDescription); "
                                    + "returning unvalidated SQLite metadata for this item\n"
                                Diagnostics.emit(message)
                            }
                        }
                        results.append(["id": id, "mailbox": mailbox, "account_name": accountName, "attachments": attachments])
                        continue
                    } catch {
                        // SQLite query itself failed — fall through to AppleScript.
                        let message = "list_attachments_batch SQLite fast path failed for "
                            + "rowId=\(rowId): \(error.localizedDescription); "
                            + "falling through to AppleScript for this item\n"
                        Diagnostics.emit(message)
                    }
                }
                // Tier 2: AppleScript fallback (legacy path, preserved unchanged).
                do {
                    let attachments = try await mailController.listAttachments(id: id, mailbox: mailbox, accountName: accountName, accountId: accountId)
                    results.append(["id": id, "mailbox": mailbox, "account_name": accountName, "attachments": attachments])
                } catch {
                    results.append(["id": id, "error": error.localizedDescription])
                }
            }
            return formatJSON(results)

        default:
            throw MailError.invalidParameter("Unknown tool: \(name)")
        }
    }

    // MARK: - Helpers

    /// Format a `SearchResult` as a JSON-serializable dictionary for the
    /// `search_emails` tool response. `internal` (not `private`) so tests
    /// can directly assert the contract — particularly that `account_id`
    /// is exposed when present (#101: documented disambiguation discovery
    /// path; LLM agents read `account_id` from search results and pass
    /// it through to `save_attachment` / other AppleScript-routed tools).
    ///
    /// `account_id` is **conditionally** included — when SearchResult's
    /// `accountId` is `nil` or empty (e.g., corrupted mailbox URL upstream),
    /// the key is omitted entirely rather than emitting JSON-null. Callers
    /// can use `if "account_id" in result` to detect presence cleanly.
    static func formatSearchResultForJSON(_ r: SearchResult) -> [String: Any] {
        var dict: [String: Any] = [
            "id": String(r.id),
            "subject": r.subject,
            "sender": r.senderAddress.isEmpty ? r.senderName : "\(r.senderName) <\(r.senderAddress)>",
            "date_received": ISO8601DateFormatter().string(from: r.dateReceived),
            "account_name": r.accountName,
            "mailbox": r.mailboxPath,
            "to": r.toRecipients
        ]
        if let aid = r.accountId, !aid.isEmpty {
            dict["account_id"] = aid
        }
        return dict
    }

    /// #177: the triage (`summary`) projection JSON — exactly `id/date/sender/
    /// subject/mailbox` (no recipient list, no account fields). `date` carries the
    /// same ISO 8601 value as `full`'s `date_received`.
    static func formatSummaryResultForJSON(_ r: SearchResult) -> [String: Any] {
        [
            "id": String(r.id),
            "date": ISO8601DateFormatter().string(from: r.dateReceived),
            "sender": r.senderAddress.isEmpty ? r.senderName : "\(r.senderName) <\(r.senderAddress)>",
            "subject": r.subject,
            "mailbox": r.mailboxPath,
        ]
    }

    private static func parseDate(_ string: String) -> Date? {
        // Try ISO 8601 with time
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: string) { return date }
        // Try date-only (YYYY-MM-DD) in local timezone
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = .current
        return dateFormatter.date(from: string)
    }

    /// #276 verify R4 (Codex R3 blocking 2) — update_draft selector
    /// validation at the HANDLER boundary, presence-first: a key that is
    /// PRESENT with a non-string value is a parameter error, never silently
    /// treated as absent (the MCP inputSchema is a published contract, not a
    /// runtime enforcement — type confusion like `draft_id: 123` +
    /// `subject_match: "X"` must not slip past the mutual-exclusion gate and
    /// run the mutation). Order: type → value → XOR on key presence. Pure
    /// static so it is unit-testable.
    static func validateUpdateDraftSelectors(
        _ arguments: [String: Value]
    ) throws -> (draftId: String?, subjectMatch: String?) {
        // Verify R6 (Codex): account scoping fields get the same
        // presence-first TYPE validation — `account_name: 123` silently
        // becoming nil would EXPAND a mutation's scope to all accounts
        // instead of erroring.
        if arguments["account_name"] != nil, arguments["account_name"]?.stringValue == nil {
            throw MailError.invalidParameter("account_name must be a string")
        }
        if arguments["account_id"] != nil, arguments["account_id"]?.stringValue == nil {
            throw MailError.invalidParameter("account_id must be a string (Mail account UUID)")
        }
        let draftIdProvided = (arguments["draft_id"] != nil)
        let subjectMatchProvided = (arguments["subject_match"] != nil)
        if draftIdProvided, arguments["draft_id"]?.stringValue == nil {
            throw MailError.invalidParameter("draft_id must be a string (numeric message id)")
        }
        if subjectMatchProvided, arguments["subject_match"]?.stringValue == nil {
            throw MailError.invalidParameter("subject_match must be a string (exact subject)")
        }
        let draftId = arguments["draft_id"]?.stringValue
        let subjectMatch = arguments["subject_match"]?.stringValue
        if let sm = subjectMatch, sm.isEmpty {
            throw MailError.invalidParameter(
                "subject_match must be non-empty (exact subject equality); "
                + "to target an empty-subject draft, use draft_id from list_drafts")
        }
        if let did = draftId, !isASCIIDigits(did) {
            throw MailError.invalidParameter(
                "draft_id must be a non-empty ASCII-numeric message id (from list_drafts); got '\(did)'")
        }
        guard draftIdProvided != subjectMatchProvided else {
            throw MailError.invalidParameter(
                "update_draft requires exactly one of draft_id or subject_match (got "
                + (draftIdProvided ? "both" : "neither") + ")")
        }
        return (draftId, subjectMatch)
    }

    /// The `get_email` Tier-1 result object. Extracted (#299) so the header-only
    /// degradation path can reuse the exact same shape the success path emits —
    /// two hand-built copies would drift.
    static func emailResultObject(id: String, content: EmailContent) -> [String: Any] {
        var result: [String: Any] = [
            "id": id,
            "subject": content.subject,
            "sender": content.sender,
            "date": content.date,
            "to": content.toRecipients,
            "cc": content.ccRecipients,
            "message_id": content.messageId
        ]
        if let text = content.textBody { result["text_body"] = text }
        if let html = content.htmlBody { result["html_body"] = html }
        if let source = content.rawSource { result["source"] = String(data: source, encoding: .utf8) ?? "" }
        return result
    }

    /// Actionable hint when a message cannot be addressed for the AppleScript
    /// fallback (#299). The causes are genuinely different and need different
    /// fixes, so a single generic sentence would misdirect: the index may be
    /// unavailable entirely (a Full Disk Access problem), the rowId may not be
    /// in it, or the entry may exist but not yield a usable account+mailbox
    /// (a non-UUID authority, an ambiguous `%2F` name, a local On-My-Mac
    /// mailbox with no account). Pure so each branch is unit-testable.
    static func unaddressableMessageHint(id: String, indexAvailable: Bool, rowIdIndexed: Bool) -> String {
        if !indexAvailable {
            return "Cannot address message \(id): the Envelope Index is unavailable, so "
                + "`mailbox` and `account_name` cannot be resolved automatically. Supply them "
                + "explicitly, or grant Full Disk Access (see check_fda) to enable id-only "
                + "addressing (#299)."
        }
        if !rowIdIndexed {
            return "Cannot address message \(id): that id is not in the Envelope Index "
                + "(is it a rowId from this Mail store, not a Message-ID?). Supply `mailbox` "
                + "plus `account_name` (or `account_id`) to address it explicitly (#299)."
        }
        return "Cannot address message \(id): its Envelope Index entry does not yield a usable "
            + "account + mailbox pair (a local On-My-Mac mailbox has no account, and a mailbox "
            + "name containing a literal '/' is ambiguous once decoded). Supply `mailbox` plus "
            + "`account_name` (or `account_id`) explicitly (#299)."
    }

    /// #274 — true when the parsed content came from a `.partial.emlx` AND the
    /// body the caller asked for is absent: "not downloaded", not "empty
    /// message". Pure so the routing contract is unit-testable.
    ///
    /// - `text`: the text body is nil/empty.
    /// - `source`: a partial file's source is header-only by definition —
    ///   always incomplete for a caller who asked for the full RFC 822.
    /// - `html` (default): neither an html nor a text body was parsed.
    static func partialBodyNotDownloaded(content: EmailContent, format: String) -> Bool {
        guard content.fromPartialEmlx else { return false }
        switch format {
        case "text":
            return (content.textBody ?? "").isEmpty
        case "source":
            return true
        default:
            return (content.htmlBody ?? "").isEmpty && (content.textBody ?? "").isEmpty
        }
    }

    /// #274 verify R1 (Codex) — format-aware "is the body STILL absent" check
    /// for the AppleScript fallback result of the partial-`.emlx` route. A
    /// bare `isEmpty` is only right for the body-only formats: a header-only
    /// SOURCE is non-empty yet body-less, so the annotation would be silently
    /// skipped — the exact header-only case #274 exists to surface (and the
    /// fast path itself already judges a non-empty partial source incomplete).
    ///
    /// - `text` / `html`: the `content` string IS the body — empty ⇒ missing.
    /// - `source`: complete only when an RFC 822 header/body separator exists
    ///   AND carries non-whitespace body bytes after it.
    static func fallbackBodyStillMissing(_ content: String, format: String) -> Bool {
        switch format {
        case "source":
            // Pick the EARLIEST separator, not CRLF-preferred (verify R2,
            // Codex): a mixed-newline source (LF top headers + a trailing
            // CRLF-CRLF later in the body) would otherwise match the LATE
            // CRLF pair, see nothing after it, and wrongly annotate a
            // message that HAS a body.
            let separators = [
                content.range(of: "\r\n\r\n"),
                content.range(of: "\n\n"),
            ].compactMap { $0 }
            guard let sep = separators.min(by: { $0.lowerBound < $1.lowerBound }) else {
                return true
            }
            return content[sep.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return content.isEmpty
        }
    }

    /// Wrap a result array in the truncation envelope (#204) so callers can
    /// detect when more rows matched than were returned instead of silently
    /// losing them. `truncated` is definitive on the SQLite fast path (limit+1
    /// fetch) and best-effort (`returned == limit`) on the AppleScript fallback.
    static func resultEnvelope(results: [[String: Any]], limit: Int, truncated: Bool) -> [String: Any] {
        [
            "results": results,
            "returned": results.count,
            "limit": limit,
            "truncated": truncated,
        ]
    }

    /// Validate + normalize the #208 `search_emails` `projection` / `dedup` params.
    /// Pure (no I/O) so the spec's normative "reject invalid combinations" contract
    /// (unknown enum value, or `dedup: logical` with `projection: full`) is
    /// unit-testable. Returns the validated projection + a `dedup` bool.
    static func validateSearchProjection(projection: String, dedup dedupStr: String) throws -> (projection: String, dedup: Bool) {
        // #177: `summary` joins ids/count/full. Like ids/count it requires the
        // SQLite index and supports `dedup: logical` (it performs no recipient
        // subquery, so the full-row-dedup ambiguity that bars `full` doesn't apply).
        guard ["full", "ids", "summary", "count"].contains(projection) else {
            throw MailError.invalidParameter("projection must be 'full', 'ids', 'summary', or 'count'")
        }
        guard ["none", "logical"].contains(dedupStr) else {
            throw MailError.invalidParameter("dedup must be 'none' or 'logical'")
        }
        let dedup = dedupStr == "logical"
        if dedup && projection == "full" {
            throw MailError.invalidParameter("dedup 'logical' is only supported with projection 'ids', 'summary', or 'count' (full-row dedup is not implemented)")
        }
        return (projection, dedup)
    }

    /// #177: parse a `skip_message_ids_path` file body into the dedup Message-ID
    /// set. Pure (no I/O) so the CRLF/line-ending handling is unit-testable.
    /// Splits on **any** newline (LF / CR / CRLF — a CRLF file is a single `\r\n`
    /// grapheme, so a bare `split("\n")` mis-parses the whole file as one entry),
    /// trims surrounding whitespace + newlines, and ignores blank lines and `#`
    /// comments. Matching is exact on the trimmed full Message-ID string.
    static func parseSkipMessageIds(_ contents: String) -> Set<String> {
        var set: Set<String> = []
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            set.insert(trimmed)
        }
        return set
    }

    private func formatJSON(_ value: Any) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            return String(describing: value)
        }
    }
}

// MARK: - Value Extensions

extension Value {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        if case .string(let s) = self { return Int(s) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        if case .string(let s) = self { return s == "true" }
        return nil
    }

    var arrayValue: [Value]? {
        if case .array(let arr) = self { return arr }
        return nil
    }

    var objectValue: [String: Value]? {
        if case .object(let obj) = self { return obj }
        return nil
    }
}

/// #304 — `plain` is the only format a composing tool acts on.
///
/// `markdown` / `html` are still PARSED so they can be refused by name: the
/// message says what was removed and what to do instead, which a generic
/// "unknown value" error cannot. The wording comes from `ComposeRefusal` so the
/// boundary and the pre-flight check can never drift apart. Any other value is
/// an ordinary validation error naming the one permitted value.
func parseBodyFormat(_ raw: String?) throws -> BodyFormat {
    guard let format = BodyFormat(rawValueOrNil: raw) else {
        throw MailError.invalidParameter(
            "format must be \"plain\" — the only supported body format (got: \(raw ?? "nil"))")
    }
    guard format == .plain else {
        throw MailError.invalidParameter(ComposeRefusal.richTextFormat(format).message)
    }
    return format
}

/// Issue #35: type-strict bool extraction. Returns the bool when key is present
/// and is a real boolean; returns `defaultValue` when key is missing or null;
/// **throws** `MailError.invalidParameter` when key is present but wrong type
/// (e.g. caller sent string `"true"` instead of bool `true`).
///
/// The previous pattern `arguments[key]?.boolValue ?? false` silently coerced
/// non-bool inputs to default, which for `save_as_draft` meant the user wanted
/// "save for review" but got "send now" — irreversible.
func requireBool(_ arguments: [String: Value], key: String, default defaultValue: Bool) throws -> Bool {
    guard let value = arguments[key] else { return defaultValue }
    if case .null = value { return defaultValue }
    // Strict type check: .boolValue on Value coerces some non-bool inputs
    // (per #35 anti-pattern). Use case-pattern matching to require an actual
    // Bool literal in the JSON.
    if case .bool(let bool) = value {
        return bool
    }
    throw MailError.invalidParameter("'\(key)' must be a boolean (true/false), got: \(typeName(of: value))")
}

/// Issue #35: type-strict optional string-array extraction. Returns nil when
/// key is missing or null; **throws** when key is present but not an array of
/// strings. The previous pattern `arguments[key]?.arrayValue?.compactMap` would
/// silently drop entries that weren't strings (e.g. caller sent a string
/// instead of an array → silent nil → recipient missing CC).
func optionalStringArray(_ arguments: [String: Value], key: String) throws -> [String]? {
    guard let value = arguments[key] else { return nil }
    if case .null = value { return nil }
    // Strict type check via case-pattern (Value's accessors are lenient).
    guard case .array(let array) = value else {
        throw MailError.invalidParameter("'\(key)' must be an array of strings, got: \(typeName(of: value))")
    }
    var result: [String] = []
    for (idx, element) in array.enumerated() {
        guard case .string(let str) = element else {
            throw MailError.invalidParameter("'\(key)[\(idx)]' must be a string, got: \(typeName(of: element))")
        }
        result.append(str)
    }
    return result
}

/// Helper for diagnostic error messages: human-readable type name for a Value.
func typeName(of value: Value) -> String {
    switch value {
    case .null: return "null"
    case .bool: return "boolean"
    case .int: return "integer"
    case .double: return "number"
    case .string: return "string"
    case .array: return "array"
    case .object: return "object"
    case .data: return "data"
    }
}

/// Issue #50: validate that `arguments["id"]` is present, a string, and parses as Int.
/// Returns the validated id as `String` to preserve the existing JSON Schema (`id: string`).
/// Throws `MailError.invalidParameter` for missing, non-string, or non-numeric input.
///
/// Without this validation, a malicious / hallucinated MCP caller could pass
/// `id = "123 whose subject is \"x\" or true ..."` which AppleScript interpolates
/// into `whose id is 123 whose subject is "x" or true ...` — `or true` short-circuits
/// the predicate and returns the wrong message. See #50 diagnosis.
func requireMessageId(_ arguments: [String: Value]) throws -> String {
    guard let raw = arguments["id"]?.stringValue else {
        throw MailError.invalidParameter("id is required and must be a numeric message id")
    }
    guard !raw.isEmpty else {
        throw MailError.invalidParameter("id must be a non-empty numeric message id (got empty string)")
    }
    guard Int(raw) != nil else {
        throw MailError.invalidParameter("id must be a numeric message id (got: '\(raw)')")
    }
    return raw
}

/// Decode the optional `account_id` argument shared by every account-referencing
/// tool. When the key is present but the value is neither a string nor JSON
/// `null` (e.g. a lenient client serialized a UUID-shaped value as an int), emit
/// an actionable stderr warning and fall back to `nil` — without the warning the
/// handler would silently degrade to the `account_name` (display_name) path and
/// re-surface the #101 collision the caller was trying to escape (#111).
///
/// Absent key and explicit JSON `null` both return `nil` with no warning — both
/// legitimately mean "no account_id supplied".
func decodeAccountId(_ arguments: [String: Value], tool: String) -> String? {
    guard let raw = arguments["account_id"] else { return nil }
    if let value = raw.stringValue { return value }
    if raw.isNull { return nil }
    let warning = "WARN: \(tool) received non-string account_id "
        + "(got: \(typeName(of: raw))); ignoring — falling back to the account_name "
        + "(display_name) path, which may surface the #101 collision behavior.\n"
    Diagnostics.emit(warning)
    return nil
}

/// Why a read-tool SQLite + .emlx fast path fell through to the AppleScript
/// fallback. Used by `fastPathFallthroughLog` (#100).
enum FastPathFallthrough {
    /// `EnvelopeIndexReader.mailboxURL(forMessageId:)` returned `nil` — the
    /// rowId is absent from the Envelope Index, or the account has no local
    /// `.emlx` store (legitimate for EWS/Exchange, see #9). Not an error.
    case rowIdNotIndexed
    /// The Envelope Index lookup or the `.emlx` parse threw; carries the
    /// thrown error's `localizedDescription`.
    case error(String)
    /// #274 — the store only holds a `.partial.emlx` and the requested body
    /// is absent: Mail has not downloaded the message body yet. Not an
    /// error — the AppleScript fallback's `content`/`source` read doubles
    /// as the fetch nudge the direct file read cannot perform.
    case partialBodyNotDownloaded
}

/// Build the stderr diagnostic line for a read-tool SQLite fast-path
/// fall-through, so the drop to AppleScript is never silent
/// (`r-must-direct-db.md` "logged fallback" rule, #100 — completes the #69
/// observability work for the previously-unlogged `nil`-return branch).
///
/// Pure (returns the string; the side-effecting write lives in
/// `logFastPathFallthrough`) so the message contract is unit-testable.
///
/// - The `.error` case is byte-identical to the pre-#100 inline `catch`-branch
///   messages — `tool="get_email"` / `perItem=false` and
///   `tool="get_emails_batch"` / `perItem=true` reproduce them exactly.
/// - The `.rowIdNotIndexed` case is deliberately worded as a neutral "miss",
///   NOT a "failure": it fires legitimately for every EWS/Exchange account on
///   every call, and must not read as an error in those setups (#9).
func fastPathFallthroughLog(tool: String, rowId: Int, reason: FastPathFallthrough,
                            perItem: Bool = false) -> String {
    let suffix = perItem ? " for this item" : ""
    switch reason {
    case .rowIdNotIndexed:
        return "SQLite \(tool) fast path miss for rowId=\(rowId): "
            + "rowId not resolvable via Envelope Index (absent, or no local "
            + ".emlx — e.g. EWS/Exchange); falling through to AppleScript\(suffix)\n"
    case .error(let detail):
        return "SQLite \(tool) fast path failed for rowId=\(rowId): "
            + "\(detail); falling through to AppleScript\(suffix)\n"
    case .partialBodyNotDownloaded:
        return "SQLite \(tool) fast path hit a partial .emlx for rowId=\(rowId): "
            + "body not downloaded yet (#274); falling through to AppleScript "
            + "to nudge Mail to fetch it\(suffix)\n"
    }
}

/// Write a `fastPathFallthroughLog` line to stderr. Thin side-effecting wrapper
/// — call this at the fast-path fall-through sites (#100).
func logFastPathFallthrough(tool: String, rowId: Int, reason: FastPathFallthrough,
                            perItem: Bool = false) {
    let line = fastPathFallthroughLog(tool: tool, rowId: rowId, reason: reason, perItem: perItem)
    Diagnostics.emit(line)
}

/// Re-word a `save_attachment` Tier-2 AppleScript failure into an actionable
/// error, when (and only when) the AppleScript error code is `-10000`
/// (`errAEEventFailed` — Mail.app's `save attachment` handler raised an
/// internal exception). The raw message ("Mail got an error: AppleEvent
/// handler failed") gives the caller nothing to act on (#103).
///
/// - Parameter localCopyConfirmedMissing: `true` when the Tier-1 SQLite +
///   `.emlx` fast path already threw `MailSQLiteError.attachmentNotFound` for
///   this call — i.e. the MCP itself *proved*, from local `.emlx` state, that
///   the attachment binary is absent locally (no inline copy, no externalised
///   copy). When `true` the message states the cause definitively; when
///   `false` it is hedged ("usually means"), since `-10000` is a generic
///   AppleEvent error and the cause was not independently confirmed.
/// - Returns: an actionable, recovery-oriented message for code `-10000`;
///   `nil` for any other code — the caller then rethrows the original error
///   unchanged. Pure (no I/O) so the message contract is unit-testable.
func saveAttachmentAppleEventHint(code: Int, accountName: String, rawMessage: String,
                                  localCopyConfirmedMissing: Bool) -> String? {
    switch code {
    case -10000:
        let cause: String
        if localCopyConfirmedMissing {
            cause = "The SQLite + .emlx fast path already confirmed the attachment's "
                + "binary is absent from the local Mail store (no inline copy in the "
                + ".emlx, no externalised copy in the Attachments cache), so Mail.app "
                + "had to re-fetch it from the IMAP server — and that fetch failed."
        } else {
            cause = "For save_attachment this usually means the attachment's binary is "
                + "not in the local Mail cache and Mail.app could not re-fetch it from "
                + "the IMAP server."
        }
        return """
        save_attachment failed: Mail.app's save-attachment handler raised an error \
        (-10000, AppleEvent handler failed — "\(rawMessage)"). \(cause) Recovery options:
        (1) Re-fetch the message: call the synchronize_account MCP tool for \
        "\(accountName)" (or in Mail.app: Mailbox menu → Take All Accounts Online, then \
        Synchronize "\(accountName)"), then retry save_attachment.
        (2) In Mail.app: select the affected mailbox, then Mailbox menu → Rebuild.
        (3) Manual fallback: open the message in Mail.app and use the attachment's \
        "Save Attachment…" / drag-out, which forces Mail.app to fetch the binary.
        If the local copy IS present, instead check that the save_path directory is \
        writable and has free space.
        """
    case -1719, -1728:
        // #173 + verify PR #187 findings 1/3/4: BOTH codes are overloaded —
        // -1719 fires for any zero-match `first … whose` filter (a stale
        // message rowId is the most common producer), and -1728 fires for any
        // failed NAMED access (a missing nested chain segment post-#174, a
        // stale account UUID, or the account-description namespace mismatch).
        // A single asserted cause per code misdirects recovery, so the hint
        // discriminates on the failing object class named in the raw
        // AppleScript message instead. Precedence message → mailbox → account
        // matches AppleScript's innermost-failure reporting: "Can't get
        // message 1 of mailbox …" names the message as the failing object
        // even though the text also mentions mailbox/account. The class names
        // inside the error text stay English even under a localized macOS
        // (they quote the AppleScript expression); an unrecognized message
        // falls through to a hedged combined hint.
        let lower = rawMessage.lowercased()
        let focus: String
        if lower.contains("message") {
            focus = """
            The failing reference is the MESSAGE lookup — the mailbox and account \
            resolved, but no message with the given id exists there. The id from \
            search_emails may be stale (message deleted, moved, or re-indexed since \
            the search). Re-run search_emails and retry with the fresh id and its \
            accompanying mailbox/account fields.
            """
        } else if lower.contains("mailbox") {
            focus = """
            The failing reference is the MAILBOX lookup. Nested Gmail paths like \
            [Gmail]/全部郵件 ARE supported (#174) — use the mailbox value verbatim \
            from search_emails / list_emails output (it reflects the on-disk \
            hierarchy), make sure it is paired with the SAME message's account, and \
            compare against the account's real names via list_mailboxes.
            """
        } else if lower.contains("account") {
            focus = """
            The failing reference is the ACCOUNT selector. Either account_name does \
            not match Mail's AppleScript account name (the account description shown \
            in Mail settings, e.g. "Google" — often NOT the email address that \
            SQLite-path tools like search_emails report), or the account UUID is \
            stale (account removed/re-added in Mail). Check list_accounts.
            """
        } else {
            focus = """
            One of the account / mailbox / message / attachment references could not \
            be resolved — the raw message above names the failing object. Check each \
            against list_accounts / list_mailboxes / a fresh search_emails run.
            """
        }
        return """
        save_attachment failed: Mail.app could not resolve a reference \
        (\(code) — "\(rawMessage)"). \(focus) \
        Passing account_id (the UUID from search_emails results or the id field in \
        list_accounts) rules out account-name namespace mismatches.
        """
    default:
        return nil
    }
}

/// Validate and prepare the `save_attachment` destination (#178).
///
/// Both tiers fail on a missing parent directory: Tier 1's `Data.write` throws
/// (`AttachmentExtractor.saveAttachment` documents "parent directory MUST already
/// exist"), and Tier 2's Mail.app `save att in POSIX file "<path>"` raises a
/// generic `-10000` that `saveAttachmentAppleEventHint` translates IMAP-cache-first
/// — sending the user to synchronize/rebuild dead-ends for what is just a missing
/// `mkdir -p` (the 2026-06-11 repro in #178).
///
/// This function removes the **missing-parent** source of that misleading `-10000`,
/// and surfaces the two adjacent destination problems as actionable errors instead
/// of letting them reach Tier 2's `-10000` (verify PR #189 review):
///
///  1. **Path shape** — `save_path` must be a well-formed absolute file path. An
///     empty / relative / trailing-slash value makes `deletingLastPathComponent`
///     resolve to the process cwd or strip the intended leaf, so the wrong tree
///     would be created and a later `-10000` would *still* mislead. Rejected as
///     `invalidParameter`.
///  2. **Missing parent** — created with `mkdir -p`. **Accepted trade-off** (the
///     issue explicitly asked for "binary 自己 mkdir -p"): a typo'd absolute path
///     silently materialises the wrong tree rather than failing fast. We bound the
///     blast radius to *absolute* paths (shape check above) and prefer this over
///     the opaque `-10000` dead-end.
///  3. **Existing-but-unwritable parent** — `createDirectory` is a no-op success
///     when the dir already exists, but the write would still fail → Tier 2
///     `-10000`. A post-create writability check surfaces it as `operationFailed`.
///
/// **Scope of the guarantee**: this removes only the *missing-parent* and the two
/// problems above as sources of a misleading `-10000`. A `-10000` after this
/// returns reflects a destination-independent cause (e.g. the attachment binary is
/// not in the local Mail cache) — which is exactly what the (unchanged, byte-locked)
/// `saveAttachmentAppleEventHint` describes.
///
/// Free function (not a method) so it's unit-testable without the MCP server.
func ensureSaveDestinationDirectory(_ savePath: String) throws {
    // 1. Path shape — must be an absolute file path (not empty / relative /
    //    directory-form), so the parent we create is the one the caller intends.
    guard savePath.hasPrefix("/"), !savePath.hasSuffix("/") else {
        throw MailError.invalidParameter(
            "save_attachment: save_path must be an absolute file path "
            + "(start with '/' and name a file, not end with '/'); got \"\(savePath)\"."
        )
    }
    let fm = FileManager.default
    let parent = URL(fileURLWithPath: savePath).deletingLastPathComponent()
    // 2. Missing parent — mkdir -p (accepted trade-off, see docstring).
    do {
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    } catch {
        throw MailError.operationFailed(
            "save_attachment: cannot create the save_path parent directory "
            + "\(parent.path): \(error.localizedDescription). "
            + "Check the path is valid and that you have write permission."
        )
    }
    // 3. Existing-but-unwritable parent — createDirectory no-ops when the dir is
    //    already present, so verify it is actually a writable directory; otherwise
    //    the write would fail downstream as a misleading -10000.
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue,
          fm.isWritableFile(atPath: parent.path) else {
        throw MailError.operationFailed(
            "save_attachment: the save_path parent \(parent.path) is not a "
            + "writable directory. Check it exists, is a directory, and is writable."
        )
    }
}

/// Normalize `save_attachment`'s account parameters before the Tier 2
/// AppleScript fallback across all AppleScript-routed tools (#173 →
/// generalized in #176).
///
/// SQLite-path tools (`search_emails` / `list_attachments` / …) emit the
/// AccountsMap **email** as `account_name`, but Mail's AppleScript
/// `account "<name>"` selector matches the account DESCRIPTION — feeding the
/// email back fails with -1728. When the caller did not supply `account_id`
/// and the `accountName` looks like an email, resolve it to a UUID via
/// `AccountMapper.uuids(forEmail:)`:
///
/// - non-empty `accountId` → return it unchanged (byte-identical to pre-#176;
///   protects the #104 sweep's exact-string contract)
/// - `accountName` without `@` → return nil (legacy display_name path, unchanged)
/// - exactly one match → return that UUID (upgrade to the `account id` path),
///   logged to stderr per the logged-decision discipline (verify PR #187 #13)
/// - multiple matches → throw an actionable error listing every candidate —
///   the same address can front different accounts (iCloud catch-all vs Google
///   in #173's report); auto-picking would silently target the wrong one
///
/// #176: lifted out of the save_attachment-only layer into a shared helper
/// threaded by every AppleScript-routed handler that takes an `account_name`.
/// The pure ref-builders (`resolveAccountRef`/`resolveMailboxRef`/`resolveMsgRef`)
/// stay untouched — normalization happens at the handler layer.
///
/// - Parameters:
///   - tool: tool name for the stderr upgrade log (default "" → "save_attachment").
///   - uuidsForEmail: Injectable lookup for tests; defaults to `AccountMapper.uuids(forEmail:)`.
func resolveAccountIdForTool(
    accountId: String?,
    accountName: String,
    tool: String = "",
    uuidsForEmail: (String) -> [String] = { AccountMapper.uuids(forEmail: $0) }
) throws -> String? {
    if let aid = accountId, !aid.isEmpty { return aid }
    guard accountName.contains("@") else { return nil }
    let matches = uuidsForEmail(accountName)
    switch matches.count {
    case 0:
        return nil
    case 1:
        // Logged-decision discipline: the silent email→UUID upgrade changes
        // which selector the AppleScript path uses — make it observable for
        // every threaded tool (centralized here, #176).
        let label = tool.isEmpty ? "save_attachment" : tool
        let message = "\(label): account_name \"\(accountName)\" auto-upgraded to "
            + "(account id \"\(matches[0])\") via AccountsMap reverse lookup (#176)\n"
        Diagnostics.emit(message)
        return matches[0]
    default:
        // Name the tool (verify PR #190 finding) so the error is distinguishable
        // across the 14 callers, not identical text regardless of which fired.
        let label = tool.isEmpty ? "save_attachment" : tool
        throw MailError.invalidParameter(
            "\(label): account_name \"\(accountName)\" matches multiple Mail accounts: "
            + matches.joined(separator: ", ")
            + ". Pass account_id explicitly to select one — use list_accounts "
            + "to see which UUID belongs to which account."
        )
    }
}

func parseBodyFormatArgument(_ raw: Value?) throws -> BodyFormat {
    guard let raw = raw else { return .plain }
    if case .null = raw { return .plain }
    guard let str = raw.stringValue else {
        throw MailError.invalidParameter("format must be a string (\"plain\")")
    }
    return try parseBodyFormat(str)
}

/// Cross-validate SQLite attachment metadata against actual .emlx contents.
/// Shared between `list_attachments` (single-message) and `list_attachments_batch`
/// handlers — both must apply identical filtering semantics to keep the response
/// shape consistent. Extracted from inline closures so test code can drive the
/// filter directly without spinning up the full MCP server (issue #28).
///
/// Filter rule: keep only SQLite entries whose `name` field appears in the
/// `realNames` set parsed from the .emlx body. Entries without a `name` field
/// (or non-String name) are dropped — this matches the original closure's
/// `guard let name = entry["name"] as? String else { return false }`.
///
/// Issue #24 background: SQLite caches attachment metadata even after Mail.app
/// strips the binary on Sent / IMAP lazy-load, leaving stale entries that
/// `save_attachment` then fails to extract. This filter returns only entries
/// the parser confirms are actually present.
func crossValidateAttachments(
    sqliteAttachments: [[String: Any]],
    realNames: Set<String>,
    savability: [String: Bool] = [:],
    unsavableReasons: [String: String] = [:]
) -> [[String: Any]] {
    /// Stamp the savability contract onto one entry (#105 / #238). Absent from
    /// `savability` → the field is OMITTED, meaning "unknown"; callers must not
    /// read an absent `savable` as `false`.
    func stamped(_ entry: [String: Any], _ name: String) -> [String: Any] {
        var out = entry
        if let savable = savability[name] {
            out["savable"] = savable
            // #238: when not savable, say WHY — "not_downloaded" (open the
            // message in Mail to fetch it) vs "not_extractable".
            if !savable, let reason = unsavableReasons[name] {
                out["savable_reason"] = reason
            }
        }
        return out
    }

    // SQLite rows that the .emlx confirms. A row the .emlx does not contain is
    // stale cache, not an attachment — Mail keeps rows after stripping the
    // binary on Sent / IMAP lazy-load (#24), and reporting those made
    // save_attachment fail on names this tool had just advertised.
    var results: [[String: Any]] = []
    var seen = Set<String>()
    for entry in sqliteAttachments {
        guard let name = entry["name"] as? String, realNames.contains(name) else { continue }
        guard seen.insert(name).inserted else { continue }
        results.append(stamped(entry, name))
    }

    // #365 — and everything the .emlx has that SQLite never indexed.
    //
    // The set used to be seeded ONLY from SQLite, with the .emlx as a filter, so
    // the result was `SQLite ∩ emlx`. Apple Mail writes no `attachments` rows
    // for messages it composed and sent itself, so for outgoing mail the left
    // side is empty and the intersection is empty regardless of what is on
    // disk — measured: 3 of 4 messages in one archive run, hiding 5 attachments
    // (~427 KB), silently. `save_attachment` succeeded on the very same tuple,
    // because retrieval parses the `.emlx` and never consults SQLite:
    // enumeration was SQLite-gated, retrieval was not.
    //
    // These entries deliberately carry NO `attachment_id`: there is no SQLite
    // row to take one from, and inventing one would send save_attachment's
    // name-free part-dir probe (#183) after a directory that does not exist.
    // Sorted because `Set` iteration order is not stable across runs.
    for name in realNames.subtracting(seen).sorted() {
        results.append(stamped(["name": name], name))
    }
    return results
}

/// #233 — single-line stderr deprecation warning emitted when the batch-export
/// tool is invoked under its deprecated pre-rename name. Pure (testable);
/// exactly one trailing newline so it stays a single stderr line.
func exportAliasDeprecationWarning() -> String {
    return "export_emails_markdown is DEPRECATED (renamed in #233) — call "
        + "batch_export_emails_markdown instead; the old name will not be removed before v3.0\n"
}
