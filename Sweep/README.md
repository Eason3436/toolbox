# Sweep 相簿清理

整理相簿像在滑短影音：照片頁每次隨機抽一組，一張一張看，不要的往上一甩；影片頁上下滑，邊看邊決定留或刪。依「照片／影片清理 App 開發規劃書（自用版）1.1」實作，三個階段一次做完。

## 跟規劃書不一樣的地方

| 規劃書 | 實作 | 原因 |
|---|---|---|
| iOS 18、Xcode 直接安裝 | iOS 27、GitHub Actions 編 IPA → SideStore 側載 | 跟 repo 其他 App 一樣（沙盒沒有 Xcode，CI 就是編譯器） |
| 往上拉打開照片詳情 | 點卡片或 ⓘ 按鈕打開 | 往上甩已經是「刪除」，兩個手勢會打架 |
| `ViewedAsset.isDeleted`、`id` | `wasDeleted`、`assetID` | `isDeleted`／`id` 是 SwiftData 自己的屬性名 |
| `CLGeocoder` | `MKReverseGeocodingRequest` | CLGeocoder 在 iOS 26 起淘汰；Ledger 已經用過同一個 API |
| GIF 用 `uniformTypeIdentifier` 判斷 | 系統「動態」智慧相簿（`smartAlbumAnimated`） | 不用逐張讀資源，幾萬張也快 |

## 檔案

| 路徑 | 內容 |
|---|---|
| `Sweep/App/` | 進入點、權限關卡、三個分頁（照片、影片、統計）、刪除結果的提示 |
| `Sweep/Models/` | SwiftData：`ViewedAsset`、`CleanStats`；分類 `MediaFilter`、統計類別 `StatsKind` |
| `Sweep/Services/PhotoLibrary.swift` | 依分類取 ID、批次刪除、收藏、檔案大小、匯出影片 |
| `Sweep/Services/Shuffler.swift` | 隨機抽組（只洗前 N 個） |
| `Sweep/Services/DeletionQueue.swift` | 待刪除清單；`commit` 才呼叫系統刪除，記錄統計 |
| `Sweep/Services/StatsRecorder.swift` | 瀏覽、刪除寫進 SwiftData；重設瀏覽記錄 |
| `Sweep/Services/ImageLoader.swift` | `PHCachingImageManager`，前後各 2 張預載 |
| `Sweep/Services/Formatters.swift` | 「85 天前」、短地名、EXIF 整理 |
| `Sweep/Features/Photos/` | 卡片堆疊與手勢、抽組邏輯、照片詳情 |
| `Sweep/Features/Videos/` | 直向分頁影片、最多 3 個播放器的 `PlayerPool` |
| `Sweep/Features/Delete/` | 刪除確認（縮圖格子，點一下改成保留） |
| `Sweep/Features/Stats/`、`Settings/` | 統計、設定、更新日誌 |
| `Tests/` | 抽組、相對時間、地名、EXIF、影片清單、統計的單元測試 |

## 驗收

1. 第一次打開會要相簿權限；只給部分照片時，照片頁上方有提示。
2. 照片頁：往左滑下一張、往右滑上一張、往上甩變紅後放開 → 右上角垃圾桶數字 +1；左下 ↶ 可以復原。
3. 一組看完會跳出刪除確認：點縮圖改成保留，按「刪除 N 項」只跳一次系統確認，完成後上方顯示騰出多少空間。
4. 左上角選單切換照片／截圖／自拍／原況照片／動圖，調每組數量。
5. 點卡片或 ⓘ 看詳情：設備、光圈、快門、ISO、焦距、檔名、解析度、大小、地圖、地址、海拔。
6. 影片頁上下滑會自動循環播放；點畫面暫停；右側收藏、分享、刪除（再按一次變保留）、復原。
7. 統計頁數字跟刪掉的對得上；「重設瀏覽記錄」後看過的照片會再被抽到。右上角齒輪是設定。
