import XCTest
@testable import CheAppleMailMCP

/// #175 — mailto-based clean-body compose. The wrapper-free path requires
/// building a percent-encoded `mailto:` URL (native compose pipeline) and
/// deciding when the GUI path is usable vs. when to fall back to the legacy
/// AppleScript injection (which produces the `blockquote type="cite"` wrapper).
/// The URL builder and the decision are pure → unit-tested here; the GUI
/// orchestration is gated/live-tested elsewhere.
final class MailtoComposeTests: XCTestCase {

    // MARK: - buildMailtoURL

    func testBuildMailtoURL_singleRecipient_plainBody() {
        let url = buildMailtoURL(to: ["a@b.c"], subject: "Hi", body: "Hello")
        XCTAssertEqual(url, "mailto:a%40b.c?subject=Hi&body=Hello")
    }

    func testBuildMailtoURL_multipleRecipients_commaJoined() {
        let url = buildMailtoURL(to: ["a@b.c", "d@e.f"], subject: "S", body: "B")
        XCTAssertTrue(url.hasPrefix("mailto:a%40b.c,d%40e.f?"),
                      "recipients should be comma-joined in the path: \(url)")
    }

    func testBuildMailtoURL_ccAndBcc_asQueryParams() {
        let url = buildMailtoURL(to: ["a@b.c"], subject: "S", body: "B",
                                 cc: ["c@d.e"], bcc: ["x@y.z"])
        XCTAssertTrue(url.contains("cc=c%40d.e"), "missing cc: \(url)")
        XCTAssertTrue(url.contains("bcc=x%40y.z"), "missing bcc: \(url)")
    }

    func testBuildMailtoURL_emptyCcBcc_omitted() {
        let url = buildMailtoURL(to: ["a@b.c"], subject: "S", body: "B",
                                 cc: [], bcc: nil)
        XCTAssertFalse(url.contains("cc="), "empty cc must be omitted: \(url)")
        XCTAssertFalse(url.contains("bcc="), "nil bcc must be omitted: \(url)")
    }

    func testBuildMailtoURL_percentEncodesSpacesNewlinesAndCJK() {
        let url = buildMailtoURL(to: ["a@b.c"], subject: "two words",
                                 body: "line1\nline2 中文")
        // space -> %20, newline -> %0A, CJK -> %E4..., and no raw delimiter leaks
        XCTAssertTrue(url.contains("subject=two%20words"), url)
        XCTAssertTrue(url.contains("body=line1%0Aline2%20"), url)
        XCTAssertTrue(url.contains("%E4%B8%AD%E6%96%87"), "CJK must be percent-encoded: \(url)")
        XCTAssertFalse(url.contains(" "), "no raw spaces allowed: \(url)")
        XCTAssertFalse(url.contains("\n"), "no raw newlines allowed: \(url)")
    }

    func testBuildMailtoURL_doesNotLeakAmpersandFromBodyIntoQuery() {
        // A literal & in the body must be encoded so it can't be parsed as a
        // query-param separator (would corrupt the mailto).
        let url = buildMailtoURL(to: ["a@b.c"], subject: "S", body: "A & B")
        XCTAssertTrue(url.contains("body=A%20%26%20B"), url)
        // exactly one '&' separator (between subject and body params)
        XCTAssertEqual(url.filter { $0 == "&" }.count, 1, "stray & leaked: \(url)")
    }

    // MARK: - buildMailtoComposeScript (GUI orchestration structure)

