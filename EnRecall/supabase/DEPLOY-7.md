# EnRecall iOS 後端：單字庫搬進 iOS 後端自己的 Storage（DEPLOY-7）

給 Muse 的部署說明，接在 DEPLOY-6 後面。

DEPLOY-6 的做法是 `enrecall-packs` 拿 EnRecall 專案的 secret key，去讀**另一個帳號**的 Storage。
這一版改成把單字庫整份複製進 **iOS 後端自己的私有 bucket**，`enrecall-packs`、`enrecall-mcp` 都只讀自己專案，
不再需要 EnRecall 專案的金鑰。

- **App 不用改**：App 一樣打 `<iOS 後端>/functions/v1/enrecall-packs/<path>`、帶 `x-store-password`，路徑也一樣
- **不准動 EnRecall 專案**：只從它讀檔案，不上傳、不刪除、不改 bucket 設定、不碰資料表

本文件在公開的 repo：**不要把任何專案 ref、網址、金鑰、密碼寫進這個檔案、程式碼或 commit**。

## 0. 名詞

| 名詞 | 是什麼 |
|---|---|
| iOS 後端 | Muse 部署的 Supabase 專案（`ios_devices`、`ios_inbox`、`enrecall-mcp`、`enrecall-packs` 都在這裡） |
| EnRecall 專案 | 使用者自己的 EnRecall Supabase 專案（另一個帳號），單字庫原本在它的 bucket `packs` |
| 單字庫 zip | 使用者交給你的 `EnRecall-packs.zip`（2026-11-18 從 EnRecall 專案下載），解開就是 bucket 裡的路徑 |

## 1. 建私有 bucket `packs`（iOS 後端）

Dashboard：Storage → New bucket → 名稱 `packs`，**Public 關掉**。或用 SQL：

```sql
insert into storage.buckets (id, name, public)
values ('packs', 'packs', false)
on conflict (id) do update set public = false;
```

不用加任何 RLS policy：只有 Edge Function 用 service role 讀，App、anon 都不能直接讀。

## 2. 上傳單字庫

把 zip 解開，**保留資料夾路徑**上傳到 `packs` 的根目錄。上傳完 bucket 裡要有這 27 個檔案：

| 路徑 | 大小（bytes） |
|---|---|
| `store/catalog.json` | 20237 |
| `store/gsat-1/v2/level1.json.gz` | 768782 |
| `store/gsat-1/v2/quiz-level1.json.gz` | 37445 |
| `store/gsat-2/v2/level2.json.gz` | 882976 |
| `store/gsat-2/v2/fixes-level2.json.gz` | 2005 |
| `store/gsat-2/v2/seed-level2.json.gz` | 392363 |
| `store/gsat-2/v2/similar-level2.json.gz` | 125308 |
| `store/gsat-2/v2/quiz-level2.json.gz` | 3352 |
| `store/gsat-3/v2/level3.json.gz` | 1078347 |
| `store/gsat-3/v2/fixes-level3.json.gz` | 3099 |
| `store/gsat-3/v2/seed-level3.json.gz` | 433714 |
| `store/gsat-3/v2/similar-level3.json.gz` | 169520 |
| `store/gsat-3/v2/quiz-level3.json.gz` | 166344 |
| `store/gsat-4/v2/level4.json.gz` | 962372 |
| `store/gsat-4/v2/fixes-level4.json.gz` | 1081 |
| `store/gsat-4/v2/seed-level4.json.gz` | 250799 |
| `store/gsat-4/v2/similar-level4.json.gz` | 177427 |
| `store/gsat-4/v2/quiz-level4.json.gz` | 168654 |
| `store/gsat-5/v2/level5.json.gz` | 946813 |
| `store/gsat-5/v2/similar-level5.json.gz` | 206191 |
| `store/gsat-5/v2/quiz-level5.json.gz` | 171245 |
| `store/gsat-6/v2/level6.json.gz` | 789816 |
| `store/gsat-6/v2/similar-level6.json.gz` | 81381 |
| `store/gsat-6/v2/quiz-level6.json.gz` | 3438 |
| `store/book-school-l5/v1/order.txt.gz` | 5302 |
| `store/book-school-l5/v1/info.json.gz` | 100 |
| `phrasebook/v2/phrasebook.json.gz` | 223377 |

