## Context

`compose_email` / `create_draft` / `reply_email` / `forward_email` 各有兩條 body 路徑：

- **clean path** — `mailto:` hand-off（compose/draft）或 native verb + paste（reply/forward），
  body 由 Mail 自己的編輯器產生，**不經 AppleScript 注入**，故無 wrapper。
- **legacy path** — AppleScript 直接寫 body。Mail 在 MIME serialization 時把任何
  AppleScript-injected body 包進 `<blockquote type="cite">`（#175 runtime 證實、不可事後剝除）。

clean path 的前提不滿足時**靜默**落到 legacy。2026-07-29 一封對外正式信件因此被包引文寄出，
且寄件者本機完全看不出異常（wrapper 的 inline style 無邊框）。

### 注入點清單（本設計的實際範圍）

discuss 階段我曾聲稱注入點只有 compose 的兩處、reply/forward「早已不注入」。**那是錯的**——
`:1120`／`:1156` 的註解描述的是 **clean** builder；**legacy** reply/forward builder 同樣注入，
且可經 `CHE_MAIL_DISABLE_PASTE_REPLY` 或 paste-ineligibility 抵達。實際盤點：

| builder | plain body | html body |
|---|---|---|
| `buildComposeEmailScript` | `content:` in make-properties | `set html content` |
| `buildCreateDraftScript` | `content:` in make-properties | `set html content` |
| `buildReplyEmailScript` | `set content` | `set html content` |
| `buildForwardEmailScript` | `set content` | `set html content` |

**八個注入點、四個 builder。**

連帶死碼（已核實）：`renderBody` 的唯一呼叫端就是這些 legacy builder，且匯出路徑用的是另一個
模組（`EmailMarkdownRenderer`）。因此 `MarkdownRendering.swift` 與 `sanitize_links` 參數
在 legacy 移除後**完全無人使用**，應一併刪除。

保證要成立就必須全數移除——只清 compose 那兩處，reply/forward 仍是一條會產生 wrapper 的活路。

### 約束

使用者的判準是**約束**：「不管怎樣，都必須完全防止 citeblock 的問題」。這排除了「把
`require_wrapper_free` 預設翻成 true」這類解法：產生 wrapper 的程式碼還在，任何新的
ineligibility 維度、忘記帶的旗標、或未來的呼叫端都能再次抵達它。

## Goals / Non-Goals

**Goals:**

- `<blockquote type="cite">` 在 compose 家族**結構上不可達**——不是更難達到，是沒有程式碼能產生它
- ineligible 情境從**靜默降級**改為**具名失敗**，且失敗訊息帶可執行的替代做法
- 收斂後的路徑集合可窮舉、可測試

**Non-Goals:**

- 不修 cc/bcc 顯示名（RFC 6068 硬限制，#277 已記）
- 不解決 CJK 附件路徑的 GUI 卡死（#220）——此處只負責明確失敗並指向既有手動配方
- 不碰匯出路徑的 markdown 渲染（`EmailMarkdownRenderer`，`batch_export_emails_markdown` 使用中）——
  那是**另一個模組**，與 compose 的 `MarkdownRendering.swift` 無關
- 不設計 rich-text compose 的替代架構（#308 / #309 的範疇）

## Decisions

### D1 — 刪除注入點，而非改變預設值

「完全防止」只有一種實作方式能兌現：讓產生 wrapper 的程式碼不存在。翻預設值把 wrapper 留在
一個布林值之外；新增一個 ineligibility 維度、或某個呼叫端反射性地傳 `false`，就回到原點。

**代價（誠實記錄）**：legacy 路徑同時是**唯一能在不開啟可見視窗的情況下組信**的路徑。
`CHE_MAIL_DISABLE_MAILTO_COMPOSE` 這個 hatch 的原始理由正是「heavy/unattended automation
where a briefly-visible compose window is unacceptable」（CHANGELOG v2.17.0）。刪除 legacy
**移除該能力**，且 clean path 無法補上——mailto hand-off 必然開視窗。這是本變更真正失去的東西，
不是可以繞過的細節。

### D2 — T2（`open_mailto`）是明確選擇，不是自動降級

`open_mailto`（#287，零 TCC）能產生乾淨 body，但它開在**系統預設**郵件 app（未必是 Mail.app）
且**帶不了附件**。自動降級到它 ＝ 換一種靜默降級，正是本變更要消滅的形狀。

因此 ineligible 時**失敗**，並在訊息中**指名** `open_mailto` 為可用替代，由呼叫端決定。

### D3 — `format` 保留參數、限縮為單值 `plain`

移除整個參數會讓「明確傳 `format: "plain"`」的呼叫端一起壞掉——而那些呼叫端做的正是對的事。
保留單值 enum 可對 `markdown` / `html` 回**具體**錯誤（為何不再支援、該怎麼做），而非泛用的
「未知參數」。

### D4 — `require_wrapper_free` 移除，而非保留為 no-op

保留一個永遠為真的旗標會讓呼叫端以為它仍在控制某個開關。移除它，讓 schema 誠實反映
「只有一條 body 路徑」。

### D5 — 兩個 env hatch 一併移除

`CHE_MAIL_DISABLE_MAILTO_COMPOSE` 與 `CHE_MAIL_DISABLE_PASTE_REPLY` 的作用都是「強制走
legacy」。legacy 消失後兩者無可強制。保留它們＝保留一個看起來能改變行為、實際不能的設定。