    func testMailtoScript_send_usesSendShortcut_andWindowIdentityGuard() {
        let url = buildMailtoURL(to: ["a@b.c"], subject: "S", body: "B")
        let s = buildMailtoComposeScript(url: url, subject: "S", attachments: [], send: true)
        // dispatch = ⇧⌘D (send), not ⌘S
        XCTAssertTrue(s.contains("keystroke \"d\" using {command down, shift down}"), s)
        XCTAssertFalse(s.contains("keystroke \"s\" using command down"), s)
        XCTAssertTrue(s.contains("Email sent successfully (mailto path)"))
        XCTAssertTrue(s.contains(url))
        // window-count first gate + window-IDENTITY guard (#175 verify hardening):
        XCTAssertTrue(s.contains("count of windows"), "missing window-count first gate")
        XCTAssertTrue(s.contains("if title of _cand is _t then"),
                      "dispatch must locate the compose window by title (= subject)")
        XCTAssertTrue(s.contains("if _w is missing value then error"),
                      "must hard-error (→ fallback) when our compose window isn't found")
        XCTAssertTrue(s.contains("perform action \"AXRaise\" of _w"),
                      "must raise OUR compose window before dispatch (wrong-window mitigation)")
        XCTAssertTrue(s.contains("count of sheets of _w) is not 0"),
                      "must refuse dispatch while an open panel/sheet is up on the target window")
        // stage-aware fallback with NO data loss: on error, close ONLY the
        // window we created — its exact id (_ourId = the new window whose title
        // is the subject), by id-iteration. Never a title guess, so a user's
        // same-titled draft can't be discarded (#175 verify R2 + #219/#277
        // verify R2, Codex BLOCKING).
        XCTAssertTrue(s.contains("on error _mErr"))
        XCTAssertTrue(s.contains("set _beforeIds to (id of every window)"),
                      "must snapshot window ids before mailto for safe cleanup")
        XCTAssertTrue(s.contains("set _ourId to (id of _cw)"),
                      "must capture our compose window's exact id (new window whose title = subject)")
        XCTAssertTrue(s.contains("if (id of _cw) is _ourId then close _cw saving no"),
                      "cleanup must close only OUR window by exact id, not a title guess")
        XCTAssertFalse(s.contains("close (every window whose name"),
                       "must NOT batch-close by subject (data-loss bug)")
    }

    func testMailtoScript_draft_usesSaveShortcut() {
        let url = buildMailtoURL(to: ["a@b.c"], subject: "S", body: "B")
        let s = buildMailtoComposeScript(url: url, subject: "S", attachments: [], send: false)
        XCTAssertTrue(s.contains("keystroke \"s\" using command down"), s)
        XCTAssertFalse(s.contains("keystroke \"d\" using {command down, shift down}"), s)
        XCTAssertTrue(s.contains("Draft created successfully (mailto path)"))
    }

    func testMailtoScript_noAttachments_omitsAttachAndClipboardAndDrain() {
        let s = buildMailtoComposeScript(url: "mailto:a%40b.c", subject: "S",
                                         attachments: [], send: false)
        // ⇧⌘A is the Attach shortcut — must be absent with no attachments
        XCTAssertFalse(s.contains("keystroke \"a\" using {command down, shift down}"), s)
        // no per-attachment clipboard set, no attachment drain delay
        XCTAssertFalse(s.contains("set the clipboard to"), s)
    }

    func testMailtoScript_attachments_oneAttachCyclePerFile_drain_localeIndependent() {
        let s = buildMailtoComposeScript(url: "mailto:a%40b.c", subject: "S",
                                         attachments: ["/tmp/a.pdf", "/tmp/b.txt"], send: false)
        // one File▸Attach (⇧⌘A) per attachment
        let attachCount = s.components(separatedBy: "keystroke \"a\" using {command down, shift down}").count - 1
        XCTAssertEqual(attachCount, 2, "expected one ⇧⌘A per attachment: \(s)")
        // go-to-folder (⇧⌘G); both paths set on clipboard for paste
        XCTAssertTrue(s.contains("keystroke \"g\" using {command down, shift down}"))
        XCTAssertTrue(s.contains("set the clipboard to \"/tmp/a.pdf\""))
        XCTAssertTrue(s.contains("set the clipboard to \"/tmp/b.txt\""))
        // clipboard save/restore is now the caller's job (Swift NSPasteboard) — NOT in the script
        XCTAssertFalse(s.contains("_savedClip"), "script must not do its own clipboard save/restore (#175 verify)")
        // attachment drain before dispatch (don't ⇧⌘D before attachment binds)
        XCTAssertTrue(s.contains("CHE_MAIL_MAILTO_ATTACH_DRAIN") || s.range(of: "delay") != nil)
        // locale-independence: no hardcoded localized menu names (the #174 trap)
        XCTAssertFalse(s.contains("附加檔案"))
        XCTAssertFalse(s.contains("Attach"))
    }

