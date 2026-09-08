## Context

#304 之後，四個 compose 工具的 body 只能來自 Mail 自己的編輯器（mailto hand-off + GUI 鍵盤操作）。收件人的顯示名（`Name <addr>`）無法放進 mailto URL（RFC 6068 只載 addr-spec），所以 #277 為 To 做了「剪貼簿貼上 + Tab」的 GUI 填入，但只做 To：compose 視窗開啟時 To 欄位預設聚焦，貼上落點確定；Cc 可能被「顯示方式」隱藏，Tab 過去再貼可能落到 Subject，草稿存檔時靜默漏收件人（#277 verify Codex BLOCKING）。當時 Cc/Bcc 顯示名走 legacy path；#304 刪除 legacy path 後變成硬拒絕（`ComposeRefusal.displayNameRecipient`）。

2026-09-07 對使用者本機（Mail on macOS 27）的三輪 live AX probe（#404 Diagnosis）建立了以下事實，本設計全部以此為據：

| 事實 | 觀測 |
|---|---|
| 地址欄位有穩定 AXIdentifier | `Mail.toField`、`Mail.ccField`、`Mail.bccField`（切出後）、`Mail.replyToField`、`Mail.subjectField`；From popup 為 `popup_from`（#219 已用） |
| Cc 預設顯示、Bcc 預設隱藏 | 新視窗無 `Mail.bccField`；「顯示方式 › 密件副本地址欄位」menu item 可 click，之後欄位出現，再 click 消失 |
| `AXMenuItemMarkChar` 不可讀 | 選單勾選狀態回 missing value；只能以欄位存在與否判斷 |
| AX `set value` 對多個帶名收件人合併成一個 token | `甲 <a1@…>, 乙 <a2@…>` → 1 token「甲 <a1@example.org>, 乙 <a2@example.org>」；純位址清單則正確拆 2 token |
| AX 聚焦 + 貼上 + Tab 正確 tokenize | `丙 <c1@…>, 丁 <c2@…>, d3@…` → 3 tokens |
| token 的 AX 屬性不含位址 | child 是 `AXStaticText` subrole `AXTextAttachment`，`AXValue` 只有顯示名，`AXHelp` / `AXURL` 為 missing value |
| `close <mailto window> saving no` 不關窗 | 彈出 `AXSheet` id `Mail.sendMessageAlert`（儲存 / 不儲存 / 取消），視窗連 sheet 留在原地 |

使用者的硬約束（#404 decision，2026-09-07）：**無論如何不走舊路徑** — 任何實作不得復活 AppleScript body 注入；`NoBodyInjectionGuardTests` 必須維持綠。

## Goals / Non-Goals

**Goals:**

- `create_draft` / `update_draft` 接受帶顯示名的 `cc` / `bcc`，草稿存檔後收件人顯示人名。
- 不留任何靜默漏收件人的通道：定位失敗、貼上後 token 數不符、存檔後位址不符，三處都要 fail loud。
- Bcc 欄位預設隱藏時仍可填。
- 修掉 on-error cleanup 對 mailto 視窗無效的問題（#333），避免本 change 新增的 abort 點更常留下孤兒視窗。

**Non-Goals:**

- `compose_email`（send）的顯示名收件人：維持拒絕。fill 失敗只能在 pre-dispatch 被抓，send 的 dispatch 是 ⇧⌘D，一旦漏抓就寄出漏收件人的信，#277 的 draft-only 紀律不變。
- 還原「顯示方式 › 密件副本地址欄位」的選單狀態：不做（見 Decisions）。
- 從 AX 讀回位址：做不到（token 不暴露位址），不嘗試。
- `reply_email` / `forward_email` 的 cc：不在範圍（它們走 native verb，收件人由 Mail 自己帶）。
- 草稿 id 漂移（#405）：sibling，另行處理。
- 用 AX `set value` 當填入手段：已被 probe 否決，不作為選項。

## Decisions

### AX 聚焦取代 Tab 盲跳

fill phase 對每個要填的欄位，先以 `text field whose AXIdentifier is "<Mail.xxField>"` 取得元素，`set focused to true`，再貼上。欄位不存在（Mail 改版或欄位被隱藏且未能揭露）→ AppleScript error → 進既有 on-error cleanup → Swift 端具名拒絕、零副作用。這把 #277 的 objection 從「行為風險」變成「可偵測失敗」。

