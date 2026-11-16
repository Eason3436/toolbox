# EnRecall iOS — 部署規劃書 4：句型卡與句型庫

接在 `DEPLOY-3.md`（學習紀錄、講義 PDF）之後。使用者常背雜誌，雜誌裡的句型請 Claude 整理好（結構、每個空格能放什麼、例句、變化、搭配、相近句型、常見錯誤、記法），透過連接器送進 App 當成「句型卡」用 FSRS 背。

- 只動 **iOS 後端專案**（`zjlitlhepabrvvtpcjgz`）。使用者自己的 EnRecall 專案（`souqknwgklqdnhguivaz`）不碰
- **句型庫**：整理過的句型存在 `ios_patterns`（共用、不分裝置）。下次遇到同一個句型直接用庫裡的，不用重寫
- App 0.11.0 起看得懂收件匣的 `kind = 'pattern'`；舊 App 會把句型當單字匯入，所以部署完請使用者更新 App
- 既有工具行為不變

## 1. Migration

套用 `migrations/20261116180000_ios_patterns.sql`：

- 新表 `ios_patterns(id 'pt:…' pk, key unique, pattern, zh, detail jsonb ≤ 32 KB, uses, created_at, updated_at)`，RLS 開、無 policy、權限收回
- `ios_inbox` 加 `kind text default 'word'`（`word`／`pattern`）、`detail jsonb`；`kind = 'pattern'` 時 `detail` 必填、`library_word_id` 是 `pt:` 開頭
- 重建 `ios_claim_inbox`（回傳多了 `kind`、`detail`）

## 2. 句型的 key 和 id

- `anchors`：句型裡**固定不變的英文字**，依出現順序，例如 `It is not until + 時間 + that + S + V` → `["it is not until", "that"]`
- 正規化每個 anchor：小寫、彎引號換直引號、連續空白變一個、去頭尾空白；be／do／have 換成原形（`am`／`are`／`was`／`were`／`been` → `is`，`does`／`did` → `do`，`has`／`had` → `have`），所以 `it was not until` 和 `it is not until` 是同一個
- `key = anchors.join("|")`，`id = "pt:" + key`
- 1–6 個 anchor，每個 1–60 字，只能有英文字母、空白、`'`、`-`

## 3. 句型內容（`detail`）

App 照這個格式顯示（`EnRecall/EnRecall/Models/PatternDetail.swift`），欄位名稱一字不差：

```json
{
  "pattern": "It is not until + 時間／子句 + that + S + V",
  "zh": "直到…才…",
  "anchors": ["it is not until", "that"],
  "level": "進階",
  "register": "正式，寫作常用",
  "explanation": "強調「到某個時間點才發生」。not until 後面放時間或子句，that 後面接完整的肯定句。",
  "slots": [
    { "slot": "時間／子句", "accepts": "時間名詞片語，或 until 後面接完整子句", "examples": ["midnight", "she moved to Taipei"] },
    { "slot": "S + V", "accepts": "完整的肯定句，時態跟著前面", "examples": ["I realized the truth"] }
  ],
  "examples": [
    { "en": "It was not until the 1990s that the internet became popular.", "zh": "直到 1990 年代網路才普及。", "source": "Studio Classroom 2026/11" },
    { "en": "It is not until we lose our health that we know its value.", "zh": "直到失去健康，我們才知道它的可貴。" }
  ],
  "variations": [
    { "form": "Not until + 時間 + 助動詞 + S + V", "note": "倒裝", "en": "Not until midnight did he finish his report.", "zh": "直到半夜他才寫完報告。" }
  ],
  "collocations": [ { "en": "It was not until later that …", "zh": "直到後來才…" } ],
  "similar": [ { "pattern": "Only when + 子句 + 助動詞 + S + V", "diff": "只有在…才…，一樣要倒裝", "en": "Only when you try will you know.", "zh": "只有試了才會知道。" } ],
  "errors": [ { "wrong": "It was not until midnight that he didn't finish it.", "right": "It was not until midnight that he finished it.", "note": "that 後面用肯定句" } ],
  "tips": "not until 先講時間，that 後面才是終於發生的事。"
}
```

