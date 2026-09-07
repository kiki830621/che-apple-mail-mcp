import Foundation

// MARK: - #175 mailto-based clean-body compose
//
// Mail.app wraps ANY AppleScript-injected outgoing-message body
// (`content:` / `set content` / `set html content`) in its
// `Apple-Mail-URLShareWrapperClass` › `blockquote type="cite"` "inserted /
// shared content" path at MIME-serialization time — so recipients (esp. mobile
// clients honoring `cite`) see the user's own new text rendered as a quotation.
// The wrapper cannot be stripped after the fact (reading the live outgoing
// message's `html content` → AppleScript -1723; re-setting clean HTML → re-wraps;
// editing the saved `.emlx` → overwritten by Mail on send). The ONLY wrapper-free
// paths are Mail's native editor: typing, clipboard paste, and the `mailto:`
// hand-off. `mailto:` is the robust one (it populates the body itself, so there
// is no fragile "focus the body field" step), at the cost of being plain-text
// only and needing a GUI keystroke (Accessibility TCC) to save/send.
//
// This file holds the PURE, unit-testable pieces: the URL builder and the
// "use mailto vs fall back to legacy injection" decision. The GUI orchestration
// (open window → sender popup → attach files → Cmd+S / Cmd+Shift+D) lives in
// MailController and is gated/live-tested.

/// RFC 3986 unreserved characters — everything else is percent-encoded. This is
/// deliberately conservative (matches Python's `urllib.parse.quote` default):
/// `@`, spaces, newlines, `&`, `=`, `?`, CJK, etc. all become `%XX`, so no body
/// or subject content can leak into the URL's structural delimiters.
///
/// Spelled out as an explicit ASCII set rather than `CharacterSet.alphanumerics`.
/// In practice both encode CJK/accented input identically (`addingPercentEncoding`
/// operates on UTF-8 bytes), so the old set was NOT buggy — but `.alphanumerics`
/// is Unicode-inclusive by definition, making the percent-encode contract depend
/// on a Foundation implementation detail. The explicit ASCII set pins the
/// contract the tests assert, independent of that detail (#175 verify, Codex).
private let mailtoUnreserved: CharacterSet =
    CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

/// Upper bound on the encoded `mailto:` URL length. Beyond this, the native
/// compose path risks silent body truncation (URL parsers / Mail), so the caller
/// falls back to the legacy injection path (which has no length limit). 8000 is
/// well under typical OS URL ceilings while comfortably fitting ordinary mail.
let maxMailtoURLLength = 8000

/// Percent-encode a single mailto component (recipient / subject / body).
func mailtoEncode(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: mailtoUnreserved) ?? ""
}

/// Build a percent-encoded `mailto:` URL that Mail's native compose pipeline
/// renders WITHOUT the `blockquote type="cite"` wrapper (#175).
///
/// Recipients go in the path (comma-joined); cc/bcc/subject/body are query
/// params. Empty/nil cc/bcc are omitted. `body` is plain text — newlines become
/// `%0A` (Mail renders them as `<br>`).
func buildMailtoURL(
    to: [String],
    subject: String,
    body: String,
    cc: [String]? = nil,
    bcc: [String]? = nil
) -> String {
    let toPart = to.map(mailtoEncode).joined(separator: ",")
    var query: [String] = []
    if let cc = cc, !cc.isEmpty {
        query.append("cc=" + cc.map(mailtoEncode).joined(separator: ","))
    }
    if let bcc = bcc, !bcc.isEmpty {
        query.append("bcc=" + bcc.map(mailtoEncode).joined(separator: ","))
    }
    query.append("subject=" + mailtoEncode(subject))
    query.append("body=" + mailtoEncode(body))
    var url = "mailto:" + toPart
    if !query.isEmpty { url += "?" + query.joined(separator: "&") }
    return url
}


// MARK: - #218 clean reply/forward (native-verb + paste)
//
// reply_email / forward_email have the SAME wrapper bug as #175 compose: the
// new reply/forward text, injected via `set content` / `set html content`, is
// wrapped in `Apple-Mail-URLShareWrapperClass` / `blockquote type="cite"` so
// mobile recipients see the user's OWN new text as a quotation. The #175 mailto
// fix does NOT transfer — `mailto:` always opens a *fresh* compose and can't
// thread a reply or carry the quoted original.
//
// The clean path drives Mail's NATIVE `reply` / `forward` verb (Mail builds the
// quoted original itself — legitimately in a `blockquote type="cite"` — and sets
// the In-Reply-To / References threading headers), then pastes ONLY the new body
// at the cursor via System Events. The native quote stays correct; only the new
// text avoids the wrapper. Like #175 it is plain-only (clipboard carries plain)
// and needs Accessibility (the GUI paste/dispatch keystrokes).
//
// #304: the injecting builders this path used to fall back to are gone. When
// either precondition fails, reply/forward now REFUSES (`ComposeRefusal`) —
// there is no second path to degrade to.

