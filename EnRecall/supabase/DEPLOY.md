# EnRecall iOS — Supabase 部署規劃書（M1 資料庫 + M2 MCP 伺服器）

> 給負責部署的人／agent。照順序做，每一步都有驗收方式。
> **碰到下面「絕對不能做」的任何一項，先停下來回報，不要自己決定。**

---

## 0. 兩個專案，各自的角色

| | **iOS 後端（要部署的地方）** | **單字商店來源（只讀）** |
|---|---|---|
| 是什麼 | 你帳號裡的 Supabase 專案，專門給 EnRecall iOS 用 | 使用者自己的 EnRecall 專案（ref `souqknwgklqdnhguivaz`），是另一個帳號 |
| 放什麼 | `ios_devices`、`ios_inbox`、三個 RPC、清除排程、Edge Function `enrecall-mcp` | 單字商店的 JSON 檔（公開的 Storage bucket `packs`） |
| 你能做的事 | 照這份文件建立、部署、測試 | **只能用 HTTPS GET 讀公開檔案**，不需要也不要任何金鑰 |

### 絕對不能做

1. **不能對 EnRecall 專案做任何寫入**：不登入、不呼叫它的 REST／RPC、不上傳 Storage。只讀 `https://souqknwgklqdnhguivaz.supabase.co/storage/v1/object/public/packs/...` 這種公開網址
2. 不能把 service role key 寫進程式碼、repo 或回覆裡。Edge Function 執行時會自動拿到 `SUPABASE_SERVICE_ROLE_KEY` 環境變數，直接讀那個就好
3. 如果 iOS 後端用的是**已經有其他東西的專案**，不能改既有的表和函式。只能新增，名稱一律以 `ios_` 或 `enrecall-` 開頭（最好直接開一個新專案，名稱 `enrecall-ios`，區域選 ap-northeast-1 Tokyo）

---

## 1. 專案資訊

| 項目 | 值 |
|---|---|
| iOS 後端專案 | 你建立的專案，下面用 `<IOS_REF>` 代表 |
| iOS 後端 API URL | `https://<IOS_REF>.supabase.co` |
| iOS 後端 publishable key | 部署完回報給我，App 要用（這是公開金鑰，可以放進 App） |
| 商店檔案根網址（公開、唯讀） | `https://souqknwgklqdnhguivaz.supabase.co/storage/v1/object/public/packs` |

---

## 2. M1：在 iOS 後端專案套用 migration

原始檔在 repo 的 `EnRecall/supabase/migrations/20261116122047_ios_inbox.sql`，整份照原樣套用（`supabase db push`，或用 MCP 的 `apply_migration`，名稱 `ios_inbox`）。

這份 migration 會用到兩個擴充套件：

- `pgcrypto`：新的 Supabase 專案預設就裝在 `extensions` schema，函式裡寫的是 `extensions.digest`
- `pg_cron`：migration 會自動啟用

套用後會有這些東西：

| 物件 | 說明 |
|---|---|
| `public.ios_devices` | `code_hash`（sha256 hex，PK）、`created_at`、`last_seen`。RLS 開啟、沒有 policy、anon／authenticated 沒有表權限 |
| `public.ios_inbox` | `id`、`code_hash`（FK → ios_devices，cascade）、`deck_name`、`word`、`pos`、`zh`、`example`、`example_zh`、`source`（`library`／`claude`）、`library_word_id`、`created_at`。權限同上 |
| `ios_inbox` 的 check 約束 | `deck_name` 去掉頭尾空白後 1–60 字；`word` 1–120 字；`zh` 不能是空的；`source = 'library'` 時 `library_word_id` 必填 |
| `public.ios_code_hash(text)` | 驗證配對碼格式（`^[A-Za-z0-9_-]{16,128}$`）並回傳 sha256 hex。只有 service_role 能呼叫 |
| `ios_register_device(p_code)`、`ios_claim_inbox(p_code)`、`ios_unregister_device(p_code)` | security definer，只有 anon 能呼叫，給 App 用 |
| `pg_cron` 工作 `ios-inbox-cleanup` | 每天 03:00 UTC 刪除超過 7 天的收件匣，以及 180 天沒出現的裝置 |

