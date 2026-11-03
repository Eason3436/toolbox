# 工具箱（Toolbox）

自用的 iOS 檔案工具 App：把檔案丟進來，App 自動辨識類型，列出可以做的事。全部在手機上離線處理。

- SwiftUI，原生介面
- 最低支援 iOS 26；CI 會自動選最新的 Xcode（有 Xcode 27 就用 iOS 27 SDK）
- 用 SideStore 側載，不上架

## 功能

| 類型 | 動作 |
| --- | --- |
| 圖片 | 比例裁切（含 XPan 65:24、寬銀幕 2.39:1）、轉檔（JPG/PNG/HEIC/TIFF）、壓縮、調整尺寸、移除位置與 EXIF、合成 PDF、旋轉翻轉、黑白濾鏡、浮水印、拼成長圖、做成動圖、辨識文字（OCR）、去背、讀取 QR Code |
| 原況照片 | 移除影片部分，保留原始照片、景深、編輯、時間、地點、最愛與相簿 |
| 影片 | 壓縮、轉檔、剪頭去尾、擷取音訊、轉 GIF、移除聲音、旋轉、變速、擷取畫面、合併 |
| 音訊 | 轉檔（M4A/ALAC/WAV/AIFF/CAF）、壓縮、切割、合併、做成鈴聲、語音轉文字（TXT／SRT 字幕） |
| PDF | 轉 Markdown、合併、拆分、轉圖片、壓縮、選取或刪除頁面、旋轉頁面、轉純文字、加密碼、移除密碼 |
| 文件（MD、HTML、TXT、RTF、CSV、JSON、Word／Excel／PPT／Pages） | 轉 PDF、轉 Word（DOCX）、轉 Markdown、轉網頁、轉純文字、轉長圖、繁簡轉換、修正亂碼（Big5→UTF-8）、CSV→Excel／JSON、JSON→CSV／Excel、整理 JSON |
| 任何檔案 | 壓縮成 ZIP、批次重新命名 |

## 編譯與安裝

每次 push，GitHub Actions 會用 macOS 機器編譯出未簽名的 `Toolbox.ipa`：

- 在 Actions 頁面的 artifact 下載，或
- push 到 `main` 時，會更新 Releases 裡的 `latest`，在 iPhone 上直接下載。

下載後在 SideStore 的 My Apps 按 `+` 選擇 `Toolbox.ipa`，SideStore 會用你的 Apple ID 簽名。

本機有 Mac 的話：

```sh
brew install xcodegen
xcodegen generate
open Toolbox.xcodeproj
```

## 功能包格式

功能包是一個 JSON 檔，把內建積木串成新功能。從「檔案」App 打開、AirDrop，或在 App 的「功能包」頁面貼上即可安裝，不用重新打包 App。

```json
{
  "id": "xpan-share",
  "title": "XPan 分享用",
  "subtitle": "裁成 XPan 比例、縮到 2048px、轉 JPG、移除位置",
  "systemImage": "pano",
  "accepts": ["image"],
  "parameters": [
    { "key": "quality", "title": "品質", "kind": "number",
      "min": 50, "max": 100, "step": 5, "unit": "%", "default": 85 }
  ],
  "steps": [
    { "op": "image.crop", "params": { "ratio": "65:24" } },
    { "op": "image.resize", "params": { "mode": "long", "longEdge": 2048, "format": "jpg", "quality": "$quality" } },
    { "op": "image.stripMetadata", "params": { "mode": "gps" } }
  ]
}
```

- `accepts`：`image`、`video`、`audio`、`pdf`
- `parameters`：會自動產生設定畫面。`kind` 可以是 `choice`（加 `options: [{ "value", "label" }]`）、`number`、`toggle`、`text`；`showIf` 可依其他參數決定是否顯示。
- `steps`：依序執行，上一步的輸出是下一步的輸入。參數值寫 `"$名稱"` 會帶入使用者在設定畫面填的值，沒寫的參數用積木的預設值。

### 可用的積木

| id | 參數 |
| --- | --- |
| `image.crop` | `ratio`（如 `"65:24"`）、`format`（`same`/`jpg`/`png`/`heic`/`tiff`）、`quality`（10–100）、`keepMetadata` |
| `image.convert` | `format`、`quality`、`keepMetadata` |
| `image.compress` | `mode`（`quality`/`size`）、`quality`、`targetKB`、`maxDimension`（`"0"`、`"2048"`…）、`format`（`same`/`jpg`/`heic`）、`keepMetadata` |
| `image.resize` | `mode`（`long`/`percent`）、`longEdge`、`percent`、`format`、`quality`、`keepMetadata` |
| `image.stripMetadata` | `mode`（`gps`/`all`） |
| `image.toPDF` | `page`（`fit`/`a4`/`letter`）、`quality`、`name` |
| `video.compress` | `quality`（`2160`/`1080`/`720`/`540`/`low`）、`codec`（`hevc`/`h264`）、`format`（`mp4`/`mov`/`m4v`） |
| `video.convert` | `format`、`codec` |
| `video.trim` | `start`、`end`（`"1:30"` 這種時間字串） |
| `video.extractAudio` | `format`（`m4a`/`wav`）、`bitrate`（`"192"`） |
| `video.toGIF` | `start`、`length`、`fps`、`width` |
| `audio.convert` | `format`（`m4a`/`alac`/`wav`/`aiff`/`caf`）、`bitrate`、`sampleRate`、`channels` |
| `audio.compress` | `bitrate`、`mono` |
| `audio.split` | `mode`（`points`/`parts`/`length`）、`points`、`parts`、`length` |
| `audio.merge` | `name` |
| `audio.ringtone` | `start`、`length` |
| `pdf.toMarkdown` | `ocr`、`pageBreaks` |
| `pdf.merge` | `name` |
| `pdf.split` | `mode`（`ranges`/`each`）、`ranges`（如 `"1-3, 5, 8-"`） |
| `pdf.toImages` | `format`（`jpg`/`png`）、`scale`（`1`/`2`/`3`） |

## 專案結構

```
Toolbox/
  App/         App 進入點與共用狀態
  Engine/      積木協定、參數、功能包、檔案管理
  Operations/  圖片、影片、音訊、PDF 的積木實作
  Services/    相簿存取、原況照片轉換
  Views/       SwiftUI 畫面
  Intents/     捷徑與 Siri（App Intents）
```
