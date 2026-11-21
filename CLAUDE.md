# CLAUDE.md

給 Claude Code 的接手說明。這個存儲庫（`Eason3436/toolbox`）是一位使用者自用的 iOS App 合集：全部用 SwiftUI 寫、用 GitHub Actions 編譯成未簽名 IPA、發佈到 GitHub Releases，再用 **SideStore** 側載到 iPhone。不上架。

使用者寫繁體中文，回覆也用繁體中文。

## 分支：所有 App 都在 main

2026-11-08 起，所有 App 都已合併進 `main`，各自在自己的資料夾。下表的「App 分支」是合併當下的快照，之後不會自動更新；新工作直接從 `main` 開分支、改完開 PR 合回 `main`。

| App | App 分支 | 原始碼 | Workflow | Release（下載連結） |
|---|---|---|---|---|
| Toolbox 工具箱 | `main` | `Toolbox/`、根目錄 `project.yml` | `build.yml` | [`latest`/Toolbox.ipa](https://github.com/Eason3436/toolbox/releases/download/latest/Toolbox.ipa) |
| Screenshots 截圖腦 | `screenshots` | `Screenshots/` | `screenshots.yml` | [`screenshots-latest`/Screenshots.ipa](https://github.com/Eason3436/toolbox/releases/download/screenshots-latest/Screenshots.ipa) |
| Recap | `recap` | `Recap/` | `recap.yml` | [`recap-latest`/Recap.ipa](https://github.com/Eason3436/toolbox/releases/download/recap-latest/Recap.ipa) |
| Ledger 記帳 | `ledger` | `Ledger/` | `ledger.yml` | [`ledger-latest`/Ledger.ipa](https://github.com/Eason3436/toolbox/releases/download/ledger-latest/Ledger.ipa) |
| Ledger 磁力特別版 | `main` | `LedgerMagnet/` | `ledger-magnet.yml` | [`ledger-magnet-latest`/LedgerMagnet.ipa](https://github.com/Eason3436/toolbox/releases/download/ledger-magnet-latest/LedgerMagnet.ipa) |
| LiveContainer 捷徑版 | `livecontainer` | `LiveContainer/`（overlay + patches） | `livecontainer.yml` | [`livecontainer-latest`/LiveContainer.ipa](https://github.com/Eason3436/toolbox/releases/download/livecontainer-latest/LiveContainer.ipa)（另有 `LiveContainer+SideStore.ipa`） |
| EnRecall 背單字 | `main` | `EnRecall/` | `enrecall.yml` | [`enrecall-latest`/EnRecall.ipa](https://github.com/Eason3436/toolbox/releases/download/enrecall-latest/EnRecall.ipa) |
| Sweep 相簿清理 | `main` | `Sweep/` | `sweep.yml` | [`sweep-latest`/Sweep.ipa](https://github.com/Eason3436/toolbox/releases/download/sweep-latest/Sweep.ipa) |
| DrivePlayer 雲端播放器 | `main` | `DrivePlayer/` | `driveplayer.yml` | [`driveplayer-latest`/DrivePlayer.ipa](https://github.com/Eason3436/toolbox/releases/download/driveplayer-latest/DrivePlayer.ipa) |
| HealthMi（第三方） | `healthmi` | 無，CI 直接 clone 上游 | `healthmi.yml` | [`healthmi-latest`/HealthMi.ipa](https://github.com/Eason3436/toolbox/releases/download/healthmi-latest/HealthMi.ipa) |

`ui-check` 是 Toolbox 早期的舊分支，可以忽略。`claude/project-thread-*` 是改名前的舊分支，內容都已在 `main`，不要再用。

Release 的 tag 每次建置都會被刪掉重建（同一個 tag 永遠放最新版），release 標題會寫是哪個 commit。

## 各 App 功能

### Toolbox 工具箱（`main`）
檔案工具：把檔案丟進來，自動判斷類型、列出能做的事，全部離線。
- 圖片：比例裁切（含 XPan 65:24）、轉檔、壓縮、縮放、移除 EXIF/位置、OCR、去背、QR、拼長圖、轉 PDF 等
- 原況照片：移除影片部分但保留編輯、景深、時間地點
- 影片／音訊：壓縮、轉檔、剪輯、擷取音訊、轉 GIF、語音轉文字（SRT）
- **4K 轉 1080p（保留空間音訊）**：獨立畫面 `Views/DownscaleView.swift`（首頁 ＋ 選單／空白首頁）。PHPicker `.current` 拿原檔 → AVAssetReader/Writer 自己組（不用 ExportSession），影像 HEVC 1080p、音訊與 timed metadata passthrough；碼率規則在 `Operations/Downscale/BitrateCalculator.swift`，單元測試在 `ToolboxTests/`
- PDF：轉 Markdown、合併、拆分、轉圖、加解密碼
- 文件（MD/HTML/TXT/CSV/JSON/Office）：轉 PDF、DOCX、Markdown、繁簡轉換、修亂碼
- **功能包**：JSON 檔把內建積木串成新功能，不用重新打包（格式見 `README.md`）
- 捷徑／Siri（`Toolbox/Intents`）、長時間工作用 `BGContinuedProcessingTask`（系統 Live Activity）；在 LiveContainer 裡另外用 LC 通用即時動態顯示進度（`Toolbox/LiveContainer/`，`LCLiveActivityAttributes.swift` 從 `LiveContainer/overlay` 原封不動複製，改了要兩邊一起改）
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
- 記一筆鍵盤的「記下」用 DistortionWavesKit（MIT，SPM `Jakubantalik/Libraries.dev` main 分支，使用者 2026-11-11 要求加的）：表單有 UIKit 元件，先拍快照當波浪前一頁（`Views/Components/SaveWave.swift`）
- 主題色可選（12 組配色＋自訂）；圖示用 PulsoIcon（ISC），**只 vendor 用到的約 99 個**在 `Ledger/Ledger/Vendor`，整包加進來會讓編譯超過 20 分鐘
- 使用者偏好：介面安靜、少「AI」字眼、要圖表不要長文字、Tab bar 用原生的
- iOS 27、Swift 5、SwiftData；`com.eason3436.ledger`
- CI 注意：長的 tuple／三元運算鏈會讓 Swift 型別檢查逾時，拆成有型別的 helper
- 更新日誌：`Ledger/Ledger/Views/Settings/ChangelogView.swift`（設定 → 版本）。每次更新加一筆並同步改 `Ledger/project.yml` 的 `MARKETING_VERSION`：大改版動第一碼、新功能動第二碼、只有修正動第三碼

### Ledger 磁力特別版（`LedgerMagnet/`）
2026-11-13 從 `Ledger/`（1.16.1）整包複製出來的另一個 App：磁鐵靠近 iPhone 時，卡片、分類圖示、列表列、膠囊、按鈕被吸過去，拿開彈回。
- 用 iPhone 自己的磁力計（CoreMotion），扣掉地磁後估計磁鐵位置；四個邊的校正存在 UserDefaults。沒用 magnetkit（那是 React 網頁套件，iPhone 不能用）
- 程式在 `LedgerMagnet/Ledger/Magnet/`：`MagnetMath`（純數學、有單元測試）、`MagnetField`（感測器）、`Magnetic`（`.magnetic()` modifier、光暈）、`MagnetSettingsView`（設定 → 磁力、校正）
- Bundle ID `com.eason3436.ledger.magnet`、顯示名稱 Magnet；資料跟原本的記帳分開。原本 `Ledger/` 的修正不會自動同步過來
- `MARKETING_VERSION` 從 1.17.0 起算，更新日誌一樣在 `Views/Settings/ChangelogView.swift`

### LiveContainer 捷徑版（`LiveContainer/`）
[LiveContainer](https://github.com/LiveContainer/LiveContainer)（AGPL-3.0）的修改版。使用者把自己的 App 裝在 LiveContainer 裡跑，但裝在裡面的 App 的捷徑動作系統看不到，所以在 LiveContainer 自己的 App Intents 延伸功能加了動作：開啟裡面的 App、傳資料到 App 收件匣、記帳：從通知記帳／快速記一筆。背景動作把 JSON 放到 `<guest home>/Library/LCShortcutInbox/`，Ledger 回到前景時讀取（`Ledger/Ledger/Services/LiveContainerInbox.swift`）。另加「App 更新」：比對 GitHub release asset 的 `updated_at`，一鍵更新上面這些 App。另加即時動態：裡面的 App 用通用格式 `LCLiveActivityAttributes` 開即時動態，由 `LiveContainer/LiveActivityWidget/`（CI 另外用 XcodeGen 編、複製進 PlugIns）畫在動態島。
- 新檔案放 `overlay/`（複製進上游），修改用 `patches/*.patch`（git apply）；上游 commit 釘在 `9108ae6`，可用 workflow_dispatch 輸入換
- Bundle ID 跟官方一樣（`com.kdt.livecontainer`），會覆蓋原本的；安裝時要選「保留 App 延伸功能」
- 細節見 `LiveContainer/README.md`

### EnRecall 背單字（`EnRecall/`）
給使用者家人用的學測背單字 App（使用者另有一個 EnRecall 網頁／Android 版，資料在他自己的 Supabase）。依「EnRecall iOS 版 開發規劃書」分 M1–M6 做。
- 從單字商店下載學測 Level 1–6、學測片語總表 → FSRS 複習；Claude App 透過 MCP 連接器把單字丟進收件匣，App 打開時領取
- **絕對不能修改、刪除或寫入使用者既有 EnRecall Supabase 專案的資料表**（另一個帳號；ref 不寫在公開 repo，要用時以 Supabase MCP 的 list_projects 查或問使用者）。要動資料表先問使用者
- **這個 repo 是公開的：專案 ref、網址、金鑰、密碼、使用者個人資料都不能進 repo（含 commit 訊息）**。2026-11-17 已改寫整個 git 歷史把它們清掉。單字包在 EnRecall 專案的 Storage bucket `packs`（0.17.0 起改私有）：App 經過 iOS 後端的 Edge Function `enrecall-packs` 下載，要帶使用者在 App 輸入的下載密碼（`Services/StoreAccess.swift`，存 Keychain），規格在 `EnRecall/supabase/DEPLOY-6.md`。2026-11-18 起單字庫改成**複製一份**到 iOS 後端自己的私有 bucket `packs`，`enrecall-packs`／`enrecall-mcp` 只讀自己專案（`EnRecall/supabase/DEPLOY-7.md`，App 不用改）。這份就是 iOS 單字庫唯一的來源：使用者 2026-11-18 說不會再更新原本的單字庫、也不會再動 Android／網頁版 EnRecall 的 GitHub，所以不用同步，也不要再去讀或改 EnRecall 專案和 Android 版的 repo
- iOS 後端（`ios_devices`、`ios_inbox`、配對碼 RPC、Edge Function `enrecall-mcp`）放在**另一個帳號的新 Supabase 專案**，由使用者的 Muse 部署；規劃書在 `EnRecall/supabase/DEPLOY.md`。網址與 anon key 放在 GitHub Actions Secrets（`ENRECALL_SUPABASE_HOST`、`ENRECALL_SUPABASE_ANON_KEY`），CI 寫成 `Config/Secrets.xcconfig`（gitignore）讓 `App.xcconfig` include；沒設 secrets 時從目前發佈的 `EnRecall.ipa` 的 Info.plist（`ERSupabaseHost`、`ERSupabaseAnonKey`）讀回同一組值；連那個也讀不到才只編譯測試、不發 release
- App 內不整合 AI、不登入、不做雲端同步；不做新手引導，空狀態只有一行字
- UI 照設計稿 https://claude.ai/artifact/JenUMptsrMx7mLauGdTiKh ；顏色全部在 Assets 的 colorset（`Color.er.*`，`DesignSystem/Theme.swift`），畫面程式碼不准有 hex、`Color.white`、`Color.black`；玻璃只用在控制層；每個畫面都要淺色、深色兩個 `#Preview`（`PreviewData` 的 in-memory container）
- 沒用 supabase-swift，網路都用 URLSession
- iOS 27、Swift 5、SwiftData；`com.eason3436.enrecall`；只有 App 本體（widget 在 M6 才加，要用 SideStore 的 ALTAppGroups）
- 進度：M1–M5 完成（2026-11-16）：商店下載 .json.gz 自己解壓（`Services/PackLibrary.swift`）、FSRS-5 排程（`Services/FSRSScheduler.swift`）、複習存檔與復原、從 Claude 匯入。M6（通知、桌面小工具）待做。更新單字包只改字義例句、不動 FSRS；已從 Claude 匯入的單字庫字留在原牌組。單字完整內容（搭配、句型、近義／反義、易混淆、相似字比較 `similar-levelN.json`、常見錯誤、字源）以 JSON 存在另一個 model `CardContent`（不要放回 Card：統計會把所有卡讀進來，會讓評分卡頓；`Models/CardDetail.swift` 寬鬆解碼）；改格式就把 `PackInstaller.contentFormat` 加 1，App 啟動時會在背景重裝舊格式的包、進度不動。複習頁用自己的 ModelContext，關閉／切背景才存檔；卡片背面用分頁顯示完整內容，上方時間軸可回頭看、改評分，「混合／新字／複習」切換。更新日誌：`EnRecall/EnRecall/Features/Settings/ChangelogView.swift`（設定 → 關於 → 更新日誌），每次更新在最上面加一筆並同步改 `EnRecall/project.yml` 的 `MARKETING_VERSION`。主畫面分頁列只放圖示（使用者要求）。例句裡的目標字用 `Services/Highlighter.swift`（含變化形）加螢光底色。學習紀錄：`Services/StudySnapshot.swift` 回到前景／進背景／複習存檔後呼叫 RPC `ios_push_snapshot` 整份上傳（設定可關），MCP 的 overview／analyze_learning／list_words／get_words／read_docs（PDF 講義）規格在 `EnRecall/supabase/DEPLOY-3.md`，由 Muse 部署。測驗（`Features/Quiz/QuizView.swift`、`Services/QuizBuilder.swift`）：中翻英／英文填空用單字包的 `quiz-levelN.json`（存在 `CardDetail.quiz`），片語、句型用例句挖空；不改 FSRS，只有「答錯的字排進今天的複習」會把到期日提前。句型卡：`DeckCategory.pattern`，內容 `Models/PatternDetail.swift` 存在 `CardContent`，從收件匣 `kind = 'pattern'` 匯入；後端句型庫 `ios_patterns` 與 MCP `lookup_patterns`／`add_patterns`／`list_patterns` 規格在 `EnRecall/supabase/DEPLOY-4.md`。複習時切換混合／新字／複習只影響下一張起。卡片背面單字下面的「≠ 易混淆字」：`Services/Lookalikes.swift`，先用單字包的 confusables／similar，再用編輯距離從自己牌組找拼字像的字（不用向量模型），複習開始時在背景建索引。發音：`Services/SpeechService.swift`，設定 › 發音（`Features/Settings/VoicePickerView.swift`）選聲音（`speechVoice` 存 identifier，空＝自動挑最好的 en-US）和語速（`speechRate`，預設語速的倍數）；Siri 聲音 Apple 不開放給 App。字典（`Features/Dictionary/DictionaryView.swift`）：大搜尋框，按搜尋才查（單字／片語／句型分組），沒搜尋時推薦幾個字；旁邊的按鈕拍照或選照片 → `Services/PhraseSpotter.swift`（Vision 認字＋比對片語總表與句型卡，不用 AI）→ `PhraseScanView`。一張卡多個牌組（0.12.0）：`Card.deck` 是原本的牌組，放進別的牌組用 `Models/DeckLink.swift`（`Deck.activeCards` 含連過來的卡、`orderedActiveCards` 照牌組自己的順序）；收件匣送來 App 已有的字會連過去，不再略過；原本的牌組不能移除；快照多 `cards[].decks`、`card_ids`，MCP 規格在 `EnRecall/supabase/DEPLOY-5.md`。單字 PDF（0.13.0，跟 Android 版一樣的講義／自測卷／速查表，App 裡自己產生、不經過 Claude）：`Services/Handout/`（`HandoutBuilder` 挑字、`HandoutHTML` 排版、`PDFRenderer` 用 WKWebView 印成 A4 加頁尾），畫面 `Features/Handout/HandoutView.swift`；首頁「產生」照上次設定一鍵做好、QuickLook 預覽。從 Claude 匯入的牌組與單字不標來源（使用者要求）。0.14.0：PDF 版面改成自己的（使用者要求不要跟 Android 一樣）：講義雙欄字卡、自測卷答案在右邊折起來那欄、速查表照熟悉度分組，強調色 `HandoutStyle` 跟著 App 配色。配色主題（設定 → 外觀）：`AppPalette`＋`@Observable ERPalette`（`Color.er` 讀到的顏色會被 Observation 追蹤，換主題整個 App 重畫），色票取自設計師公開的配色（Nord、Rosé Pine、Everforest、Flexoki、Radix Sand＋Bronze、Gruvbox Material、Solarized、Iceberg、Melange），`EnRecall/scripts/palettes.py` 產生 `Assets.xcassets/Themes/<名稱>/`，要改色改腳本重跑，不要手改 colorset；大面積底色（背景、卡片、框線、首頁深色卡）在腳本裡用 OKLCH 壓彩度（淺色 C≤0.012、深色 ≤0.026，使用者說背景不要太黃）。牌組卡的暫停是分段選擇旁邊獨立一顆鍵（`Deck.isPaused`／`runMode`，`resumeModeRaw` 記暫停前的模式）。自訂牌組可「新卡一次出完」（`Deck.newCardsAll`，0.16.2：不看每天新卡、也不佔全部上限；使用者說背雜誌不分一天幾個字，從 Claude 匯入的新牌組預設打開）。首頁、牌組頁的今日數字用 `Services/StudySummaryCache.swift`：卡片讀成值存起來，只在 Card／ReviewLog／DeckLink 存檔（`ModelContext.didSave`）後重讀，改牌組設定只重算；牌組卡的進度數字拆成子 View，按鍵才不會卡（以前每按一下就重讀幾千張卡）。評分鍵（`RatingBar`）：同一塊玻璃用 `glassEffectID` 分開／融回上次按的那顆，跟卡片、時間軸共用 `RatingBar.morph`。分頁列不縮小（`.tabBarMinimizeBehavior(.never)`，使用者要求）。App 圖示（0.16.0）：灰藍底、斜放的後卡＋白色字卡上一個順時針循環箭頭（`AppIcon.icon/Assets/front.svg` 由弧線＋折線箭頭組成）。M6（0.15.0）：App 裝在 **LiveContainer** 裡（使用者說的），所以通知、小工具都要經過 LiveContainer：每日提醒 `Services/ReminderScheduler.swift` 每次用完 App 就排好接下來 7 天（字數用 `StudyForecast` 預估，沒字要背的那天不排），要在 LiveContainer 打開這個 App 的「修復本地通知」；桌面小工具不在 EnRecall 裡，是 LiveContainer 的通用小工具 `LiveContainer/LiveActivityWidget/LCAppWidget.swift`（跟即時動態同一個 extension），EnRecall 用 `Services/LiveContainer/HomeWidgetPublisher.swift` 把 `LCWidgetSnapshot`（從 LiveContainer 原封不動複製）寫到 LiveContainer 的 App Group `LCWidgets/`

### Sweep 相簿清理（`Sweep/`）
依使用者的「照片／影片清理 App 開發規劃書（自用版）」做的相簿清理 App（2026-11-17）。照片頁每次隨機抽一組，先攤成扇子從底部浮上來（`FanView`），點一下用 zoom 轉場（fullScreenCover，不要改回 push：藏分頁列會讓返回時排版跳）進整理畫面（`PhotoDeckView`）：往左下一張、往右上一張、按住往上拖時假動態島變大、放開吸進動態島（`Features/Shared/DynamicIsland.swift`，在動態島位置畫純黑膠囊）、可復原、兩指捏小看前後 3 天（`DayGridView`）；影片頁是直向分頁短影音（最多 3 個 `AVPlayer`）。刪除一律「先標記、再批次刪除」（`Services/DeletionQueue.swift`），系統確認視窗只跳一次。
- 分類：照片／截圖／自拍／原況照片／動圖（自拍、動圖用系統智慧相簿）；統計只分照片、截圖、影片三類
- SwiftData：`ViewedAsset`（`assetID`、`wasDeleted`；`id`／`isDeleted` 會跟 SwiftData 撞名）、`CleanStats`；設定用 `@AppStorage`（`Services/Settings.swift`）
- 照片資訊在卡片背面：點照片或下方膠囊翻面（`PhotoInfoView`，往上拖是刪除，所以不是往上拉；背面一直掛著、資訊在背景先讀、地圖用 MKMapSnapshotter，翻面才不卡）；後面那張平常淡、模糊，拖動時才變清楚；影片照原比例放在狀態列和進度條之間，其餘用同一個 AVPlayer 的第二個 layer 放大＋模糊填滿；照片分頁整個用深色配色（背景是模糊照片壓暗）；地名用 `MKReverseGeocodingRequest`
- iOS 27、Swift 5；`com.eason3436.sweep`；只有 App 本體，沒有 extension
- 更新日誌：`Sweep/Sweep/Features/Settings/ChangelogView.swift`（統計 → 齒輪 → 更新日誌），每次更新加一筆並同步改 `Sweep/project.yml` 的 `MARKETING_VERSION`
- 細節、跟規劃書不同的地方、驗收步驟見 `Sweep/README.md`

### DrivePlayer 雲端播放器（`DrivePlayer/`）
依使用者的「DrivePlayer 開發規劃書（第一階段：MP4／MOV）」做的 Google Drive 影音播放器（類似 Infuse）。M0–M6 都寫完（2026-11-21），實機驗收待使用者確認。
- 播放：AVPlayer → `LocalStreamProxy`（NWListener 只聽 127.0.0.1，每個請求帶最新 token 轉送 Range 到 Drive；token 一小時過期，不能直接塞進 AVURLAsset）。`PlaybackEngine` protocol 是給第二階段 MPVKit（MKV）預留的
- `Packages/Core`：純 Swift（不准 import UIKit／AVFoundation／SwiftUI／SwiftData），沙盒可以裝 Linux 版 Swift 跑 `swift test`（`curl` swift.org 的 ubuntu24.04 tarball 解到 /opt/swift）；CI 另外在 ubuntu-latest 跑
- Google 登入（GoogleSignIn-iOS，SPM，規劃書唯一允許的第三方套件）：`GOOGLE_CLIENT_ID`、`GOOGLE_REVERSED_CLIENT_ID` 放 Actions Secrets，CI 寫成 `Config/Secrets.xcconfig`（gitignore），沒設也照樣編譯、App 內顯示原因
- **TMDB API Key 不編進 IPA**（使用者 2026-11-21 要求不要公開；Release 是公開的）：在 App「設定 → TMDB」輸入，`/configuration` 檢查後存鑰匙圈（`Util/Keychain.swift`）。不要再把它加回 Secrets／Info.plist
- **Bundle ID 是 `com.yueze.driveplayer`**（規劃書指定，Google OAuth iOS 用戶端綁這個），不是 `com.eason3436.` 前綴；使用者照規劃書用 Sideloadly（不改 Bundle ID）安裝
- iOS 18 起、**Swift 6 語言模式**（strict concurrency complete）；SwiftData 存在 `Application Support/DrivePlayer.store`
- 細節、跟規劃書不同的地方、驗收步驟見 `DrivePlayer/README.md`

### HealthMi（只有 workflow）
第三方開源 App [ShawnDiego/HealthMi](https://github.com/ShawnDiego/HealthMi)（Apache-2.0，小米運動健康 → Apple 健康）。`healthmi.yml` clone 上游、xcodegen、ad-hoc 簽 HealthKit entitlement 後打包。手動觸發時可用 `ref` 指定上游版本。注意：SideStore 免費帳號會把 HealthKit entitlement 拿掉。

## 建置與發佈

- 專案檔都用 **XcodeGen**（各 App 資料夾裡的 `project.yml`），不要提交 `.xcodeproj`
- **沙盒裡沒有 Swift／Xcode，CI 就是編譯器**。改完 push，看 Actions 結果；失敗就讀 build log 修
- Runner：Recap、Screenshots、Ledger（含磁力特別版）、EnRecall、Sweep、DrivePlayer、HealthMi 用 `xcode-27`（iOS 27 SDK）；Toolbox、LiveContainer 用 `macos-26`（Toolbox 會自動挑最新的 Xcode）
- 觸發：
  - `build.yml`（Toolbox）只忽略 `Screenshots/**`、`Ledger/**`、`LedgerMagnet/**`、`EnRecall/**`、`Sweep/**`、`DrivePlayer/**` 和它們的 workflow，其他改動在**每個分支的每次 push 都會跑**；只有 push 到 `main` 才更新 `latest` release
  - `recap.yml`、`ledger.yml`、`ledger-magnet.yml`、`enrecall.yml`、`sweep.yml`、`driveplayer.yml`：push 改到各自資料夾時跑，也可手動
  - `screenshots.yml`：只能手動
  - `livecontainer.yml`、`healthmi.yml`：改到 workflow 本身（或 `LiveContainer/**`）時跑，也可手動並指定上游 ref
  - GitHub 的 push 事件偶爾沒觸發，用 workflow_dispatch 手動跑；macOS job 偶爾沒拿到 runner 被取消，重跑即可
- Recap、Screenshots、Ledger、EnRecall、Sweep 的 workflow 會在模擬器跑單元測試

## 給使用者 IPA 的規則

每次編譯完，**一律附 GitHub Releases 下載連結**：
`https://github.com/Eason3436/toolbox/releases/download/<tag>/<檔名>.ipa`（上面表格那幾條），並說明目前是哪個 commit／版本。

## 限制與慣例

- **SideStore 免費 Apple ID**：同時最多 3 個 App、每 7 天 10 個 App ID（每個 extension 也算一個）、7 天要重簽。新增 extension 前要想清楚
- SideStore 不接受非 ASCII 的 App 名稱，`CFBundleName`／`CFBundleDisplayName` 要用英文（例如 Toolbox，不是工具箱）
- 不能用 CloudKit、HealthKit 等需要付費帳號的權限
- **SwiftData 不要用預設的 `default.store`**（`.modelContainer(for:)`、沒給 url 的 `ModelConfiguration`）：預設會放進 App Group，在 LiveContainer 裡就是 LC 的 App Group，所有 App 共用同一個檔案，輪流打開會互相把資料表遷移掉（2026-11-18 EnRecall、Sweep 因此掉資料）。一律用 `ModelConfiguration(schema:url:)` 指到 App 自己 Application Support 裡、有 App 名稱的檔案（見 `EnRecall/EnRecall/App/AppDatabase.swift`）
- **使用者不付費 API**（包括 Claude API）。可以用 Apple 裝置端模型（Foundation Models）、Gemini 免費額度、Groq 免費額度
- 盡量用 Apple 原生框架，不加第三方套件（例外要先問使用者，例如 PulsoIcon）
- App 圖示用 Icon Composer 格式（`AppIcon.icon`，Liquid Glass）
- 使用者喜歡 Apple 原生、HIG 風格的介面，不要「AI 感」
- 動畫要有目的（回饋、引導、維持空間脈絡），時間要短，而且可以中斷（用 SwiftUI 的 spring／`withAnimation`，不要用固定延遲串動畫）
- 方向用 leading／trailing，不要用 left／right；有方向性的圖示（返回、播放進度、箭頭）要能在 RTL 語系鏡像。數字、金額、日期與時間軸用 `formatted()`／`FormatStyle` 依語系處理，不要手動拼字串
- 觸覺回饋用系統的 `sensoryFeedback`／`UIFeedbackGenerator`（success、warning、error、selection、impact），要跟視覺事件同步，不要過度使用
- Bundle ID 前綴 `com.eason3436.`
