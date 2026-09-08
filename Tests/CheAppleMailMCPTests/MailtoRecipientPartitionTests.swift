import XCTest
@testable import CheAppleMailMCP

/// #404 — which recipient lists ride the `mailto:` URL and which are filled
/// through the compose window's AX-addressed field. A list rides the URL only
/// when every entry is a bare addr-spec (RFC 6068); a list carrying ANY display
/// name is omitted from the URL as a whole and filled through the GUI (order
/// preserved; bare + named tokenize alike), so a recipient is never carried
/// twice and never dropped.
final class MailtoRecipientPartitionTests: XCTestCase {

    private let named = "王小明 <ming@example.com>"

    func testAllBare_everythingRidesTheURL_noFill() {
        let p = partitionRecipientsForMailto(to: ["a@b.c"], cc: ["c@b.c"], bcc: ["d@b.c"])
        XCTAssertEqual(p.urlTo, ["a@b.c"])
        XCTAssertEqual(p.urlCc, ["c@b.c"])
        XCTAssertEqual(p.urlBcc, ["d@b.c"])
        XCTAssertTrue(p.fill.isEmpty)
    }

    func testNamedCc_ccOmittedFromURL_filledWholeListInOrder() {
        let p = partitionRecipientsForMailto(to: ["a@b.c"], cc: ["x@b.c", named], bcc: [])
        XCTAssertEqual(p.urlTo, ["a@b.c"])
        XCTAssertEqual(p.urlCc, [], "a cc list with any display name must not ride the URL")
        XCTAssertEqual(p.fill.map(\.field), [.cc])
        XCTAssertEqual(p.fill.first?.recipients, ["x@b.c", named], "the WHOLE list is filled, order preserved")
    }

    func testNamedInAllThree_fillOrderIsToCcBcc() {
        let p = partitionRecipientsForMailto(to: [named], cc: [named], bcc: [named])
        XCTAssertEqual(p.urlTo, []); XCTAssertEqual(p.urlCc, []); XCTAssertEqual(p.urlBcc, [])
        XCTAssertEqual(p.fill.map(\.field), [.to, .cc, .bcc])
    }

    func testEmptyLists_produceNoFillEntries() {
        let p = partitionRecipientsForMailto(to: ["a@b.c"], cc: [], bcc: [])
        XCTAssertTrue(p.fill.isEmpty)
        XCTAssertEqual(p.urlCc, [])
    }

    func testAddressField_mapsToMailAXIdentifiers() {
        // Live-observed on Mail (macOS 27), 2026-09-07 — #404 Diagnosis P1.
        XCTAssertEqual(AddressField.to.axIdentifier, "Mail.toField")
        XCTAssertEqual(AddressField.cc.axIdentifier, "Mail.ccField")
        XCTAssertEqual(AddressField.bcc.axIdentifier, "Mail.bccField")
    }

    func testURLBuiltFromPartition_carriesNoCcWhenCcIsNamed() {
        let p = partitionRecipientsForMailto(to: ["a@b.c"], cc: [named], bcc: ["d@b.c"])
        let url = buildMailtoURL(to: p.urlTo, subject: "s", body: "b", cc: p.urlCc, bcc: p.urlBcc)
        XCTAssertFalse(url.contains("?cc=") || url.contains("&cc="), url)
        XCTAssertTrue(url.contains("bcc=d%40b.c"), url)
    }
}