替代方案：維持 Tab 序列並在每次 Tab 後讀 `AXFocusedUIElement` 的 identifier 驗證落點。可行但多一輪 AX 往返且仍依賴欄位順序，AXIdentifier 直接定位更短更確定。

### 貼上而非 set value

填入內容以 `set the clipboard to "<A <a>, B <b>, c@x>"` + `keystroke "v" using command down` + `keystroke tab` 交給 Mail 的輸入 tokenizer，沿用 #277 To 路徑已出貨、已對 CJK 驗過的機制（`withClipboardPreserved` 包住）。AX `set value` 走 NSTokenField 的 object-value 路徑，對帶顯示名的逗號清單不拆，live probe 直接重現，故排除。

### Bcc 欄位揭露不還原

`Mail.bccField` 不存在時，click「顯示方式」選單中名稱含「密件副本」或「Bcc」的 menu item（locale 雙關鍵字比對，與 #219 對 From popup 的做法同型），輪詢至 `Mail.bccField` 出現（上限與 #296 的 popup 輪詢一致），再填。**不還原**：還原只能在 ⌘S 之前 click 一次，而「隱藏 Bcc 欄位會不會丟掉已 tokenize 的 Bcc 收件人」未驗證；⌘S 之後視窗已關、選單狀態又不可讀。代價是使用者的 Mail 之後開新信會多一個 Bcc 欄位，成本低且可逆；result 字串必須揭露這件事。

替代方案：切出 → 填 → ⌘S → 再開一個空視窗 click 還原。多開一個視窗等於多一個孤兒風險，否決。

### AX token read-back 為 pre-dispatch gate

每個欄位貼上 + Tab 之後，讀該欄位 `UI elements` 的 count 與各 child 的 `AXValue`：count 必須等於該欄位的收件人數；每個 child 的值必須等於對應收件人的顯示名（bare 位址的 token 顯示位址本身）。不符 → error → cleanup → 拒絕。這是 fill 是否成功的唯一即時證據；位址正確性不在此驗（AX 讀不到）。

### 存檔後 recipient receipt

⌘S 後，以 subject 精確比對在 drafts mailbox 定位新草稿（沿用 `update_draft` post-create receipt 的定位與 settle 邏輯，#276），讀 `address of every cc recipient` / `address of every bcc recipient`，與意圖位址集合比對。相符 → result 帶 `recipients_verified: true`；不符或定位失敗 → `recipients_verified: false` + `recipients_diff`（expected / found），**草稿保留、不刪**。方向與 #276 一致：失敗永遠朝保留草稿。receipt 只在有 cc/bcc 顯示名填入時執行，純 URL 路徑不變。

### 第 6 類 ineligibility 改為 send-only

`composeRefusal` 的 `displayNameFillViable` 只看 `draftMode`；第 6 類理由改寫為「寄出時任一收件人（to/cc/bcc）帶顯示名」。六類封閉列舉維持六類，不新增第七類。`composeViaMailto` 內對 send 的 defense-in-depth guard 保留原樣。

### cleanup 收掉 discard sheet（#333）

on-error cleanup 在 `close _cw saving no` 之後：若 `_cw` 仍存在且其 `sheet 1` 的 AXIdentifier 為 `Mail.sendMessageAlert`，click 該 sheet 中 title 為「不儲存」或以「Don」開頭的 button，再確認 `_cw` 已不存在；仍存在 → error 訊息加註「compose 視窗殘留，請手動關閉」。這是 #333 的機制修法；#333 的其餘（連鎖偵測、title 碰撞）不在本 change。

### update_draft 自動繼承

`draft-update` spec 的「same mechanism and eligibility rules as `create_draft`」條款不動；eligibility 放寬後 `update_draft` 自動接受顯示名 cc/bcc。其既有 post-create receipt（新 id 出現）與新的 recipient receipt 合併成一次 drafts 讀取，不疊兩層 settle。

## Implementation Contract

**Behavior**

