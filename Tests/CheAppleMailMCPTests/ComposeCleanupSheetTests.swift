import XCTest
@testable import CheAppleMailMCP

/// #333 / #404 — `close <mailto window> saving no` does NOT close a mailto
/// compose window: Mail answers with the "save this message as a draft?" sheet
/// (AXIdentifier `Mail.sendMessageAlert`) and the window stays behind it — the
/// orphan-window chain #333 describes. The on-error cleanup must dismiss that
/// sheet through its discard button and confirm the window is gone; if the
/// window survives, the failure message says so and names the title.
final class ComposeCleanupSheetTests: XCTestCase {

    private func draftScript() -> String {
        buildMailtoComposeScript(url: "mailto:a@x?subject=S", subject: "S", attachments: [], send: false)
    }

    func testCleanup_dismissesDiscardSheet_byIdentifierAndExactDiscardTitle() {
        let s = draftScript()
        XCTAssertTrue(s.contains("close _cw saving no"), "the close attempt stays — it is the sheet it triggers that must be handled")
        XCTAssertTrue(s.contains("\"Mail.sendMessageAlert\""), "the sheet is recognized by its AXIdentifier")
        XCTAssertTrue(s.contains("\"不儲存\""), "zh-TW discard title")
        // R1 #11: `starts with "Don"` also matched "Done". Exact titles only,
        // both apostrophes macOS uses.
        XCTAssertTrue(s.contains("\"Don't Save\"") && s.contains("\"Don’t Save\""), s)
        XCTAssertFalse(s.contains("starts with \"Don"), "prefix match on the discard title is forbidden: \(s)")
    }

    func testCleanup_everyButtonClickIsGuardedByTheDiscardCondition() {
        // R1 #12: the old "never clicks save" assertion could not fail (the
        // generator always puts a newline between `then` and `click`). This
        // one reads the generated script line by line: every `click _b` must
        // sit directly under the exact discard-title condition.
        let lines = draftScript().components(separatedBy: "\n")
        var clicks = 0
        for (i, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "click _b" {
            clicks += 1
            let guardLine = lines[i - 1].trimmingCharacters(in: .whitespaces)
            XCTAssertEqual(guardLine, "if _bt is \"不儲存\" or _bt is \"Don't Save\" or _bt is \"Don’t Save\" then",
                           "click _b at line \(i + 1) is not guarded by the discard condition")
        }
        XCTAssertEqual(clicks, 1, "exactly one sheet-button click exists in cleanup")
    }

    func testCleanup_skipsTheSheetWhenTheTitleIsNotUnique() {
        // R1 #11: the sheet is found through the window TITLE (System Events
        // cannot see Mail's window ids). If more than one window carries our
        // subject, the discard click could hit someone else's unsaved message —
        // so cleanup must refuse to click and fall through to WINDOWLEFTOPEN.
        let s = draftScript()
        XCTAssertTrue(s.contains("_titleMatches"), s)
        XCTAssertTrue(s.contains("if _titleMatches is 1 then"), "the discard click must be gated on title uniqueness: \(s)")
    }

    func testCleanup_reportsSurvivingWindowByTitle() {
        let s = draftScript()
        XCTAssertTrue(s.contains("WINDOWLEFTOPEN:"), "a window that survives cleanup is reported, not silently left")
        XCTAssertTrue(s.contains("compose window titled \\\"S\\\" was left open"), s)
    }

    func testCleanup_distinguishesRefusedFromUndismissable() {
        // R2-10 (DA): when several windows carry the subject, cleanup
        // deliberately refuses to click — the message must say so, not claim
        // the sheet "could not be dismissed".
        let s = draftScript()
        XCTAssertTrue(s.contains("cleanup refused to dismiss its discard sheet because"), s)
        XCTAssertTrue(s.contains("windows carry this subject"), s)
        XCTAssertTrue(s.contains("its discard sheet could not be dismissed"), s)
    }

    func testCleanup_sendPath_keepsPostDispatchBranchUntouched() {
        // #242: after ⇧⌘D the window is the user's only evidence — the
        // POSTDISPATCH branch must not gain a sheet-dismissal that closes it.
        let s = buildMailtoComposeScript(url: "mailto:a@x?subject=S", subject: "S", attachments: [], send: true)
        let post = s.range(of: "if _mErr starts with \"POSTDISPATCH:\"")!.lowerBound
        let elseBranch = s.range(of: "else if _dispatched")!.lowerBound
        let between = s[post..<elseBranch]
        XCTAssertFalse(between.contains("sendMessageAlert"), "no cleanup inside the post-dispatch branch")
    }
}
