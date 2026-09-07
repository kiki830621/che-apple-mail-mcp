## 1. Eligibility：第 6 類 ineligibility 改為 send-only

- [x] 1.1 `composeRefusal` 的 `displayNameFillViable` 只由 `draftMode` 決定，`composeRefusalForCall` 不再檢查 cc/bcc 顯示名；`ComposeRefusal.displayNameRecipient.message` 改為 send-only 語意並指向 `create_draft`。驗證：`MailtoComposeTests` 新增 refusal 矩陣（draft/send × to/cc/bcc × bare/named，12 格）— draft × named 全部回 nil、send × named 全部回 `.displayNameRecipient`，對應 spec「Ineligible composing calls fail without side effects」與「From-scratch composing tools accept cc and bcc recipients」。
- [x] 1.2 `composeViaMailto` 對 send 的 defense-in-depth guard 維持覆蓋三個清單；`urlTo` / `urlCc` / `urlBcc` 在該清單含顯示名時整段省略。驗證：`buildMailtoURL` 測試 — `cc` 含顯示名時 URL 無 `cc=`，純位址時有。

## 2. Fill phase：AX 聚焦取代 Tab 盲跳、貼上而非 set value

- [x] 2.1 [P] `ComposeScriptBuilder` 的 fill 輸入改為 per-field 結構（`AddressField` 枚舉 `to / cc / bcc` → `Mail.toField` / `Mail.ccField` / `Mail.bccField`），每個欄位生成「依 AXIdentifier 取元素 → `set focused` → ⌘V → Tab」的 AppleScript 片段，不含任何 `set value`。驗證：script builder golden 測試 — 含 cc fill 時輸出含 `"Mail.ccField"` 與 `set focused`，且整份 script 不含 `set value of`；To-only 輸入仍通過既有 fill 測試（keystroke tab、引號轉義、先於 popup）；既有 To 路徑亦改為 AX 聚焦。
- [x] 2.2 [P] AX token read-back 為 pre-dispatch gate：每個欄位 Tab 之後生成「讀 `UI elements` count 與各 child `AXValue`」的比對片段，期望值由 Swift 端依 `parseRecipient` 算出（有顯示名 → 顯示名；無 → 位址），不符 → `error` 帶 pre-dispatch sentinel。驗證：golden 測試 — 兩個 named cc 時 script 含期望 count `2` 與兩個顯示名字面值；`"Doe, Jane" <jane@…>` 的期望值為 `Doe, Jane`（引號已剝），對應 spec「Draft display-name recipients are filled through AX-addressed fields」。
- [x] 2.3 Bcc 欄位揭露不還原：`Mail.bccField` 不存在時生成「click 顯示方式選單中名稱含『密件副本』或『Bcc』的 item → 輪詢欄位出現（沿用 From-popup 輪詢上限）」片段，成功時設旗標供 result 帶 `bcc_field_revealed: true`，找不到 item 或逾時 → 具名 error；不生成第二次 click。驗證：golden 測試 — bcc fill 分支含選單 click 與輪詢、不含還原 click；Swift 端 result 組裝測試含 `bcc_field_revealed`，對應 spec「Bcc field is revealed on demand and disclosed, not restored」。

## 3. 存檔後 recipient receipt

- [x] 3.1 `MailController` 在 ⌘S 後、且本次有 display-name cc/bcc fill 時，以 subject 精確比對定位新草稿，讀 `address of every cc recipient` / `bcc recipient`，與意圖位址集合比對；相符 → result `recipients_verified: true`，不符或找不到 → `recipients_verified: false` + `recipients_diff`（expected / found），草稿不刪、呼叫不視為失敗；純位址呼叫不執行 receipt、result 無此欄位。驗證：以 runner seam（#185 的 `runScript` 注入）餵假 drafts 列表的單元測試覆蓋 match / diff / not-found / not-applicable 四例，對應 spec「Draft recipient receipt verifies addresses after save」。
- [x] 3.2 update_draft 自動繼承：其既有 post-create receipt（新 id 出現）與 recipient receipt 合併為同一次 drafts 讀取，不疊兩層 settle；`deleted_old` 語意不變。驗證：`update_draft` 既有測試全綠 + 新增一例 named cc 走 update 路徑回傳同時含 `deleted_old` 與 `recipients_verified`。

## 4. cleanup 收掉 discard sheet（#333）

- [x] 4.1 on-error cleanup 在 `close _cw saving no` 之後：若 `_cw` 仍存在且 `sheet 1` 的 AXIdentifier 為 `Mail.sendMessageAlert`，click title 為「不儲存」或以「Don」開頭的 button，再確認 `_cw` 不存在；仍存在 → 原錯誤訊息附加「compose 視窗殘留：<title>」。驗證：golden 測試 — cleanup 片段含 `Mail.sendMessageAlert` 與兩種按鈕 title 比對、不含「儲存」/「Save」按鈕的 click；error 訊息組裝測試覆蓋殘留註記，對應 spec「Compose-window cleanup dismisses the discard-draft sheet」。

## 5. Description、rules、CHANGELOG

- [ ] 5.1 [P] `Server.swift` 中 `create_draft` / `update_draft` 的 `to` / `cc` / `bcc` description 改寫：draft 接受顯示名（AX 聚焦貼上、Bcc 自動揭露不還原、`recipients_verified` 語意）、send 拒絕；移除「keep the legacy path」字樣與 `ComposeScriptBuilder.swift` 內「keeps the LEGACY path」註解。驗證：`grep -rn "legacy path" Sources/` 只剩歷史說明性註解（無行為描述）；doc-count guard 測試（#248）綠。
- [ ] 5.2 [P] 三份 rules 第 6 類同步：`.claude/rules/compose-wrapper-free.md`、`plugin/rules/compose-wrapper-free.md`、`/Users/che/Developer/che-claude-config/rules/common-mail-compose.md` — 第 6 類改為「send 帶顯示名收件人」，並註明 draft 的 Bcc 會被切出且不還原。驗證：三份檔案的第 6 類列文字 diff 一致（逐字相同段落）。
- [ ] 5.3 [P] `CHANGELOG.md` `[Unreleased]` 新增 Changed 條目（#404 / #333）：draft 顯示名 cc/bcc、result 新欄位、第 6 類語意改寫、cleanup sheet；`README.md` 能力矩陣更新 cc/bcc 顯示名一列。驗證：`ManifestVersionTests` 與 README/manifest 計數 guard 綠。

## 6. 全套測試與 live gate

- [ ] 6.1 `swift test` 全綠，`NoBodyInjectionGuardTests` 與 `NoContentContainsScanGuardTests` 綠（證明沒有復活舊路徑）。驗證：測試輸出 0 failures，並在 issue #404 貼上 summary 行。
- [ ] 6.2 Live gate（attended）：對真實帳號 `create_draft` 帶 named Cc + named Bcc（初始 Bcc 隱藏），Mail 草稿顯示人名 token，result 含 `recipients_verified: true` 與 `bcc_field_revealed: true`；再以 `update_draft` 重跑一次；最後刪除測試草稿。驗證：指令與觀測值貼進 #404 closing comment；未跑 → 貼 `blocked-on-setup` 保持 open 並在 description 加 caveat（`.claude/rules/deferred-live-verification.md`）。