| 欄位 | 必填 | 說明 |
|---|---|---|
| `pattern` | ● | 句型公式。空格用中文或 S／V／N／Ving 標，用 ` + ` 連，≤ 120 字 |
| `zh` | ● | 中文意思，≤ 120 字 |
| `anchors` | ● | 見第 2 節 |
| `slots` | ● | 至少 1 個：`slot` 空格名稱、`accepts` 能放什麼（詞性、片語、子句、時態限制）、`examples` 2–4 個能放進去的詞 |
| `examples` | ● | 2–5 句，`en`＋`zh`；雜誌原句放第一句並填 `source` |
| `level` |  | `基礎`／`進階`／`寫作` |
| `register` |  | 語氣與場合 |
| `explanation` |  | 2–4 句用法說明 |
| `variations` |  | 其他寫法（倒裝、省略、口語版），`form` 必填 |
| `collocations` |  | 常跟這個句型一起出現的詞 |
| `similar` |  | 相近句型的差別，`pattern` 必填 |
| `errors` |  | 常見錯誤，`wrong`／`right`／`note` |
| `tips` |  | 一句記法 |

伺服器驗證：必填欄位、型別（字串／陣列）、每個陣列 ≤ 10 筆、整份 ≤ 32 KB。多出來的欄位刪掉再存。

## 4. MCP 工具（enrecall-mcp v4，版本 `4.0.0`）

配對碼驗證與錯誤格式照 `DEPLOY.md` 5.2、5.8。

### 4.1 `lookup_patterns`

整理前先查庫裡有沒有。

輸入：`{ "patterns": [ { "pattern": "公式（選填）", "anchors": ["it is not until", "that"] } ] }`（1–50 個）

輸出：

```json
{
  "found": [ { "query": ["it is not until", "that"], "id": "pt:it is not until|that", "pattern": "…", "zh": "…", "detail": { … }, "uses": 3 } ],
  "similar": [ { "query": ["not until"], "candidates": [ { "id": "pt:it is not until|that", "pattern": "…", "zh": "…" } ] } ],
  "not_found": [ ["make it a rule to"] ]
}
```

- `found`：key 完全一樣
- `similar`：key 不一樣，但有一個 anchor 包含在庫裡某個句型的 anchor 裡（或反過來），最多 5 個候選。讓 Claude 判斷是不是同一個句型

### 4.2 `add_patterns`

把句型送進收件匣，順便存進句型庫。

輸入：

```json
{ "deck": "雜誌句型 11 月",
  "patterns": [ { "id": "pt:…（lookup 找到的就只填 id）", "detail": { …第 3 節… } } ],
  "update_library": false }
```

每一筆依序：

1. 有 `id` 而且庫裡有：用庫裡的內容，`uses + 1`
2. 沒有 `id`：驗證 `detail`，算 key
   - 庫裡已經有這個 key：用庫裡的（`update_library = true` 時改用新的內容覆蓋、`updated_at = now()`），`uses + 1`
   - 庫裡沒有：存進 `ios_patterns`
   - 驗證失敗：放進 `rejected`，原因寫哪個欄位不對
3. 寫進 `ios_inbox`：`kind = 'pattern'`、`word = pattern`、`zh = zh`、`pos = level`、`example`／`example_zh` = 第一句例句、`source = 'library'`、`library_word_id = id`、`detail = 庫裡最後的內容`
4. 同一次呼叫內同一個 id 只留一筆；收件匣 2000 筆上限照 `add_words`

輸出：`{ "deck", "added", "from_library", "saved_new", "updated", "rejected": [ { "pattern", "reason" } ], "message": "已送出 3 個句型，請打開 EnRecall App 匯入。" }`

### 4.3 `list_patterns`

看庫裡存了哪些句型。輸入：`{ "query": "選填，比對 pattern／zh／key", "limit": 1–100（預設 30） }`。輸出：`{ "total": 42, "patterns": [ { "id", "pattern", "zh", "level", "uses", "updated_at" } ] }`，最近更新的在前。

### 4.4 `read_docs` 加一份 `pattern-guide`

`read_docs("pattern-guide")` 回傳第 3 節（格式與欄位表）加上第 5 節「整理句型的規則」。`available` 變成 `["pdf-handout", "pattern-guide"]`。

### 4.5 `instructions` 換成這段