    func testMailtoScript_subjectWithQuotes_escapedInTitleGuardAndClose() {
        let s = buildMailtoComposeScript(url: "mailto:a%40b.c",
                                         subject: "say \"hi\"", attachments: [], send: false)
        // subject is escaped wherever it's embedded (title compare + on-error close)
        XCTAssertTrue(s.contains("say \\\"hi\\\""), s)
    }

    //
    // Reply/forward have the same wrapper bug as #175 compose, but the fix drives
    // Mail's NATIVE `reply`/`forward` verb (Mail quotes the original itself) and
    // pastes only the NEW body at the cursor — never `set content`/`set html
    // content`. The clean path is plain-only + needs Accessibility (GUI paste),
    // and an env hatch can force the legacy injection path.

    // MARK: - #304 composeRefusal (pre-flight refusals — was the legacy-route decision)

    func testRefusal_eligibleCall_returnsNil() {
        XCTAssertNil(composeRefusal(format: .plain,
                                               accessibilityTrusted: true,
                                               hasCustomSender: false,
                                               hasSubject: true))
    }

    func testRefusal_customSender_eligibleWhenAccessible() {
        // #219 flip: with Accessibility granted, a SIMPLE custom sender rides the
        // clean path (verified From popup) — no ineligibility reason.
        XCTAssertNil(composeRefusal(format: .plain,
                                               accessibilityTrusted: true,
                                               hasCustomSender: true,
                                               hasSubject: true))
    }

    func testRefusal_nonSimpleCustomSender_routesToLegacy() {
        // #219 verify R2 (Codex): a custom sender that is NOT a simple addr-spec
        // (a quoted local-part) must route to legacy — the From-popup exact-suffix
        // match is spoof-proof only for simple addresses.
        let reason = composeRefusal(format: .plain,
                                               accessibilityTrusted: true,
                                               hasCustomSender: true,
                                               hasSubject: true,
                                               customSenderIsSimple: false)
        XCTAssertNotNil(reason, "a non-simple custom sender must be ineligible for the clean popup")
        XCTAssertTrue(reason?.message.contains("simple addr-spec") == true,
                      "reason must name why (not a simple addr-spec): \(reason?.message ?? "nil")")
    }

    // MARK: - #219 verify R2 — isSimpleAddrSpec (From-popup spoof gate)

    func testIsSimpleAddrSpec_plainAddress_true() {
        XCTAssertTrue(isSimpleAddrSpec("me@corp.example"))
        XCTAssertTrue(isSimpleAddrSpec("first.last+tag@sub.corp.example"))
    }

    func testIsSimpleAddrSpec_quotedLocalPart_false() {
        // The exact Codex R2 spoof payload: a quoted local-part with embedded
        // angle brackets could suffix-match a crafted evil account label.
        XCTAssertFalse(isSimpleAddrSpec("\"prefix<foo\"@evil.example"))
        XCTAssertFalse(isSimpleAddrSpec("foo\"@evil.example"))
    }

    func testIsSimpleAddrSpec_angleBracketsOrWhitespaceOrMultiAt_false() {
        XCTAssertFalse(isSimpleAddrSpec("a<b@c.example"))
        XCTAssertFalse(isSimpleAddrSpec("a b@c.example"))
        XCTAssertFalse(isSimpleAddrSpec("a@b@c.example"))
        XCTAssertFalse(isSimpleAddrSpec("noatsign.example"))
        XCTAssertFalse(isSimpleAddrSpec(""))
    }

    func testIsSimpleAddrSpec_unicodeWhitespace_false() {
        // #219 verify R4 (Codex): reject any Unicode whitespace, not just ASCII
        // space/tab — an embedded NBSP (U+00A0) or ideographic space must not
        // slip a non-simple sender past the popup gate.
        XCTAssertFalse(isSimpleAddrSpec("a\u{00A0}b@c.example"), "NBSP must be rejected")
        XCTAssertFalse(isSimpleAddrSpec("a\u{3000}b@c.example"), "ideographic space must be rejected")
    }

    // #304 removed `testRefusal_customSenderNoAccessibility_namesPopupAnd219`.
    // It pinned a message that named BOTH from_address and the #219 popup when
    // a custom sender met a missing Accessibility grant. The closed enumeration
    // reports one reason per call, and that call's reason is simply
    // `.accessibilityNotGranted` — granting Accessibility is the fix either way,
    // and sub-dividing the message by which parameter happened to need it is
    // exactly the "seventh case by analogy" the enumeration forbids.

