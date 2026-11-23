# EnRecall iOS 後端：助理用的 Gemini 代理（DEPLOY-8）

給 Muse 的部署說明，接在 DEPLOY-7 後面。App 0.22.0 加了「助理」聊天頁：App 自己執行查字、加牌組、做 PDF 這些工具，
只有「問模型」這一步經過 iOS 後端的新 Edge Function `gemini-proxy` 轉給 Gemini。**Gemini API key 只放在 Edge Function secrets，不進 App、不進 repo。**

- 只動 **iOS 後端專案**。不碰 EnRecall 專案、不改任何既有的表、RPC、Edge Function
- 不用新的資料表、不用 migration
- 本文件在公開的 repo：**不要把專案 ref、網址、金鑰、密碼寫進這個檔案、程式碼或 commit**

## 1. Edge Function secrets（iOS 後端）

| 名稱 | 值 | 誰提供 |
|---|---|---|
| `GEMINI_KEY_PRIMARY` | 主要的 Gemini API key（Google AI Studio） | 使用者 |
| `GEMINI_KEY_BACKUP` | 備用的 Gemini API key（另一個帳號），主要那把額度用完才會用 | 使用者 |
| `STORE_PASSWORD` | 已經有了（DEPLOY-6 的下載密碼），**不用改** | — |

- 只能在 Edge Function 裡用 `Deno.env.get()` 讀，不能寫進原始碼、log、回應
- 只設一把也可以（另一把留空）：就不會有備援

## 2. 部署 `gemini-proxy`

- 原始碼：`EnRecall/supabase/functions/gemini-proxy/index.ts`、`deno.json`（照原樣部署，不用改）
- `verify_jwt` 設 `false`（App 帶的是 publishable／anon key，不靠它驗證；跟 `enrecall-packs` 一樣）
- 網址：`https://<iOS 後端>.supabase.co/functions/v1/gemini-proxy`

函式做的事：

1. 只接受 `POST`（其他回 `405`）
2. 檢查 `x-store-password` 跟 `STORE_PASSWORD`（固定時間比較；錯了等 500 毫秒回 `401`）
3. 檢查 `x-device-code`（App 的配對碼）格式，算 sha256，`ios_devices` 裡要有這台裝置，沒有回 `401`
4. body 是 `{ "model": "gemini-4-hydrogen" | "gemini-4-neon", "request": { generateContent 的 body } }`。模型不在白名單回 `400`
5. 用 `GEMINI_KEY_PRIMARY` 打 `https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent`（key 放在 `x-goog-api-key` 標頭）
6. PRIMARY 回額度或計費錯誤（`429`、`403`／`400` 裡有 quota、billing、RESOURCE_EXHAUSTED、API key 無效）時，**改用 BACKUP 重送一次**，log 記一行 `switching to backup`。不會每次輪流用
7. 成功：原樣回傳 Gemini 的 JSON（裡面有 `usageMetadata`），標頭 `x-gemini-key: primary|backup`
8. 兩把都額度不足：回 `429` `{"error":{"code":"quota_exhausted"}}`，App 顯示「本月 AI 額度已用完」、不再重試
9. 其他錯誤：Gemini 的狀態碼和內容原樣回傳

log 只印狀態碼和錯誤類型，**不要印出 key、密碼、配對碼、使用者的內容**。

## 3. 測試

```sh
URL=https://<iOS 後端>.supabase.co/functions/v1/gemini-proxy
KEY=<iOS 後端的 publishable key>
PW=<下載密碼>
CODE=TESTmuse$(openssl rand -hex 10)
# 先註冊測試配對碼（跟 DEPLOY.md 第 6 節一樣）
curl -s -X POST "https://<iOS 後端>.supabase.co/rest/v1/rpc/ios_register_device" \
  -H "apikey: $KEY" -H "Content-Type: application/json" -d "{\"p_code\":\"$CODE\"}"
H=(-H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json")
BODY='{"model":"gemini-4-hydrogen","request":{"contents":[{"role":"user","parts":[{"text":"用一句話說 hello"}]}]}}'
```

| # | 測試 | 預期 |
|---|---|---|
| 1 | `curl "${H[@]}" "$URL"`（GET） | `405` |
| 2 | 沒有 `x-store-password` | `401` |
| 3 | 錯的密碼 | `401`（大約 0.5 秒後才回） |
| 4 | 對的密碼、沒註冊的配對碼 `x-device-code: wrongcode0000000000` | `401` |
| 5 | 對的密碼＋測試配對碼，`model` 是 `gemini-1.0-pro` | `400`，`model_not_allowed` |
| 6 | 對的密碼＋測試配對碼＋上面的 `BODY` | `200`，有 `candidates`、`usageMetadata`，標頭 `x-gemini-key: primary` |
| 7 | 同 6，`model` 換 `gemini-4-neon` | `200` |
| 8 | 暫時把 `GEMINI_KEY_PRIMARY` 改成一把無效的 key 再打 6 | `200`，標頭 `x-gemini-key: backup`，log 有 `switching to backup`。**測完改回來** |
| 9 | 暫時兩把都改成無效的 key 再打 6 | `429`，`quota_exhausted`。**測完改回來** |

範例（測試 6）：

```sh
curl -s -D - "${H[@]}" -H "x-store-password: $PW" -H "x-device-code: $CODE" -d "$BODY" "$URL"
```

收尾（**一定要做**）：

```sh
curl -s -X POST "https://<iOS 後端>.supabase.co/rest/v1/rpc/ios_unregister_device" \
  -H "apikey: $KEY" -H "Content-Type: application/json" -d "{\"p_code\":\"$CODE\"}"
```

## 4. 回報

- 部署好的函式版本
- 第 3 節每一項的結果（不要附 key、密碼、配對碼）
- 跟這份文件不一樣的地方和原因

## 5. App 端（給參考，Muse 不用做）

- App 帶 `apikey`、`Authorization: Bearer <publishable key>`、`x-store-password`（使用者在設定 › 單字商店輸入的下載密碼）、`x-device-code`（這台手機的配對碼）
- 模型名稱、思考程度寫在 `EnRecall/EnRecall/Features/Assistant/AssistantConfig.swift`。之後換模型要兩邊一起改：App 的設定和 `index.ts` 的 `MODELS` 白名單
- 工具全部在 App 裡執行（直接讀寫本機資料庫），不經過收件匣、不會動到 `ios_inbox`、`ios_patterns`