### M1 驗收（用 iOS 後端的 publishable key）

```bash
URL=https://<IOS_REF>.supabase.co
KEY=<iOS 後端的 publishable key>
H=(-H "apikey: $KEY" -H "Content-Type: application/json")
curl -s "${H[@]}" "$URL/rest/v1/ios_inbox?select=*"                     # 預期 401 permission denied
curl -s "${H[@]}" "$URL/rest/v1/ios_devices?select=*"                   # 預期 401
curl -s "${H[@]}" -X POST -d '{"code_hash":"x","deck_name":"a","word":"a","zh":"a","source":"claude"}' "$URL/rest/v1/ios_inbox"   # 預期 401
curl -s "${H[@]}" -X POST -d '{"p_code":"TESTx0000000000000001"}' "$URL/rest/v1/rpc/ios_code_hash"        # 預期 401
curl -s "${H[@]}" -X POST -d '{"p_code":"short"}' "$URL/rest/v1/rpc/ios_register_device"                  # 預期 400 invalid code
curl -s "${H[@]}" -X POST -d '{"p_code":"TESTx0000000000000001"}' "$URL/rest/v1/rpc/ios_register_device"  # 預期 204
curl -s "${H[@]}" -X POST -d '{"p_code":"TESTx0000000000000001"}' "$URL/rest/v1/rpc/ios_claim_inbox"      # 預期 []
curl -s "${H[@]}" -X POST -d '{"p_code":"TESTx0000000000000001"}' "$URL/rest/v1/rpc/ios_unregister_device" # 預期 204
```

另外確認 `select jobname, schedule from cron.job` 有 `ios-inbox-cleanup  0 3 * * *`。

Supabase Security Advisor 會對這三個 RPC 跳「anon 可執行 security definer」警告，**這是刻意的**，不用處理。

---

## 3. 單字庫資料來源（EnRecall 專案的公開 Storage，唯讀）

單字商店是 EnRecall 專案 `packs` bucket 裡的 JSON，沒有資料表。MCP 伺服器和 iOS App 都直接用 HTTPS 讀這些公開檔案，不需要金鑰。

下面寫的 `<path>`，完整網址都是 `STORE_BASE/<path>`，其中 `STORE_BASE = https://souqknwgklqdnhguivaz.supabase.co/storage/v1/object/public/packs`。

### 3.1 商店清單 `store/catalog.json`（沒有 gzip）

```json
{ "v": 1, "packs": [
  { "id": "gsat-1", "kind": "word", "level": 1, "title": "學測 Level 1", "version": 2, "words": 960,
    "files": [ { "name": "level1.json", "path": "store/gsat-1/v2/level1.json.gz", "sha256": "…" }, … ] },
  …
  { "id": "phrasebook", "kind": "phrase", "title": "學測片語總表", "version": 2, "words": 2159,
    "files": [ { "name": "phrasebook.json", "path": "phrasebook/v2/phrasebook.json.gz" } ] }
]}
```

**只用這 7 個包**：`gsat-1`～`gsat-6`、`phrasebook`。其他的（`video`、`book-school-*`）不用管。

每個包要讀的檔案，路徑一律從 `files[].path` 拿，不要寫死版本號：

| 包 | 要讀的檔案（`files[].name`） | 不用讀 |
|---|---|---|
| `gsat-N` | `levelN.json`、`fixes-levelN.json`（有才讀） | `quiz-*`、`seed-*`、`similar-*` |
| `phrasebook` | `phrasebook.json` | — |

`.json.gz` 是 gzip，用 `DecompressionStream("gzip")` 解開。

