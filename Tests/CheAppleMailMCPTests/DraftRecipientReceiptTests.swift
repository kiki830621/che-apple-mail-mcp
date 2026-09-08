import XCTest
@testable import CheAppleMailMCP

/// #404 — after ⌘S, a draft created with any display-name cc/bcc is re-read
/// from the drafts mailbox and its cc / bcc addresses compared with what the
/// caller asked for. The AX token read-back proved the fill landed; only this
/// receipt proves the ADDRESSES Mail stored. A mismatch or a missing draft is
/// disclosed, never treated as a failure, and the draft is always kept.
final class DraftRecipientReceiptTests: XCTestCase {

    // MARK: script + parse

    func testReceiptScript_locatesNewestDraftByExactSubject_readsCcAndBcc() {
        let s = buildDraftRecipientReceiptScript(subject: "Re: \"Q3\" plan")
        XCTAssertTrue(s.contains("drafts mailbox"))
        XCTAssertTrue(s.contains("considering case"), "subject match must be case-sensitive (Swift == parity with update_draft)")
        XCTAssertTrue(s.contains("\\\"Q3\\\""), "subject must be AppleScript-escaped")
        XCTAssertTrue(s.contains("cc recipients of") && s.contains("bcc recipients of"))
        XCTAssertTrue(s.contains("return \"NOTFOUND\""))
        XCTAssertTrue(s.contains("> _bestId"), "several drafts may share the subject (update_draft keeps the old one until the receipt) — the newest id wins")
    }

    func testParseReceipt_splitsCcAndBcc_andNotFound() throws {
        let r = try XCTUnwrap(parseRecipientReceipt("a@x.org\u{1E}b@x.org\u{1D}c@x.org"))
        XCTAssertEqual(r.ccFound, ["a@x.org", "b@x.org"])
        XCTAssertEqual(r.bccFound, ["c@x.org"])
        let empty = try XCTUnwrap(parseRecipientReceipt("\u{1D}"))
        XCTAssertEqual(empty.ccFound, []); XCTAssertEqual(empty.bccFound, [])
        XCTAssertNil(parseRecipientReceipt("NOTFOUND"))
    }

    // MARK: verdict (three-state, PR #407 R1 #3)

    func testOutcome_match_isCaseAndOrderInsensitive() {
        let o = recipientReceiptOutcome(
            expectedCc: ["王小明 <Ming@Example.com>", "b@x.org"], expectedBcc: [],
            receipt: .found(RecipientReceipt(ccFound: ["b@x.org", "ming@example.com"], bccFound: [])))
        XCTAssertEqual(o, .verified)
        let d = recipientReceiptDisclosure(o)
        XCTAssertTrue(d.contains("recipients_verified: true"), d)
        XCTAssertFalse(d.contains("recipients_diff"), d)
    }

    func testOutcome_mismatch_carriesStructuredDiff_asJSON_andKeepsDraft() {
        let o = recipientReceiptOutcome(
            expectedCc: [], expectedBcc: ["甲 <a@example.org>", "乙 <b@example.org>"],
            receipt: .found(RecipientReceipt(ccFound: [], bccFound: ["a@example.org"])))
        guard case .mismatch = o else { return XCTFail("expected .mismatch, got \(o)") }
        let d = recipientReceiptDisclosure(o)
        XCTAssertTrue(d.contains("recipients_verified: false"), d)
        // spec: recipients_diff is an OBJECT — emitted as a JSON fragment so a
        // programmatic caller can parse it instead of substring-matching prose.
        XCTAssertTrue(d.contains("recipients_diff: {\"cc\":{\"expected\":[],\"found\":[]},\"bcc\":{\"expected\":[\"a@example.org\",\"b@example.org\"],\"found\":[\"a@example.org\"]}}"), d)
        XCTAssertTrue(d.contains("KEPT"), d)
    }

    func testOutcome_notFound_isFalseAndSaysNotFound() {
        let o = recipientReceiptOutcome(expectedCc: ["a@x.org"], expectedBcc: [], receipt: .notFound)
        let d = recipientReceiptDisclosure(o)
        XCTAssertTrue(d.contains("recipients_verified: false"), d)
        XCTAssertTrue(d.contains("not found"), d)
        XCTAssertTrue(d.contains("KEPT"), d)
    }