    func testRefusal_displayNames_draftFillViable() {
        // #277: display-name recipients are clean-path-eligible when the
        // caller marks the GUI fill viable (draft mode, bcc clean)...
        XCTAssertNil(composeRefusal(format: .plain,
                                               accessibilityTrusted: true,
                                               hasCustomSender: false,
                                               hasSubject: true,
                                               recipientsAddrSpecOnly: false,
                                               displayNameFillViable: true))
        // ...and stay legacy-routed when not viable (send mode / bcc names).
        let reason = composeRefusal(format: .plain,
                                               accessibilityTrusted: true,
                                               hasCustomSender: false,
                                               hasSubject: true,
                                               recipientsAddrSpecOnly: false,
                                               displayNameFillViable: false)
        XCTAssertTrue(reason?.message.contains("#277") == true,
                      "non-viable display-name reason must cite the draft-only boundary: \(reason?.message ?? "nil")")
    }

    func testRefusal_emptySubject_namesSubject() {
        let reason = composeRefusal(format: .plain,
                                               accessibilityTrusted: true,
                                               hasCustomSender: false,
                                               hasSubject: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.message.lowercased().contains("subject") == true,
                      "empty-subject reason must mention the subject: \(reason?.message ?? "nil")")
    }

    func testRefusal_nonPlainFormat_namesFormat() {
        for format in [BodyFormat.markdown, BodyFormat.html] {
            let reason = composeRefusal(format: format,
                                                   accessibilityTrusted: true,
                                                   hasCustomSender: false,
                                                   hasSubject: true)
            XCTAssertNotNil(reason, "\(format) must be ineligible")
            XCTAssertTrue(reason?.message.contains(format.rawValue) == true,
                          "format reason must name the format: \(reason?.message ?? "nil")")
        }
    }

    func testRefusal_noAccessibility_namesAccessibility() {
        let reason = composeRefusal(format: .plain,
                                               accessibilityTrusted: false,
                                               hasCustomSender: false,
                                               hasSubject: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.message.contains("Accessibility") == true,
                      "accessibility reason must name the missing grant: \(reason?.message ?? "nil")")
    }

    // MARK: - #304 replyForwardRefusal (pre-flight refusals, reply/forward family)

    func testReplyForwardRefusal_eligibleCall_returnsNil() {
        XCTAssertNil(replyForwardRefusal(format: .plain,
                                                          accessibilityTrusted: true))
    }

    func testReplyForwardRefusal_nonPlainFormat_namesFormat() {
        for format in [BodyFormat.markdown, BodyFormat.html] {
            let reason = replyForwardRefusal(format: format,
                                                              accessibilityTrusted: true)
            XCTAssertNotNil(reason, "\(format) must be ineligible")
            XCTAssertTrue(reason?.message.contains(format.rawValue) == true,
                          "format reason must name the format: \(reason?.message ?? "nil")")
        }
    }

    func testReplyForwardRefusal_noAccessibility_namesAccessibility() {
        let reason = replyForwardRefusal(format: .plain,
                                                          accessibilityTrusted: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.message.contains("Accessibility") == true,
                      "accessibility reason must name the missing grant: \(reason?.message ?? "nil")")
    }

    func testClampedErrorEcho_foldsAllNewlineFlavorsAndControls_andCapsLength() {
        // #229 verify finding: \n-only folding left \r / CRLF / U+2028 / U+2029 /
        // control chars able to break the one-bounded-line contract.
        let messy = "line1\r\nline2\rline3\u{2028}line4\u{2029}line5\tline6\nend"
        let out = clampedErrorEcho(messy)
        for bad in ["\n", "\r", "\u{2028}", "\u{2029}", "\t"] {
            XCTAssertFalse(out.contains(bad), "separator/control must be folded: \(out.debugDescription)")
        }
        XCTAssertTrue(out.contains("line1  line2"),
                      "CRLF folds to two spaces (one per scalar) — content preserved: \(out.debugDescription)")
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(clampedErrorEcho(long).count, 200, "default cap is 200 chars")
    }

}

// MARK: - #220 non-ASCII attachment paths route to the legacy (native-attach) path

extension MailtoComposeTests {