### 3.2 單字檔 `levelN.json`、`fixes-levelN.json`

```json
{ "version": 3, "words": [
  { "word": "ability", "phonetic": "/əˈbɪləti/", "level": 1,
    "meanings": [
      { "pos": "n.", "zh": "能力；才能",
        "examples": [ { "en": "Amy has the ability to learn new languages quickly.", "zh": "Amy 有快速學習新語言的能力。" } ],
        … },
      …
    ],
    … 其他欄位（synonyms、collocations…）MCP 用不到 }
]}
```

- 六級合起來 5,938 個字，**正規化後完全不重複**，跨級也不重複
- `fixes-levelN.json` 格式一樣，裝的是**補充的字**（例如 `Dr.`、`x-ray`、`ought to`），跟主檔不重疊，直接合併進去。萬一重疊，以 fixes 為準
- 一個字常有好幾個字義，同一個詞性也可能有好幾個（例如 `add` 有兩個 `v.`）

### 3.3 片語檔 `phrasebook.json`

```json
{ "version": 2, "format": 2, "items": [
  { "no": 1933, "p": "such as", "zh": "例如；像是", "pos": "轉折／連接用語",
    "ex": "Fruits such as apples and oranges are rich in vitamins.", "exZh": "蘋果和柳橙等水果富含維生素。", … }
]}
```

2,159 條，正規化後不重複。很多片語帶佔位詞，例如 `rely on sb/sth`、`so … that …`、`look out (for sb/sth)`。

---

## 4. 共用規則（MCP 和 iOS App 必須完全一致）

### 4.1 正規化

```ts
function normalize(s: string): string {
  return s.trim().toLowerCase()
    .replace(/[’‘]/g, "'")
    .replace(/\s+/g, " ");
}
```

### 4.2 單字 id（`library_word_id`）

**一個字一張卡**，id 由正規化後的字組成，商店更新後也不會變：

| 來源 | id |
|---|---|
| 單字（gsat-1～6，含 fixes） | `w:` + normalize(word)，例如 `w:ability`、`w:dr.` |
| 片語（phrasebook） | `p:` + normalize(p)，例如 `p:rely on sb/sth` |

### 4.3 單字庫的一筆資料怎麼變成一張卡

單字（`w:`）：

| 欄位 | 規則 |
|---|---|
| `word` | 原本的 `word`（保留大小寫，例如 `Dr.`） |
| `pos` | 各字義的 `pos` 去重複、照出現順序，用 ` / ` 接起來。例如 `n.`、`n. / v.` |
| `zh` | 只有一種詞性：各字義的 `zh` 用 `；` 接起來。有多種詞性：每個字義一行 `「<pos> <zh>」`，用 `\n` 接起來。例如 `n. 紀錄\nv. 記錄` |
| `example` / `example_zh` | 第一個有例句的字義，它的 `examples[0].en` 和 `.zh`；都沒有就給 `null` |

片語（`p:`）：`word = p`、`pos = pos`、`zh = zh`、`example = ex`、`example_zh = exZh`。

### 4.4 片語的備用比對 key

Claude 常常只送 `rely on`，不會帶 `sb/sth`。所以每個片語除了正規化後的完整字串，再多建一個「核心 key」：

```ts
function phraseCore(p: string): string {
  return normalize(p)
    .replace(/\([^)]*\)|（[^）]*）/g, " ")             // 括號內容
    .replace(/\b(sb\/sth|sb|sth|one's|oneself|v-ing|v)\b/g, " ")
    .replace(/…|\.\.\./g, " ")
    .replace(/\s+/g, " ").trim();
}
```

比對順序：

1. 單字 key
2. 片語完整 key
3. 片語核心 key

核心 key 可能對到好幾條片語，這時全部回傳。

---

## 5. Edge Function `enrecall-mcp`

### 5.1 基本規格

