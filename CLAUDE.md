# CLAUDE.md

給 Claude Code 的接手說明。這個存儲庫（`Eason3436/toolbox`）是一位使用者自用的 iOS App 合集：全部用 SwiftUI 寫、用 GitHub Actions 編譯成未簽名 IPA、發佈到 GitHub Releases，再用 **SideStore** 側載到 iPhone。不上架。

使用者寫繁體中文，回覆也用繁體中文。

## 最重要的一件事：每個 App 在不同分支

`main` 有 Toolbox 和 Recap（PR #1 已合併）。其他 App 各自在以 App 命名的分支開發，**還沒合併進 main**。要改某個 App，先切到它的分支：

| App | 分支 | 原始碼 | Workflow | Release（下載連結） |
|---|---|---|---|---|
| Toolbox 工具箱 | `main` | `Toolbox/`、根目錄 `project.yml` | `build.yml` | [`latest`/Toolbox.ipa](https://github.com/Eason3436/toolbox/releases/download/latest/Toolbox.ipa) |
| Screenshots 截圖腦 | `screenshots` | `Screenshots/` | `screenshots.yml` | [`screenshots-latest`/Screenshots.ipa](https://github.com/Eason3436/toolbox/releases/download/screenshots-latest/Screenshots.ipa) |
| Recap | `main`（`recap` 分支也可用） | `Recap/` | `recap.yml` | [`recap-latest`/Recap.ipa](https://github.com/Eason3436/toolbox/releases/download/recap-latest/Recap.ipa) |
| Ledger 記帳 | `ledger` | `Ledger/` | `ledger.yml` | [`ledger-latest`/Ledger.ipa](https://github.com/Eason3436/toolbox/releases/download/ledger-latest/Ledger.ipa) |
| LiveContainer 捷徑版 | `livecontainer` | `LiveContainer/`（overlay + patches） | `livecontainer.yml` | [`livecontainer-latest`/LiveContainer.ipa](https://github.com/Eason3436/toolbox/releases/download/livecontainer-latest/LiveContainer.ipa)（另有 `LiveContainer+SideStore.ipa`） |
| HealthMi（第三方） | `healthmi` | 無，CI 直接 clone 上游 | `healthmi.yml` | [`healthmi-latest`/HealthMi.ipa](https://github.com/Eason3436/toolbox/releases/download/healthmi-latest/HealthMi.ipa) |

`ui-check` 是 Toolbox 早期的舊分支，可以忽略。`claude/project-thread-*` 是改名前的舊分支，內容已搬到上面的 App 分支，不要再用。

Release 的 tag 每次建置都會被刪掉重建（同一個 tag 永遠放最新版），release 標題會寫是哪個 commit。

## 各 App 功能

### Toolbox 工具箱（`main`）
檔案工具：把檔案丟進來，自動判斷類型、列出能做的事，全部離線。
- 圖片：比例裁切（含 XPan 65:24）、轉檔、壓縮、縮放、移除 EXIF/位置、OCR、去背、QR、拼長圖、轉 PDF 等
- 原況照片：移除影片部分但保留編輯、景深、時間地點
- 影片／音訊：壓縮、轉檔、剪輯、擷取音訊、轉 GIF、語音轉文字（SRT）
- PDF：轉 Markdown、合併、拆分、轉圖、加解密碼
- 文件（MD/HTML/TXT/CSV/JSON/Office）：轉 PDF、DOCX、Markdown、繁簡轉換、修亂碼
- **功能包**：JSON 檔把內建積木串成新功能，不用重新打包（格式見 `README.md`）
- 捷徑／Siri（`Toolbox/Intents`）、長時間工作用 `BGContinuedProcessingTask`（系統 Live Activity）
- 結構：`Engine/`（積木註冊、功能包）、`Operations/`（各類處理）、`Views/`、`Services/`
- iOS 26 起；Bundle ID `com.eason3436.toolbox`；Swift 5

### Screenshots 截圖腦（`Screenshots/`）
AI 截圖管理（對標 Pixel Screenshots），完全離線：PhotoKit 同步截圖 → Vision OCR + Foundation Models（圖片輸入）分析標題與分類 → 搜尋、自然語言問答（附來源截圖）、收藏集自動規則、Share Extension、App Intents。
- iOS 27、Swift 6、SwiftData；target：App + `ShareExtension`（`com.eason3436.screenshots.share`）+ 單元測試
- App Group 透過 SideStore 的 `ALTAppGroups` 取得；CI 用 ad-hoc 簽名嵌入 entitlements
- 6 個階段都完成（2026-11-03）。`Screenshots/README.md` 有逐階段檔案表與驗收步驟
- Workflow 只能手動觸發（workflow_dispatch）

### Recap（`Recap/`）
全天錄音 → 裝置端轉文字 → AI 每日摘要，加上課堂模式。
- 背景錄音（AVAudioEngine，5 分鐘一段 m4a，中斷自動恢復）、SpeechAnalyzer 轉錄、Foundation Models 分段摘要 → 每日 Recap
- 課堂模式：英文即時字幕＋中文即時翻譯；中文課只錄音，下課後轉錄。課表（使用者自己貼上，不要寫死在程式裡，repo 是公開的）決定科目，課後筆記
- AI 供應者：Apple 裝置端 / Gemini（免費額度）；Groq Whisper（免費額度，有每日分鐘上限）提升辨識
- 追問（附引用來源）、Siri App Intents、Live Activity／動態島（widget extension `com.eason3436.recap.widget`）、匯入音訊、完整備份還原（`.recapbackup`）、更新紀錄頁 `Views/ChangelogView.swift`（每次更新加一筆）
- Supabase 同步（`Recap/supabase/schema.sql`、`Services/RecapSync.swift`）程式已寫好，但使用者 2026-11-06 說先不用，預設關閉、表也沒建
- iOS 27、**Swift 5 語言模式**（刻意選的，避免音訊 tap callback 的 Swift 6 isolation crash）
- HealthMi 曾經內嵌在 Recap，已移除（免費帳號拿不到 HealthKit 權限），除非使用者要求不要加回去

### Ledger 記帳（`Ledger/`）
原生 SwiftUI 記帳 App，參考 Cashew 的設計，Liquid Glass。
- 分頁：首頁／明細（列表⇄月曆）／分析／規劃／資產，加浮動 ＋（記一筆、一句話記帳、掃發票）
- 捷徑 App Intent「從通知記帳」：iOS 27 捷徑的「通知」自動化把銀行通知交給 App，Foundation Models 解析商家／金額／分類（失敗退回正規式）；另有「快速記一筆」、「更新資產報價」
- 資產：Yahoo Finance 報價（台股 2330 → .TW/.TWO）＋匯率；帳單（含自動扣款、收入帳單）
- 掃發票（Vision OCR，只存文字不存照片）、MapKit 商家卡片／分店比對、AI 自動分類、Cashew `.sql` 備份匯入、iCloud Drive 資料夾同步（`記帳同步.json`，只合併新增；SideStore 簽名用不了 CloudKit）
- 主題色可選（12 組配色＋自訂）；圖示用 PulsoIcon（ISC），**只 vendor 用到的約 99 個**在 `Ledger/Ledger/Vendor`，整包加進來會讓編譯超過 20 分鐘
- 使用者偏好：介面安靜、少「AI」字眼、要圖表不要長文字、Tab bar 用原生的
- iOS 27、Swift 5、SwiftData；`com.eason3436.ledger`
- CI 注意：長的 tuple／三元運算鏈會讓 Swift 型別檢查逾時，拆成有型別的 helper

### LiveContainer 捷徑版（`LiveContainer/`）
[LiveContainer](https://github.com/LiveContainer/LiveContainer)（AGPL-3.0）的修改版。使用者把自己的 App 裝在 LiveContainer 裡跑，但裝在裡面的 App 的捷徑動作系統看不到，所以在 LiveContainer 自己的 App Intents 延伸功能加了動作：開啟裡面的 App、傳資料到 App 收件匣、記帳：從通知記帳／快速記一筆。背景動作把 JSON 放到 `<guest home>/Library/LCShortcutInbox/`，Ledger 回到前景時讀取（`Ledger/Ledger/Services/LiveContainerInbox.swift`）。另加「App 更新」：比對 GitHub release asset 的 `updated_at`，一鍵更新上面這些 App。
- 新檔案放 `overlay/`（複製進上游），修改用 `patches/*.patch`（git apply）；上游 commit 釘在 `9108ae6`，可用 workflow_dispatch 輸入換
- Bundle ID 跟官方一樣（`com.kdt.livecontainer`），會覆蓋原本的；安裝時要選「保留 App 延伸功能」
- 細節見 `LiveContainer/README.md`

### HealthMi（只有 workflow）
第三方開源 App [ShawnDiego/HealthMi](https://github.com/ShawnDiego/HealthMi)（Apache-2.0，小米運動健康 → Apple 健康）。`healthmi.yml` clone 上游、xcodegen、ad-hoc 簽 HealthKit entitlement 後打包。手動觸發時可用 `ref` 指定上游版本。注意：SideStore 免費帳號會把 HealthKit entitlement 拿掉。

## 建置與發佈

- 專案檔都用 **XcodeGen**（各 App 資料夾裡的 `project.yml`），不要提交 `.xcodeproj`
- **沙盒裡沒有 Swift／Xcode，CI 就是編譯器**。改完 push，看 Actions 結果；失敗就讀 build log 修
- Runner：Recap、Screenshots、Ledger、HealthMi 用 `xcode-27`（iOS 27 SDK）；Toolbox、LiveContainer 用 `macos-26`（Toolbox 會自動挑最新的 Xcode）
- 觸發：
  - `build.yml`（Toolbox）沒有路徑篩選，**每個分支的每次 push 都會跑**；只有 push 到 `main` 才更新 `latest` release
  - `recap.yml`、`ledger.yml`：push 改到各自資料夾時跑，也可手動
  - `screenshots.yml`：只能手動
  - `livecontainer.yml`、`healthmi.yml`：改到 workflow 本身（或 `LiveContainer/**`）時跑，也可手動並指定上游 ref
  - GitHub 的 push 事件偶爾沒觸發，用 workflow_dispatch 手動跑；macOS job 偶爾沒拿到 runner 被取消，重跑即可
- Recap、Screenshots、Ledger 的 workflow 會在模擬器跑單元測試

## 給使用者 IPA 的規則

每次編譯完，**一律附 GitHub Releases 下載連結**：
`https://github.com/Eason3436/toolbox/releases/download/<tag>/<檔名>.ipa`（上面表格那幾條），並說明目前是哪個 commit／版本。

## 限制與慣例

- **SideStore 免費 Apple ID**：同時最多 3 個 App、每 7 天 10 個 App ID（每個 extension 也算一個）、7 天要重簽。新增 extension 前要想清楚
- SideStore 不接受非 ASCII 的 App 名稱，`CFBundleName`／`CFBundleDisplayName` 要用英文（例如 Toolbox，不是工具箱）
- 不能用 CloudKit、HealthKit 等需要付費帳號的權限
- **使用者不付費 API**（包括 Claude API）。可以用 Apple 裝置端模型（Foundation Models）、Gemini 免費額度、Groq 免費額度
- 盡量用 Apple 原生框架，不加第三方套件（例外要先問使用者，例如 PulsoIcon）
- App 圖示用 Icon Composer 格式（`AppIcon.icon`，Liquid Glass）
- 使用者喜歡 Apple 原生、HIG 風格的介面，不要「AI 感」
- Bundle ID 前綴 `com.eason3436.`
