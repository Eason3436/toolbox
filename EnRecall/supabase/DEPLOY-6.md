# EnRecall iOS 後端：單字包改成私有（DEPLOY-6）

給 Muse 的部署說明。單字包原本放在使用者 EnRecall 專案的**公開** Storage bucket `packs`，任何人知道網址就能整包下載。
這一版把 bucket 改成私有，iOS App 改成經過 iOS 後端的新 Edge Function `enrecall-packs` 下載，要帶「下載密碼」。

本文件在公開的 repo：**不要把任何專案 ref、網址、金鑰、密碼寫進這個檔案、程式碼或 commit**，全部用 Edge Function secrets。

## 0. 名詞

| 名詞 | 是什麼 |
|---|---|
| iOS 後端 | Muse 部署的 Supabase 專案（`ios_devices`、`ios_inbox`、`enrecall-mcp` 都在這裡） |
| EnRecall 專案 | 使用者自己的 EnRecall Supabase 專案（另一個帳號），單字包在它的 Storage bucket `packs` |

## 1. 要設定的 Edge Function secrets（iOS 後端）

| 名稱 | 值 | 誰提供 |
|---|---|---|
| `ENRECALL_STORAGE_URL` | EnRecall 專案的 API 網址（`https://<EnRecall 專案 ref>.supabase.co`） | 使用者 |
| `ENRECALL_STORAGE_KEY` | EnRecall 專案的 **secret key**（建議在它的 Settings → API Keys 另外建一把，名稱 `ios-packs`，之後可以單獨撤銷） | 使用者 |
| `STORE_PASSWORD` | 下載密碼，至少 16 個字元的隨機字串 | 使用者自己決定，App 裡輸入同一個 |

限制（很重要）：

1. `ENRECALL_STORAGE_KEY` 權限很大。**只能**拿來對 EnRecall 專案的 Storage 做 `GET /storage/v1/object/packs/<path>`。
   不准呼叫它的 REST／RPC、不准上傳或刪除 Storage、不准讀寫任何資料表。
2. 金鑰和密碼只能在 Edge Function 裡用 `Deno.env.get()` 讀，不能寫進原始碼、log、回應或 repo。

## 2. 新的 Edge Function `enrecall-packs`

- 部署：`verify_jwt` 設 `false`（App 會帶 publishable／anon key，但不靠它驗證）
- 網址：`https://<iOS 後端>.supabase.co/functions/v1/enrecall-packs/<path>`
- 函式收到的路徑是 `/enrecall-packs/<path>`，把前綴拿掉就是 `<path>`

### 2.1 只接受 GET

其他方法回 `405`。

### 2.2 檢查密碼

- 請求標頭 `x-store-password`
- 跟 `STORE_PASSWORD` 用**固定時間比較**（先比長度，再逐位元 XOR 累加），不要用 `===`
- 沒帶或不對：等 500 毫秒再回 `401`，body `{"error":"unauthorized"}`（拖慢暴力猜密碼）
- 不要在 log 印出收到的密碼

### 2.3 檢查路徑

只允許：

```
store/catalog.json
^(store|phrasebook)/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\.gz$
```

而且不能含 `..`、`//`、反斜線。不符合回 `404`。

### 2.4 轉送

```ts
const base = Deno.env.get("ENRECALL_STORAGE_URL")!;
const key = Deno.env.get("ENRECALL_STORAGE_KEY")!;
const headers: Record<string, string> = { apikey: key };
// 舊版 JWT 格式的 service_role key 也要放 Authorization；新版 sb_secret_ 只放 apikey
if (key.startsWith("eyJ")) headers.Authorization = `Bearer ${key}`;
const upstream = await fetch(`${base}/storage/v1/object/packs/${path}`, { headers });
```

- 上游 `200`：把 body **直接串流**回去（不要整包讀進記憶體），`Content-Type` 照上游，`Content-Length` 有就帶，
  另外加 `Cache-Control: private, no-store`
- 上游 `400`／`404`：回 `404`
- 其他：回 `502`，body `{"error":"upstream"}`

### 2.5 測試

```sh
URL=https://<iOS 後端>.supabase.co/functions/v1/enrecall-packs
# 1. 沒密碼 → 401
curl -s -o /dev/null -w "%{http_code}\n" "$URL/store/catalog.json"
# 2. 錯的密碼 → 401
curl -s -o /dev/null -w "%{http_code}\n" -H "x-store-password: wrong" "$URL/store/catalog.json"
# 3. 對的密碼 → 200，是 JSON，裡面有 packs
curl -s -H "x-store-password: $PW" "$URL/store/catalog.json" | head -c 200
# 4. 單字包 → 200，gzip
curl -s -H "x-store-password: $PW" "$URL/store/gsat-1/v2/level1.json.gz" | gunzip | head -c 200
# 5. 路徑跳脫 → 404
curl -s -o /dev/null -w "%{http_code}\n" -H "x-store-password: $PW" "$URL/store/../secret"
# 6. POST → 405
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "x-store-password: $PW" "$URL/store/catalog.json"
```

## 3. 改 `enrecall-mcp` 讀單字庫的方式

`lookup_words`、`get_words` 等工具原本用 `STORE_BASE`（公開網址）讀單字包。bucket 改私有後會讀不到，改成：

- 刪掉 `STORE_BASE` 和它的預設值（原始碼裡不能再出現 EnRecall 專案的網址）
- 改用 2.4 同一段：`ENRECALL_STORAGE_URL` ＋ `ENRECALL_STORAGE_KEY` 打 `GET /storage/v1/object/packs/<path>`
- 一樣只能 GET 這個 bucket
- 測試：`lookup_words` 查 `abandon` 要回 found

## 4. 順序

1. 使用者在 EnRecall 專案建 secret key，連同網址、下載密碼交給 Muse
2. Muse 設三個 secrets、部署 `enrecall-packs`、改好 `enrecall-mcp`，跑完 2.5 和第 3 節的測試
3. 使用者裝新版 App（0.17.0 起），在設定 → 單字商店輸入下載密碼
4. 確定 App 能下載後，使用者才把 EnRecall 專案的 `packs` bucket 改成私有（Storage → packs → Edit bucket → 關掉 Public）
5. 改私有後再跑一次 2.5 的第 3、4 個測試，另外確認原本的公開網址回 400／404
