import Foundation

// MARK: - #404 post-save recipient receipt

/// The cc / bcc addresses Mail stored on the saved draft, as read back through
/// the AppleScript object model. The AX token read-back in the fill phase can
/// only see display names (a token exposes no address over AX — live probe
/// 2026-09-07), so this receipt is the only evidence that the ADDRESSES landed.
struct RecipientReceipt: Equatable {
    let ccFound: [String]
    let bccFound: [String]
}

/// Script: locate the NEWEST draft (highest message id) whose subject equals
/// `subject` exactly, across every account's drafts mailbox, and return its cc
/// and bcc addresses as `cc1␞cc2␝bcc1` (ASCII 30 between addresses, ASCII 29
/// between the two lists); `NOTFOUND` when no draft carries the subject.
///
/// Newest-id wins because `update_draft` keeps the old draft (same subject)
/// until its own receipt confirms the replacement — the receipt must not read
/// the old draft's recipients as if they were the new draft's. The subject
/// comparison runs under `considering case` for parity with the Swift `==`
/// that `update_draft`'s receipt applies to `parseDraftRows`.
func buildDraftRecipientReceiptScript(subject: String) -> String {
    return """
    -- #404 recipient receipt
    tell application "Mail"
        set _best to missing value
        set _bestId to -1
        considering case
            repeat with mb in (every mailbox of drafts mailbox)
                repeat with dm in (every message of mb)
                    try
                        if ((subject of dm) as string) is "\(appleScriptEscape(subject))" then
                            if (id of dm) > _bestId then
                                set _bestId to (id of dm)
                                set _best to dm
                            end if
                        end if
                    end try
                end repeat
            end repeat
        end considering
        if _best is missing value then return "NOTFOUND"
        set ccStr to ""
        set firstCc to true
        repeat with r in (cc recipients of _best)
            if firstCc then
                set firstCc to false
                set ccStr to (address of r) as string
            else
                set ccStr to ccStr & (ASCII character 30) & ((address of r) as string)
            end if
        end repeat
        set bccStr to ""
        set firstBcc to true
        repeat with r in (bcc recipients of _best)
            if firstBcc then
                set firstBcc to false
                set bccStr to (address of r) as string
            else
                set bccStr to bccStr & (ASCII character 30) & ((address of r) as string)
            end if
        end repeat
        return ccStr & (ASCII character 29) & bccStr
    end tell
    """
}

/// Parse the receipt script's return value; `nil` when the draft was not found.
func parseRecipientReceipt(_ raw: String) -> RecipientReceipt? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "NOTFOUND" { return nil }
    let halves = trimmed.split(separator: "\u{1D}", maxSplits: 1, omittingEmptySubsequences: false)
    func addresses(_ s: Substring?) -> [String] {
        guard let s, !s.isEmpty else { return [] }
        return s.split(separator: "\u{1E}", omittingEmptySubsequences: true).map(String.init)
    }
    return RecipientReceipt(
        ccFound: addresses(halves.first),
        bccFound: addresses(halves.count > 1 ? halves[1] : nil))
}

/// The disclosure appended to a draft result. Compares the caller's intended
/// addresses (display names stripped via `parseRecipient`) with what the draft
/// holds, case-insensitively and order-insensitively. Never a failure: a
/// mismatch or a missing draft is reported with `recipients_verified: false`
/// and the draft is KEPT — the failure direction is always toward keeping
/// drafts (#276).
func recipientReceiptDisclosure(
    expectedCc: [String], expectedBcc: [String], receipt: RecipientReceipt?
) -> String {
    let wantCc = expectedCc.map { parseRecipient($0).address.lowercased() }
    let wantBcc = expectedBcc.map { parseRecipient($0).address.lowercased() }
    guard let receipt else {
        return " [recipients_verified: false — a draft with this subject was not found in the drafts "
            + "mailbox after saving; any draft that did land is KEPT; recipients_diff: "
            + diffLine("cc", wantCc, []) + "; " + diffLine("bcc", wantBcc, []) + "]"
    }
    let gotCc = receipt.ccFound.map { $0.lowercased() }
    let gotBcc = receipt.bccFound.map { $0.lowercased() }
    let ccOk = Set(wantCc) == Set(gotCc)
    let bccOk = Set(wantBcc) == Set(gotBcc)
    if ccOk && bccOk {
        return " [recipients_verified: true — cc/bcc addresses read back from the saved draft]"
    }
    return " [recipients_verified: false — the saved draft's recipients differ from the request; "
        + "draft KEPT for you to check; recipients_diff: "
        + diffLine("cc", wantCc, gotCc) + "; " + diffLine("bcc", wantBcc, gotBcc) + "]"
}

private func diffLine(_ field: String, _ expected: [String], _ found: [String]) -> String {
    return "\(field) expected [\(expected.joined(separator: ", "))] found [\(found.joined(separator: ", "))]"
}

/// The tag `buildMailtoComposeScript` appends to its return value when the
/// fill phase revealed the Bcc field; translated into the result disclosure.
let bccFieldRevealedScriptTag = " [bcc-field-revealed]"