/// #229 — fold every newline flavor (\n, \r, CRLF, U+2028, U+2029, NEL) and
/// control character to a single space and cap the length, so an echoed GUI
/// error stays one bounded line inside a result-string disclosure.
func clampedErrorEcho(_ text: String, limit: Int = 200) -> String {
    let separators = CharacterSet.newlines.union(.controlCharacters)
    let folded = text.unicodeScalars
        .map { separators.contains($0) ? " " : String($0) }
        .joined()
    return String(folded.prefix(limit))
}

// MARK: - #304 pre-flight refusal

/// #220 — true iff every attachment path is pure ASCII. The mailto path
/// attaches via the GUI go-to-folder sheet (⇧⌘G + paste), which hangs
/// deterministically on CJK/fullwidth paths (live repro, v2.17.0) — the
/// panel-closed proxy can't detect a sheet that never accepts its input.
/// ASCII-only paths are the known-good set; anything else is refused (#304)
/// with the manual-drag recipe — the path that used to absorb them attached
/// natively but assigned the body, which is what this project no longer does.
func attachmentPathsGuiSafe(_ paths: [String]?) -> Bool {
    guard let paths, !paths.isEmpty else { return true }
    return paths.allSatisfy { $0.allSatisfy(\.isASCII) }
}


/// #251 — parse an RFC 5322 mailbox form `Name <email>` (or `"Name" <email>`)
/// into (name, address). A bare address returns (nil, input); a bare-angle
/// form `<email>` normalizes to the inner address (verify round). An UNQUOTED
/// name containing `<`/`>` is malformed — RFC 5322 makes them specials,
/// forbidden in unquoted atoms — and returns (nil, input) so the boundary
/// validation rejects it on the whole string (verify REQUIRED: a multi-angle
/// input like `A <a@x> <b@y>` must fail loudly, never silently reinterpret
/// as a send to the LAST address). Quoted names may contain specials.
/// Whitespace-tolerant.
func parseRecipient(_ raw: String) -> (name: String?, address: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    // #286: the display-name / addr-spec split point is the LAST '<' that is
    // NOT inside an RFC 5322 quoted string — a bare lastIndex(of: "<") landed
    // inside a quoted local-part that STARTS with '<' (`"Foo" <"<a>"@x>`) and
    // garbled the extraction (name=`Foo" <`, addr=`a>"@x`). Quote state honors
    // quoted-pairs (`\"` stays inside), same escape semantics as
    // `unescapeQuotedPairs` / `containsUnquotedAngle`. Two deliberate edges:
    //   - An UNTERMINATED quote never yields an unquoted '<' — the string
    //     stays bare and the validator rejects it (fail-loud; the old split
    //     silently accepted an unbalanced-quote display name).
    //   - The scan walks Characters, not scalars: a grapheme-masked '<'
    //     (fused with U+FE0F) is literal text here — no split — and the
    //     validator's SCALAR-level scan (#280) rejects it downstream.
    //     Splitting at a scalar index could land mid-grapheme and trap on
    //     String slicing, so fail-safe beats scalar precision at this layer.
    // Split-happened invariant: an unquoted '<' requires every quote before
    // it to have closed, so the extracted name always carries balanced quote
    // state — the `wasQuoted` prefix/suffix heuristic below can no longer
    // pair quotes from two different sources (#286's second defect).
    var lastUnquotedLT: String.Index? = nil
    var inQuote = false
    var escaped = false
    var idx = trimmed.startIndex
    while idx < trimmed.endIndex {
        let ch = trimmed[idx]
        if inQuote {
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inQuote = false
            }
        } else if ch == "\"" {
            inQuote = true
        } else if ch == "<" {
            lastUnquotedLT = idx
        }
        idx = trimmed.index(after: idx)
    }
    guard trimmed.hasSuffix(">"), let lt = lastUnquotedLT else {
        return (nil, trimmed)
    }
    let addrStart = trimmed.index(after: lt)
    let addrEnd = trimmed.index(before: trimmed.endIndex)
    let address = String(trimmed[addrStart..<addrEnd]).trimmingCharacters(in: .whitespaces)
    guard !address.isEmpty else { return (nil, trimmed) }
    var name = String(trimmed[..<lt]).trimmingCharacters(in: .whitespaces)
    if name.isEmpty {
        // Bare-angle `<a@b.c>` — an addr-spec in angles; normalize.
        return (nil, address)
    }
    let wasQuoted = name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2
    if wasQuoted {
        // #266: decode RFC 5322 quoted-pairs inside the quoted display name so
        // the native recipient name carries the intended value (`\"` → `"`,
        // `\\` → `\`), not the backslash-escaped source form. Any `\x` becomes
        // `x`; an unbalanced trailing backslash is kept literally.
        name = unescapeQuotedPairs(String(name.dropFirst().dropLast()))
    } else if name.contains("<") || name.contains(">") {
        // Unquoted angles in the name = malformed (extra/unmatched pairs) —
        // fail loudly via whole-string validation, never reinterpret.
        return (nil, trimmed)
    }
    guard !name.isEmpty else { return (nil, trimmed) }
    return (name, address)
}

