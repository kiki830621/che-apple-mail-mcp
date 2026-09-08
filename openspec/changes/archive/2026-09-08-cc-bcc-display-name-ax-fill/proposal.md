## Why

`create_draft` / `update_draft` 的 clean path 對帶顯示名的 Cc/Bcc（`Name <addr>`）一律拒絕，而 To 自 #277 起就支援。#277 當時排除 Cc 的理由是「Tab 盲跳到可能被隱藏的欄位再貼上，會靜默漏收件人」；#304 刪除 legacy path 後，這條從降級變成硬拒絕，卻沒有人重新評估過。2026-09-07 的 live AX probe（#404 Diagnosis）證實 Mail 的 compose 視窗給每個地址欄位穩定的 AXIdentifier（`Mail.toField` / `Mail.ccField` / `Mail.bccField`），可以直接聚焦而不必猜 Tab 順序，#277 的 objection 已可用結構性手段消除。同一輪 probe 也觀測到 on-error cleanup 的 `close … saving no` 對 mailto 視窗只會彈出「儲存成草稿？」sheet 而不關窗，是 #333 孤兒視窗連鎖的機制；本 change 新增的每個 pre-dispatch abort 點都會經過那條 cleanup，所以一併修。

## What Changes

- `create_draft` / `update_draft` 接受帶顯示名的 `cc` / `bcc`；填入方式為「以 AXIdentifier 聚焦該欄位 → 剪貼簿貼上 → Tab」，與 #277 的 To 機制同一 tokenizer。**不得**用 AX `set value`（live probe：多個帶名收件人會被合併成單一 token）。
- Bcc 欄位若不存在（Mail 預設隱藏），先 click「顯示方式 › 密件副本地址欄位」切出，輪詢 `Mail.bccField` 出現後再填。**不還原**該選單狀態，改在 result 揭露「Bcc 欄位已顯示」。
- 每個欄位貼上後以 AX 讀回 token 數與顯示名，不符 → pre-dispatch 失敗、關閉自己開的視窗、具名原因。
- ⌘S 後新增 recipient receipt：在草稿匣定位新草稿，讀 `cc recipients` / `bcc recipients` 比對意圖位址；不符回 `verified:false` 與差異清單，**草稿保留**。
- **BREAKING（spec 層）**：`message-composition` 的六類 ineligibility 第 6 類由「cc/bcc 帶顯示名」改為「**寄出**（`compose_email`）時任一收件人帶顯示名」。`compose_email` 行為不變（仍拒），`create_draft` / `update_draft` 從拒絕變為接受。
- on-error cleanup（#333）：`close _cw saving no` 之後偵測 `Mail.sendMessageAlert` sheet，click「不儲存」，再確認視窗已消失；失敗才回報「視窗殘留」。
- Tool description（`create_draft` / `update_draft` 的 to/cc/bcc）、`.claude/rules/compose-wrapper-free.md`、`plugin/rules/compose-wrapper-free.md`、`che-claude-config/rules/common-mail-compose.md` 六類失敗表、CHANGELOG 同步。

## Capabilities

### New Capabilities

（無 — 全部落在既有 `message-composition` 之內）

### Modified Capabilities

- `message-composition`：(1) 「From-scratch composing tools accept cc and bcc recipients」— draft 接受顯示名 cc/bcc，send 維持拒絕；(2) 「Ineligible composing calls fail without side effects」— 第 6 類改寫為 send-only；(3) 新增 requirement：AX-addressed 欄位填入、Bcc 欄位揭露、recipient receipt、cleanup 收掉 discard sheet。

## Impact

- Affected specs: `message-composition`（delta 見 `specs/message-composition/spec.md`）；`draft-update` 不改 — 其「same mechanism and eligibility rules as `create_draft`」條款自動繼承。
- Affected code:
  - `Sources/CheAppleMailMCP/MailtoCompose.swift` — `ComposeRefusal.displayNameRecipient` 訊息、`composeRefusal` 的 `displayNameFillViable` 語意
  - `Sources/CheAppleMailMCP/AppleScript/MailController.swift` — `composeRefusalForCall` 移除 cc/bcc 條件；`composeViaMailto` 的 fill 清單擴為 to/cc/bcc；receipt 呼叫
  - `Sources/CheAppleMailMCP/AppleScript/ComposeScriptBuilder.swift` — fill phase per-field AX 聚焦、Bcc 揭露、AX read-back、cleanup 收 sheet
  - `Sources/CheAppleMailMCP/Server.swift` — `create_draft` / `update_draft` description ×5（含 L364 過期的「keep the legacy path」）
  - `Tests/CheAppleMailMCPTests/` — refusal 矩陣、script builder golden、`NoBodyInjectionGuardTests` 維持綠
  - `.claude/rules/compose-wrapper-free.md`、`plugin/rules/compose-wrapper-free.md`、`~/Developer/che-claude-config/rules/common-mail-compose.md`、`CHANGELOG.md`、`README.md`
- Issues: #404（主）、#333（併入）；#277 / #304 / #219 / #276 為前置脈絡。
