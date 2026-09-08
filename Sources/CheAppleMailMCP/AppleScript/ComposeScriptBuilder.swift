import Foundation

func appleScriptEscape(_ string: String) -> String {
    return string
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r\n", with: "\" & return & \"")
        .replacingOccurrences(of: "\n", with: "\" & return & \"")
        .replacingOccurrences(of: "\r", with: "\" & return & \"")
        .replacingOccurrences(of: "\t", with: "\" & tab & \"")
}

// Issue #39 / #61: helper-owns-indent contract.
// `attachmentFragment` and `recipientFragment` emit lines with their own
// 4-space indent baked in. Callers MUST prefix with bare "\n" (newline only,
// no extra spaces) — the helper output already has the indent. Adding
// extra prefix at call sites breaks visual alignment between first line
// (caller-prefix + helper-indent = double-indented) and subsequent lines
// (separator-only + helper-indent = single-indented), regressing #39's
// single-source-of-truth promise.
//
// Issue #60: Mail.app's AppleScript attachment pipeline is asynchronous.
// Two failure modes when emitting consecutive `make new attachment` calls
// without pacing: (1) `at after the last paragraph` in the next call
// resolves to the same anchor as the previous one because the previous
// insert hasn't materialized yet — Mail.app's collision behavior drops
// all but one; (2) `save` / `send` commits before in-flight attachment
// binds drain. For N >= 2 we interleave `delay 0.3` between attachments
// (gives anchor materialization time) and append `delay 0.5` trailing
// (ensures pipeline drain before dispatch). N == 1 has no race so emits
// no delay — keeps the common path latency-free.

// Issue #64: delay constants are escape-hatchable via env vars.
// Defaults (0.3 / 0.5) are picked rather than measured; on a Mac under load
// (Time Machine, Spotlight reindex, dozen apps) or after Mail.app updates
// the timing window can shift. Without an escape hatch, a user reporting
// "still drops attachments 6 months from now" has no way to test calibration
// without a code change. Sane bounds (0–10s) prevent denial-of-self attacks.
private let defaultDelayBetween = 0.3
private let defaultDelayTrailing = 0.5

private func resolvedDelay(envKey: String, fallback: Double) -> Double {
    guard let raw = ProcessInfo.processInfo.environment[envKey],
          let value = Double(raw),
          value >= 0, value <= 10 else {
        return fallback
    }
    return value
}

private func attachmentFragment(for paths: [String]) -> String {
    guard !paths.isEmpty else { return "" }
    let lines = paths.map { path in
        "    make new attachment with properties {file name:POSIX file \"\(appleScriptEscape(path))\"} at after the last paragraph"
    }
    if paths.count == 1 {
        return lines[0]
    }
    let between = resolvedDelay(envKey: "CHE_MAIL_ATTACHMENT_DELAY_BETWEEN", fallback: defaultDelayBetween)
    let trailing = resolvedDelay(envKey: "CHE_MAIL_ATTACHMENT_DELAY_TRAILING", fallback: defaultDelayTrailing)
    var pieces: [String] = []
    for (idx, line) in lines.enumerated() {
        pieces.append(line)
        if idx < lines.count - 1 {
            pieces.append("    delay \(between)")
        }
    }
    pieces.append("    delay \(trailing)")
    return pieces.joined(separator: "\n")
}

// #251: internal (not private) so RecipientDisplayNameTests can pin the
// name-aware output directly. A `Name <email>` recipient becomes the native
// {name, address} property pair — Mail displays the person's name; a bare
// address keeps the historical single-property form byte-identical.
func recipientFragment(_ addresses: [String], kind: String) -> String {
    addresses.map { addr in
        let parsed = parseRecipient(addr)
        if let name = parsed.name {
            return "    make new \(kind) recipient at end of \(kind) recipients "
                + "with properties {name:\"\(appleScriptEscape(name))\", "
                + "address:\"\(appleScriptEscape(parsed.address))\"}"
        }
        return "    make new \(kind) recipient at end of \(kind) recipients with properties {address:\"\(appleScriptEscape(parsed.address))\"}"
    }.joined(separator: "\n")
}

// MARK: - #175 mailto-based clean-body compose (GUI orchestration)
//
// Builds the AppleScript that drives Mail's NATIVE compose pipeline via a
// `mailto:` hand-off (which, unlike `set content` / `set html content`, does NOT
// wrap the body in `Apple-Mail-URLShareWrapperClass` / `blockquote type="cite"`).
// The mailto window is NOT an AppleScript `outgoing message` object, so save/send
// and attachments are driven by System Events keystrokes.
//
// Locale-independence (avoids the #174-class hardcoded-string trap): EVERY step
// uses a keyboard SHORTCUT, never a localized menu-item name —
//   ⇧⌘A = File ▸ Attach,  ⇧⌘G = Go to folder,  ⌘S = save draft,  ⇧⌘D = send.
// These are identical across UI languages.
//
// Robustness (hardened per two #175 verify rounds — DA + Codex cross-model):
//   - WINDOW IDENTITY: before EVERY keystroke phase (each attach AND dispatch) we
//     re-locate the compose window BY TITLE (= subject; eligibility guarantees a
//     non-empty subject) and best-effort raise it, so a keystroke lands on OUR
//     window and not one the user opened/focused during a delay. A bare
//     window-count delta is NOT enough (`activate` can open a viewer). RESIDUAL
//     (documented): AX has no "send keystroke to a specific window" primitive, so
//     a TOCTOU gap between raise and keystroke remains — inherent to GUI
//     automation; a detectable mismatch (our window gone) hard-errors → fallback.
//   - ATTACHMENT COMPLETION: the pre-dispatch check asserts `count of sheets of
//     _w is 0`, so a still-open File▸Attach panel blocks dispatch; a drain delay
//     gives the attachment time to bind before ⇧⌘D. RESIDUAL: panel-closed is a
//     proxy for bind, not per-file completion polling.
//   - STAGE-AWARE FALLBACK + NO DATA LOSS: the GUI interaction is wrapped in
//     try/on-error that closes ONLY a window we created — identified by NEW
//     `id of window` (captured before the mailto) AND matching subject — so a
//     pre-existing same-titled draft the user already had open is never
//     `saving no` discarded (a data-loss bug the second verify round caught).
//     Dispatch is the last statement, so a pre-dispatch error means nothing was
//     sent (fallback safe; no double-send).
//   - CLIPBOARD: the per-attachment path is set on the clipboard here, but
//     save/restore is done by the caller in Swift (full-fidelity NSPasteboard,
//     failure-safe) — this script does NOT save/restore.
// Delays are env-overridable (#64 pattern) because GUI timing drifts under load.