/// #266 — decode RFC 5322 quoted-pairs (`\x` → `x`) in a quoted-string body
/// (outer quotes already stripped). A backslash escapes the next character; a
/// trailing lone backslash is kept literally. Single pass.
func unescapeQuotedPairs(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    var escaped = false
    for ch in s {
        if escaped {
            out.append(ch)
            escaped = false
        } else if ch == "\\" {
            escaped = true
        } else {
            out.append(ch)
        }
    }
    if escaped { out.append("\\") }
    return out
}

/// #270 — true iff the string contains a `<` or `>` that is NOT inside a
/// well-formed RFC 5322 quoted string in a position where one may appear.
/// Quote state honors quoted-pairs (`\"` stays inside the quoted string —
/// same escape semantics as `unescapeQuotedPairs`). Two verify-round (R1,
/// Codex) tightenings keep the exemption honest:
///   - An UNTERMINATED quote is not a quoted-string at all (RFC 5322), so
///     angles seen inside one count as unquoted at EOF (`"a<b@x`, and the
///     #265-regression shape `"a<b>@x`, are both rejected).
///   - A quoted-string cannot appear in the DOMAIN — after the first
///     unquoted `@`, a `"` is a literal, so `a@"<x>"` counts its angles.
/// Used by the boundary validator to reject stray angles whether paired
/// (`x <a@b> <c@d>`, #265) or unpaired (`<a@x` / `a@x>`, #270) without
/// mis-rejecting legal quoted local-parts (`"a<b"@x`). Single pass.
///
/// Iterates unicodeScalars, NOT Characters (#280 verify, Codex): a `>`
/// followed by a combining scalar (e.g. U+FE0F variation selector) fuses
/// into one extended grapheme cluster under Character iteration, so the
/// cluster compares unequal to ">" and the stray angle slips the scan.
/// Every structural character here (`"` `\` `@` `<` `>`) is a single ASCII
/// scalar, so scalar-level comparison is strictly more precise.
func containsUnquotedAngle(_ s: String) -> Bool {
    var inQuote = false
    var escaped = false
    var angleInOpenQuote = false
    var seenUnquotedAt = false
    for ch in s.unicodeScalars {
        if inQuote {
            if escaped {
                // R2 (Codex): an escaped angle is still an angle character —
                // record it, or an unterminated quote holding `\<` / `\>`
                // would bypass the EOF check below (re-opening the #265
                // paired-shape regression via `"a\<b\>@x`). A properly
                // closed quote still resets the record, so the legal
                // `"a\<b\>"@x` stays exempt.
                if ch == "<" || ch == ">" { angleInOpenQuote = true }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inQuote = false
                angleInOpenQuote = false
            } else if ch == "<" || ch == ">" {
                angleInOpenQuote = true
            }
        } else if ch == "\"" {
            // Quotes may only open a quoted-string in the local part; after
            // an unquoted `@` they are literal characters.
            if !seenUnquotedAt { inQuote = true }
        } else if ch == "@" {
            seenUnquotedAt = true
        } else if ch == "<" || ch == ">" {
            return true
        }
    }
    // EOF with an open quote: no quoted-string was formed — any angle seen
    // inside it was never actually protected.
    return inQuote && angleInOpenQuote
}