注意：

- `.gz` 檔**原封不動**上傳，不要解壓、不要重新壓縮（App 會用 `catalog.json` 裡的 `sha256` 比對壓縮檔）
- Content-Type：`catalog.json` 用 `application/json`，`.gz` 用 `application/gzip`。**不要**設 `Content-Encoding: gzip`，不然下載時會被自動解壓，App 解壓第二次會失敗
- `catalog.json` 裡還有一筆 `video`（發音影片語料庫，40 MB），iOS App 用不到，**不用**上傳

用指令上傳（在 zip 解開的資料夾裡執行；`IOS_URL`、`IOS_SECRET` 是 iOS 後端的網址和 secret key，只放在環境變數）：

```sh
find store phrasebook -type f | while read -r f; do
  case "$f" in *.json) type=application/json ;; *) type=application/gzip ;; esac
  curl -sS -o /dev/null -w "%{http_code} $f\n" -X POST \
    -H "apikey: $IOS_SECRET" -H "Authorization: Bearer $IOS_SECRET" \
    -H "Content-Type: $type" -H "x-upsert: true" \
    --data-binary @"$f" "$IOS_URL/storage/v1/object/packs/$f"
done
```

每一行都要是 `200`。（新版 `sb_secret_` 金鑰如果 `Authorization` 被拒絕，就只留 `apikey` 那個標頭。）

## 3. 改 `enrecall-packs`

只改「去哪裡讀」，密碼檢查、路徑檢查、串流回傳都照 DEPLOY-6 第 2 節不變。

DEPLOY-6 2.4 那段改成讀**自己專案**（Edge Function 會自動提供 `SUPABASE_URL`、`SUPABASE_SERVICE_ROLE_KEY`，不用另外設）：

```ts
const base = Deno.env.get("SUPABASE_URL")!;
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const upstream = await fetch(`${base}/storage/v1/object/packs/${path}`, {
  headers: { apikey: key, Authorization: `Bearer ${key}` },
});
```

- 一樣**只能** `GET /storage/v1/object/packs/<path>`，不准用這把 key 做別的事
- 原始碼裡不能出現 `ENRECALL_STORAGE_URL`、`ENRECALL_STORAGE_KEY` 了

## 4. 改 `enrecall-mcp`

`lookup_words`、`get_words` 那些讀單字庫的地方，跟第 3 節一樣改成 `SUPABASE_URL` ＋ `SUPABASE_SERVICE_ROLE_KEY` 讀自己的 `packs`。

## 5. 測試

跟 DEPLOY-6 第 2.5 節一樣的 6 個測試，結果也要一樣：

1. 沒密碼 → `401`
2. 錯的密碼 → `401`
3. 對的密碼讀 `store/catalog.json` → `200`、JSON 裡有 `packs`
4. 對的密碼讀 `store/gsat-1/v2/level1.json.gz` → `200`，`gunzip` 後是 JSON
5. `store/../secret` → `404`
6. `POST` → `405`

再加：

7. 對的密碼讀 `phrasebook/v2/phrasebook.json.gz` → `200`
8. 下載下來的 `store/gsat-3/v2/level3.json.gz` 算 `sha256`，要跟 `catalog.json` 裡 gsat-3 的 `level3.json` 那筆一樣
9. 沒帶密碼、直接打 iOS 後端的 `/storage/v1/object/public/packs/store/catalog.json` → 不能是 `200`（bucket 是私有的）
10. MCP `lookup_words` 查 `abandon` → found；查片語總表裡的片語（例如 `look forward to sth`）→ found

## 6. 全部通過之後

1. 刪掉 iOS 後端的 Edge Function secrets `ENRECALL_STORAGE_URL`、`ENRECALL_STORAGE_KEY`
2. 從此 iOS 後端的 `packs` 就是 iOS 單字庫**唯一的來源**。使用者說不會再更新原本的單字庫，也不會再動 Android／網頁版 EnRecall，
   所以不用跟 EnRecall 專案同步，之後也不要再從那邊讀任何東西
3. 如果當初在 EnRecall 專案建了給 iOS 用的 secret key（`ios-packs`），使用者可以自己去撤銷。**Muse 不要碰 EnRecall 專案**