    func testOutcome_unavailable_neverClaimsNotFound() {
        // A script failure (timeout, TCC, runtime error) is NOT evidence of absence.
        let o = recipientReceiptOutcome(expectedCc: ["a@x.org"], expectedBcc: [],
                                        receipt: .unavailable("AppleScript call did not return within 45s"))
        let d = recipientReceiptDisclosure(o)
        XCTAssertTrue(d.contains("recipients_verified: false"), d)
        XCTAssertTrue(d.contains("recipients_receipt: unavailable"), d)
        XCTAssertTrue(d.contains("45s"), d)
        XCTAssertFalse(d.contains("not found"), "a receipt that could not run must not be reported as absence: \(d)")
        XCTAssertTrue(d.contains("KEPT"), d)
    }

    func testCreateDraft_receiptScriptThrows_reportsUnavailable_withoutRetry() async throws {
        final class Counter: @unchecked Sendable { var receiptCalls = 0 }
        let c = Counter()
        await MailController.shared.setTestSeams(
            scriptRunner: { script in
                if script.contains("#404 recipient receipt") {
                    c.receiptCalls += 1
                    throw MailError.scriptTimedOut(seconds: 45, automationGranted: true)
                }
                return "Draft created successfully (mailto path)"
            },
            refusal: { nil })
        let r = try await MailController.shared.createDraft(
            to: ["a@b.c"], subject: "s", body: "b", cc: ["王小明 <ming@example.com>"], bcc: nil)
        XCTAssertTrue(r.contains("recipients_receipt: unavailable"), r)
        XCTAssertFalse(r.contains("not found"), r)
        XCTAssertEqual(c.receiptCalls, 1, "a script failure is not retried — only NOTFOUND polls")
    }

    func testCreateDraft_fromAddressAndBccReveal_disclosesBoth() async throws {
        // R1 #1: the sender disclosure used to be appended BEFORE the suffix
        // check for the script tag, so bcc_field_revealed was lost and the raw
        // tag leaked whenever from_address was also set.
        _ = await seams(receipt: "\u{1D}b@example.org",
                        guiResult: "Draft created successfully (mailto path) [bcc-field-revealed]")
        let r = try await MailController.shared.createDraft(
            to: ["a@b.c"], subject: "s", body: "b", cc: nil, bcc: ["密件人 <b@example.org>"],
            fromAddress: "me@corp.example")
        XCTAssertTrue(r.contains("sender verified via From popup: me@corp.example"), r)
        XCTAssertTrue(r.contains("bcc_field_revealed: true"), r)
        XCTAssertFalse(r.contains("[bcc-field-revealed]"), "raw script tag must never leak: \(r)")
        XCTAssertTrue(r.contains("recipients_verified: true"), r)
    }

    func testCreateDraft_mixedNamedAndBareCc_receiptCoversWholeList() async throws {
        _ = await seams(receipt: "b@example.com\u{1E}ming@example.com\u{1D}")
        let r = try await MailController.shared.createDraft(
            to: ["a@b.c"], subject: "s", body: "b", cc: ["王小明 <ming@example.com>", "b@example.com"], bcc: nil)
        XCTAssertTrue(r.contains("recipients_verified: true"), r)
    }

    func testUpdateDraft_receiptMismatch_keepsOldDraft() async throws {
        // R1 #4 (gated on the three-state receipt): a DEFINITIVE mismatch keeps
        // the old draft — the only copy whose recipients were right — and says so.
        final class Log: @unchecked Sendable { var deleted = false; var n = 0 }
        let l = Log()
        let RS = "\u{1E}", GS = "\u{1D}"
        let rows = ["101\(RS)102\(GS)A\(RS)B", "101\(RS)102\(GS)A\(RS)B", "101\(RS)102\(RS)999\(GS)A\(RS)B\(RS)s"]
        await MailController.shared.setTestSeams(
            scriptRunner: { script in
                if script.contains("#404 recipient receipt") { return "other@example.com\(GS)" }
                if script.contains("whose id is") { l.deleted = true; return "Draft deleted" }
                if script.contains("mailto:") { return "Draft created successfully (mailto path)" }
                if script.contains("drafts mailbox") { defer { l.n += 1 }; return rows[min(l.n, rows.count - 1)] }
                return ""
            },
            refusal: { nil })
        let result = try await MailController.shared.updateDraft(
            draftId: "101", subjectMatch: nil, accountName: "Google", accountId: nil,
            to: ["a@x.co"], subject: "s", body: "b", cc: ["王小明 <ming@example.com>"], bcc: nil,
            attachments: nil, format: .plain, fromAddress: nil)
        XCTAssertEqual(result["deleted_old"] as? Bool, false)
        XCTAssertFalse(l.deleted, "no delete script may run after a definitive recipient mismatch")
        let note = result["note"] as? String ?? ""
        XCTAssertTrue(note.contains("recipients"), note)
        // R2-1 / R2-7 (DA): the note must not instruct the caller to delete
        // anything, must not blame the fill, and must say the receipt only
        // identifies the draft by subject (#409) — the evidence is weaker than
        // an instruction to do something irreversible.
        XCTAssertFalse(note.contains("delete the other") || note.contains("delete_email"), note)
        XCTAssertTrue(note.contains("#409"), note)
        XCTAssertTrue(note.contains("KEPT"), note)
        XCTAssertTrue((result["new_draft"] as? String ?? "").contains("recipients_verified: false"))
    }

