# EnRecall iOS 後端：助理改用 Claude（DEPLOY-9）

給 Muse 的部署說明，取代 DEPLOY-8（`gemini-proxy`）。使用者 2026-11-23 決定助理改用 Claude API：
App 0.22.1 起改打新的 Edge Function `claude-proxy`，它用 Anthropic 官方 SDK 呼叫 Claude Messages API。
**Claude API key 只放在 Edge Function secrets，不進 App、不進 repo。**

- 只動 **iOS 後端專案**。不碰 EnRecall 專案、不改任何既有的表、RPC、其他 Edge Function
- 不用新的資料表、不用 migration
- 本文件在公開的 repo：**不要把專案 ref、網址、金鑰、密碼寫進這個檔案、程式碼或 commit**

## 1. 收掉 `gemini-proxy`

App 不會再呼叫它。在 iOS 後端刪掉 Edge Function `gemini-proxy`；如果設過 `GEMINI_KEY_PRIMARY`、`GEMINI_KEY_BACKUP`，一起刪掉。

## 2. Edge Function secrets（iOS 後端）

| 名稱 | 值 | 誰提供 |
|---|---|---|
| `ANTHROPIC_API_KEY` | Claude API key（Claude Console → API Keys 建一把，名稱建議 `enrecall-ios`，之後可以單獨撤銷） | 使用者 |
| `ANTHROPIC_API_KEY_BACKUP` | 選填：另一個帳號的 key。主要那把帳單、額度或認證有問題時才會用 | 使用者 |
| `STORE_PASSWORD` | 已經有了（DEPLOY-6 的下載密碼），**不用改** | — |

- 只能在 Edge Function 裡用 `Deno.env.get()` 讀，不能寫進原始碼、log、回應
- 建議在 Claude Console 幫這把 key 所在的 workspace 設每月花費上限

## 3. 部署 `claude-proxy`

- 原始碼：`EnRecall/supabase/functions/claude-proxy/index.ts`、`deno.json`（照原樣部署，不用改）
- `verify_jwt` 設 `false`（跟 `enrecall-packs`、之前的 `gemini-proxy` 一樣）
- 網址：`https://<iOS 後端>.supabase.co/functions/v1/claude-proxy`
- 用到的套件：`npm:@anthropic-ai/sdk@1.12.0`（官方 TypeScript SDK）、`jsr:@supabase/supabase-js@2`

函式做的事：

1. 只接受 `POST`（其他回 `405`）
2. 檢查 `x-store-password` 跟 `STORE_PASSWORD`（固定時間比較；錯了等 500 毫秒回 `401`）
3. 檢查 `x-device-code`（App 的配對碼）格式，算 sha256，`ios_devices` 裡要有這台裝置，沒有回 `401`
4. body 是 `{ "request": { Messages API 的 body }, "betas": [...] }`：
   - `request.model` 只能是 `claude-opus-5-5`，不然回 `400 model_not_allowed`
   - `request.max_tokens` 要 1–32000
   - `betas` 只能是 `server-side-fallback-2026-07-01`、`thinking-binding-controls-2026-08-01`，不然回 `400 beta_not_allowed`
5. 用 `ANTHROPIC_API_KEY` 透過 SDK 的 `client.beta.messages.stream(...).finalMessage()` 呼叫（串流等完整回覆，回覆長也不會 HTTP 逾時；SDK 自己會對 429／5xx 重試兩次）
6. 主要那把 key 回 `401`／`402`／`403`（認證、帳單、權限）時，**改用 `ANTHROPIC_API_KEY_BACKUP` 重送一次**，log 記一行 `switching to backup`
7. 成功：回 `200`，body 是 Claude 的完整 message JSON（裡面有 `usage`），標頭 `x-claude-key: primary|backup`
8. 錯誤：key 都不能用 → `402 quota_exhausted`（App 顯示「AI 額度已用完」）；`429` → `429 rate_limited`；`5xx`／`529` → `503 overloaded`；其他（例如 400 參數不對）→ 原本的狀態碼和 API 的錯誤訊息

log 只印狀態碼和錯誤類型，**不要印出 key、密碼、配對碼、使用者的內容**。

注意：Supabase Edge Function 有執行時間上限（免費方案 150 秒）。App 一般模式的回覆多半在 10–60 秒內；如果常常超時，再跟我說。

## 4. 測試

```sh
URL=https://<iOS 後端>.supabase.co/functions/v1/claude-proxy
KEY=<iOS 後端的 publishable key>
CODE=TESTmuse$(openssl rand -hex 10)
curl -s -X POST "https://<iOS 後端>.supabase.co/rest/v1/rpc/ios_register_device" \
  -H "apikey: $KEY" -H "Content-Type: application/json" -d "{\"p_code\":\"$CODE\"}"
H=(-H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json")
BODY='{"request":{"model":"claude-opus-5-5","max_tokens":1024,"output_config":{"effort":"low"},"messages":[{"role":"user","content":"用一句話說 hello"}]},"betas":[]}'
```

| # | 測試 | 預期 |
|---|---|---|
| 1 | GET | `405` |
| 2 | 沒有 `x-store-password` | `401` |
| 3 | 錯的密碼 | `401`（大約 0.5 秒後才回） |
| 4 | 對的密碼、沒註冊的配對碼 | `401` |
| 5 | 對的密碼＋測試配對碼，`model` 換成 `claude-haiku-4-5` | `400 model_not_allowed` |
| 6 | 對的密碼＋測試配對碼＋上面的 `BODY` | `200`，有 `content`、`usage`，標頭 `x-claude-key: primary` |
| 7 | 同 6，`betas` 加 `"foo-2026"` | `400 beta_not_allowed` |
| 8 | 有設備用 key 的話：暫時把 `ANTHROPIC_API_KEY` 改成無效的值再打 6 | `200`，`x-claude-key: backup`，log 有 `switching to backup`。**測完改回來** |
| 9 | 暫時把兩把都改成無效的值再打 6 | `402 quota_exhausted`。**測完改回來** |

第 4–9 項要帶對的下載密碼。手上沒有這個密碼的話不用跟使用者要：跑第 1–3 項就好，其餘由使用者在 App 上驗（App 能正常回答，就代表密碼、配對碼、轉送都通了）。

收尾（**一定要做**）：

```sh
curl -s -X POST "https://<iOS 後端>.supabase.co/rest/v1/rpc/ios_unregister_device" \
  -H "apikey: $KEY" -H "Content-Type: application/json" -d "{\"p_code\":\"$CODE\"}"
```

## 5. 回報

- `gemini-proxy` 已刪除、`claude-proxy` 的版本
- 第 4 節每一項的結果（不要附 key、密碼、配對碼）
- 跟這份文件不一樣的地方和原因

## 6. App 端（給參考，Muse 不用做）

- 模型與思考深度：`EnRecall/EnRecall/Features/Assistant/AssistantConfig.swift`（`claude-opus-5-5`；一般模式 effort `medium`、精準模式 `high`）。換模型要兩邊一起改：App 的設定和 `index.ts` 的 `MODELS`
- App 帶 `apikey`、`Authorization: Bearer <publishable key>`、`x-store-password`、`x-device-code`
- 請求用了 `fallbacks: "default"`（被安全分類器拒絕時伺服器自動換模型重跑）、`thinking.block_binding.prefix_mismatch_behavior: "drop_block"`（萬一對話紀錄對不上就丟掉舊的思考區塊、不讓整個請求失敗）、自動提示快取（`cache_control`）
- 工具全部在 App 裡執行（直接讀寫本機資料庫），不經過收件匣
