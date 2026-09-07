## 1. 先立防線（在刪除任何東西之前）

- [x] 1.1 新增 `Tests/CheAppleMailMCPTests/NoBodyInjectionGuardTests.swift`：掃 `Sources/CheAppleMailMCP/` 全文，禁止 `set content`、`set html content`、以及 outgoing-message 建構中的 `content:` property。比照既有 `NoNonThrowingStderrWriteGuardTests` 的**整檔文字**掃描寫法（逐行掃會被跨行呼叫繞過），並在註解說明本 guard 存在的理由是 #304 的實寄事故 （→ Requirement: Composing tools never inject a body via AppleScript）
- [x] 1.2 確認 1.1 的 guard 對**當前** main **失敗**（8 個注入點都應被抓到）——guard 若一開始就綠，它沒有在防任何東西
- [x] 1.3 決定 design.md `## Open Questions` 的那一題：reply/forward 的 paste 失敗歸入哪一類 failure mode；把結論寫回 design.md，不留待實作時即興決定 （→ design: Open Questions；Failure modes（封閉列舉——只有以下六類，不得依性質相似類推第七類））

## 2. 移除注入點與其路由

- [x] 2.1 `ComposeScriptBuilder.swift`：刪除 `buildComposeEmailScript` 的 `content:` property 與 `set html content` （→ Requirement: Composing tools never inject a body via AppleScript；design: 注入點清單（本設計的實際範圍）；D1 — 刪除注入點，而非改變預設值）
- [x] 2.2 `ComposeScriptBuilder.swift`：刪除 `buildCreateDraftScript` 的 `content:` property 與 `set html content`
- [x] 2.3 `ComposeScriptBuilder.swift`：刪除 `buildReplyEmailScript` 的 `set content` 與 `set html content`
- [x] 2.4 `ComposeScriptBuilder.swift`：刪除 `buildForwardEmailScript` 的 `set content` 與 `set html content` （→ REMOVED: Reply and forward wrap original content in HTML blockquote）
- [x] 2.5 刪除因 2.1–2.4 而無人呼叫的 legacy 組裝 helper；用編譯器的 unused 警告與 `grep` 交叉確認，不靠肉眼
- [x] 2.6 刪除 `Sources/CheAppleMailMCP/MarkdownRendering.swift`（`renderBody` / `markdownToHTML`），並移除其測試中僅測 compose 渲染的部分 （→ REMOVED: Markdown mode renders via AttributedString；HTML mode writes body to AppleScript html content；Markdown rendering has documented Foundation parser limitations）
- [x] 2.7 確認 1.1 的 guard 此時**轉綠**

## 3. eligibility：從路由開關改成失敗理由

- [x] 3.1 `MailtoCompose.swift`：`mailtoIneligibilityReason` 的回傳值不再決定「走哪條路」，而是決定「用什麼理由失敗」 （→ Requirement: Ineligible composing calls fail without side effects；design: Behavior（呼叫端觀察到什麼）；約束）
- [x] 3.2 移除 `mailtoComposeDisableEnvKey`（`CHE_MAIL_DISABLE_MAILTO_COMPOSE`）與 `replyForwardPasteDisableEnvKey`（`CHE_MAIL_DISABLE_PASTE_REPLY`）及其分支 （→ design D5 — 兩個 env hatch 一併移除）
- [x] 3.3 依 design.md 的**封閉六類**實作失敗訊息，每一類都要帶可執行的替代做法；第 3 類必須指名 `open_mailto` 並註明它帶不了附件 （→ Requirement: Ineligible composing calls fail without side effects；design: Failure modes（封閉列舉——只有以下六類，不得依性質相似類推第七類）；D2 — T2（`open_mailto`）是明確選擇，不是自動降級）
- [x] 3.4 確保失敗路徑**零副作用**：不建立草稿、不寄出、不刪除既有草稿（`update_draft` 的 upsert 尤其要驗）

## 4. Tool schema 與參數