- 執行環境：Supabase Edge Functions（Deno）
- 協定：MCP **Streamable HTTP、無狀態**（不發 session id，每個請求獨立處理）。只需要支援 `POST`。`GET` 回 405
- 套件：`mcp-lite` + Hono，或 `@modelcontextprotocol/sdk`（stateless 模式）。選一個就好
- 原始碼放在 `EnRecall/supabase/functions/enrecall-mcp/index.ts`
- 部署：`supabase functions deploy enrecall-mcp --no-verify-jwt --project-ref <IOS_REF>`。用 MCP 工具部署的話，`verify_jwt` 要設 `false`
- 資料庫存取（iOS 後端自己的資料庫）：`createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"))`
- 單字庫：讀環境變數 `STORE_BASE`，沒設就用預設值 `https://souqknwgklqdnhguivaz.supabase.co/storage/v1/object/public/packs`。只能用 `fetch` GET
- 伺服器名稱 `enrecall-ios`，版本 `1.0.0`

### 5.2 網址與配對碼

```
https://<IOS_REF>.supabase.co/functions/v1/enrecall-mcp/<配對碼>
```

- 函式收到的路徑是 `/enrecall-mcp/<配對碼>`，取最後一段
- 配對碼是 App 產生的 24 字元隨機字串，字元集 `A-Z a-z 0-9`。伺服器端用 `^[A-Za-z0-9_-]{16,128}$` 驗證
- `code_hash = sha256(配對碼) 的小寫 hex`（`crypto.subtle.digest`）。必須跟資料庫的 `ios_code_hash()` 算出來的一樣
- 用 `code_hash` 查 `ios_devices`
  - 格式不對或查不到：`initialize`、`tools/list` 照常回應；**三個工具被呼叫時都回傳錯誤**（`isError: true`），文字是：`配對碼無效，請在 EnRecall App 的設定頁重新複製連接器網址。`
  - 查得到：順便更新 `last_seen = now()`

### 5.3 單字庫索引（在記憶體裡）

- 第一次需要時建立，存在模組層級的變數，**10 分鐘後重新讀 catalog.json**。各包的 `version` 有變才重建
- 建索引時一次只解析一個檔，取出 4.3 需要的欄位就把原始物件丟掉，避免吃太多記憶體（原始 JSON 解開後約 30 MB）
- 索引結構：
  - `byId: Map<id, Entry>`
  - `byWord: Map<normalize(word), id>`
  - `byPhrase: Map<normalize(p), id>`
  - `byPhraseCore: Map<core, id[]>`
- `Entry = { library_word_id, word, pos, zh, example, example_zh, pack }`
- 讀 Storage 失敗：工具回傳錯誤 `單字庫暫時讀不到，請稍後再試。`，不要寫入任何東西

### 5.4 伺服器說明（`instructions`）

```
你正在協助使用者把單字加進 EnRecall App 的牌組。流程：
1. 從使用者提供的圖片或文字辨識出英文單字與片語。
2. 一律轉成原形（ran→run、studies→study、children→child），片語保留原樣（不要加 sb/sth）。
3. 先呼叫 lookup_words。found 的字直接使用回傳資料，不要自己寫例句或改中文。
4. 只有 not_found 的字才由你撰寫：詞性、繁體中文解釋、一句適合高中生程度的英文例句與中文翻譯。
5. 呼叫 add_words 送出（found 的字帶上 library_word_id）。完成後告訴使用者：共幾個字、幾個來自單字庫、幾個是你寫的，並提醒打開 EnRecall App 匯入。
單字庫的一個字是一張卡，裡面已經包含所有詞性與字義，不用挑。
```

### 5.5 工具 `lookup_words`

查單字庫裡有沒有這些字。

輸入：

```json
{ "type": "object",
  "properties": { "words": { "type": "array", "items": { "type": "string" }, "minItems": 1, "maxItems": 200, "description": "原形單字或片語" } },
  "required": ["words"] }
```

