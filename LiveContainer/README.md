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

`ContentState` 欄位（除了 `title` 都可省略）：`subtitle`、`systemImage`（SF Symbol）、`progress`（0–1，顯示進度條／圓環）、`timerStart`（正數計時）、`timerEnd`（倒數）、`compactText`（動態島右邊的短字）、`tintHex`。點即時動態會打開 LiveContainer 裡的這個 App；`forCurrentApp(openURL:)` 可以指定點了之後交給 App 的網址。

限制：動態島上不能放執行 App 程式碼的按鈕（按鈕的 App Intent 會跑在 LiveContainer，不是 App 裡）。

## 主畫面／鎖定畫面小工具

裝在 LiveContainer 裡的 App 不能帶自己的小工具，所以跟即時動態同一個 widget extension 裡多了一個通用小工具「App」（小、中、鎖定畫面），不會多用 App ID：

- 小工具：`LiveActivityWidget/LCAppWidget.swift`，長按小工具 → 編輯，選要顯示哪個 App
- 格式：`LiveActivityWidget/LCWidgetSnapshot.swift`，App 把它原封不動複製進去，寫成 JSON 放在 `<LiveContainer 的 App Group>/LCWidgets/<App 的 Bundle ID>.json`
- App Group 路徑用 LiveContainer 自己的 `+[NSUserDefaults lcAppGroupPath]` 拿（用 `NSSelectorFromString` 呼叫），寫完呼叫 `WidgetCenter.shared.reloadAllTimelines()`
- `entries` 可以放好幾筆有時間的狀態（例如接下來每小時還有幾張要背），小工具時間到了自己換，App 不用在背景跑
- extension 要讀 App Group，CI 用 `LCLiveActivityWidget.entitlements` 簽 ad-hoc；SideStore 安裝時會換成 `group.com.SideStore.SideStore.<Team ID>`，小工具從 `embedded.mobileprovision` 讀真正的群組名稱

範例：EnRecall 的 `Services/LiveContainer/HomeWidgetPublisher.swift`。

## 通知

裝在裡面的 App 自己排的本地通知（`UNUserNotificationCenter`），要在 LiveContainer 的 App 設定打開「修復本地通知」才會出現，顯示成 LiveContainer 的通知。

## 補翻譯

上游有些畫面沒有繁中（例如設定 → 儲存空間管理）。翻譯放在 `strings/<語言>.json`（`{"key": "翻譯"}`，key 從上游 `Resources/Localizable.xcstrings` 找），CI 用 `scripts/merge_strings.py` 合併進去：上游已經有的翻譯不蓋掉，上游沒有的 key 會讓建置失敗（換上游版本時才會發現改名）。

## 安裝注意

- 用 SideStore 安裝時要保留 App 延伸功能（Keep App Extensions），捷徑動作和即時動態都在延伸功能裡。即時動態的 widget 是多一個延伸功能，免費帳號會多用一個 App ID。
- 裝好後先打開一次 LiveContainer，捷徑才拿得到 App 清單。
- Bundle ID 和官方版一樣（`com.kdt.livecontainer`），會直接覆蓋原本的 LiveContainer，裡面的 App 和資料會保留。