// #218: the GUI dispatch keystroke is shared between the mailto compose path
// (#175) and the native-verb reply/forward paste path. Locale-independent
// shortcuts: ⇧⌘D = send, ⌘S = save draft. Extracted so both paths emit
// byte-identical dispatch (and a single place to change it).
func composeDispatchKeystroke(send: Bool) -> String {
    return send
        ? "keystroke \"d\" using {command down, shift down}"
        : "keystroke \"s\" using command down"
}

func buildMailtoComposeScript(
    url: String,
    subject: String,
    attachments: [String],
    send: Bool,
    fromAddress: String? = nil,
    fill: [RecipientFill] = []
) -> String {
    let windowDelay = resolvedDelay(envKey: "CHE_MAIL_MAILTO_WINDOW_DELAY", fallback: 1.8)
    let stepDelay = resolvedDelay(envKey: "CHE_MAIL_MAILTO_STEP_DELAY", fallback: 0.7)
    let attachDrain = resolvedDelay(envKey: "CHE_MAIL_MAILTO_ATTACH_DRAIN", fallback: 1.5)
    let dispatchKey = composeDispatchKeystroke(send: send)
    let dispatchLabel = send
        ? "Email sent successfully (mailto path)"
        : "Draft created successfully (mailto path)"
    let subjEsc = appleScriptEscape(subject)

    // raiseOnly (runs inside `tell process "Mail"`): re-locate the compose window
    // BY TITLE (= subject) and best-effort raise it so the NEXT keystroke lands on
    // OUR window. Re-applied before EVERY keystroke phase (each attach + dispatch)
    // — focus the user/system stole during a delay is reclaimed. Hard-errors if
    // our window is gone (→ safe fallback). Keys off the target `_w`, never
    // `front window` (that evaluated unreliably under the actor's in-process
    // NSAppleScript context and regressed the path to always-fallback); AXRaise is
    // best-effort (wrapped) so an AX quirk can't break the path.
    let raiseOnly = """
                set _t to "\(subjEsc)"
                set _w to missing value
                set _wMatches to 0
                repeat with _cand in windows
                    if title of _cand is _t then
                        set _w to _cand
                        set _wMatches to _wMatches + 1
                    end if
                end repeat
                if _w is missing value then error "mailto compose window not found (title)"
                if _wMatches > 1 then error "AMBIGUOUS: more than one window is titled the subject — cannot safely target our compose window for the next keystroke (safe fallback)"
                try
                    perform action "AXRaise" of _w
                end try
                delay 0.25
    """
    // verifyNoSheet: raiseOnly + assert no open sheet (the File▸Attach panel must
    // have closed) — used immediately before dispatch.
    let verifyNoSheet = raiseOnly + """

                if (count of sheets of _w) is not 0 then error "a sheet/panel is still open on the compose window"
    """

    // #242 verify hardening (Codex HIGH + DA): `_dispatched` guards the tail —
    // the post-dispatch `delay` runs ONLY on the success path (mail definitely
    // sent), so an error there must be sentinel-marked too, not just keystroke
    // errors. Flag initialized BEFORE the outer try so the handler can always
    // reference it.
    let flagInit = send ? "set _dispatched to false\n    " : ""
    // #404: `_bccRevealed` is read by the return statement, so it is
    // initialized before the outer try (same reason as `_dispatched`).
    let fillsBcc = fill.contains { $0.field == .bcc }
    let bccFlagInit = fillsBcc ? "set _bccRevealed to false\n    " : ""

    // #404: handlers for the AX-addressed fill phase. `findAddressField` scans
    // the compose window's text fields for a stable AXIdentifier (indexed +
    // guarded, #295 — a for-in item-fetch throws -2700 on a settling AX tree);
    // `findMenuItemNamed` scans ONLY the View menu — the menu-bar item named
    // "顯示方式" (zh-TW Mail) or "View" (English Mail); other UI languages fail
    // cleanly with BCCREVEAL naming that limit (PR #407 R1 #10 / R2-8) — for an
    // item whose name contains one of the locale fragments: the menu is matched
    // by name, the item by fragment.
    let fillHandlers = fill.isEmpty ? "" : """
    on findAddressField(_w, _idf)
        tell application "System Events"
            tell process "Mail"
                set _tfTotal to 0
                try
                    set _tfTotal to (count of text fields of _w)
                end try
                repeat with _tfi from 1 to _tfTotal
                    try
                        set _tf to text field _tfi of _w
                        if (value of attribute "AXIdentifier" of _tf) is _idf then return _tf
                    end try
                end repeat
            end tell
        end tell
        return missing value
    end findAddressField

    on findMenuItemNamed(_frags)
        tell application "System Events"
            tell process "Mail"
                repeat with _mbi in menu bar items of menu bar 1
                    -- PR #407 R1 #10: only the View menu (顯示方式 / View). The
                    -- Window menu lists window TITLES — our own subject — so a
                    -- bar-wide fragment scan could click a window entry instead.
                    set _mbName to ""
                    try
                        set _mbName to (name of _mbi as text)
                    end try
                    if _mbName is not "顯示方式" and _mbName is not "View" then
                        -- skip
                    else
                    try
                        repeat with _mi in menu items of menu 1 of _mbi
                            set _nm to ""
                            try
                                set _nm to (name of _mi as text)
                            end try
                            repeat with _f in _frags
                                if _nm contains (_f as text) then return _mi
                            end repeat
                        end repeat
                    end try
                    end if
                end repeat
            end tell
        end tell
        return missing value
    end findMenuItemNamed

    """

    // 1. Capture Mail window ids BEFORE the mailto, hand it off, then identify
    // OUR compose window as the NEW window (id unseen before) whose title is our
    // subject — captured as `_ourId`. On-error cleanup closes ONLY `_ourId`, by
    // id-iteration — never by a title guess, so it can never discard a user's
    // same-titled draft (`saving no` on the wrong window would be data loss —
    // #175 verify R2 + #219/#277 verify R2, Codex BLOCKING). `id of window` is
    // stable + unique. We do NOT assume exactly one new window: launching Mail
    // from closed opens the viewer too, so we pick the new window by subject
    // rather than a count==1 assertion (which would over-reject to legacy
    // whenever Mail wasn't already running).
    // #219/#277 verify (Codex BLOCKING): System Events (where raiseOnly runs)
    // cannot read Mail's window `id`, so the KEYSTROKE-targeting bridge is the
    // title (= subject). Two guards make that bridge sound: (i) refuse the clean
    // path if our subject already titled a window BEFORE the mailto (below), and
    // (ii) raiseOnly asserts EXACTLY ONE window carries our title before each
    // keystroke phase — a same-title window opening concurrently (after the
    // snapshot) makes raiseOnly error pre-dispatch → cleanup closes only `_ourId`
    // → legacy fallback, so a race can neither keystroke/dispatch the wrong
    // window nor lose the user's window. The `my senderMatches` handler is
    // prepended only when a sender popup is driven — see below. It matches the
    // requested addr against a popup label by (a) exact bare addr, (b) the
    // literal `<addr>` angle-addr suffix, or (c) the LAST space-delimited token
    // equalling the addr. #219 live-smoke R6 (Codex/Claude verify all assumed a
    // `Name <addr>` format) found Mail's From popup actually renders
    // `Display Name – addr` with a SPACE + EN DASH (U+2013) + SPACE separator —
    // no angle brackets — so (a)/(b) never matched and the clean path always
    // fell to legacy. Branch (c) is separator-agnostic (en-dash / hyphen / any)
    // and anti-spoof-safe: `isSimpleAddrSpec` gates the addr to no-whitespace
    // upstream, so a simple addr is always the final space-delimited token, and
    // the compare is exact `is` (a `… – notche@x` label's last token is
    // `notche@x` ≠ `che@x`), never a substring. Never extracts between < and >
    // (a quoted local-part could spoof that).
    let senderMatchHandler = (fromAddress?.isEmpty == false) ? """
    on senderMatches(_label, _addr)
        set _label to _label as text
        if _label is _addr then return true
        if _label ends with ("<" & _addr & ">") then return true
        set _tid to AppleScript's text item delimiters
        set AppleScript's text item delimiters to space
        set _parts to text items of _label
        set AppleScript's text item delimiters to _tid
        if (count of _parts) is greater than 0 then
            if (item -1 of _parts) is _addr then return true
        end if
        return false
    end senderMatches

    """ : ""
    var s = fillHandlers + senderMatchHandler + """
    tell application "Mail"
        set _wc to (count of windows)
        set _beforeIds to (id of every window)
        set _beforeTitles to (name of every window)
        activate
        mailto "\(appleScriptEscape(url))"
    end tell
    delay \(windowDelay)
    tell application "Mail"
        if (count of windows) <= _wc then error "mailto did not open a compose window"
        if _beforeTitles contains "\(subjEsc)" then error "a window titled \\"\(subjEsc)\\" already existed before this compose — cannot safely disambiguate the new window (safe fallback)"
        set _ourId to missing value
        set _ourMatches to 0
        repeat with _cw in windows
            try
                if (_beforeIds does not contain (id of _cw)) and ((name of _cw) is "\(subjEsc)") then
                    set _ourId to (id of _cw)
                    set _ourMatches to _ourMatches + 1
                end if
            end try
        end repeat
        if _ourMatches is 0 then error "could not identify our new compose window by subject after mailto (safe fallback)"
        if _ourMatches > 1 then error "more than one new window is titled the subject — cannot safely identify our compose window (safe fallback)"
    end tell
    \(flagInit)\(bccFlagInit)try
        tell application "System Events"
            tell process "Mail"
                set frontmost to true
    \(raiseOnly)
            end tell
        end tell
    """

    // 1.5 (#277 → #404): display-name recipient fill via clipboard paste,
    // one address field at a time, each ADDRESSED BY ITS AXIdentifier.
    // The mailto URL omits any display-name-carrying list (a name can't ride
    // RFC 6068; pasting `Name <addr>` lets Mail tokenize natively). Paste, not
    // keystroke: CJK names via keystroke hit IME nondeterminism (#220 lesson);
    // the Swift caller wraps the run in withClipboardPreserved. Paste, not AX
    // `set value`: the live probe (#404, 2026-09-07) showed `set value` with a
    // comma list of NAMED recipients collapses into ONE token — the silent
    // recipient loss this phase exists to prevent.
    //
    // #277 verify (Codex BLOCKING) excluded Cc because a Tab-to-Cc + paste
    // could land in Subject when the field is hidden. #404 answers that by
    // focusing the field through its AXIdentifier (Mail.toField / Mail.ccField
    // / Mail.bccField): a hidden or renamed field is NOT FOUND → FILLFIELD
    // error → pre-dispatch cleanup → named refusal. Bcc, hidden by default, is
    // revealed on demand through the View menu (BCCREVEAL on failure) and is
    // deliberately NOT hidden again — the caller learns it via the
    // `[bcc-field-revealed]` tag on the return value.
    //
    // After each paste + Tab the field's tokens are read back (FILLREADBACK):
    // count must equal the recipient count and each token's AXValue must equal
    // the recipient's display name (its address when bare). The token exposes
    // no address over AX, so the addresses themselves are verified after the
    // save by the Swift-side recipient receipt.
    // Draft-only by design (#277): send:true never reaches this phase — a
    // failed fill on a send would fire with missing recipients.
    for entry in fill {
        let idf = entry.field.axIdentifier
        let line = entry.recipients.joined(separator: ", ")
        // PR #407 R1 #6: a bare address's token is NOT an invariant — Mail
        // renders an address that has a Contacts card as the card's NAME. So a
        // bare recipient contributes an empty expectation (= any token text);
        // only a recipient that carries a display name expects that name. The
        // COUNT stays strict — that is what catches `set value`-style merging.
        let expectedNames = entry.recipients.map { r -> String in
            let parsed = parseRecipient(r)
            return "\"" + appleScriptEscape(parsed.name ?? "") + "\""
        }.joined(separator: ", ")
        let expectedCount = entry.recipients.count
        let reveal: String
        if entry.field == .bcc {
            let frags = entry.field.revealMenuNameFragments
                .map { "\"" + appleScriptEscape($0) + "\"" }.joined(separator: ", ")
            // The human-readable list goes INSIDE a string literal, so it must
            // not carry the literal quotes of the AppleScript list above
            // (osacompile: "Expected end of line but found unknown token").
            let fragsPlain = appleScriptEscape(entry.field.revealMenuNameFragments.joined(separator: " / "))
            reveal = """

                if _fld is missing value then
                    set _revealItem to my findMenuItemNamed({\(frags)})
                    if _revealItem is missing value then error "BCCREVEAL: no View menu item reveals the Bcc address field (looked for \(fragsPlain) under a menu named 顯示方式 or View — Mail UI languages other than zh-TW and English are not supported yet; show the Bcc field yourself and retry)"
                    click _revealItem
                    repeat 12 times
                        set _fld to my findAddressField(_w, "\(idf)")
                        if _fld is not missing value then exit repeat
                        delay 0.3
                    end repeat
                    if _fld is missing value then error "BCCREVEAL: the Bcc address field (\(idf)) did not appear after revealing it"
                    set _bccRevealed to true
                end if
        """
        } else {
            reveal = ""
        }
        s += """

        set the clipboard to "\(appleScriptEscape(line))"
        tell application "System Events"
            tell process "Mail"
                set frontmost to true
                \(raiseOnly)
                -- PR #407 R1 #13: the AX tree settles for a beat after the
                -- window opens (#295/#296) — poll the field, never judge one probe.
                set _fld to missing value
                repeat 12 times
                    set _fld to my findAddressField(_w, "\(idf)")
                    if _fld is not missing value then exit repeat
                    delay 0.3
                end repeat\(reveal)
                if _fld is missing value then error "FILLFIELD: address field \(idf) not found on the compose window — cannot fill \(entry.field.rawValue) display-name recipients"
                set focused of _fld to true
                delay 0.25
                keystroke "v" using command down
                delay \(stepDelay)
                keystroke tab
                delay \(stepDelay)
                set _expected to {\(expectedNames)}
                set _tokTotal to 0
                try
                    set _tokTotal to (count of UI elements of _fld)
                end try
                if _tokTotal is not \(expectedCount) then error "FILLREADBACK: \(idf) holds " & _tokTotal & " recipient tokens, expected \(expectedCount)"
                repeat with _ti from 1 to _tokTotal
                    set _tokVal to ""
                    try
                        set _tokVal to (value of UI element _ti of _fld as text)
                    end try
                    if (item _ti of _expected) is not "" and _tokVal is not (item _ti of _expected) then error "FILLREADBACK: \(idf) token " & _ti & " reads \\"" & _tokVal & "\\", expected \\"" & (item _ti of _expected) & "\\""
                end repeat
            end tell
        end tell
        delay \(stepDelay)
        """
    }

    // 1.7 (#219): verified sender popup. mailto always composes from the
    // DEFAULT account; a custom from_address is selected here by driving the
    // compose window's From popup. HARD REQUIREMENT (issue #219): selection
    // AND read-back use EXACT addr-spec equality, NOT substring containment
    // (#219 verify, Codex BLOCKING: `contains "user@x"` would match — and
    // wrongly VERIFY — a `notuser@x` account, sending from the wrong address).
    // `my senderMatches()` compares a menu label / popup value to the requested
    // account by EXACT match — bare `is _addr`, the `<addr>` angle-suffix, OR
    // the last space-delimited token (Mail's real `Name – addr` en-dash format,
    // #219 live-fix) — never by extraction (a quoted local-part could spoof
    // that; the caller normalizes `fromAddress` to a bare addr-spec and a
    // non-simple one is gated to legacy upstream by `isSimpleAddrSpec`). The
    // From popup is identified by its stable, locale-independent AXIdentifier
    // "popup_from" (#219 verify, Codex BLOCKING) — NOT a "value contains @"
    // scan, which a signature popup named like an email could satisfy and be
    // driven as the WRONG control. Any SENDERPOPUP error is pre-dispatch: the
    // on-error handler closes OUR window (saving no) and the Swift router falls
    // back to legacy `set sender` (correct sender beats clean body, #175).
    if let from = fromAddress, !from.isEmpty {
        let fromEsc = appleScriptEscape(from)
        s += """

        tell application "System Events"
            tell process "Mail"
                set frontmost to true
                \(raiseOnly)
                set _fromPopup to missing value
                -- #219 verify (Codex BLOCKING): identify the From popup by its
                -- stable, locale-independent AXIdentifier "popup_from" (live AX
                -- dump: priority=popup_priority, From=popup_from, signature=
                -- popup_signature), NEVER a "value contains @" scan — a signature
                -- popup whose value happens to hold an email (a user-named
                -- signature) could otherwise be picked as From and pass a
                -- self-consistent select + read-back on the WRONG control while
                -- the real From stays on the default account. #295: indexed +
                -- guarded fetch (a for-in item-fetch throws -2700 on an unstable
                -- AX tree). #219 live-fix: poll until the From popup's value is
                -- populated (empty for a beat after the window opens).
                repeat 12 times
                    set _fromPopup to missing value
                    set _pbTotal to 0
                    try
                        set _pbTotal to (count of pop up buttons of _w)
                    end try
                    repeat with _pbi from 1 to _pbTotal
                        try
                            set _pb to pop up button _pbi of _w
                            if (value of attribute "AXIdentifier" of _pb) is "popup_from" then
                                set _fromPopup to _pb
                                exit repeat
                            end if
                        end try
                    end repeat
                    if _fromPopup is not missing value then
                        set _fromValNow to ""
                        try
                            set _fromValNow to (value of _fromPopup as text)
                        end try
                        if _fromValNow contains "@" then exit repeat
                    end if
                    delay 0.3
                end repeat
                if _fromPopup is missing value then error "SENDERPOPUP: From popup (AXIdentifier popup_from) not found on the compose window"
                click _fromPopup
                delay \(stepDelay)
                -- #296: in-process NSAppleScript can evaluate the menu before it
                -- has opened/populated (settling-AX sibling of #295, menu layer —
                -- empirically: the identical matcher passes under osascript and
                -- gets ZERO items in-process). Poll for a populated menu; if
                -- still empty, re-click ONCE and poll again. Total failure falls
                -- to the existing sentinel (fail-closed unchanged). Enumeration
                -- is indexed + guarded, same as the #295 popup scan.
                set _miTotal to 0
                repeat 12 times
                    try
                        set _miTotal to (count of menu items of menu 1 of _fromPopup)
                    end try
                    if _miTotal > 0 then exit repeat
                    delay 0.3
                end repeat
                if _miTotal is 0 then
                    click _fromPopup
                    delay \(stepDelay)
                    repeat 12 times
                        try
                            set _miTotal to (count of menu items of menu 1 of _fromPopup)
                        end try
                        if _miTotal > 0 then exit repeat
                        delay 0.3
                    end repeat
                end if
                set _pickedItem to missing value
                ignoring case
                    repeat with _mii from 1 to _miTotal
                        try
                            set _mi to menu item _mii of menu 1 of _fromPopup
                            if my senderMatches(name of _mi as text, "\(fromEsc)") then
                                set _pickedItem to _mi
                                exit repeat
                            end if
                        end try
                    end repeat
                end ignoring
                if _pickedItem is missing value then
                    key code 53
                    error "SENDERPOPUP: no From account exactly matches \\"\(fromEsc)\\" (menu items seen: " & _miTotal & ")"
                end if
                click _pickedItem
                delay \(stepDelay)
                set _senderReadback to (value of _fromPopup as text)
                ignoring case
                    if not (my senderMatches(_senderReadback, "\(fromEsc)")) then error "SENDERPOPUP: read-back mismatch — popup shows \\"" & _senderReadback & "\\""
                end ignoring
            end tell
        end tell
        delay \(stepDelay)
        """
    }

    // 2. Attachments: re-raise OUR window, then one File ▸ Attach (⇧⌘A) cycle each,
    // path pasted into the Go-to-folder (⇧⌘G) field (clipboard set here, restored by
    // the caller in Swift). ASCII-only paths reach this flow: the sheet hangs
    // deterministically on CJK/fullwidth input even via paste (#220 live repro), so
    // non-ASCII paths are routed to the legacy native-attach path upstream — do NOT
    // remove that gate.
    if !attachments.isEmpty {
        // #341/#321 — put the caret at the END of the body before attaching.
        //
        // Mail's File ▸ Attach inserts at the CURRENT insertion point, and after
        // the mailto hand-off fills the body the caret sits at its START. So the
        // attachment icon landed to the LEFT of the first line — before the
        // salutation — which for a formal letter is the first thing the
        // recipient sees. Reported twice from live use (#321 2026-07-31,
        // #341 2026-08-07 with a screenshot) before the cause was identified.
        //
        // ⌘↓ (key code 125 + command) is "move to end of document" in a Cocoa
        // text view, and is locale-independent like the other shortcuts here.
        // Emitted ONCE before the loop, not per attachment: after the first
        // attach the caret is already past the body, and repeating it would be
        // harmless but would misrepresent the intent.
        s += """

        tell application "System Events"
            tell process "Mail"
                set frontmost to true
                \(raiseOnly)
                key code 125 using {command down}
            end tell
        end tell
        delay \(stepDelay)
        """
        for path in attachments {
            s += """

            tell application "System Events"
                tell process "Mail"
                    set frontmost to true
                    \(raiseOnly)
                    keystroke "a" using {command down, shift down}
                end tell
            end tell
            delay \(stepDelay)
            set the clipboard to "\(appleScriptEscape(path))"
            tell application "System Events"
                tell process "Mail"
                    keystroke "g" using {command down, shift down}
                    delay \(stepDelay)
                    keystroke "v" using command down
                    delay 0.4
                    key code 36
                    delay \(stepDelay)
                    key code 36
                end tell
            end tell
            delay \(stepDelay)
            """
        }
        // Drain: give the attachment(s) time to bind before dispatch (#60-style).
        s += "\n        delay \(attachDrain)\n"
    }

    // 3. Final re-raise + no-lingering-panel check + dispatch.
    // #242: for send:true the dispatch keystroke is wrapped in its own
    // POSTDISPATCH sentinel — once ⇧⌘D has been attempted, the send state is
    // UNKNOWN (the mail may already be on the wire), so the Swift layer must
    // not fall back to a legacy re-send (duplicate outbound). Pre-dispatch
    // errors (window lost, lingering sheet) stay unmarked → safe fallback.
    // ⌘S (draft save) keeps the plain fallback: a duplicated draft is visible
    // and harmless, unlike a duplicated send.
    let dispatchBlock: String
    if send {
        dispatchBlock = """
                try
                    \(dispatchKey)
                on error _dErr
                    error "POSTDISPATCH: " & _dErr
                end try
                set _dispatched to true
        """
    } else {
        dispatchBlock = "            \(dispatchKey)"
    }
    // #242: the on-error cleanup must NOT close the compose window when the
    // send state is unknown — that window is the user's only evidence. Only
    // send:true can produce sentinel-marked errors, so send:false keeps the
    // unconditional cleanup (AppleScript-equivalent to the pre-#242 script;
    // the cleanupBody extraction shifts leading whitespace, which AppleScript
    // ignores — verify #242, regression lens).
    // #333/#404: a mailto compose window does NOT close on `saving no` — Mail
    // answers with the "save this message as a draft?" sheet (AXIdentifier
    // Mail.sendMessageAlert; live probe 2026-09-07) and the window stays
    // behind it, which is how a pre-dispatch abort used to leave an orphan
    // window that made the next attempt fail on "same-title window exists"
    // (#333). Cleanup therefore dismisses the sheet through its DISCARD
    // button (title 不儲存 / Don't Save — never the save or cancel buttons),
    // re-checks that our window is gone, and otherwise appends a
    // WINDOWLEFTOPEN note to the error so the caller knows to close it.
    let cleanupBody = """
            tell application "Mail"
                repeat with _cw in windows
                    try
                        if (id of _cw) is _ourId then close _cw saving no
                    end try
                end repeat
            end tell
            delay 0.4
            tell application "System Events"
                tell process "Mail"
                    -- PR #407 R1 #11: System Events cannot see Mail's window
                    -- ids, so the sheet is found through the window TITLE. If
                    -- more than one window carries our subject the click could
                    -- discard someone else's unsaved message — refuse, and let
                    -- the WINDOWLEFTOPEN note below report it.
                    set _titleMatches to 0
                    repeat with _cw2 in windows
                        try
                            if (title of _cw2) is "\(subjEsc)" then set _titleMatches to _titleMatches + 1
                        end try
                    end repeat
                    if _titleMatches is 1 then
                    repeat with _cw2 in windows
                        try
                            if (title of _cw2) is "\(subjEsc)" and (count of sheets of _cw2) > 0 then
                                set _sh to sheet 1 of _cw2
                                if (value of attribute "AXIdentifier" of _sh) is "Mail.sendMessageAlert" then
                                    repeat with _b in buttons of _sh
                                        set _bt to ""
                                        try
                                            set _bt to (title of _b as text)
                                        end try
                                        if _bt is "不儲存" or _bt is "Don't Save" or _bt is "Don’t Save" then
                                            click _b
                                            exit repeat
                                        end if
                                    end repeat
                                end if
                            end if
                        end try
                    end repeat
                    end if
                end tell
            end tell
            delay 0.4
            set _stillOpen to false
            tell application "Mail"
                repeat with _cw in windows
                    try
                        if (id of _cw) is _ourId then set _stillOpen to true
                    end try
                end repeat
            end tell
            set _leftOpenReason to "its discard sheet could not be dismissed"
            if _titleMatches is greater than 1 then set _leftOpenReason to "cleanup refused to dismiss its discard sheet because " & _titleMatches & " windows carry this subject and only one can be ours"
            if _titleMatches is 0 then set _leftOpenReason to "no window carrying this subject was visible to System Events, so nothing was clicked"
            if _stillOpen then set _mErr to (_mErr as text) & " — WINDOWLEFTOPEN: the compose window titled \\"\(subjEsc)\\" was left open (" & _leftOpenReason & "); close it in Mail before retrying"
    """
    // send:true handler: three branches, all rethrow — sentinel-marked errors
    // (keystroke) pass through untouched; unmarked errors with the flag set
    // (tail) get marked here; genuine pre-dispatch errors clean up + rethrow.
    let handlerBlock = send
        ? """
            if _mErr starts with "POSTDISPATCH:" then
                error _mErr
            else if _dispatched then
                error "POSTDISPATCH: " & _mErr
            else
        \(cleanupBody)
                error _mErr
            end if
        """
        : "\(cleanupBody)\n        error _mErr"
    // send:true keeps the settle delay INSIDE the outer try (flag-guarded);
    // send:false keeps it after end try, as before.
    let preHandlerTail = send ? "\n        delay \(stepDelay)" : ""
    let postTryTail = send ? "" : "\n    delay \(stepDelay)"
    s += """

        tell application "System Events"
            tell process "Mail"
                set frontmost to true
    \(verifyNoSheet)
    \(dispatchBlock)
            end tell
        end tell\(preHandlerTail)
    on error _mErr
    \(handlerBlock)
    end try\(postTryTail)
    \(fillsBcc ? "set _bccTag to \"\"\n    if _bccRevealed then set _bccTag to \" [bcc-field-revealed]\"\n    return \"\(dispatchLabel)\" & _bccTag" : "return \"\(dispatchLabel)\"")
    """
    return s
}