/// #251 — true iff any recipient in the given lists carries a display name.
func anyRecipientHasDisplayName(_ recipients: [String]?) -> Bool {
    guard let recipients else { return false }
    return recipients.contains { parseRecipient($0).name != nil }
}

/// #219 verify R2 (Codex) — true iff `addr` is a plain addr-spec safe for the
/// exact From-popup suffix match (`senderMatches`). That match is spoof-proof
/// ONLY for a simple address: a quote / angle bracket / whitespace in the addr
/// (an exotic quoted local-part such as `"prefix<foo"@evil.example`) could let a
/// crafted account label end in the literal `<addr>` and suffix-match the WRONG
/// account. Requires exactly one '@' and none of `" < > ` or whitespace, so a
/// non-simple custom sender is routed to legacy (native `set sender`, correct
/// account, body wrapped) instead of the clean popup.
func isSimpleAddrSpec(_ addr: String) -> Bool {
    let a = addr.trimmingCharacters(in: .whitespacesAndNewlines)
    if a.isEmpty { return false }
    if a.contains("\"") || a.contains("<") || a.contains(">") { return false }
    // any Unicode whitespace, not just ASCII space/tab — an embedded NBSP or
    // other Unicode space could otherwise slip through (#219 verify R4, Codex).
    if a.contains(where: { $0.isWhitespace }) { return false }
    return a.filter { $0 == "@" }.count == 1
}

/// #304 — the pre-flight reasons a composing call cannot run.
///
/// **This is a closed enumeration.** A seventh case must not be added by
/// analogy: every case here is decidable BEFORE the operation starts and
/// therefore carries the guarantee that nothing happened. A failure that
/// occurs mid-operation (a keystroke that does not land, a paste that does not
/// take, a send stage that errors) is a different thing and is governed by the
/// post-dispatch classification in `isPostDispatchError` — it propagates, and
/// its message must NOT claim the call was a no-op.
///
/// Until #304 these same conditions chose a ROUTE rather than a refusal: they
/// diverted the call to a builder that assigned the body via AppleScript, which
/// Mail wraps in `<blockquote type="cite">` at MIME serialization. The sender
/// could not see it (the wrapper's inline style has no border) while Gmail and
/// Outlook showed the whole letter as quoted text. On 2026-07-29 a formal
/// meeting notice went out that way to 10 recipients and could not be recalled.
/// The builders are gone, so these conditions now end the call.
///
/// Each case's `message` must name the reason AND an executable alternative —
/// a refusal that leaves the caller with nothing to do is a worse outcome than
/// the silent degradation it replaced.
enum ComposeRefusal: Equatable {
    /// 1 — `format` is `markdown` or `html`.
    case richTextFormat(BodyFormat)
    /// 2 — empty subject.
    case emptySubject
    /// 3 — Accessibility (`AXIsProcessTrusted`) not granted.
    case accessibilityNotGranted
    /// 4 — `from_address` is not a simple addr-spec.
    case customSenderNotSimple
    /// 5 — an attachment path contains non-ASCII characters.
    case nonASCIIAttachmentPath
    /// 6 — a recipient carries a display name the clean path cannot fill.
    ///
    /// Always for cc/bcc; and for `to` on a SEND, because the GUI fill is
    /// draft-only (#277 — a fill that fails on a send would dispatch with
    /// missing recipients). A draft's `to` display name is supported.
    case displayNameRecipient

