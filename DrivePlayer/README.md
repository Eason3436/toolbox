# DrivePlayer

自用的 iOS 影音播放器（類似 Infuse／VidHub），片源是自己的 Google Drive。第一階段支援 `.mp4`、`.m4v`、`.mov`，用 Apple 原生的 AVPlayer 播放，杜比視界、HDR、E-AC3 全景聲都交給系統處理。

- iOS 18 以上、iPhone；Swift 6、SwiftUI、SwiftData、AVKit
- Bundle ID：`com.yueze.driveplayer`
- 下載：<https://github.com/Eason3436/toolbox/releases/download/driveplayer-latest/DrivePlayer.ipa>

## 安裝（Windows + Sideloadly）

1. 下載上面的 `DrivePlayer.ipa`（或 GitHub → Actions → 最新一次成功的「Build DrivePlayer IPA」→ Artifacts → `DrivePlayer-ipa`）
2. 用 Sideloadly 拖入 `.ipa`，輸入 Apple ID 後安裝。**不要勾選更改 Bundle ID**（Google 登入是綁在 `com.yueze.driveplayer` 上的）
3. iPhone：「設定 → 一般 → VPN 與裝置管理」信任開發者，並開啟「開發者模式」
4. 免費 Apple ID 每 7 天要用 Sideloadly 重新簽一次

> 用 SideStore 也可以裝，但 SideStore 會在 Bundle ID 後面加上 Team ID。如果之後 Google 登入失敗，請改用 Sideloadly，或在 Google Cloud 再建一個 iOS 用戶端、Bundle ID 填 SideStore 改過的那個。

## 第一次設定（只要做一次）

1. **Google Cloud Console**
   1. 建立專案 → 啟用「Google Drive API」
   2. OAuth 同意畫面：類型「外部」，狀態維持「測試中」，把自己的 Gmail 加進測試使用者
   3. 建立 OAuth 用戶端 ID：類型 **iOS**，Bundle ID 填 `com.yueze.driveplayer`
   4. 記下 Client ID（`xxxx.apps.googleusercontent.com`）與「iOS URL scheme」（反轉後的 Client ID）
   - 「測試中」的登入大約 7 天失效一次，App 會提示重新登入
2. Client ID 寫在 `Config/App.xcconfig`（已經填好，2026-11-21）。要換用戶端就改那兩行；或在 GitHub Actions Secrets 設 `GOOGLE_CLIENT_ID`，CI 會用 Secrets 的值蓋過去
3. **TMDB**：註冊後在帳號設定 → API 申請（v3 的 API Key 或 Read Access Token 都可以），**在 App 的「設定 → TMDB」貼上**。Key 只存在 iPhone 的鑰匙圈，不會編進 IPA，所以公開的 Release 裡看不到

iOS 用戶端沒有 client secret，Client ID 本來就會放在 App 裡（Google 的設計就是這樣，不算機密），所以直接寫在 repo。

## 使用

1. 「設定」→ 登入 Google（要勾選允許讀取雲端硬碟），再到「設定 → TMDB」貼上 API Key
2. 「媒體庫」→ 加入資料夾：瀏覽雲端硬碟，進到放影片的資料夾後按右上角「＋」。子資料夾會一起掃描
3. 掃描完會自動從 TMDB 抓海報、簡介、演員、評分。比對不到的在首頁最下面「未辨識」，點一下可以手動搜尋指定
4. 檔名建議：電影 `片名.年份.2160p.DV.Atmos.mp4` 或 `片名 (年份).mp4`；劇集 `劇名.S01E05.mp4`、`劇名 第05集.mp4`、`[字幕組] 劇名 - 05 [1080p].mp4`，或放在 `劇名/Season 1/` 底下

## 播放與字幕設定（0.3.0）

- **詳細頁**：整張海報往下淡成海報的主色（`PosterTint` 取海報下半部平均色、壓低亮度）、TMDB 片名 logo（繁中 → 中文 → 英文 → 原文）、規格 logo（4K／1080p、杜比視界、HDR10／HLG、杜比全景聲、5.1／7.1）、導演＋演員表、類型、媒體庫裡同類型的「相似內容」、檔案位置
- **規格**：E-AC3 的 `dec3` 設定盒讀聲道數與全景聲（JOC），影片的 transfer function 分 HDR10／HLG（`Core/AudioSpec.swift`、`SpecProbe`）
- **設定 → 播放**：快轉／倒轉間隔（播放時左右兩側點兩下）、長按倍速、繼續播放（繼續／從頭／每次詢問）、連續播放、自動跳過片頭片尾（每部劇在「⋯ → 片頭片尾」設定長度）、95% 自動標記已看、記住播放速度、自動小窗、觸覺回饋、行動網路提醒、預先緩衝
- **設定 → 字幕和音軌**：同資料夾同名外掛字幕（.srt／.vtt／.ass，自己解析、畫在影片上，Big5／GB18030 也讀得到）、內嵌字幕自動選語言、預設音軌語言、字幕顏色／邊框／粗體／斜體／大小
- 全 App 的捲動邊緣用 iOS 26 的 `.scrollEdgeEffectStyle(.soft)`

參考截圖裡有、這版沒做的：IMDb／爛番茄評分（要另外的付費或申請 API）、線上字幕搜尋（要 OpenSubtitles 帳號與 key）、HDR 字幕（只對圖片字幕有用，AVPlayer 沒有）、硬體加速與百度載入優化（AVPlayer 一律硬體解碼、沒有百度）、磁碟快取（要改寫本機代理）。杜比的 logo 是自己畫的雙 D＋字，不是官方圖檔。

## 首頁與詳細頁（0.4.0）