- `create_draft` / `update_draft` 帶 `cc: ["王小明 <ming@example.com>"]` 或 `bcc: [...]` 時不再拒絕；草稿在 Mail 的 Cc/Bcc 顯示人名 token。
- `compose_email` 帶任何顯示名收件人（to/cc/bcc）仍拒絕，錯誤訊息指向 `create_draft`。
- result 字串（成功時）多兩個欄位：`recipients_verified: true|false`；`false` 時附 `recipients_diff: {cc: {expected: [...], found: [...]}, bcc: {...}}`；若 Bcc 欄位由本次呼叫切出，附 `bcc_field_revealed: true`。
- 任何 fill 階段失敗（欄位不存在、揭露逾時、token 數／顯示名不符）→ 呼叫失敗、不建草稿、自己開的視窗已關（含 sheet 已收）。

**Interface / data shape**

- 工具 schema 不變（`to` / `cc` / `bcc` 仍為 string array）；description 改寫。
- `ComposeRefusal.displayNameRecipient` 的 `message` 改為 send-only 語意。
- `composeRefusal(...)` 簽名不變；`displayNameFillViable` 的呼叫端語意改為 `draftMode`。
- `ComposeScriptBuilder` 的 fill 輸入由 `fillToRecipients: [String]` 改為 per-field 結構 `fill: [(field: AddressField, recipients: [String])]`，`AddressField` 枚舉 `to / cc / bcc` 各對應 AXIdentifier。

**Failure modes**

- 欄位不存在 / 揭露逾時 / read-back 不符：AppleScript error 帶 sentinel → cleanup → `MailError.invalidParameter` 具名原因。
- receipt 定位失敗或位址不符：**不是**錯誤，成功回傳但 `recipients_verified: false`。
- cleanup 收 sheet 失敗：原錯誤訊息附加「視窗殘留」註記，不吞掉原因。

**Acceptance criteria**

- 單元：refusal 矩陣（draft/send × to/cc/bcc × bare/named）；script builder golden 含 cc/bcc fill 分支、Bcc 揭露分支、cleanup sheet 分支；`NoBodyInjectionGuardTests` 綠；全套測試綠。
- Live gate（attended，依 `.claude/rules/deferred-live-verification.md`）：對真實帳號 `create_draft` 帶 named Cc + named Bcc，Mail 草稿顯示人名，result `recipients_verified: true`；再以 `update_draft` 重跑一次。未跑 → issue 貼 `blocked-on-setup` 保持 open，description 加 caveat。

**Scope boundaries**

- In：上述 draft 路徑、cleanup sheet、description ×5、三份 rules 第 6 類、CHANGELOG、README 能力矩陣。
- Out：send 路徑、Bcc 選單還原、AX 讀位址、reply/forward cc、#405、#333 的其餘子項。

## Risks / Trade-offs

- [Mail 改版換掉 AXIdentifier] → 定位失敗即 fail-closed，不會誤填；description 註明依賴 `Mail.ccField` / `Mail.bccField`。
- [Bcc 選單 item 名稱 locale 差異] → 雙關鍵字（密件副本 / Bcc）比對，找不到 → 具名拒絕「Bcc 欄位無法揭露」。
- [切出 Bcc 改變使用者 Mail 的持久偏好] → result 揭露 `bcc_field_revealed`，rules 第 6 類註明。
- [receipt 因 drafts 同步延遲讀不到] → `recipients_verified: false`，草稿保留，caller 可重列驗證；不誤報成功。
- [貼上後 Tab 的落點] → Tab 只用來 commit token，不用來定位；落到哪個欄位不影響。
- [read-back 只驗顯示名] → 位址由 receipt 驗；兩層合起來才是完整證據，description 要說清楚。
- [cleanup 多一次 AX 往返] → 只在 error path 執行，成功路徑零成本。

## Migration Plan

- 版本：minor bump（行為放寬 + result 新欄位，無 schema 破壞）；CHANGELOG 標明 spec 層第 6 類語意改寫。
- Rollback：revert commit 即回到拒絕行為；無資料遷移。
- 三份 rules（repo / plugin / che-claude-config）同一天改。

## Open Questions

- 無。五項 trade-off 已於 2026-09-07 spectra-discuss 定案（#404 decision comment）。