輸出（JSON 字串放在 `content[0].text`，同一份也放 `structuredContent`）：

```json
{
  "found": [
    { "query": "record",
      "entries": [ { "library_word_id": "w:record", "word": "record", "pos": "n. / v.", "zh": "n. 紀錄\nv. 記錄", "example": "…", "example_zh": "…" } ] },
    { "query": "rely on",
      "entries": [ { "library_word_id": "p:rely on sb/sth", "word": "rely on sb/sth", "pos": "動詞片語（不可分）", "zh": "依賴；信賴", "example": "…", "example_zh": "…" } ] }
  ],
  "not_found": ["photosynthesis"]
}
```

- 用 4.4 的比對順序。單字通常只有 1 筆 entry，片語核心 key 可能有好幾筆
- 輸入重複的字只查一次

### 5.6 工具 `add_words`

把單字送進收件匣。

輸入：

```json
{ "type": "object",
  "properties": {
    "deck": { "type": "string", "description": "目標牌組名稱，不存在時 App 會自動建立" },
    "words": { "type": "array", "minItems": 1, "maxItems": 200,
      "items": { "type": "object",
        "properties": {
          "word": { "type": "string" }, "pos": { "type": "string" }, "zh": { "type": "string" },
          "example": { "type": "string" }, "example_zh": { "type": "string" },
          "library_word_id": { "type": "string", "description": "lookup_words 回傳的 id；有就填" } },
        "required": ["word"] } } },
  "required": ["deck", "words"] }
```

**伺服器端強制規則**：就算 Claude 沒有先呼叫 lookup，下面這些也一定要成立。

1. `deck` 去掉頭尾空白後必須是 1–60 字，否則整次呼叫回錯誤 `牌組名稱要 1–60 個字。`
2. 每個字依序判斷：
   1. 有 `library_word_id`，而且 `byId` 查得到：用單字庫的資料**覆蓋 Claude 送來的所有欄位**，`source = 'library'`
   2. 沒有 id，或 id 查不到：用 4.4 的順序比對 `word`
      - 對到 1 筆：用單字庫的資料，`source = 'library'`
      - 對到多筆（只會發生在片語核心 key）：全部加入，都是 `source = 'library'`
      - 都沒對到：用 Claude 的內容，`source = 'claude'`，`library_word_id = null`。這時 `zh` 必填，沒有就放進 `rejected`，原因是 `缺少中文解釋`
   3. `word` 去掉頭尾空白後是空的，或超過 120 字：放進 `rejected`，原因是 `單字格式不正確`
3. 同一次呼叫內重複的只留一筆。去重 key：`library` 用 `library_word_id`，`claude` 用 `normalize(word) + "|" + normalize(pos ?? "")`
4. 收件匣上限：這台裝置現有的筆數加上這次要加的超過 **2000** 筆，就整次拒絕，錯誤訊息是 `收件匣已滿（2000 筆），請先打開 EnRecall App 匯入。`
5. 一次 `insert` 寫進 `ios_inbox`，欄位對應 `deck_name = deck`。空字串一律存成 `null`

輸出：

```json
{ "deck": "第 3 課", "added": 25, "from_library": 18, "from_claude": 7,
  "rejected": [ { "word": "xxx", "reason": "缺少中文解釋" } ],
  "message": "已送出 25 個單字，請打開 EnRecall App 匯入。" }
```

### 5.7 工具 `check_inbox`

- 輸入：無（`{ "type": "object", "properties": {} }`）
- 輸出：`{ "pending": 25, "decks": [ { "deck": "第 3 課", "count": 25 } ] }`，依 `deck_name` 分組，最早建立的排前面

### 5.8 錯誤處理

- 工具執行的錯誤：回 `{ content: [{ type: "text", text: "<中文訊息>" }], isError: true }`，不要拋出例外變成 HTTP 500
- JSON-RPC 格式錯誤：照 MCP 規範回 JSON-RPC error
- log 只印錯誤類型。**不要印出配對碼**

