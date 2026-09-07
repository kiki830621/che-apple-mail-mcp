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

    // MARK: verdict

    func testDisclosure_match_isCaseAndOrderInsensitive() {
        let d = recipientReceiptDisclosure(
            expectedCc: ["王小明 <Ming@Example.com>", "b@x.org"], expectedBcc: [],
            receipt: RecipientReceipt(ccFound: ["b@x.org", "ming@example.com"], bccFound: []))
        XCTAssertTrue(d.contains("recipients_verified: true"), d)
        XCTAssertFalse(d.contains("recipients_diff"), d)
    }

    func testDisclosure_diff_listsExpectedAndFound_andKeepsDraft() {
        let d = recipientReceiptDisclosure(
            expectedCc: [], expectedBcc: ["甲 <a@example.org>", "乙 <b@example.org>"],
            receipt: RecipientReceipt(ccFound: [], bccFound: ["a@example.org"]))
        XCTAssertTrue(d.contains("recipients_verified: false"), d)
        XCTAssertTrue(d.contains("recipients_diff"), d)
        XCTAssertTrue(d.contains("bcc expected [a@example.org, b@example.org] found [a@example.org]"), d)
        XCTAssertTrue(d.contains("KEPT"), d)
    }

    func testDisclosure_notFound_isFalseAndSaysSo() {
        let d = recipientReceiptDisclosure(expectedCc: ["a@x.org"], expectedBcc: [], receipt: nil)
        XCTAssertTrue(d.contains("recipients_verified: false"), d)
        XCTAssertTrue(d.contains("not found"), d)
        XCTAssertTrue(d.contains("KEPT"), d)
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
        XCTAssertTrue(r.contains("bcc expected [a@example.org, b@example.org] found [a@example.org]"), r)
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