- **推薦輪播**：首頁最上面，每次打開 App 換一批，有無字海報＋片名 logo 的優先，7 秒自動換頁（`UI/Home/CategoryViews.swift` 的 `FeaturedCarousel`）
- **分類**：類型、評分（7 分台、8 分台）、發行年代、分級；分類規則在 `Core/Library.swift`，卡片顏色由分類名稱算出來
- **無字海報**：TMDB `images.posters` 裡語言是 null／`xx` 的那張存在 `textlessPosterPath`，詳細頁、輪播用它疊 logo；沒有無字版時 logo 放在海報下面
- 詳細頁頂端：海報在最上面時不顯示柔和邊緣（`heroTopEdge`），往上捲才出現；往下拉時海報以底部為基準放大
- 劇集的集數橫排（`EpisodeCard`），打開時停在下一集；TMDB 只寫「第 5 集」的單集標題不再重複（`Core` 的 `EpisodeTitle`）
- **不需要配對**：`MatchState.ignored`，清掉 TMDB 資料、用檔名當標題，放在首頁「其他影片」；「重新自動比對」可以恢復
- 更新日誌：`App/UI/Settings/ChangelogView.swift`（設定 → 關於 → 更新日誌），每次更新加一筆並同步改 `project.yml` 的 `MARKETING_VERSION`

## 驗收步驟（實機）

| 里程碑 | 怎麼確認 |
|---|---|
| M1 | 設定 → 登入 Google → 「我的雲端硬碟」看得到自己的資料夾與 MP4 |
| M2 | 播一部超過 1 小時的 4K 杜比視界 MP4：從頭播到尾不中斷（中途 token 會換新）；拖曳進度條正常；畫面右上角出現杜比視界標誌 |
| M3 | 媒體庫加入資料夾 → 首頁右上角「全部影片」列出所有影片 |
| M4 | 大部分影片有海報；未辨識的可以手動指定 |
| M5 | 播到一半關掉、滑掉 App 再打開 → 詳細頁顯示「自 00:12:34 繼續」；劇集播完倒數 10 秒播下一集 |
| M6 | 開飛航模式：上方出現「沒有網路連線」提示、播放時顯示中文錯誤，不會閃退；登出後一樣 |

## 架構

```
DrivePlayer/
├─ project.yml                 XcodeGen（.xcodeproj 不進 repo）
├─ Config/                     App.xcconfig、Secrets.xcconfig.template（Info.plist 由 XcodeGen 產生）
├─ Packages/Core/              純 Swift，Linux 可以 swift test
│  ├─ FilenameParser           檔名 → 片名／年份／季／集／畫質標籤（45 個測試）
│  ├─ TMDBModels、DriveModels  Codable 模型
│  ├─ EpisodeGrouping          劇 → 季 → 集
│  ├─ MatchScoring             TMDB 搜尋結果挑最像的（片名＋年份）
│  ├─ PlaybackRules            90% 算看完、續播位置、時間碼
│  └─ HTTPMessage              本機代理的 HTTP 解析（Range、Content-Range）
└─ App/
   ├─ Auth/GoogleAuthService   GoogleSignIn、token 快取（AccessTokenStore）
   ├─ Drive/                   DriveClient（Drive v3）、DriveScanner（遞迴掃描）
   ├─ Streaming/LocalStreamProxy  NWListener 只聽 127.0.0.1，每個請求帶最新 token 轉送 Range 到 Drive
   ├─ Player/                  PlaybackEngine（AVPlayerEngine）、PlayerController、DrivePlayerViewController
   ├─ Metadata/                TMDBClient（同時最多 4 個請求）、MetadataMatcher、SpecProbe
   ├─ Data/                    SwiftData 模型、LibraryManager、PlaybackStore
   ├─ UI/                      Home、Detail、Library、Settings、Components
   └─ Util/                    ImageCache、NetworkMonitor、AppConfig
```

播放：`AVPlayer → http://127.0.0.1:{port}/stream/{fileId}/{檔名} → LocalStreamProxy → https://www.googleapis.com/drive/v3/files/{fileId}?alt=media`

- 代理每個請求都向 `AccessTokenStore` 拿 token（還有 2 分鐘以上才過期就用快取，不然叫 GoogleSignIn 換新），401 時強制換新重試一次
- 回應原樣轉送 `206`、`Content-Range`、`Content-Length`、`Content-Type`、`Accept-Ranges: bytes`；資料分段寫回，送出但還沒寫進 socket 的超過 8 MB 就暫停下載（不會整部讀進記憶體）
- App 回到前景時 `ensureRunning()`，listener 被系統關掉會在同一個 port 重開

## 跟規劃書不同的地方

- 放在 `Eason3436/toolbox` 的 `DrivePlayer/` 資料夾（這個 repo 的慣例是所有 App 放在一起），workflow 是 `.github/workflows/driveplayer.yml`，Release tag 是 `driveplayer-latest`
- CI 用 repo 其他 App 共用的 `xcode-27` runner（不是 `macos-15`）；App 最低版本仍是 iOS 18
- 觸發條件：任何分支 push 改到 `DrivePlayer/**` 都會跑（不只 `main`），也可以手動
- 規劃書的 `Episode` 模型合併進 `MediaItem`（`kind == .episode`，掛在 `Show` 底下），省一層對應
- 播放畫面用 UIKit 全螢幕呈現 `AVPlayerViewController`（不是包在 SwiftUI 裡），才有原生的關閉鍵與子母畫面

## 後續階段

- 第二階段 MKV：加 MPVKit，實作 `PlaybackEngine`，共用 `LocalStreamProxy`
- 第三階段：桌機用 ffmpeg 把 MKV 不重新壓縮轉成 HLS（fMP4）
- 外掛字幕、離線下載、Apple TV 版