/// #304 — forward with NO new body: the native `forward` verb plus the
/// recipient fragment, and nothing else. This is the one composing script that
/// never had a body to assign, so it survives the removal of the injecting
/// builders unchanged — and unlike the paste path it needs no Accessibility
/// grant, because it drives no keystrokes.
///
/// Mail builds the quoted original itself; the user adds no note. Extracted
/// from the former `buildForwardEmailScript(userBody: nil)` branch so the
/// deletion of that builder does not take a wrapper-free capability with it.
func buildForwardNoBodyScript(messageRef: String, to: [String]) -> String {
    return """
    tell application "Mail"
        set originalMsg to \(messageRef)
        set fwdMsg to forward originalMsg with opening window
        tell fwdMsg
    \(recipientFragment(to, kind: "to"))
        end tell
        send fwdMsg
        return "Email forwarded successfully"
    end tell
    """
}

// MARK: - #218 native-verb + paste reply/forward (wrapper-free new body)
//
// Until #304 there were also `buildReplyEmailScript` / `buildForwardEmailScript`
// here: they opened the reply/forward window with the native verb but then
// OVERWROTE Mail's content with a self-composed body via `set content` /
// `set html content` — which Mail wraps in `Apple-Mail-URLShareWrapperClass` /
// `blockquote type="cite"` (the #218 bug, same mechanism as #175 compose). They
// are gone; these builders are now the ONLY reply/forward path.
//
// These builders keep Mail's NATIVE quote (the `reply`/`forward` verb builds it,
// correctly, in its own cite-blockquote + sets threading headers) and inject the
// NEW body ONLY via a System Events clipboard paste at the cursor — never `set
// content`/`set html content`. So the quoted original stays a proper quote and
// the user's new text is clean. Plain-only + Accessibility-gated; when either
// precondition fails the caller now REFUSES with a named reason (#304) rather
// than falling back to a body-assigning builder.
//
// Window identity = id-delta (the `Re:`/`Fwd:` title prefix is LOCALIZED, so it
// is never matched). We capture window ids before the verb, diff to find the new
// window, read its ACTUAL title (`name of _w`, whatever locale) and bridge that
// real title into the System Events / AX context (where Mail's window id is not
// visible). On-error cleanup closes ONLY the windows we created (by id) — never a
// pre-existing user window (the #175-round-2 data-loss guard).

