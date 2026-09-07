import XCTest
@testable import CheAppleMailMCP

/// #404 — the compose script's recipient fill phase addresses each field by
/// its AXIdentifier (focus → paste → Tab), never by Tab order and never by
/// assigning the field's AX value (live probe 2026-09-07: `set value` merges a
/// comma list of NAMED recipients into ONE token — silent recipient loss);
/// reads back the tokens as a pre-dispatch gate; and reveals the Bcc field on
/// demand without restoring the menu.
final class ComposeFillPhaseTests: XCTestCase {

    private func script(_ fill: [RecipientFill], from: String? = nil) -> String {
        buildMailtoComposeScript(
            url: "mailto:?subject=S", subject: "S", attachments: [],
            send: false, fromAddress: from, fill: fill)
    }

    // MARK: 2.1 — AX focus, paste, Tab; never set value

    func testCcFill_focusesFieldByAXIdentifier_thenPastesAndTabs() {
        let s = script([RecipientFill(field: .cc, recipients: ["甲 <a1@example.org>"])])
        XCTAssertTrue(s.contains("\"Mail.ccField\""), "cc must be located by AXIdentifier")
        XCTAssertTrue(s.contains("set focused of"), "the field is focused through AX, not reached by Tab")
        XCTAssertTrue(s.contains("keystroke \"v\" using command down"))
        XCTAssertTrue(s.contains("keystroke tab"))
        XCTAssertFalse(s.contains("set value of"), "set value merges named recipients into one token — forbidden")
    }

    func testToFill_alsoAddressesMailToField() {
        let s = script([RecipientFill(field: .to, recipients: ["甲 <a1@example.org>"])])
        XCTAssertTrue(s.contains("\"Mail.toField\""))
        XCTAssertFalse(s.contains("\"Mail.ccField\""))
    }

    func testFillPrecedesSenderPopup_andMissingFieldIsSentinelError() {
        let s = script([RecipientFill(field: .cc, recipients: ["甲 <a1@example.org>"])], from: "me@corp.example")
        let fillIdx = s.range(of: "\"Mail.ccField\"")!.lowerBound
        let popupIdx = s.range(of: "SENDERPOPUP")!.lowerBound
        XCTAssertTrue(fillIdx < popupIdx)
        XCTAssertTrue(s.contains("FILLFIELD:"), "an unlocatable field must raise a pre-dispatch sentinel error")
    }

    func testNoFill_noFillPhase() {
        let s = script([])
        XCTAssertFalse(s.contains("Mail.ccField"))
        XCTAssertFalse(s.contains("keystroke tab"))
        XCTAssertFalse(s.contains("FILLREADBACK"))
    }

    // MARK: 2.2 — token read-back gate

    func testReadback_expectsTokenCountAndDisplayNames() {
        let s = script([RecipientFill(field: .cc, recipients: ["甲 <a1@example.org>", "乙 <a2@example.org>"])])
        XCTAssertTrue(s.contains("FILLREADBACK:"), "a count/name mismatch must raise a pre-dispatch sentinel error")
        XCTAssertTrue(s.contains("{\"甲\", \"乙\"}"), "expected token names are the display names, in order: \(s)")
        XCTAssertTrue(s.contains("is not 2"), "expected token count is the recipient count")
    }

    func testReadback_bareAddressExpectsTheAddress_quotedNameIsUnquoted() {
        let s = script([RecipientFill(field: .cc, recipients: ["\"Doe, Jane\" <jane@example.org>", "d3@example.org"])])
        XCTAssertTrue(s.contains("{\"Doe, Jane\", \"d3@example.org\"}"), s)
    }

    // MARK: 2.3 — Bcc reveal, disclosed, not restored

    func testBccFill_revealsHiddenFieldViaViewMenu_once_andPolls() {
        let s = script([RecipientFill(field: .bcc, recipients: ["密件人 <bcc@example.org>"])])
        XCTAssertTrue(s.contains("\"Mail.bccField\""))
        XCTAssertTrue(s.contains("密件副本") && s.contains("Bcc"), "menu item matched by locale fragments")
        XCTAssertTrue(s.contains("BCCREVEAL:"), "unrevealable Bcc must raise a pre-dispatch sentinel error")
        XCTAssertTrue(s.contains("(looked for 密件副本 / Bcc)"),
                      "the fragment list inside the error string must not carry literal quotes (osacompile -2741)")
        XCTAssertTrue(s.contains("set _bccRevealed to true"), "the caller must learn the field was revealed")
        XCTAssertEqual(s.components(separatedBy: "click _revealItem").count - 1, 1,
                       "the View menu item is clicked at most once — never restored")
    }

    func testCcOnlyFill_hasNoRevealPhase() {
        let s = script([RecipientFill(field: .cc, recipients: ["甲 <a1@example.org>"])])
        XCTAssertFalse(s.contains("BCCREVEAL"))
        XCTAssertFalse(s.contains("密件副本"))
    }

    func testReturnValue_carriesBccRevealedTag() {
        let s = script([RecipientFill(field: .bcc, recipients: ["密件人 <bcc@example.org>"])])
        XCTAssertTrue(s.contains("[bcc-field-revealed]"), "result tag lets Swift disclose bcc_field_revealed")
    }
}