    func testAttachmentPathsGuiSafe() {
        XCTAssertTrue(attachmentPathsGuiSafe(nil))
        XCTAssertTrue(attachmentPathsGuiSafe([]))
        XCTAssertTrue(attachmentPathsGuiSafe(["/Users/che/report.pdf", "/tmp/data.csv"]))
        XCTAssertFalse(attachmentPathsGuiSafe(["/Users/che/「議程」.pdf"]),
                       "fullwidth brackets hang the go-to-folder sheet (#220)")
        XCTAssertFalse(attachmentPathsGuiSafe(["/Users/che/會議通知.pdf"]))
        XCTAssertFalse(attachmentPathsGuiSafe(["/ok/a.pdf", "/bad/附件.pdf"]),
                       "one unsafe path taints the batch — the GUI loop attaches all of them")
    }

    func testRefusal_nonAsciiAttachmentPath_namedReason() {
        let reason = composeRefusal(
            format: .plain, accessibilityTrusted: true,
            hasCustomSender: false, hasSubject: true,
            attachmentsGuiSafe: false)
        XCTAssertNotNil(reason)
        XCTAssertEqual(reason, .nonASCIIAttachmentPath)
        XCTAssertTrue(reason!.message.contains("#220"),
                      "reason must cite the hang issue: \(reason!.message)")
        XCTAssertTrue(reason!.message.contains("non-ASCII"), reason!.message)
    }

    func testRefusal_asciiAttachments_stillEligible() {
        XCTAssertNil(composeRefusal(
            format: .plain, accessibilityTrusted: true,
            hasCustomSender: false, hasSubject: true,
            attachmentsGuiSafe: true))
    }
}


// MARK: - #220 wiring lock

extension MailtoComposeTests {

    func testWiring_allFourProbeSitesThreadAttachments() throws {
        // Reverting the `attachments:` argument at any one probe site keeps
        // the suite green otherwise (the seam override short-circuits before
        // the real probe) — pin the wiring by source scan, the repo's
        // idiomatic lock for behaviorally-unreachable invariants (#220).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/AppleScript/MailController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        // One needle covering both threaded dimensions: the probe's exact
        // two-argument tail (attachments #220 + recipients #251). A bare
        // "attachments: attachments," needle would also match the many
        // composeViaMailto/legacy call sites.
        // #404 (PR #407 R1 #9): the three lists are threaded AS three lists —
        // `to:` / `cc:` / `bcc:` — not concatenated into one `recipients:`.
        let sendTail = "attachments: attachments,\n                to: to, cc: cc ?? [], bcc: bcc ?? [])"
        let draftTail = "attachments: attachments,\n                to: to,\n                draftMode: true, cc: cc ?? [], bcc: bcc ?? [])"
        // #304: two probe sites, not four — the `require_wrapper_free` strict
        // branches that duplicated each probe are gone, because refusing IS the
        // behavior now. Both dimensions must still be threaded at both sites.
        let draftCount = source.components(separatedBy: draftTail).count - 1
        // The draft tail ends "]]," so it can never match the send tail's
        // "]))" — the two counts are disjoint, no double-count subtraction.
        let sendCount = source.components(separatedBy: sendTail).count - 1
        XCTAssertEqual(draftCount, 1,
                       "the createDraft probe must thread draftMode+bcc (#277); found \(draftCount)")
        XCTAssertEqual(sendCount, 1,
                       "the composeEmail probe must thread the send-path tail; found \(sendCount)")
    }

    // MARK: #219/#277 — sender-popup + display-name-fill script phases

