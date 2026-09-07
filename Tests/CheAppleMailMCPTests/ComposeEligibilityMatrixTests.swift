import XCTest
@testable import CheAppleMailMCP

/// #404 — reason 6 of the closed ineligibility enumeration is send-only: on a
/// DRAFT a display name in `to`, `cc`, or `bcc` is filled through the GUI and
/// is not a refusal reason; on a SEND any display name refuses (a fill that
/// failed on a send would dispatch with missing recipients, #277).
///
/// `composeCallRefusal` is the pure derivation MailController's private caller
/// delegates to, so the 12-cell matrix (draft/send × to/cc/bcc × bare/named)
/// is testable without a live Accessibility grant.
final class ComposeEligibilityMatrixTests: XCTestCase {

    private let named = "王小明 <ming@example.com>"
    private let bare = "ming@example.com"

    private func refusal(draft: Bool, to: [String] = ["a@b.c"], cc: [String] = [], bcc: [String] = []) -> ComposeRefusal? {
        composeCallRefusal(
            format: .plain, accessibilityTrusted: true, fromAddress: nil,
            subject: "s", attachments: nil, to: to, cc: cc, bcc: bcc, draftMode: draft)
    }

    func testMatrix_draft_namedInAnyList_isEligible() {
        XCTAssertNil(refusal(draft: true, to: [named]), "draft × named to")
        XCTAssertNil(refusal(draft: true, cc: [named]), "draft × named cc")
        XCTAssertNil(refusal(draft: true, bcc: [named]), "draft × named bcc")
        XCTAssertNil(refusal(draft: true, to: [named], cc: [named], bcc: [named]), "draft × all named")
    }

    func testMatrix_draft_bareInAnyList_isEligible() {
        XCTAssertNil(refusal(draft: true, to: [bare]))
        XCTAssertNil(refusal(draft: true, cc: [bare]))
        XCTAssertNil(refusal(draft: true, bcc: [bare]))
    }

    func testMatrix_send_namedInAnyList_refusesReason6() {
        XCTAssertEqual(refusal(draft: false, to: [named]), .displayNameRecipient, "send × named to")
        XCTAssertEqual(refusal(draft: false, cc: [named]), .displayNameRecipient, "send × named cc")
        XCTAssertEqual(refusal(draft: false, bcc: [named]), .displayNameRecipient, "send × named bcc")
    }

    func testMatrix_send_bareInAnyList_isEligible() {
        XCTAssertNil(refusal(draft: false, to: [bare]))
        XCTAssertNil(refusal(draft: false, cc: [bare]))
        XCTAssertNil(refusal(draft: false, bcc: [bare]))
    }

    func testReason6Message_isSendOnly_andPointsToCreateDraft() {
        let msg = ComposeRefusal.displayNameRecipient.message
        XCTAssertTrue(msg.contains("send"), "reason 6 must name the send as the boundary: \(msg)")
        XCTAssertTrue(msg.contains("create_draft"), "reason 6 must point the caller to create_draft: \(msg)")
        XCTAssertTrue(msg.contains("#277"), "reason 6 must cite the draft-only boundary: \(msg)")
        XCTAssertFalse(msg.contains("never into Cc/Bcc"), "cc/bcc are no longer excluded on drafts: \(msg)")
        XCTAssertFalse(msg.contains("hidden via Header Fields"), "the hidden-field rationale is superseded by AX addressing (#404): \(msg)")
    }

    func testOtherReasonsStillPrecedeReason6() {
        // Evaluation order is the enumeration order; a send with a named cc AND
        // an empty subject reports reason 2, not reason 6.
        XCTAssertEqual(
            composeCallRefusal(format: .plain, accessibilityTrusted: true, fromAddress: nil,
                               subject: "", attachments: nil, to: ["a@b.c"], cc: [named], bcc: [],
                               draftMode: false),
            .emptySubject)
    }
}
