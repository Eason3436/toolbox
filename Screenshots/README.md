# Screenshots（截圖腦）

自用的 AI 截圖管理 App，對標 Pixel Screenshots。iPhone 17 Pro Max、iOS 27 以上，完全離線（Vision OCR + Apple Foundation Models 裝置端模型）。

## 安裝

1. 到 GitHub Release `screenshots-latest` 下載 `Screenshots.ipa`（由 Actions 的「Build Screenshots IPA」手動觸發打包）。
2. 在 iPhone 的 SideStore → My Apps → ＋ → 選 `Screenshots.ipa`。
3. 第一次打開選「允許完整取用」照片，再選匯入範圍。
4. 確認「設定 → Apple Intelligence 與 Siri」已開啟、模型已下載完成。

### 簽署注意（SideStore 免費帳號）
- App 內含 **Share Extension**，會多佔一個 App ID（免費帳號每 7 天最多 10 個 App ID，同時最多 3 個 App）。
- **App Group**：IPA 已帶 `group.com.eason3436.screenshots` 權限，SideStore 會改成加上你 Team ID 的名稱並寫進 `ALTAppGroups`，App 會自動讀取。若「設定」頁出現橘色「App Group 無法使用」，代表分享延伸功能收不到圖片，其他功能不受影響。

## 功能與檔案

| 階段 | 內容 | 主要檔案 |
|---|---|---|
| 1 | 權限、PhotoKit 讀取截圖、首頁兩欄卡片 | `Views/RootView`, `Views/PermissionView`, `Views/HomeView`, `Views/ScreenshotCard` |
| 2 | SwiftData、persistent change 增量同步、相簿變更監看、BGProcessingTask | `Models/ScreenshotItem`, `Services/PhotoSyncService`, `App/AppServices` |
| 3 | Vision OCR、Foundation Models 圖片輸入、NSDataDetector 校正、佇列（過熱暫停、低耗電只在前景、重試 1 次） | `Services/OCRService`, `Services/AIAnalyzer`, `Services/EntityExtractor`, `Services/AnalysisQueue` |
| 4 | 關鍵字搜尋（命中反白）、分類／日期／收藏集篩選、詳情頁、快速動作、Spotlight | `Services/SearchService`, `Views/ScreenshotDetailView`, `Services/ActionService` |
| 5 | 自然語言問答（工具呼叫，附來源截圖，找不到會直說） | `Services/AskService`, `Views/AskView` |
| 6 | 收藏集＋自動規則、釘選／封存、刪除原圖、Share Extension、App Intents | `Views/CollectionsView`, `ShareExtension/`, `Intents/ScreenshotIntents` |

單元測試：`Tests/SearchServiceTests.swift`（搜尋排序、資料解析、問答來源標記、日期分段）。

與規格的差異：
- `Collection` 改名 `ScreenshotCollection`（避免和 Swift 內建 `Collection` 撞名）。
- `status` 在資料庫存成字串 `statusRaw`（SwiftData 的查詢條件不支援列舉）。
- 分享進來的圖片若在相簿找不到同一張截圖（例如從截圖預覽直接分享、還沒存檔），會存進相簿再收錄。

## 驗收測試

1. **列表**：打開 App，首頁顯示所有截圖，依日期分段，快速捲動不卡。
2. **同步**：截一張圖後回到 App，2 秒內出現在最上面；在「照片」刪除一張截圖再回來，它會消失。
3. **AI 分析**：標題列顯示「分析中 n / 總數」，卡片出現 AI 標題與分類；中文、英文截圖各試一張。
4. **搜尋**：在搜尋列輸入截圖裡的一段文字，能找到並反白；詳情頁按「加入提醒事項」能建立提醒。
5. **問答**：在「問答」問「上次截的那家拉麵店叫什麼？」會回答並附來源縮圖；問不存在的東西會回答「找不到相關截圖。」
6. **收藏集**：建立收藏集，設定「分類自動加入：票券訂單」，相符的截圖會自動加入。
7. **刪除原圖**：首頁按「選取」→ 勾選 → 刪除原圖，系統跳出確認後一併移除。
8. **分享**：在照片 App 分享一張截圖 → Screenshots，回到 App 後會優先分析。
9. **背面輕點**：照「設定 → 背面輕點收錄截圖」的步驟建立捷徑，輕點背面兩下即可收錄。