    func testMailtoScript_senderPopup_exactMatchSentinelsAndOrdering() {
        // #219 (+ verify R1/R2, Codex): the popup phase matches the account by
        // EXACT addr-spec — an exact-SUFFIX predicate (senderMatches), never
        // substring `contains` (which would verify a superstring account like
        // notme@corp.example) and never EXTRACTION of the text between < and >
        // (a quoted local-part like "x<me@x>y"@evil.example would otherwise be
        // parsed to me@x and SPOOF the match — Codex R2 BLOCKING). Both the menu
        // selection and the read-back use senderMatches; all failures are
        // SENDERPOPUP sentinels (pre-dispatch → legacy fallback), before dispatch.
        let script = buildMailtoComposeScript(
            url: "mailto:a@x?subject=S", subject: "S", attachments: [],
            send: false, fromAddress: "me@corp.example")
        XCTAssertTrue(script.contains("on senderMatches(_label, _addr)"),
                      "exact-match needs the senderMatches handler")
        // the handler must be an exact-suffix match, NOT an addr extraction
        XCTAssertTrue(script.contains("ends with (\"<\" & _addr & \">\")"),
                      "senderMatches must match by the exact <addr> suffix (anti-spoof)")
        XCTAssertFalse(script.contains("text item -1 of _s"),
                       "must NOT extract the addr between < and > — a quoted local-part could spoof it (Codex R2)")
        XCTAssertTrue(script.contains("my senderMatches(name of _mi as text, \"me@corp.example\")"),
                      "menu selection must call senderMatches with the requested addr, not contains")
        XCTAssertTrue(script.contains("not (my senderMatches(_senderReadback, \"me@corp.example\"))"),
                      "read-back must call senderMatches (exact), not contains")
        XCTAssertFalse(script.contains("whose name contains"),
                       "no substring matching allowed in the popup phase (#219 verify)")
        // #219 verify R4 (Codex): the From popup must be UNAMBIGUOUS — a rogue
        // @-valued signature popup (a signature named like an email) makes ≥2
        // AXIdentifier-identified From popup (see the dedicated assertions below).
        // #295: the popup scan must snapshot the count and fetch each popup by
        // INDEX inside the try — never the bare `repeat … in (pop up buttons of
        // _w)` whose own item-fetch can leak a raw -2700 on an unstable AX tree.
        XCTAssertTrue(script.contains("count of pop up buttons of _w"),
                      "must snapshot the popup count once (#295)")
        XCTAssertTrue(script.contains("pop up button _pbi of _w"),
                      "must fetch each popup by guarded index, not an unguarded collection iteration (#295)")
        XCTAssertFalse(script.contains("repeat with _pb in (pop up buttons of _w)"),
                       "the unguarded collection loop leaks -2700 on a settling AX tree (#295)")
        // #219 verify (Codex BLOCKING): the From popup is identified by its
        // stable locale-independent AXIdentifier "popup_from", NOT a value-
        // contains-@ scan (a signature popup named like an email could otherwise
        // be picked as From and self-consistently pass select+read-back on the
        // WRONG control). No `_fromPopupCount` heuristic remains.
        XCTAssertTrue(script.contains("(value of attribute \"AXIdentifier\" of _pb) is \"popup_from\""),
                      "From popup must be identified by AXIdentifier popup_from, not a value-@ scan (Codex BLOCKING)")
        XCTAssertFalse(script.contains("_fromPopupCount"),
                       "the value-@ popup-count heuristic must be gone — replaced by AXIdentifier (Codex BLOCKING)")
        // #219 live-fix: (1) poll until the From popup value populates (empty for
        // a beat after open); (2) Mail's From popup renders `Name – addr` (space
        // EN DASH space), no angle brackets — senderMatches must accept the last
        // space-delimited token as the addr, else the clean path always legacys.
        XCTAssertTrue(script.contains("repeat 12 times"),
                      "must bounded-poll for the From popup value to populate (#219 live-fix)")
        XCTAssertTrue(script.contains("text items of _label"),
                      "senderMatches must handle the `Name – addr` popup format via last-token match (#219 live-fix)")
        XCTAssertTrue(script.contains("if (item -1 of _parts) is _addr then return true"),
                      "last space-delimited token must exact-match the addr (separator-agnostic, anti-spoof)")
        XCTAssertTrue(script.contains("SENDERPOPUP: read-back mismatch"))
        let popupIdx = script.range(of: "SENDERPOPUP")!.lowerBound
        let dispatchIdx = script.range(of: "keystroke \"s\" using command down")!.lowerBound
        XCTAssertTrue(popupIdx < dispatchIdx, "popup verification must precede the dispatch keystroke")
    }