```
你可以幫使用者做三件事：

一、把單字加進 EnRecall App 的牌組：
1. 從使用者提供的圖片或文字辨識出英文單字與片語。
2. 一律轉成原形（ran→run、studies→study、children→child），片語保留原樣（不要加 sb/sth）。
3. 先呼叫 lookup_words。found 的字直接使用回傳資料，不要自己寫例句或改中文。
4. 只有 not_found 的字才由你撰寫：詞性、繁體中文解釋、一句適合高中生程度的英文例句與中文翻譯。
5. 呼叫 add_words 送出（found 的字帶上 library_word_id）。完成後告訴使用者：共幾個字、幾個來自單字庫、幾個是你寫的，並提醒打開 EnRecall App 匯入。
單字庫的一個字是一張卡，裡面已經包含所有詞性與字義，不用挑。

二、把句型做成句型卡（使用者說「句型」、或圖片是雜誌文章並要求整理句型時）：
1. 先 read_docs("pattern-guide") 看格式。
2. 從文章找出值得背的句型（固定結構、可以套用在寫作的），每個句型列出 anchors（固定不變的英文字，原形）。
3. 呼叫 lookup_patterns。found 的直接用 id；similar 的自己判斷是不是同一個句型；not_found 的才照格式完整整理（雜誌原句當第一句例句並寫出處）。
4. 呼叫 add_patterns 送出。完成後告訴使用者：幾個句型、幾個是庫裡現成的、幾個是新整理的，並提醒打開 App 匯入。
單字和句型可以同一次一起做：單字用 add_words，句型用 add_patterns。

三、看學習成效、做複習講義：
- 問最近背得怎樣：先 overview，要細節再 analyze_learning。用數字和短句回答，建議具體、一兩點就好。資料是 App 上次上傳的（看 snapshot_at），太舊就請使用者打開 App。
- 要講義／自測卷／速查表 PDF：先 read_docs("pdf-handout")，照文件挑字、用 get_words 拿完整內容，排成 HTML 再轉 PDF。不要自己編字義或例句。
```

## 5. 整理句型的規則（`pattern-guide` 的後半）

```markdown
## 整理句型的規則

- 對象是高中生（學測程度），解釋用繁體中文、白話，不用文法術語堆疊；必要的術語（倒裝、分詞構句）第一次出現時用一句話說明。
- 挑句型：選「換掉空格就能自己造句」的結構（It is not until … that、The + 比較級 …, the + 比較級 …、be likely to V），不要選一次性的慣用語或單一片語（那些用 add_words）。
- pattern 公式：固定的英文照寫，空格用中文或 S／V／N／Ving／adj. 標，用 ` + ` 連。不要用 sb/sth。
- anchors：只放固定不變的英文字，依出現順序，一律原形（is、do、have）。至少要有一個兩個字以上的詞組，伺服器才認得出是同一個句型；固定字太少的句型（The + 比較級 …, the + 比較級 …）用最常見的寫法當 anchors，例如 ["the more", "the more"]。App 會用 anchors 在例句裡畫螢光標記。
- slots：每個空格寫清楚能放什麼詞性、片語或子句，有沒有時態或單複數限制，附 2–4 個能直接放進去的例子。
- examples：2–5 句。雜誌原句放第一句、source 寫雜誌名稱和期數；其他句子要日常、短、跟原句不同情境，翻譯自然。
- variations、similar：只寫學測常見、真的會混淆的；沒有就省略，不要硬湊。
- errors：寫學生真的會犯的錯，wrong 和 right 都要是完整句子。
- 不確定的內容寧可省略，不要編。
```

## 6. 驗收

1. 套 migration、部署 v4 後 `tools/list` 有 11 個工具
2. `add_patterns` 送一個新句型 → `ios_patterns` 多一筆、`ios_inbox` 多一筆 `kind = pattern`
3. App 0.11.0 打開 → 牌組頁「句型卡」出現該牌組，卡片背面有結構、例句、變化…分頁，例句裡固定字有螢光標記
4. 再送一次同一個句型（只填 id）→ `ios_patterns` 不增加、`uses = 2`；App 不重複建卡
5. `lookup_patterns` 用時態不同的 anchors（`it was not until`）→ 正規化後一樣找得到
6. `detail` 缺 `slots` → `rejected` 寫原因，不寫入
7. 舊的三個單字工具照常
