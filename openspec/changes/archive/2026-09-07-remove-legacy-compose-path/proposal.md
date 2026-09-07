## Why

2026-07-29，一封對外正式開會通知（10 位收件人）以 legacy path 寄出，整段 body 被包進
`<blockquote type="cite">`。**寄件者在 Apple Mail 端完全看不出異常**——該 wrapper 的 inline
style 無邊框，本機檢查正常；Gmail 網頁版／Outlook 才顯示成引用文字。事後手動補的一行落在
blockquote **之外**，在部分客戶端呈現為「一段引用文字中插入一句白話」。**已寄出，無法回收。**

觸發條件只是 **cc 帶了中文姓名**——一個看起來與排版毫無關係的選擇。

現況的三個結構性問題：

1. 前提不滿足 → **靜默**退回 legacy → body 被包 blockquote
2. 揭露只出現在**回傳字串**（`[legacy path — …]`），是**事後**才看得到，呼叫端已無選擇機會
3. `require_wrapper_free: true` 這個保護存在，但**預設 false**，等於預設不安全

使用者的判準（2026-08-14 discuss）是**約束而非偏好**：「不管怎樣，都必須完全防止 citeblock
的問題」。這一句排除了「調整預設值」這類解法——只要產生 wrapper 的程式碼還在，任何新的
ineligibility 維度、任何忘記帶的旗標、任何未來的呼叫端，都能再次走到它。

## What Changes

**把 wrapper 變成結構上不可達**，而不是把它變得比較難達到。

wrapper 的**唯一**來源是 AppleScript 對 body 的指派——`set content`、`set html content`、
以及 outgoing-message 建構中的 `content:` property。完整盤點見 design.md：**四個 builder、
八個注入點**，`compose_email` / `create_draft` / `reply_email` / `forward_email` 各有 plain 與
html 兩處。

（discuss 當下我曾誤判為「只有 compose 的兩處、reply/forward 早已不注入」——那是把 **clean**
builder 的註解當成了全部。legacy reply/forward builder 同樣注入，且可經
`CHE_MAIL_DISABLE_PASTE_REPLY` 或 paste-ineligibility 抵達。範圍以 design.md 的盤點為準。）

因此本變更是**刪掉全部八個注入點與所有導向它們的路由**，compose 收斂成三層，且**沒有任何一層
能產生 wrapper**：

| 層 | 路徑 | 需要 | 能力 |
|---|---|---|---|
| **T1** | `mailto:` hand-off + GUI 鍵盤操作 | Accessibility | 完整：body、附件、指定寄件人、To 顯示名 |
| **T2** | `open_mailto`（LaunchServices，#287） | **零 TCC** | 乾淨 body；**不能**帶附件；使用者自行存檔／寄出 |
| **T3** | 明確失敗，附具名原因與手動配方 | — | — |

同時移除兩個因此失去意義的 API 面：

- **`format` 的 `markdown` / `html`**：兩者結構上都需要 `set html content`。移除。
- **`require_wrapper_free`**：沒有 wrapper 可以「要求免於」了。移除。
- **`sanitize_links`**：只服務 markdown 渲染，隨之失去作用對象。移除。
- **`MarkdownRendering.swift`**：`renderBody` 的唯一呼叫端就是 legacy builder（已核實），
  匯出路徑用的是另一個模組 `EmailMarkdownRenderer`。legacy 移除後本檔完全無人使用，一併刪除。
- **兩個 env hatch**（`CHE_MAIL_DISABLE_MAILTO_COMPOSE` / `CHE_MAIL_DISABLE_PASTE_REPLY`）：
  作用都是「強制走 legacy」，已無可強制。移除。

### 兩個 discuss 未定案、在此定案的問題

**(Q1) T2 是自動降級，還是呼叫端明確選擇？→ 明確選擇。**
`open_mailto` 開在**系統預設**郵件 app（未必是 Mail.app），且帶不了附件。自動降級到它
＝ 另一種靜默降級，正是本變更要消滅的形狀。T3 的失敗訊息會**指名** `open_mailto` 作為
可用的替代，由呼叫端決定。

**(Q2) `format` 參數整個消失，還是保留但只接受 `plain`？→ 保留，只接受 `plain`。**
移除整個參數會讓「明確傳 `format: "plain"`」的既有呼叫端一起壞掉，而那些呼叫端做的正是
對的事。保留單值 enum 可以對 `markdown`／`html` 回一個**具體**的錯誤（說明為何不再支援、
以及該怎麼做），而不是泛用的「未知參數」。

## Non-Goals

- **不修 cc/bcc 顯示名**。mailto URL 依 RFC 6068 只承載 addr-spec，這是格式的硬限制而非
  本變更的取捨；#277 已將其記為已知限制。To 的顯示名仍由 #277 的 GUI fill 提供。
- **不改 reply/forward 的 clean path 行為**。#218 的 native verb + paste 保持原樣；本變更
  移除的是它們的 **legacy** builder（同樣注入，見上）與 `format: markdown|html`。
- **不解決 CJK 附件路徑的 GUI 卡死（#220）**。clean path 的 ⇧⌘G 對非 ASCII 路徑會卡住，
  這裡的處置是**明確失敗 + 指向既有的手動拖曳配方**，而非修好那個 sheet。既有規則本來就
  明訂「含中文／全形符號路徑的附件：一律建乾淨草稿 + 請使用者手動拖曳」，所以這是與現行
  文件一致的行為，不是新的限制。
- **不碰匯出路徑的 markdown 渲染**。`batch_export_emails_markdown` 用的是
  `EmailMarkdownRenderer`，與 compose 的 `MarkdownRendering.swift` 是**不同模組**，不受影響。
- **不做 rich-text compose 的替代方案**（IMAP APPEND / MailKit 等）。那是 #308／#309 的
  範疇，與本變更獨立。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `message-composition`: compose 的 body 路徑收斂為單一非注入路徑，format 限縮為單值 plain，
  移除 wrapper-free 嚴格模式參數與 link-sanitising 參數，ineligible 情境從靜默降級改為具名失敗。

## Impact

- **Affected specs**：`openspec/specs/message-composition/spec.md` — **新增 2、修改 4、移除 6**。
- **Affected code**：
  - `Sources/CheAppleMailMCP/AppleScript/ComposeScriptBuilder.swift`（刪除八個注入點與 legacy 組裝）
  - `Sources/CheAppleMailMCP/MarkdownRendering.swift`（**整檔刪除**）
  - `Sources/CheAppleMailMCP/MailtoCompose.swift`（eligibility → 失敗理由，不再是路由開關）
  - `Sources/CheAppleMailMCP/Server.swift`（`format` enum、移除 `require_wrapper_free`、
    工具描述）
  - `Sources/CheAppleMailMCP/AppleScript/MailController.swift`（compose 進入點）
- **Breaking**：`format: markdown|html`、`require_wrapper_free`、`sanitize_links` 皆為公開
  tool schema 的一部分。需 major/minor 版本判斷與 CHANGELOG 明列。
- **能力損失（誠實記錄）**：legacy 是唯一能**不開啟可見視窗**組信的路徑（env hatch 的原始理由）。
  移除後無替代方案；詳見 design.md D1。
- **Docs**：`plugin/rules/compose-wrapper-free.md` 與其全域鏡像
  `che-claude-config/rules/common-mail-compose.md` 的多數條文可退役——#304 本來就預期如此。
  兩份必須**一起改**。
- **Downstream issues**：#305 / #306 / #308 / #309 / #310 / #333 皆掛在本變更之後。
