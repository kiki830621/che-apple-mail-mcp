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

    func testCleanup_dismissesDiscardSheet_byIdentifierAndDiscardTitle() {
        let s = draftScript()
        XCTAssertTrue(s.contains("close _cw saving no"), "the close attempt stays — it is the sheet it triggers that must be handled")
        XCTAssertTrue(s.contains("\"Mail.sendMessageAlert\""), "the sheet is recognized by its AXIdentifier")
        XCTAssertTrue(s.contains("\"不儲存\""), "zh-TW discard title")
        XCTAssertTrue(s.contains("starts with \"Don"), "English discard title (Don't Save / Don’t Save)")
        XCTAssertFalse(s.contains("\"儲存\" then click") || s.contains("\"Save\" then click"),
                       "the save button must never be clicked from cleanup")
    }

    func testCleanup_reportsSurvivingWindowByTitle() {
        let s = draftScript()
        XCTAssertTrue(s.contains("WINDOWLEFTOPEN:"), "a window that survives cleanup is reported, not silently left")
        XCTAssertTrue(s.contains("compose window titled \\\"S\\\" was left open"), s)
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