## Implementation Contract

### Behavior（呼叫端觀察到什麼）

成功時與現況**無差異**：body 乾淨、附件就位、寄件人正確。差別全在失敗面——過去會得到一封
wrapped 的信加一段事後揭露，現在得到一個**沒有副作用的錯誤**（不建立草稿、不寄出、不刪除
既有草稿）。

### Interface

- `compose_email` / `create_draft` / `reply_email` / `forward_email`
  - `format`: enum 由 `["plain","markdown","html"]` → `["plain"]`；omitted 仍視為 `plain`
  - `require_wrapper_free`: **移除**
  - `sanitize_links`: **移除**（只服務 markdown 渲染，隨之失去意義）
- `update_draft`：`require_wrapper_free` 同步移除
- 刪除模組：`Sources/CheAppleMailMCP/MarkdownRendering.swift`（含 `renderBody` / `markdownToHTML`）
- `open_mailto`：不變（成為 T2 的具名替代）

### Failure modes（封閉列舉——只有以下六類，不得依性質相似類推第七類）

每一類都必須回傳**具名原因 + 可執行替代**，且**不得**產生任何副作用：

| # | 觸發 | 訊息應說 |
|---|---|---|
| 1 | `format` 為 `markdown` / `html` | 不再支援；rich text 結構上需要注入路徑。改用 `plain`，或見 #308/#309 |
| 2 | subject 為空 | clean path 以視窗標題辨識自己的 compose 視窗；請提供 subject |
| 3 | Accessibility 未授權 | GUI 鍵盤操作不可用；授權後重試，或改用 `open_mailto`（零 TCC、無附件、需手動存檔） |
| 4 | `from_address` 非 simple addr-spec | 提供 bare addr-spec，或省略 `from_address` 後在 Mail 手動切換寄件人 |
| 5 | 附件路徑含非 ASCII 字元 | ⇧⌘G sheet 對非 ASCII 會卡死（#220）；建乾淨草稿（不帶 `attachments`）後手動拖曳 |
| 6 | cc/bcc 帶顯示名（`Name <addr>`） | mailto 只承載 addr-spec（RFC 6068）；cc/bcc 請用純位址。To 的顯示名仍支援 |

第 5、6 類的配方**與現行規則文件一致**（`compose-wrapper-free.md` 本來就明訂手動拖曳與純位址），
所以這不是新增限制，而是把既有文件的指示變成工具本身會說的話。

### Migration

- 版本：breaking（移除 enum 值與參數）。CHANGELOG 需逐項列出，並說明「原本會靜默 wrap 的呼叫
  現在會失敗」——這是**預期**行為改變，不是回歸。
- 呼叫端：傳 `markdown`/`html` 者需改 `plain`；傳 `require_wrapper_free` 者移除該參數。
- 文件：`plugin/rules/compose-wrapper-free.md` 與全域鏡像
  `che-claude-config/rules/common-mail-compose.md` 多數條文退役，**兩份必須一起改**（該規則
  自身即載明此點）。README 的 Accessibility 段需重寫（現況描述 legacy fallback 為正常行為）。

## Risks / Trade-offs

| 風險 | 處置 |
|---|---|
| **失去無視窗自動化能力**（D1 代價） | 接受並記錄。無替代方案；若日後成為真實阻塞，走 #308（IMAP APPEND）而非復活注入 |
| 失敗率上升，呼叫端可能被擋住 | 六類失敗各帶可執行配方；其中兩類的配方就是現行規則已經要求的做法 |
| `sanitize_links` 與 `MarkdownRendering.swift` 一併成為死碼 | 兩者只服務 compose 的 markdown 渲染（`renderBody` 的唯一呼叫端是 legacy builder，已核實）；隨 legacy 一併移除，並從四個 compose schema 拿掉 `sanitize_links` |
| 移除 hatch 影響未知的既有腳本 | hatch 只在 README/CHANGELOG 出現，無 SOP 使用；仍需在 CHANGELOG 明列 |

## Resolved Questions

### Q3 — reply/forward 的 paste 失敗歸入哪一類 failure mode？（tasks 1.3，已定案）

**不歸入任何一類——它不是 ineligibility。**

封閉六類全是 **pre-flight** 判定：在產生任何副作用**之前**就能決定，因此可以「具名失敗且零副作用」。
paste 失敗發生在**操作進行中**，那時視窗已開、動作已部分執行，語意完全不同。把它塞進第 3 類
（Accessibility）會是典型的「依性質相似類推第七類」，正是 `common-spec-prose-enumeration`
要防的事——而且會謊稱零副作用。

它已經有既有機制：#242 的 `POSTDISPATCH:` sentinel 會分類 send-stage 的 runtime error，
router 據此**rethrow 而非 fallback**，決定重試是否安全。移除 legacy 對這條路徑只改變一件事：
錯誤現在**必然**往上拋，而不是靜默落回注入路徑——也就是 `require_wrapper_free: true` 早已
在做的事，只是不再是選項。

因此：

- 六類 ineligibility ＝ **開始之前**就拒絕，零副作用，訊息帶替代做法
- runtime GUI/paste 失敗 ＝ **進行中**的錯誤，沿用 #242 的 POSTDISPATCH 分類與 rethrow 語意，
  訊息必須說明「已經做到哪裡」，**不得**宣稱零副作用

兩者在 spec 中是分開的 requirement，不共用同一個列舉。