/// Shared core for the clean reply/forward paste path. `openVerb` is the native
/// Mail verb (`reply` / `reply all` / `forward`); `nativeLines` is the (already
/// `\n`-prefixed, helper-indented) cc/to/attachment fragment block to set on the
/// reply/forward message object, or `""` for none. Delays reuse the #175 mailto
/// env keys (same GUI-timing class).
private func buildReplyForwardPasteScript(
    messageRef: String,
    openVerb: String,
    msgVar: String,
    newBody: String,
    nativeLines: String,
    needsAttachDrain: Bool,
    send: Bool,
    successLabel: String,
    notOpenedError: String
) -> String {
    let windowDelay = resolvedDelay(envKey: "CHE_MAIL_MAILTO_WINDOW_DELAY", fallback: 1.8)
    let stepDelay = resolvedDelay(envKey: "CHE_MAIL_MAILTO_STEP_DELAY", fallback: 0.7)
    let attachDrain = resolvedDelay(envKey: "CHE_MAIL_MAILTO_ATTACH_DRAIN", fallback: 1.5)
    let dispatchKey = composeDispatchKeystroke(send: send)
    let bodyEsc = appleScriptEscape(newBody)

    // WINDOW IDENTITY — front-window-id guard (#218 verify; live-verified).
    //
    // The id-delta uniquely identifies OUR newly-opened window in the Mail object
    // model. But the keystrokes go through System Events / AX, and AX has no view
    // of Mail's window id. The mailto path (#175) bridges to AX by window TITLE —
    // which does NOT work here: Mail's reply/forward COMPOSE windows expose an
    // EMPTY `name` (the live test proved a reply window's title is ""), so a
    // title match would either refuse the (common) empty-title case → legacy-wrap,
    // or match the wrong same-titled window. Instead we use the guard the verify
    // reviewers (Logic + Devil's Advocate) recommended: in the MAIL context, gate
    // each keystroke phase on `id of front window` ∈ the id-delta set — i.e. OUR
    // window is the frontmost Mail window. `reply/forward with opening window`
    // opens the window frontmost; if the user stole focus during a delay, the id
    // won't match → error → on-error close (scoped to our ids) → MailController
    // catch → legacy injection fallback. Then `set frontmost to true` + keystroke
    // hits that frontmost window. RESIDUAL (inherent GUI automation, documented):
    // a sub-second TOCTOU between the Mail-side check and the AX keystroke remains
    // — same class as the #175 mailto residual; a detectable change degrades to
    // the legacy fallback.
    let frontGuard = """
        tell application "Mail"
            if (count of windows) is 0 then error "no Mail window to target (falling back)"
            if (id of front window) is not in _newIds then error "our reply/forward window is not frontmost (focus changed) — falling back"
        end tell
    """

    // #254: `_dispatched` flag (see the #242 block below) — initialized before
    // the outer try so the handler can always reference it; send-only.
    let rfFlagInit = send ? "set _dispatched to false\n    " : ""

    // 1. Capture ids, drive the native verb, compute the new-window id delta.
    var s = """
    tell application "Mail"
        set _beforeIds to (id of every window)
        set originalMsg to \(messageRef)
        set \(msgVar) to \(openVerb) originalMsg with opening window
    end tell
    delay \(windowDelay)
    tell application "Mail"
        set _afterIds to (id of every window)
        set _newIds to {}
        repeat with _k from 1 to (count of _afterIds)
            set _thisId to item _k of _afterIds
            if _beforeIds does not contain _thisId then set end of _newIds to _thisId
        end repeat
        if (count of _newIds) is 0 then error "\(notOpenedError)"
    end tell
    \(rfFlagInit)try
    \(frontGuard)
        tell application "System Events"
            tell process "Mail"
                set frontmost to true
                delay 0.25
                set the clipboard to "\(bodyEsc)"
                keystroke "v" using command down
                delay \(stepDelay)
            end tell
        end tell
    """

    // 2. Native cc/to/attachments on the message object — set AFTER the body
    // paste so the fresh body-top cursor is undisturbed (the paste lands above
    // Mail's quote; object mutations don't move the GUI insertion point).
    if !nativeLines.isEmpty {
        s += """

        tell application "Mail"
            tell \(msgVar)\(nativeLines)
            end tell
        end tell
        """
    }
    if needsAttachDrain {
        s += "\n        delay \(attachDrain)\n"
    }

    // 3. Re-confirm our window is still frontmost + no lingering panel + dispatch;
    // on-error closes ONLY the windows we created (by id), never a pre-existing
    // user window.
    //
    // Draft path closes its own window AFTER the dispatch succeeds: a saved-draft
    // ⌘S leaves the compose window OPEN (unlike a ⇧⌘D send, which closes it), so
    // without this every quiet draft accumulates a window — and an open compose
    // window also holds the draft, blocking later deletion. The close lives
    // OUTSIDE the `try` (best-effort, own inner `try`): a close failure must NOT
    // propagate into the legacy fallback, which would save a SECOND draft (the
    // double-dispatch hazard the "dispatch is the last statement in `try`"
    // ordering deliberately avoids). `saving yes` is a harmless re-save of the
    // already-saved draft, never a discard.
    // Both window closes ITERATE `every window` and test id membership, rather
    // than the `first window whose id is X` FILTER form — that filter is
    // unreliable on Mail compose windows (it silently fails the same way
    // `whose message id is` does), leaving the window open. Iteration + an
    // `(id of _cw) is in _newIds` membership check closes reliably (live-verified).
    let draftWindowClose = send ? "" : """


    tell application "Mail"
        repeat with _cw in (every window)
            try
                if (id of _cw) is in _newIds then close _cw saving yes
            end try
        end repeat
    end tell
    """
    // #254 (the #242 pattern, verbatim): for send:true the dispatch keystroke
    // gets its own POSTDISPATCH sentinel and the `_dispatched` flag marks any
    // error from the success-path tail — once ⇧⌘D has been attempted the send
    // state is UNKNOWN and the Swift layer must not fall back to a legacy
    // re-send (duplicate outbound reply/forward). The draft path (⌘S) keeps
    // the plain fallback and its post-try window close (a close failure must
    // never re-enter the legacy fallback — the double-dispatch hazard).
    let rfDispatchBlock: String
    if send {
        rfDispatchBlock = """
                    try
                        \(dispatchKey)
                    on error _dErr
                        error "POSTDISPATCH: " & _dErr
                    end try
                    set _dispatched to true
        """
    } else {
        rfDispatchBlock = "                \(dispatchKey)"
    }
    let rfCleanupBody = """
            tell application "Mail"
                repeat with _cw in (every window)
                    try
                        if (id of _cw) is in _newIds then close _cw saving no
                    end try
                end repeat
            end tell
    """
    let rfHandlerBlock = send
        ? """
            if _mErr starts with "POSTDISPATCH:" then
                error _mErr
            else if _dispatched then
                error "POSTDISPATCH: " & _mErr
            else
        \(rfCleanupBody)
                error _mErr
            end if
        """
        : "\(rfCleanupBody)\n        error _mErr"
    let rfPreHandlerTail = send ? "\n    delay \(stepDelay)" : ""
    let rfPostTryTail = send ? "" : "\n    delay \(stepDelay)"
    s += """

    \(frontGuard)
        tell application "System Events"
            tell process "Mail"
                set frontmost to true
                delay 0.25
                if (count of sheets of window 1) is not 0 then error "a sheet/panel is still open on the compose window"
    \(rfDispatchBlock)
            end tell
        end tell\(rfPreHandlerTail)
    on error _mErr
    \(rfHandlerBlock)
    end try\(rfPostTryTail)\(draftWindowClose)
    return "\(successLabel)"
    """
    return s
}