    func testMailtoScript_windowIdentity_subjectNewWindowAndUniqueTitle() {
        // #219/#277 verify R2 (Codex BLOCKING): the title is the only
        // System-Events keystroke bridge, so the path must fail closed on any
        // same-title ambiguity rather than keystroke/dispatch the wrong window.
        // Identity: the NEW window (id unseen before the mailto) whose title is
        // our subject, captured as _ourId — NOT a count==1 assertion (Mail
        // launched from closed opens the viewer too, which would over-reject).
        // raiseOnly asserts exactly ONE window carries our title before each
        // keystroke phase. Cleanup closes ONLY _ourId, by id-iteration (never a
        // title guess → can't discard a user's same-title draft with `saving no`).
        let script = buildMailtoComposeScript(
            url: "mailto:a@x?subject=S", subject: "S", attachments: [],
            send: false, fromAddress: "me@corp.example")
        XCTAssertTrue(script.contains("(_beforeIds does not contain (id of _cw)) and ((name of _cw) is \"S\")"),
                      "must identify our window as the NEW window whose title is the subject")
        XCTAssertTrue(script.contains("set _ourId to (id of _cw)"),
                      "must capture our compose window's id by subject match, not a count assertion")
        XCTAssertTrue(script.contains("if _ourMatches > 1 then error"),
                      "must fail closed when >1 NEW window carries our subject (concurrent same-subject window)")
        XCTAssertFalse(script.contains("if (count of _newIds) is not 1 then error"),
                       "must NOT force legacy when Mail opens a second (viewer) window on launch — count all windows, only subject-matching new ones")
        XCTAssertTrue(script.contains("if _wMatches > 1 then error"),
                      "raiseOnly must fail closed when more than one window carries our title")
        XCTAssertTrue(script.contains("if (id of _cw) is _ourId then close _cw saving no"),
                      "cleanup must close ONLY our window by id-iteration, never a title guess")
        XCTAssertFalse(script.contains("first window whose id is _ourId"),
                       "must NOT use `whose id is` on a compose window (silently fails — reply-path lesson)")
    }

    func testMailtoScript_preExistingSameTitleWindow_guarded() {
        // #219/#277 verify (Codex): title (=subject) is the only System-Events
        // window bridge, so a pre-existing same-subject window makes identity
        // ambiguous — the script must refuse (pre-dispatch → legacy fallback).
        let script = buildMailtoComposeScript(
            url: "mailto:a@x?subject=S", subject: "S", attachments: [], send: false)
        XCTAssertTrue(script.contains("set _beforeTitles to (name of every window)"))
        XCTAssertTrue(script.contains("if _beforeTitles contains \"S\" then error"),
                      "must refuse the clean path when a same-titled window already exists")
    }

    func testMailtoScript_noFromAddress_noPopupPhase() {
        let script = buildMailtoComposeScript(
            url: "mailto:a@x?subject=S", subject: "S", attachments: [], send: false)
        XCTAssertFalse(script.contains("SENDERPOPUP"),
                       "no popup phase without a custom sender — byte-stable default path")
    }

    func testMailtoScript_fillTo_orderingAndEscaping() {
        // #277 (+ verify, Codex) → #404: the fill runs BEFORE the popup phase
        // and before dispatch; since #404 every field (to/cc/bcc) is addressed
        // by AXIdentifier rather than relying on the fresh window's default To
        // focus. Quotes in display names are AppleScript-escaped.
        let script = buildMailtoComposeScript(
            url: "mailto:?subject=S", subject: "S", attachments: [],
            send: false, fromAddress: "me@corp.example",
            fill: [RecipientFill(field: .to, recipients: ["\"Wang, X\" <w@x.example>"])])
        XCTAssertTrue(script.contains("keystroke tab"))
        XCTAssertTrue(script.contains("\\\"Wang, X\\\" <w@x.example>"),
                      "display-name quotes must be AppleScript-escaped in the clipboard literal")
        let fillIdx = script.range(of: "keystroke \"v\" using command down")!.lowerBound
        let popupIdx = script.range(of: "SENDERPOPUP")!.lowerBound
        XCTAssertTrue(fillIdx < popupIdx, "recipient fill must precede the sender popup phase")
    }

    func testMailtoScript_noFillRecipients_noFillPhase() {
        let script = buildMailtoComposeScript(
            url: "mailto:a@x?subject=S", subject: "S", attachments: [], send: false)
        XCTAssertFalse(script.contains("keystroke tab"),
                       "no fill phase without display-name recipients — byte-stable default path")
    }
}
