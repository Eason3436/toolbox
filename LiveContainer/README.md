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

## 即時動態（動態島）

裝在 LiveContainer 裡的 App 跑在 LiveContainer 的程序裡，系統會把它開的即時動態當成 LiveContainer 的，並用 LiveContainer 自己的 widget extension 來畫。LiveContainer 不認得每個 App 自己的 `ActivityAttributes`，所以這個版本內建一個通用的格式 `LCLiveActivityAttributes`，App 用它就能顯示在鎖定畫面和動態島：

- widget extension：`LiveActivityWidget/`（CI 用 XcodeGen 另外編好，複製進 `LiveContainer.app/PlugIns`，Bundle ID `com.kdt.livecontainer.LiveActivity`）
- 格式：`overlay/LiveContainerSwiftUI/LCLiveActivityAttributes.swift`
- 測試：LiveContainer → App 更新 → 即時動態 → 顯示測試即時動態

App 這邊要做的：

1. 把 `LCLiveActivityAttributes.swift` 原封不動複製進 App（ActivityKit 用型別名稱配對，名字和欄位不能改）
2. App 的 Info.plist 保留 `NSSupportsLiveActivities = YES`
3. 在 LiveContainer 裡時改用這個格式：

```swift
if LCLiveActivityAttributes.isInsideLiveContainer {
    let activity = try Activity.request(
        attributes: LCLiveActivityAttributes.forCurrentApp(systemImage: "waveform", tintHex: "#FF3B30"),
        content: ActivityContent(state: .init(title: "錄音中", subtitle: "第 3 段", timerStart: startedAt), staleDate: nil),
        pushType: nil)
    // 之後用 activity.update(...) / activity.end(...)，跟一般即時動態一樣
}
```

`ContentState` 欄位（除了 `title` 都可省略）：

| 欄位 | 顯示 |
|---|---|
| `subtitle` | 第二行，例如狀態或最新一句字幕 |
| `systemImage` | SF Symbol（動態島左邊、鎖定畫面左邊的圓） |
| `progress` | 0–1，鎖定畫面進度條、動態島圓環 |
| `timerStart` / `timerEnd` | 正數計時／倒數，顯示在右邊 |
| `pausedElapsed` | 暫停：顯示固定的秒數，圖示換成暫停 |
| `isFinished` | 完成：打勾、顯示最後的值 |
| `detail` | 小字補充，例如「第 2/5 個」 |
| `levels` | 最近幾秒音量（0–1），動態島左邊畫波形 |
| `compactText` | 沒有計時和進度時，動態島右邊的短字 |
| `tintHex` | 顏色 |

點即時動態會打開 LiveContainer 裡的這個 App；`forCurrentApp(openURL:)` 可以指定點了之後交給 App 的網址。超過 90 秒沒更新時可以用 `staleDate` 讓它顯示「可能不是最新狀態」。

已經使用的 App：Recap（錄音）、Toolbox（背景處理檔案的進度）。它們各有一份 `LCLiveActivityAttributes.swift` 副本，CI 會檢查跟這裡的一模一樣。

排版照 Apple 的即時動態設計規範：動態島左邊放辨識用的圖示或波形、右邊只放一個重點數值；展開時圖示和數值留在兩側，標題和細節放下面；鎖定畫面 14 pt 邊距、高度精簡，有完成狀態和過期提示。

限制：動態島上不能放執行 App 程式碼的按鈕（按鈕的 App Intent 會跑在 LiveContainer，不是 App 裡）。

## 安裝注意

- 用 SideStore 安裝時要保留 App 延伸功能（Keep App Extensions），捷徑動作和即時動態都在延伸功能裡。即時動態的 widget 是多一個延伸功能，免費帳號會多用一個 App ID。
- 裝好後先打開一次 LiveContainer，捷徑才拿得到 App 清單。
- Bundle ID 和官方版一樣（`com.kdt.livecontainer`），會直接覆蓋原本的 LiveContainer，裡面的 App 和資料會保留。