    func testUpdateDraft_phantomCreate_sameSubjectNamedCc_reportsNotConfirmed_notMismatch() async throws {
        // R2-1 (logic N1 + DA): on a same-subject update the receipt's first
        // read is `.found` (the OLD draft carries the subject), so it judges at
        // the first instant after ⌘S. If the create was a phantom, the old
        // draft's recipients differ from the request → a false mismatch. The
        // gate must therefore sit AFTER the id receipt: a phantom must keep
        // reporting "not confirmed" (2.5), never the mismatch note.
        final class Log: @unchecked Sendable { var deleted = false; var n = 0 }
        let l = Log()
        let RS = "\u{1E}", GS = "\u{1D}"
        // locate, pre-create snapshot, and EVERY post-create poll show the same
        // rows — no new id ever appears (phantom create).
        let rows = ["101\(RS)102\(GS)s\(RS)B"]
        await MailController.shared.setTestSeams(
            scriptRunner: { script in
                if script.contains("#404 recipient receipt") { return "old-cc@example.com\(GS)" }   // the OLD draft's cc
                if script.contains("whose id is") { l.deleted = true; return "Draft deleted" }
                if script.contains("mailto:") { return "Draft created successfully (mailto path)" }
                if script.contains("drafts mailbox") { l.n += 1; return rows[0] }
                return ""
            },
            refusal: { nil })
        let result = try await MailController.shared.updateDraft(
            draftId: "101", subjectMatch: nil, accountName: "Google", accountId: nil,
            to: ["a@x.co"], subject: "s", body: "b", cc: ["王小明 <ming@example.com>"], bcc: nil,
            attachments: nil, format: .plain, fromAddress: nil)
        XCTAssertEqual(result["deleted_old"] as? Bool, false)
        XCTAssertFalse(l.deleted)
        let note = result["note"] as? String ?? ""
        XCTAssertTrue(note.contains("not confirmed"), "a phantom create must be reported as unconfirmed, not as a recipient mismatch: \(note)")
        XCTAssertFalse(note.contains("differ from the request"), note)
    }

    func testUpdateDraft_receiptUnavailable_stillDeletesOld() async throws {
        // DA: gating on "receipt unavailable" would leave two drafts on every
        // update for the accounts #406 describes — only a definitive mismatch gates.
        final class Log: @unchecked Sendable { var deleted = false; var n = 0 }
        let l = Log()
        let RS = "\u{1E}", GS = "\u{1D}"
        let rows = ["101\(RS)102\(GS)A\(RS)B", "101\(RS)102\(GS)A\(RS)B", "101\(RS)102\(RS)999\(GS)A\(RS)B\(RS)s"]
        await MailController.shared.setTestSeams(
            scriptRunner: { script in
                if script.contains("#404 recipient receipt") { throw MailError.scriptTimedOut(seconds: 45, automationGranted: true) }
                if script.contains("whose id is") { l.deleted = true; return "Draft deleted" }
                if script.contains("mailto:") { return "Draft created successfully (mailto path)" }
                if script.contains("drafts mailbox") { defer { l.n += 1 }; return rows[min(l.n, rows.count - 1)] }
                return ""
            },
            refusal: { nil })
        let result = try await MailController.shared.updateDraft(
            draftId: "101", subjectMatch: nil, accountName: "Google", accountId: nil,
            to: ["a@x.co"], subject: "s", body: "b", cc: ["王小明 <ming@example.com>"], bcc: nil,
            attachments: nil, format: .plain, fromAddress: nil)
        XCTAssertEqual(result["deleted_old"] as? Bool, true)
        XCTAssertTrue(l.deleted)
        XCTAssertTrue((result["new_draft"] as? String ?? "").contains("recipients_receipt: unavailable"))
    }

    // MARK: createDraft integration through the runner seam

    private func seams(receipt: String?, guiResult: String = "Draft created successfully (mailto path)") async -> () -> [String] {
        final class Log: @unchecked Sendable { var scripts: [String] = [] }
        let log = Log()
        await MailController.shared.setTestSeams(
            scriptRunner: { script in
                log.scripts.append(script)
                if script.contains("#404 recipient receipt") {
                    guard let receipt else { XCTFail("receipt must not run"); return "" }
                    return receipt
                }
                return guiResult
            },
            refusal: { nil })
        return { log.scripts }
    }