---

## 6. 驗收（全部通過才算完成）

先準備一組測試配對碼，測完一定要刪掉：

```bash
URL=https://<IOS_REF>.supabase.co
KEY=<iOS 後端的 publishable key>
CODE=TESTmuse$(openssl rand -hex 10)
curl -s -X POST "$URL/rest/v1/rpc/ios_register_device" -H "apikey: $KEY" -H "Content-Type: application/json" -d "{\"p_code\":\"$CODE\"}"
MCP="$URL/functions/v1/enrecall-mcp/$CODE"
```

用 MCP Inspector（`npx @modelcontextprotocol/inspector`，選 Streamable HTTP），或直接用 curl 送 JSON-RPC（header 加 `Accept: application/json, text/event-stream`）：

| # | 測試 | 預期 |
|---|---|---|
| 1 | `initialize`、`tools/list` | 三個工具，schema 跟 5.5–5.7 一致 |
| 2 | 用錯的配對碼（例如 `.../enrecall-mcp/wrongcode0000000000`）呼叫 `add_words` | `isError: true`，訊息是「配對碼無效…」；`ios_inbox` 沒有新資料 |
| 3 | `lookup_words(["Ability", " record ", "rely on", "photosynthesis"])` | 前三個 found，id 分別是 `w:ability`、`w:record`、`p:rely on sb/sth`；`photosynthesis` 在 not_found |
| 4 | `add_words` 送 `{"word":"Ran"}`，沒帶 zh，也沒先查 | rejected（`ran` 不在單字庫，`run` 才在）。這是預期行為，原形由 Claude 負責 |
| 5 | `add_words` 送 `{"word":"ability","zh":"亂寫","example":"My own sentence."}` | `source=library`；`ios_inbox` 存的是單字庫的中文和例句 |
| 6 | `add_words` 送 `{"word":"photosynthesis"}`，沒有 zh | rejected，原因是 `缺少中文解釋` |
| 7 | `add_words` 送 `photosynthesis` 加完整內容 | `source=claude`、`library_word_id` 是 null |
| 8 | 同一次呼叫送兩個 `ability` | `added` 只算 1 |
| 9 | `check_inbox` | 數量跟上面加的一致，依牌組分組 |
| 10 | 用 anon 呼叫 `ios_claim_inbox(CODE)` | 拿回全部資料；再呼叫一次是空的 |
| 11 | `fixes` 的字：`lookup_words(["x-ray", "Dr."])` | 兩個都 found |

收尾（**一定要做**）：

```bash
curl -s -X POST "$URL/rest/v1/rpc/ios_unregister_device" -H "apikey: $KEY" -H "Content-Type: application/json" -d "{\"p_code\":\"$CODE\"}"
```

做完確認 `select count(*) from ios_devices` 和 `select count(*) from ios_inbox` 都回到測試前的數字。

最後跑一次 Supabase Security Advisor，除了第 2 節說的三個 RPC 警告，不能有跟 `ios_*` 或 `enrecall-mcp` 有關的新警告。

---

## 7. 交付物

1. iOS 後端專案已套用 M1 migration，`enrecall-mcp` 已部署（`verify_jwt = false`）
2. `EnRecall/supabase/functions/enrecall-mcp/index.ts`（以及 `deno.json`，如果有用到）
3. 一份簡短回報，內容包括：
   - **iOS 後端的 API URL 和 publishable key**（App 的設定檔要用。這兩個是公開值，**不要**附 service role key）
   - 第 2 節 M1 驗收、第 6 節每一項的結果
   - 函式版本號
   - 跟這份規劃書不一樣的地方和原因

使用者在 Claude App 新增連接器時用的網址：

```
https://<IOS_REF>.supabase.co/functions/v1/enrecall-mcp/<App 設定頁顯示的配對碼>
```