- [x] 4.1 `Server.swift`：四個 compose 工具的 `format` enum 改為 `["plain"]`，描述說明其為唯一支援值 （→ Requirement: Composing tools accept a format parameter；Composing tools input schema exposes format parameter；design: D3 — `format` 保留參數、限縮為單值 `plain`）
- [x] 4.2 `Server.swift`：從 `compose_email` / `create_draft` / `reply_email` / `forward_email` / `update_draft` 移除 `require_wrapper_free` （→ REMOVED: Wrapper-free strictness parameter；design: D4 — `require_wrapper_free` 移除，而非保留為 no-op；Interface）
- [x] 4.3 `Server.swift`：從四個 compose 工具移除 `sanitize_links` （→ REMOVED: Markdown mode honors opt-in URL scheme allowlist via `sanitize_links`）
- [x] 4.4 移除 `MailController` 與各 builder 上對應的 `requireWrapperFree` / `sanitizeLinks` 參數
- [x] 4.5 `format: "markdown"` / `"html"` 回**具名**錯誤（指出已移除、改用 `plain`、並指向 #308/#309），而非泛用的 enum 驗證訊息
- [x] 4.6 跑 `REGENERATE_MCPB_MANIFEST=1 swift test --filter ManifestToolsSetEqualityTests` 同步 `mcpb/manifest.json` 的工具描述（#348 的 guard 會擋住忘記這步的情況）

## 5. 測試

- [x] 5.1 [P] 六類 failure mode 各一個測試：具名理由 + 零副作用
- [x] 5.2 [P] `format: markdown` / `html` 被拒且訊息具名
- [x] 5.3 [P] schema 測試（→ Requirement: From-scratch composing tools accept cc and bcc recipients — cc/bcc 顯示名應被拒）：`format` enum 為 `["plain"]`；`require_wrapper_free` 與 `sanitize_links` 皆不存在
- [x] 5.4 [P] 移除或改寫既有斷言 legacy 行為的測試——**逐一判斷**每個失敗的既有測試是「它在釘住被移除的行為」還是「我們弄壞了別的東西」，不可整批刪除
- [x] 5.5 live GUI 驗證（比照 #341/#321）：clean path 建出的草稿，其 source **不含**包住 body 的 `<blockquote type="cite">` （→ Requirement: Plain mode preserves existing behavior — 驗證 body 未被注入）

  **2026-08-15 11:32–11:35 已執行並通過**（使用者的前景終端機，有 GUI session）：

  ```
  $ CHE_MAIL_LIVE_TEST=1 swift test --filter MailtoComposeLiveTests
  Test Case '-[CheAppleMailMCPTests.MailtoComposeLiveTests
             testLive_createDraft_mailtoPath_producesWrapperFreeBody]' passed (201.599 seconds).
  Executed 1 test, with 0 failures (0 unexpected)
  ```

  測試走完 mailto hand-off → ⌘S 存草稿 → 讀該草稿 `.emlx` → 斷言 body 未被 `<blockquote type="cite">` 包住 → 刪除草稿收尾。中途截圖確認 compose 視窗標題 = subject（`LIVEMAILTO_1786764742`）、body 兩行完整、收件人與預設寄件人正確。事後確認 **0 筆 `LIVEMAILTO_` 草稿殘留**。

  **先前失敗的那次是環境問題、非程式問題**（已排除）：背景 session 中 System Events 對 `process "Mail"` 回報 **0 個 AX window**（即使 Mail frontmost、Accessibility 已授權、Mail 自己的 scripting model 有視窗），GUI 驅動不可用。同一份 code 在有 GUI session 的終端機一次就過。

## 6. 文件（兩份規則必須一起改）

- [x] 6.1 改寫 `plugin/rules/compose-wrapper-free.md`：eligibility 表 → 失敗理由表；刪除「揭露後由使用者拍板」等已不存在的流程
- [x] 6.2 同步改寫全域鏡像 `che-claude-config/rules/common-mail-compose.md`（已 commit `7bb9344`）。**更正**：實際上是**三份**不是兩份——`.claude/rules/`（canonical）、`plugin/rules/`（隨 plugin 出貨）、全域鏡像；三份皆已改，且三份的「相關」段都已改寫為「三份要一起改」
- [x] 6.3 改寫 `README.md` 的 Accessibility 段落：現況把 legacy fallback 描述為正常行為
- [x] 6.4 `CHANGELOG.md`：breaking 條目逐項列出（`format` enum、`require_wrapper_free`、`sanitize_links`、兩個 env hatch），並明說「原本會靜默 wrap 的呼叫現在會失敗」是**預期**行為改變 （→ design: Migration）
- [x] 6.5 在 CHANGELOG 誠實記錄 D1 的代價：失去「不開可見視窗即可組信」的能力，且無替代方案 （→ design D1 的代價段）