    var message: String {
        switch self {
        case .richTextFormat(let format):
            return "format '\(format.rawValue)' is no longer supported. No path this "
                + "project ships today can deliver rich text without assigning the body via "
                + "AppleScript, and assigning it that way is what wraps the whole letter in "
                + "<blockquote type=\"cite\"> (#304). Whether a clipboard paste could carry "
                + "rich text AND stay wrapper-free is UNVERIFIED, not impossible — #306 is "
                + "settling it. Use format 'plain'; alternative architectures are #308 / #309."
        case .emptySubject:
            return "the subject is empty. The compose path identifies its own window by "
                + "the window title (= subject) before it fires any keystroke, so an "
                + "untitled window cannot be told apart from one you opened yourself. "
                + "Supply a non-empty subject."
        case .accessibilityNotGranted:
            return "Accessibility (AXIsProcessTrusted) is not granted, so the GUI "
                + "keystrokes that save / send / attach cannot be driven. Grant it "
                + "(see check_accessibility) and retry, or use open_mailto — it needs no "
                + "TCC grant at all and opens a clean compose window, but it cannot carry "
                + "attachments and you save or send it yourself."
        case .customSenderNotSimple:
            return "from_address is not a simple addr-spec (it contains a quote, an angle "
                + "bracket, or whitespace). The From popup is verified by exact addr-spec "
                + "match, which is only spoof-proof for a bare address (#219). Pass a bare "
                + "addr-spec, or omit from_address and switch the sender in Mail's compose "
                + "window yourself."
        case .nonASCIIAttachmentPath:
            return "an attachment path contains non-ASCII characters. The go-to-folder "
                + "sheet (⇧⌘G) hangs deterministically on CJK / fullwidth paths (#220). "
                + "Create the draft WITHOUT the attachments argument and drag the file into "
                + "the window — do not rename the file to ASCII, because the recipient sees "
                + "that name."
        case .displayNameRecipient:
            return "a recipient carries a display name (Name <addr>) on a send. A mailto: URL "
                + "carries addr-spec only (RFC 6068), so display names are filled through the "
                + "compose window's GUI — and that fill is DRAFT-only: on a send, a fill that "
                + "failed would dispatch with missing recipients (#277). Use bare addresses to "
                + "send now, or create a draft (create_draft), where display names in to, cc "
                + "and bcc are supported (#404), and send it from Mail after checking the recipients."
        }
    }
}

/// #304 — the pre-flight refusal for a from-scratch compose (`compose_email` /
/// `create_draft`), or `nil` when the call may proceed.
///
/// Evaluation order follows the enumeration: a call that trips several
/// conditions reports the first, and the caller fixes them one at a time.
func composeRefusal(
    format: BodyFormat,
    accessibilityTrusted: Bool,
    hasCustomSender: Bool,
    hasSubject: Bool,
    attachmentsGuiSafe: Bool = true,
    recipientsAddrSpecOnly: Bool = true,
    displayNameFillViable: Bool = false,
    customSenderIsSimple: Bool = true
) -> ComposeRefusal? {
    guard format == .plain else { return .richTextFormat(format) }
    if !hasSubject { return .emptySubject }
    if !accessibilityTrusted { return .accessibilityNotGranted }
    if hasCustomSender && !customSenderIsSimple { return .customSenderNotSimple }
    if !attachmentsGuiSafe { return .nonASCIIAttachmentPath }
    // #277: display-name recipients ride the clean path via GUI clipboard fill —
    // but DRAFT-only (a failed fill on a send would fire with missing
    // recipients), TO-only, and only when the caller marked the fill viable.
    if !recipientsAddrSpecOnly && !displayNameFillViable { return .displayNameRecipient }
    return nil
}

/// #404 — the full pre-flight derivation for a from-scratch compose call
/// (`compose_email` / `create_draft` / `update_draft`'s replacement), or `nil`
/// when the call may proceed. Pure: every input the enumeration depends on is a
/// parameter, so the draft/send × to/cc/bcc × bare/named matrix is testable
/// without a live Accessibility grant. `MailController` delegates here.
///
/// Reason 6 is SEND-only. On a draft, a display name in ANY of the three lists
/// is filled through the compose window's AX-addressed field (#277 for `to`,
/// #404 for `cc` / `bcc`) and is not a refusal reason. On a send it refuses:
/// a fill that failed would dispatch with missing recipients.
func composeCallRefusal(
    format: BodyFormat,
    accessibilityTrusted: Bool,
    fromAddress: String?,
    subject: String,
    attachments: [String]?,
    to: [String],
    cc: [String],
    bcc: [String],
    draftMode: Bool
) -> ComposeRefusal? {
    let anyDisplayName = anyRecipientHasDisplayName(to)
        || anyRecipientHasDisplayName(cc)
        || anyRecipientHasDisplayName(bcc)
    return composeRefusal(
        format: format,
        accessibilityTrusted: accessibilityTrusted,
        hasCustomSender: (fromAddress?.isEmpty == false),
        hasSubject: !subject.isEmpty,
        attachmentsGuiSafe: attachmentPathsGuiSafe(attachments),
        recipientsAddrSpecOnly: !anyDisplayName,
        displayNameFillViable: draftMode,
        // #219 verify R2 (Codex): only a simple addr-spec is safe to drive the
        // exact From-popup match; an exotic quoted local-part is refused.
        customSenderIsSimple: fromAddress.map { isSimpleAddrSpec(parseRecipient($0).address) } ?? true
    )
}

