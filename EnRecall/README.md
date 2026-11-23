# EnRecall iOS

學測背單字：從單字商店下載學測 Level 1–6 與學測片語總表，用 FSRS 排程複習；Claude App 可以透過 MCP 連接器把單字送進來。

## 安裝

1. 在 iPhone 上下載 [EnRecall.ipa](https://github.com/Eason3436/toolbox/releases/download/enrecall-latest/EnRecall.ipa)
2. 打開 SideStore → My Apps → 左上角 ＋ → 選剛下載的 EnRecall.ipa
3. 免費 Apple ID 簽的 App 7 天後會過期：記得在 SideStore 按 Refresh（或開背景重新整理）。
   續簽、覆蓋安裝新版都**不會清掉進度**；只有刪除 App 才會

需求：iOS 27。

## 發音

Siri 的聲音 Apple 不開放給第三方 App。App 會自動挑手機上品質最好的美式英文聲音；想要更自然的聲音，到「設定 › 輔助使用 › 朗讀內容 › 聲音 › 英文」下載「高品質」或「增強」版本。

## 開發

- 專案檔用 XcodeGen（`project.yml`），CI（`.github/workflows/enrecall.yml`）編譯並發佈到 `enrecall-latest`
- 後端設定在 `EnRecall/Config/App.xcconfig`；iOS 後端的部署規劃在 `supabase/DEPLOY.md`
- 助理（`EnRecall/Features/Assistant/`）：Claude（`claude-opus-5-5`）經過 iOS 後端的 `claude-proxy` 呼叫（`supabase/DEPLOY-9.md`），工具在 App 裡執行
- 結構：`App/`（進入點、分頁、路由）、`Models/`（SwiftData）、`Services/`（商店、出卡規則、統計、發音）、`DesignSystem/`（色票、元件）、`Features/`（各畫面）
