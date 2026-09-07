import XCTest
@testable import CheAppleMailMCP

/// PR #407 verify R1 (#404): the tool-level `description:` strings and the
/// parameter-level `"description": .string(...)` literals in Server.swift are
/// what an LLM caller reads before deciding whether to pass `Name <addr>`.
/// After #304 (legacy path removed) and #404 (drafts accept display names in
/// to/cc/bcc), any of these phrases in a description is a contract lie:
/// `ManifestToolsSetEqualityTests` only diffs tool-level descriptions, so a
/// stale PARAMETER description passed every guard until a reviewer read it.
final class ComposeDescriptionDriftTests: XCTestCase {

    private static let forbidden = [
        "legacy path",
        "To-only",
        "TO ONLY",
        "hidden via Header Fields",
        "a cc/bcc recipient carries a display name",   // the pre-#404 reason-6 wording; the current one reads "a to/cc/bcc recipient … on a SEND"
        "Display-name CC recipients ALWAYS",
        "double-gated",   // PR #407 R2-2: update_draft's delete has three gates since the recipient gate (#404)
    ]

    private func serverSource() throws -> [String] {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Sources/CheAppleMailMCP/Server.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8).components(separatedBy: "\n")
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Server.swift not found from \(#filePath)")
    }

    func testNoDescriptionStillDescribesTheRemovedPaths() throws {
        let lines = try serverSource()
        var offenders: [String] = []
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("description:") || trimmed.contains("\"description\": .string(") else { continue }
            for phrase in Self.forbidden where line.contains(phrase) {
                offenders.append("Server.swift:\(idx + 1) contains \"\(phrase)\"")
            }
        }
        XCTAssertTrue(offenders.isEmpty, "stale compose-path wording in tool/parameter descriptions:\n" + offenders.joined(separator: "\n"))
    }
}