/// #304 — the pre-flight refusal for `reply_email` / `forward_email`. Only two
/// of the six conditions can arise here: a reply has no subject, sender,
/// attachment-path or cc/bcc gate of its own on this path.
func replyForwardRefusal(
    format: BodyFormat,
    accessibilityTrusted: Bool
) -> ComposeRefusal? {
    guard format == .plain else { return .richTextFormat(format) }
    if !accessibilityTrusted { return .accessibilityNotGranted }
    return nil
}

/// #304 — run a composing tool's single (non-injecting) path.
///
/// The wiring lives in a helper for the reason #241 gave when it extracted the
/// previous router: the pure predicates were pinned by tests, but deleting the
/// inline wiring at a call site kept the suite green. `mapRuntimeError` carries
/// the #242 / #301 post-dispatch and timeout classification, which stays a
/// per-site decision (a draft may retry; a send may not).
func dispatchComposePath(
    refusal: ComposeRefusal?,
    cleanPath: () throws -> String,
    mapRuntimeError: (Error) -> Error = { $0 }
) throws -> String {
    if let refusal {
        throw MailError.invalidParameter(refusal.message)
    }
    do {
        return try cleanPath()
    } catch {
        throw mapRuntimeError(error)
    }
}

/// #242 — true iff `error` carries the POSTDISPATCH sentinel that
/// `buildMailtoComposeScript` (send:true) attaches to any error thrown at or
/// after the send-keystroke dispatch. Such errors mean the send state is
/// UNKNOWN (the mail may already be on the wire) — the caller must NOT fall
/// back to a legacy re-send.
func isPostDispatchError(_ error: Error) -> Bool {
    if case MailError.scriptFailed(let message, _) = error {
        // Prefix-only, symmetric with the AppleScript `does not start with`
        // cleanup check — a mid-string token (user-controlled content echoed
        // into a pre-dispatch error) must not classify (#242 verify).
        return message.hasPrefix("POSTDISPATCH:")
    }
    return false
}

/// #301 — true when the error is the script-deadline timeout. On a SENDING
/// clean path a timeout is an unknown-send-state condition of its own: the
/// whole keystroke flow (including ⇧⌘D and its post-dispatch tail) is ONE
/// script, so the deadline can expire on either side of the send keystroke —
/// and the terminated interpreter can no longer report which. The #242
/// POSTDISPATCH sentinel only classifies `.scriptFailed` errors thrown BY the
/// script; a timeout never carries the sentinel, so without this predicate it
/// would sail through `!isPostDispatchError` into the legacy re-send — the
/// duplicate-outbound hazard the sentinel exists to prevent (verify #301,
/// regression lens P0). Draft flows deliberately do NOT gate on this: a
/// duplicated draft is visible and harmless, and keeping their fallback is
/// what un-hangs draft creation (#301's own goal).
func isTimeoutError(_ error: Error) -> Bool {
    if case MailError.scriptTimedOut = error { return true }
    return false
}

/// #242/#239 — the canonical unknown-send-state error for a compose-family
/// send whose dispatch was already attempted: names the hazard, directs the
/// caller to check Sent/Outbox, and explicitly forbids a retry (an
/// auto-retrying LLM caller would otherwise re-send — the exact duplicate
/// hazard the sentinel exists to prevent). Shared by the default path's
/// router hook and the #239 strict branch.
///
/// #301: a send-flow TIMEOUT gets its own wording — the send keystroke may or
/// may not have fired (the interpreter was terminated mid-flight and cannot
/// say), which is a different honest statement than "was already dispatched".
func unknownSendStateError(_ error: Error) -> MailError {
    if isTimeoutError(error) {
        return MailError.scriptFailed(
            message: "the GUI send flow hit its deadline and was terminated mid-flight — "
                + "the send keystroke may or may not have fired, so the send state is "
                + "UNKNOWN. NOT retrying via the legacy path (that could send a "
                + "duplicate). Check Mail's Sent mailbox / Outbox and any leftover "
                + "compose window before re-sending. Original error: "
                + clampedErrorEcho(error.localizedDescription),
            code: -1)
    }
    return MailError.scriptFailed(
        message: "the send keystroke was already dispatched but the GUI step failed "
            + "afterwards — the send state is UNKNOWN and the mail may already be on "
            + "the wire. NOT retrying via the legacy path (that could send a duplicate). "
            + "Check Mail's Sent mailbox / Outbox before re-sending. The compose window "
            + "(if still open) was left untouched for inspection. Original error: "
            + clampedErrorEcho(error.localizedDescription),
        code: -1)
}