/// #218 — wrapper-free reply: native `reply`/`reply all` verb (Mail quotes the
/// original) + clipboard paste of the plain new body at the cursor. cc/attachments
/// are set natively on the reply message (unchanged from #34/#60). `saveAsDraft`
/// ⌘S vs send ⇧⌘D. The new body is NEVER `set content`/`set html content`.
func buildReplyEmailPasteScript(
    messageRef: String,
    newBody: String,
    replyAll: Bool,
    ccAdditional: [String]? = nil,
    attachments: [String]? = nil,
    saveAsDraft: Bool
) -> String {
    var fragments: [String] = []
    if let cc = ccAdditional, !cc.isEmpty {
        fragments.append(recipientFragment(cc, kind: "cc"))
    }
    let hasAttachments = (attachments?.isEmpty == false)
    if let atts = attachments, !atts.isEmpty {
        fragments.append(attachmentFragment(for: atts))
    }
    let nativeLines = fragments.isEmpty ? "" : "\n" + fragments.joined(separator: "\n")

    return buildReplyForwardPasteScript(
        messageRef: messageRef,
        openVerb: replyAll ? "reply all" : "reply",
        msgVar: "replyMsg",
        newBody: newBody,
        nativeLines: nativeLines,
        needsAttachDrain: hasAttachments,
        send: !saveAsDraft,
        successLabel: saveAsDraft ? "Reply saved as draft (paste path)"
                                  : "Reply sent successfully (paste path)",
        notOpenedError: "reply did not open a compose window"
    )
}

/// #218 — wrapper-free forward: native `forward` verb (Mail quotes the original)
/// + clipboard paste of the plain new note at the cursor. `to` recipients are set
/// natively on the forward message. Forward always sends (no draft mode in the
/// `forward_email` tool). The new note is NEVER `set content`/`set html content`.
func buildForwardEmailPasteScript(
    messageRef: String,
    to: [String],
    newBody: String
) -> String {
    let nativeLines = to.isEmpty ? "" : "\n" + recipientFragment(to, kind: "to")

    return buildReplyForwardPasteScript(
        messageRef: messageRef,
        openVerb: "forward",
        msgVar: "fwdMsg",
        newBody: newBody,
        nativeLines: nativeLines,
        needsAttachDrain: false,
        send: true,
        successLabel: "Email forwarded successfully (paste path)",
        notOpenedError: "forward did not open a compose window"
    )
}