    override func tearDown() async throws {
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
    }

    func testCreateDraft_namedCc_runsReceipt_andDisclosesVerified() async throws {
        let scripts = await seams(receipt: "ming@example.com\u{1D}")
        let r = try await MailController.shared.createDraft(
            to: ["a@b.c"], subject: "s", body: "b", cc: ["王小明 <ming@example.com>"], bcc: nil)
        XCTAssertTrue(r.contains("recipients_verified: true"), r)
        XCTAssertTrue(scripts().contains { $0.contains("#404 recipient receipt") })
    }

    func testCreateDraft_namedBcc_receiptDiff_keepsDraft() async throws {
        _ = await seams(receipt: "\u{1D}a@example.org", guiResult: "Draft created successfully (mailto path) [bcc-field-revealed]")
        let r = try await MailController.shared.createDraft(
            to: ["a@b.c"], subject: "s", body: "b", cc: nil, bcc: ["甲 <a@example.org>", "乙 <b@example.org>"])
        XCTAssertTrue(r.contains("recipients_verified: false"), r)
        XCTAssertTrue(r.contains("\"bcc\":{\"expected\":[\"a@example.org\",\"b@example.org\"],\"found\":[\"a@example.org\"]}"), r)
        XCTAssertTrue(r.contains("bcc_field_revealed: true"), r)
        XCTAssertFalse(r.contains("[bcc-field-revealed]"), "the raw script tag is translated, not leaked: \(r)")
    }

    func testCreateDraft_bareCcOnly_noReceipt_noField() async throws {
        let scripts = await seams(receipt: nil)
        let r = try await MailController.shared.createDraft(
            to: ["a@b.c"], subject: "s", body: "b", cc: ["c@b.c"], bcc: nil)
        XCTAssertFalse(r.contains("recipients_verified"), r)
        XCTAssertFalse(scripts().contains { $0.contains("#404 recipient receipt") })
    }

    /// 3.2 — `update_draft` inherits the receipt through `createDraft`; its own
    /// post-create receipt (new id) and the recipient receipt are two reads of
    /// the drafts mailbox but ONE settle — the recipient receipt already waited
    /// for the draft, so the id receipt confirms on its first poll (no sleep).
    func testUpdateDraft_namedCc_returnsDeletedOldAndRecipientsVerified() async throws {
        final class Counter: @unchecked Sendable { var n = 0; var sleeps = 0 }
        let c = Counter()
        let RS = "\u{1E}", GS = "\u{1D}"
        // locate → pre-create snapshot → post-create id receipt (3 reads, as in
        // UpdateDraftTests.testUpdateDraft_byId_createThenDelete).
        let rows = ["101\(RS)102\(GS)A\(RS)B", "101\(RS)102\(GS)A\(RS)B", "101\(RS)102\(RS)999\(GS)A\(RS)B\(RS)s"]
        await MailController.shared.setTestSeams(
            scriptRunner: { script in
                if script.contains("#404 recipient receipt") { return "ming@example.com\(GS)" }
                if script.contains("whose id is") { return "Draft deleted" }
                if script.contains("mailto:") { return "Draft created successfully (mailto path)" }
                if script.contains("drafts mailbox") {
                    defer { c.n += 1 }
                    return rows[min(c.n, rows.count - 1)]
                }
                return ""
            },
            refusal: { nil })
        let result = try await MailController.shared.updateDraft(
            draftId: "101", subjectMatch: nil, accountName: "Google", accountId: nil,
            to: ["a@x.co"], subject: "s", body: "b", cc: ["王小明 <ming@example.com>"], bcc: nil,
            attachments: nil, format: .plain, fromAddress: nil)
        XCTAssertEqual(result["deleted_old"] as? Bool, true)
        XCTAssertTrue((result["new_draft"] as? String ?? "").contains("recipients_verified: true"),
                      "\(result["new_draft"] ?? "")")
        XCTAssertEqual(c.n, 3, "locate + pre-create snapshot + ONE post-create id receipt — no extra polling after the recipient receipt")
    }

    func testCreateDraft_namedTo_only_noReceipt() async throws {
        // The receipt exists for cc/bcc (the lists #404 opened); a named To
        // alone keeps the #277 behavior.
        let scripts = await seams(receipt: nil)
        _ = try await MailController.shared.createDraft(
            to: ["王小明 <ming@example.com>"], subject: "s", body: "b", cc: nil, bcc: nil)
        XCTAssertFalse(scripts().contains { $0.contains("#404 recipient receipt") })
    }
}
