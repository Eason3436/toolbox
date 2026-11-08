# LiveContainer 捷徑版

這是 [LiveContainer](https://github.com/LiveContainer/LiveContainer)（AGPL-3.0）的修改版，原始碼修改都在 `overlay/`，由 `.github/workflows/livecontainer.yml` 套到上游原始碼後編譯，發布在 release `livecontainer-latest`：

- https://github.com/Eason3436/toolbox/releases/download/livecontainer-latest/LiveContainer.ipa

## 為什麼要這樣做

iOS 只會從「真的安裝在系統上」的 App 讀取捷徑動作（App Intents）。裝在 LiveContainer 裡的 App 對系統來說不存在，所以它的捷徑動作不會出現在捷徑 App 裡。

這個版本在 LiveContainer 自己的 App Intents 延伸功能裡加了幾個動作，在捷徑 App 裡會顯示在「LiveContainer」底下：

| 動作 | 做什麼 | 會打開 App 嗎 |
|---|---|---|
| 開啟 LiveContainer 裡的 App | 從清單選 App 打開，可附一個網址交給 App | 會 |
| 傳送資料給 LiveContainer 裡的 App | 把文字放進 App 的收件匣 | 不會（可選完成後打開） |
| 記帳：從通知記帳 | 把通知全文交給「記帳」 | 不會（可選完成後打開） |
| 記帳：快速記一筆 | 用商家＋金額記一筆 | 不會（可選完成後打開） |

## 收件匣格式（LCShortcutInbox）

LiveContainer 不能在背景執行裝在裡面的 App 的程式碼，所以「背景」動作只是把一個 JSON 檔放進 App 的資料夾：

```
<App 的 home>/Library/LCShortcutInbox/<毫秒時間>-<uuid>.json
```

```json
{
  "version": 1,
  "id": "UUID",
  "action": "ledger.logNotification",
  "text": "通知全文",
  "params": { "accountName": "台新" },
  "createdAt": "2026-11-07T07:30:00Z",
  "source": "LiveContainer"
}
```

App 在變成前景時讀取這個資料夾（`FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]` 底下的 `LCShortcutInbox`），依檔名排序處理，處理完就刪掉檔案。

記帳用的動作代號：

- `ledger.logNotification`：`text` 是通知全文，`params.accountName` 選填
- `ledger.quickAdd`：`params.merchant`、`params.amount`（數字），`params.accountName` 選填

## 安裝注意

- 用 SideStore 安裝時要保留 App 延伸功能（Keep App Extensions），捷徑動作在延伸功能裡。
- 裝好後先打開一次 LiveContainer，捷徑才拿得到 App 清單。
- Bundle ID 和官方版一樣（`com.kdt.livecontainer`），會直接覆蓋原本的 LiveContainer，裡面的 App 和資料會保留。
