# EnRecall iOS — 部署規劃書 3：學習紀錄與講義 PDF

接在 `DEPLOY.md`（M1 資料庫 + M2 MCP）之後。目的：讓 Claude 透過連接器看得到 App 的複習成效，並能像 Android 版一樣排出單字講義／自測卷／速查表 PDF。

- 只動 **iOS 後端專案**（`zjlitlhepabrvvtpcjgz`）。使用者自己的 EnRecall 專案（`souqknwgklqdnhguivaz`）一樣只能讀公開 Storage，**不能碰資料表**
- App 0.10.0 起會自動呼叫 `ios_push_snapshot`；後端還沒部署前 App 安靜失敗，不影響使用
- 既有三個工具（`lookup_words`、`add_words`、`check_inbox`）行為不變

## 1. Migration

套用 `migrations/20261116160000_ios_snapshots.sql`：

- 表 `ios_snapshots(code_hash pk → ios_devices on delete cascade, payload jsonb, updated_at)`，RLS 開、無 policy、權限收回
- RPC `ios_push_snapshot(p_code text, p_payload jsonb)`：security definer，用 `ios_code_hash()` 算 hash；payload 要是有 `v` 的物件、≤ 8 MB；裝置沒註冊就順便註冊；整份覆蓋
- 只給 anon 執行 `ios_push_snapshot`

### 驗收

```bash
# 用 publishable key；p_code 換成 24 字元測試碼
curl -X POST "$URL/rest/v1/rpc/ios_push_snapshot" -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" -d '{"p_code":"TestCodeTestCodeTest1234","p_payload":{"v":1,"decks":[],"cards":[],"logs":[]}}'
# → 204
# anon 直接 select ios_snapshots → 拿不到資料
# 測完 ios_unregister_device 刪掉測試碼，ios_snapshots 那筆跟著刪掉
```

## 2. 快照格式（App 上傳的 `p_payload`）

key 是 snake_case，時間是 ISO 8601（UTC，例如 `2026-11-16T08:30:00Z`）。

```json
{
  "v": 1,
  "generated_at": "2026-11-16T08:30:00Z",
  "app_version": "0.10.0",
  "time_zone": "Asia/Taipei",
  "daily_new_limit": 20,
  "decks": [
    { "id": "gsat-4", "name": "學測 Level 4", "kind": "storePack", "category": "word",
      "mode": "active", "level": 4, "daily_new_limit": 10,
      "total": 1000, "new": 820, "learning": 12, "review": 168, "mastered": 40 }
  ],
  "cards": [
    { "id": "w:absolute", "deck": "gsat-4", "word": "absolute", "pos": "adj.", "zh": "完全的；絕對的",
      "source": "library", "state": "review", "due": "2026-11-20T00:00:00Z",
      "stability": 6.2, "difficulty": 5.8, "reps": 4, "lapses": 1, "last_review": "2026-11-14T12:00:00Z" }
  ],
  "logs": [
    { "c": "w:absolute", "r": 3, "s": "review", "t": "2026-11-14T12:00:00Z", "d": 6 }
  ]
}
```

| 欄位 | 說明 |
|---|---|
| `decks[].kind` | `storePack`（單字商店）／`custom`（從 Claude 匯入） |
| `decks[].mode` | `active` 學新字／`reviewOnly` 只複習／`paused` 暫停 |
| `decks[].mastered` | `state = review` 且 `stability ≥ 21` 天 |
| `cards` | **只有學過的卡**（`reps > 0`），加上自訂牌組的全部卡。沒學過的單字庫字不在裡面，只算在 `decks[].new` |
| `cards[].id` | 單字庫的卡 = `library_word_id`（`w:absolute`、`p:such as`）；Claude 寫的 = `claude:<uuid>` |
| `cards[].state` | `new`／`learning`／`review`／`relearning` |
| `cards[].source` | `library`／`claude` |
| `logs` | 最近 90 天的每一次評分，舊的在前。`c` 卡 id、`r` 評分（1 不會、2 模糊、3 認識、4 很熟）、`s` 評分前的狀態（`new` = 那天第一次學）、`t` 時間、`d` 排到幾天後 |

## 3. MCP：enrecall-mcp v3

版本改成 `3.0.0`。新增五個工具，配對碼驗證與錯誤格式照 `DEPLOY.md` 5.2、5.8。

讀快照：`select payload, updated_at from ios_snapshots where code_hash = $1`。沒有資料時，下面前四個工具都回錯誤（`isError: true`）：
`還沒收到學習紀錄。請打開 EnRecall App（設定 › Claude 連接器 › 分享學習紀錄要打開），回到前景後會自動上傳。`

### 3.1 共用計算

- **日期**：一律換成快照的 `time_zone` 再分日
- **記得的機率**（FSRS-5）：`R = (1 + 19/81 × t / S) ^ (−0.5)`，`t` = 現在 − `last_review`（天，可以有小數），`S` = `stability`。`new` 卡沒有 R
- **記憶點**：`●` 的數量 = `ceil(R × 5)`，至少 1 顆，例如 `●●○○○`
- **答對率**：`r ≥ 2` 的比例。分開算「複習」（`s` 是 `review`）和「學習中」（`learning`／`relearning`）；`s = new` 的不算進答對率
- **最常忘**：`lapses` 多的在前，同分比 R 低的
- **快忘掉**：`state = review` 且 R < 0.9，R 低的在前
- 每個輸出都帶 `snapshot_at`（`updated_at`），讓 Claude 知道資料多新

### 3.2 `overview`

輸入：無。輸出：

```json
{
  "snapshot_at": "2026-11-16T08:30:00Z",
  "app_version": "0.10.0",
  "today": { "reviews": 42, "new_learned": 10, "accuracy": 0.86, "minutes_est": 9 },
  "due": { "today": 35, "tomorrow": 28, "next_7_days": 160 },
  "streak_days": 5,
  "last_7_days": { "reviews": 260, "new_learned": 60, "accuracy": 0.84, "active_days": 6 },
  "decks": [ { "name": "學測 Level 4", "mode": "active", "total": 1000, "learned": 180, "mastered": 40, "new_left": 820 } ],
  "totals": { "learned": 520, "mastered": 130 }
}
```

- `due.today`：`due` ≤ 今天結束的卡（不含 new）
- `streak_days`：到今天（今天還沒複習就從昨天算）連續有複習的天數
- `minutes_est`：評分次數 × 8 秒，四捨五入到分鐘

### 3.3 `analyze_learning`

輸入：`{ "days": 1–90（預設 14）, "top": 1–50（預設 15）, "deck": "牌組名稱或 id（選填）" }`。輸出：

```json
{
  "snapshot_at": "…",
  "range": { "from": "2026-11-03", "to": "2026-11-16", "days": 14 },
  "daily": [ { "date": "2026-11-16", "reviews": 42, "new_learned": 10, "accuracy": 0.86 } ],
  "ratings": { "1": 30, "2": 55, "3": 160, "4": 75 },
  "accuracy": { "review": 0.88, "learning": 0.71 },
  "most_forgotten": [ { "id": "w:absolute", "word": "absolute", "zh": "…", "lapses": 3, "recall": 0.42, "memory": "●●○○○", "deck": "學測 Level 4" } ],
  "fading": [ { "id": "…", "word": "…", "zh": "…", "recall": 0.71, "due": "2026-11-17", "memory": "●●●●○" } ],
  "decks": [ { "name": "學測 Level 4", "reviews": 120, "accuracy": 0.83, "learned_in_range": 40 } ],
  "notes": [ "這 14 天有 3 天沒複習", "Level 5 的答對率比其他牌組低 12%" ]
}
```

- `daily` 每一天都要有（沒複習的天 0），舊的在前
- `notes`：伺服器只寫事實（缺幾天、哪個牌組答對率最低、評分「不會」的比例），不寫建議；建議讓 Claude 自己說

### 3.4 `list_words`

挑要印成講義的字。輸入：

```json
{ "deck": "牌組名稱或 id（選填）",
  "state": "learning | review | mastered | all（預設 all）",
  "sort": "weakest | lapses | recent | due | alphabet（預設 weakest）",
  "min_lapses": 0,
  "reviewed_within_days": "選填，最近 N 天複習過的",
  "limit": 1–300（預設 50） }
```

- `weakest`：R 低的在前；`recent`：`last_review` 新的在前；`due`：`due` 早的在前
- 輸出：`{ "snapshot_at": "…", "total_matched": 87, "words": [ { "id", "word", "pos", "zh", "deck", "state", "recall", "memory", "lapses", "reps", "due", "last_review", "source" } ] }`

### 3.5 `get_words`

講義要用的完整內容（跟 App 卡片背面同一份資料）。輸入：`{ "ids": ["w:absolute", "p:such as"]（1–120 個）}`，也接受 `words`（原形，用 `DEPLOY.md` 4.4 比對）。

- 找到哪個包：`DEPLOY.md` 5.3 的索引已經有 `pack`，按包分組，**一次只解析一個包**，取出要的那幾筆就丟掉
- 單字：回傳 `levelN.json` 那一筆套上 `fixes-levelN.json` 之後的**原樣物件**（音標、字義、例句、搭配、句型、片語、近義／反義、易混淆、常見錯誤、字源、同字根），另外加 `similar`：`similar-levelN.json` 裡含這個字的比較組
- 片語：`phrasebook.json` 那一筆原樣
- 有快照時每筆加上學習狀態：`{ "progress": { "recall": 0.42, "memory": "●●○○○", "lapses": 3, "state": "review" } }`；沒學過寫 `"memory": "新字"`
- `claude:` 開頭的 id：從快照的 `cards` 回傳 `word`、`pos`、`zh`（沒有完整內容）
- 輸出：`{ "words": [ … ], "not_found": [ … ] }`

### 3.6 `read_docs`

輸入：`{ "name": "pdf-handout" }`。回傳第 5 節的文件全文（Markdown）。`name` 不對時回 `{ "available": ["pdf-handout"] }`。

### 3.7 `instructions` 換成這段

```
你可以幫使用者做兩件事：

一、把單字加進 EnRecall App 的牌組：
1. 從使用者提供的圖片或文字辨識出英文單字與片語。
2. 一律轉成原形（ran→run、studies→study、children→child），片語保留原樣（不要加 sb/sth）。
3. 先呼叫 lookup_words。found 的字直接使用回傳資料，不要自己寫例句或改中文。
4. 只有 not_found 的字才由你撰寫：詞性、繁體中文解釋、一句適合高中生程度的英文例句與中文翻譯。
5. 呼叫 add_words 送出（found 的字帶上 library_word_id）。完成後告訴使用者：共幾個字、幾個來自單字庫、幾個是你寫的，並提醒打開 EnRecall App 匯入。
單字庫的一個字是一張卡，裡面已經包含所有詞性與字義，不用挑。

二、看學習成效、做複習講義：
- 問最近背得怎樣：先 overview，要細節再 analyze_learning。用數字和短句回答（每天幾個、答對率、最常忘的字），建議具體、一兩點就好。資料是 App 上次上傳的（看 snapshot_at），太舊就請使用者打開 App。
- 要講義／自測卷／速查表 PDF：先 read_docs("pdf-handout")，照文件挑字（list_words 或 analyze_learning 的 most_forgotten、fading）、用 get_words 拿完整內容，排成 HTML 再轉 PDF。不要自己編字義或例句。
```

## 4. 驗收

1. 套 migration、部署 v3 後，`tools/list` 有 8 個工具
2. 用 App 0.10.0 的配對碼：打開 App → 背幾張 → 關掉複習 → `ios_snapshots` 有那台裝置的資料，`updated_at` 是剛剛
3. `overview` 的今天評分數跟 App「紀錄」頁一樣
4. `list_words` `sort=weakest` 前幾個是 App 裡剛評「不會」的字
5. `get_words(["w:absolute"])` 有搭配、近義、易混淆、`similar`
6. 錯的配對碼：五個新工具都回「配對碼無效…」
7. 沒有快照的配對碼：四個資料工具回「還沒收到學習紀錄…」，`read_docs` 照常
8. 在 Claude App 說「幫我把最近最常忘的 30 個字做成講義 PDF」→ 產出的 PDF 符合第 5 節

## 5. 文件 `pdf-handout`（`read_docs` 回傳這一整節，不含這行說明）

````markdown
# 單字 PDF（講義・自測卷・速查表）

使用者要把單字印出來時照這份做。三種用途，選的是「拿來做什麼」：

| 用途 | 給誰 | 長相 |
|---|---|---|
| **講義**（讀） | 想複習、要看完整內容 | 左欄字＋右欄字義、例句、延伸，一字一列 |
| **自測卷**（考） | 想考自己 | 一題一列＋右邊寫答案的線，答案在最後一頁 |
| **速查表**（查） | 考前快速掃過 | 四欄，一行一字 |

使用者沒說就做講義。易混淆字對（get_words 的 similar）只放講義。

## 資料從哪裡來

| PDF 上的東西 | 來源 |
|---|---|
| 要印哪些字 | 使用者指定；或 list_words（例如 sort=weakest、min_lapses=2、deck）、analyze_learning 的 most_forgotten／fading |
| 字、音標、級別、字義、搭配、例句、句型、近義・反義、易混淆、常見錯誤、字源、同根 | get_words |
| 記憶點 ●●●○○、忘 N | get_words 的 progress（memory、lapses）；沒學過寫「新字」 |
| 片語 | get_words（p: 開頭的 id） |

不要自己編字義或例句：get_words 有的照抄；Claude 寫的字（claude: 開頭）只有字、詞性、中文，就只印這些，寧可少一行也不要寫錯。

## 共同的頁面

- A4 直式，以 794×1123 px 計算：左右留白 38px，內容寬 718px。白底、**只用黑白灰**（黑白印表機印出來要一樣清楚），不用彩色、不加底色塊。
- 字型：中文無襯線（Noto Sans TC）；**英文單字、詞性、級別、頁尾用等寬字**，例句英文用無襯線。
- 頁首（只有第一頁）：左邊 `單字 · 講義`（19px 粗體，中間的「·」灰）；右邊兩行，上面 `ENRECALL`（9px 等寬粗體、字距拉開），下面 `範圍 · 122 字 · 2026-11-16`（9.5px 灰）；下面一條 1.6px 黑線。
- 圖例一行（8.8px 灰字，項目間空 14px，下面一條淺灰線）：只列用得到的，例如 `灰字＝次要字義`、`●●●○○＝現在記得的機率`。
- 頁尾：一條淺灰線，左邊 `範圍 · 標準份量`，右邊 `1 / 7`，8.5px 等寬灰字。
- 一個字（一題、一組）的整列不拆到兩頁；列和列之間一條灰色點線。
- 依級別排時每個 Level 一個小標題 `Level 4（74 字）`，10px 粗體，下面一條 1px 黑線，至少帶著下一列一起換頁。

## 份量

使用者沒特別要求就用**標準**。

| 內容 | 精簡 | 標準 | 完整 |
|---|---|---|---|
| 字義（精簡最多 3 個）、記憶點 | ● | ● | ● |
| 音標、例句、搭配、近義、反義、易混淆 | | ● | ● |
| 詞形變化、句型、常見錯誤、字源・同根 | | | ● |

片語：精簡＝中文＋記憶點；標準加用法、例句、學測出現次數；完整再加易混淆。易混淆字對：精簡只有兩個字和差別；標準加例句、記法；完整加重點。

## 講義（單字）

一字一列，左欄 112px 放字，右欄（左欄後空 10px）放內容：

```
absolute            adj. 完全的；十足的  ／  adj. 絕對的；無條件的
/ˈæbsəluːt/         The teacher gave us **absolute** freedom to choose a project topic.  老師讓我們完全自由地選擇專題主題。
[L4] ●○○○○ 忘1      [搭配] absolute silence 完全安靜  [近] sheer 純粹的 · pure 純粹的  [反] partial 部分的
```

**左欄**

1. 單字，13.5px 等寬粗體；太長就折行，不截掉。
2. 音標 `/…/`，8.8px 灰。
3. 狀態一行：級別框 `L4`（7.8px 等寬粗體、1px 黑框、小圓角；學測以外沒有框）、記憶點 `●●●○○`（還沒背過寫「新字」）、`忘3`（忘過才印），8.5px 灰。

**右欄**（由上往下，沒資料或沒開就整行不印）

1. 字義 11.2px：詞性（等寬小灰粗體）＋中文，字義之間空一格全形。有字義分組時組和組用淡灰「 ／ 」隔開，次要組的中文灰字。
2. 例句 9.8px：英文，目標字（含變化形）粗體，後面空兩格接灰色中文翻譯。
3. 延伸一行 9px 灰：每組前面一個細框小標籤 `搭配`、`近`、`反`、`混`。搭配最多兩個（`英文 中文；英文 中文`），近、反、混每種最多 3 個，近、反帶中文；不列超出學測範圍（tag 有 beyond）的近義字。
4. 完整份量再一行 9px：`變化 bubbles · bubbled · bubbling`、`句型 a bubble of + N 例句`、`誤 ~~錯的~~ → 對的`、`字源 re- 再 + view 看 → 再看一次`、`同根 preview · interview`。

精簡份量右欄只有字義一行時，狀態改放在那一行最右邊，一頁約 39 字。標準約 20 字、完整約 14 字。

## 講義（片語）

同一套，左欄是片語（11.8px 等寬粗體，sb、sth 照印），狀態一行是 `[核心]` 黑框（只有核心片語）、`常見`／`看得懂就好`、記憶點。右欄：

1. 中文 11.2px 粗體＋詞性（小灰）＋`學測 12 次`（小灰）＋`[用法] …`。
2. 例句（片語粗體）＋翻譯；`[混] …`。

## 講義（易混淆字對）

左欄兩個字上下排（12.5px 等寬粗體），**兩個字不一樣的字母加底線**；下面一個 `形近`／`義近`／`形近・義近` 小框。右欄分成兩半，各自一條 1.6px 黑色直線開頭：`accompany v. 陪伴；陪同` ＋ 例句；下面一整行粗體寫兩字的差別，後面 `[記法] …`；完整份量再一行重點。

## 自測卷

- 頁首下面一行兩個圓圈編號步驟：①看中文和挖空的例句寫英文 ②寫完翻到最後一頁對答案；右邊 `灰色提示＝首字母和字母數`。頁首範圍後面加方向（`中→英`／`英→中`／`混合`）。
- 一題一列：題號 `01`（9px 等寬灰）、題目（中文粗體＋小灰詞性；英→中時題目是英文等寬粗體）、下面一行例句（9.2px 灰，一行放不下加「…」）；右邊 220px 寬的答案線，中→英時線上方有灰色提示 `c _ _ _ _`（首字母＋每個字母一格，最多 10 格；片語每個字一組 `g _ _ _   u _`，sb、sth 照印）。一頁約 34 題。
- **例句要挖空**：目標字（含變化形、不規則變化 took／gave、片語中間的詞形 gave up）換成 `_____`；好幾句時每一句都要挖，挖不到的那一句連同翻譯拿掉——**答案絕對不能印在題目上**。英→中時例句不挖，目標字粗體。
- 答案另起一頁：標題 `單字 · 自測卷答案`、一行「寫完再翻過來對。」，由上往下 5 欄（有中文答案時 3 欄），`1 abandon`。
- 記得的機率低的排前面。

## 速查表

- 四欄、欄距 14px、欄間淡灰直線，由上往下排滿一欄再換下一欄。
- 一行一字：單字（等寬粗體）＋詞性（小灰等寬）＋最常考的字義，9.2px，放不下加「…」。
- 依字母排時每個字母一個 `A` 小標題（11.5px 等寬粗體＋1px 黑線）。一頁約 120 字。

## 做法

把內容排成 HTML 再轉 PDF。下面是講義的樣式，只換 `<main>` 裡的內容；自測卷與速查表用同一套顏色與字型自己排。

```html
<!doctype html>
<html lang="zh-Hant"><head><meta charset="utf-8">
<title>單字 · 講義</title>
<link href="https://fonts.googleapis.com/css2?family=Noto+Sans+TC:wght@400;700&family=JetBrains+Mono:wght@400;700&display=swap" rel="stylesheet">
<style>
  @page { size: A4; margin: 8mm 10mm 12mm; }
  * { box-sizing: border-box; }
  body { margin: 0; font-family: "Noto Sans TC", sans-serif; color: #111; font-size: 11px; }
  header { display: flex; justify-content: space-between; align-items: flex-end; border-bottom: 1.6px solid #111; padding-bottom: 6px; }
  header h1 { font-size: 19px; margin: 0; } header h1 i { font-style: normal; color: #777; font-weight: 400; }
  header .r { text-align: right; } header .brand { font: 700 9px "JetBrains Mono", monospace; letter-spacing: .14em; }
  header .meta { font-size: 9.5px; color: #555; }
  .legend { font-size: 8.8px; color: #666; padding: 3px 0; border-bottom: 1px solid #ddd; display: flex; gap: 14px; }
  .row { display: grid; grid-template-columns: 112px 1fr; column-gap: 10px; padding: 5px 0; border-bottom: 1px dotted #c4c4c4; break-inside: avoid; }
  .w { font: 700 13.5px "JetBrains Mono", monospace; word-break: break-all; }
  .ph { font-size: 8.8px; color: #666; }
  .st { font: 8.5px "JetBrains Mono", monospace; color: #555; margin-top: 2px; }
  .lv { font-weight: 700; color: #111; border: 1px solid #111; border-radius: 2px; padding: 0 2px; font-size: 7.8px; }
  .ss { font-size: 11.2px; line-height: 1.2; }
  .pos { font: 700 9px "JetBrains Mono", monospace; color: #555; }
  .dim { color: #7a7a7a; } .sep { color: #bbb; }
  .ex { font-size: 9.8px; color: #222; line-height: 1.18; } .ex i { font-style: normal; color: #777; }
  .xs { font-size: 9px; color: #444; line-height: 1.2; } .xs i { font-style: normal; color: #777; }
  .tag { font-weight: 700; font-size: 8px; color: #111; border: .9px solid #999; border-radius: 2px; padding: 0 2px; margin-right: 3px; }
</style></head>
<body><main>
  <header><h1>單字 <i>·</i> 講義</h1><div class="r"><div class="brand">ENRECALL</div><div class="meta">最常忘 · 30 字 · 2026-11-16</div></div></header>
  <div class="legend"><span>灰字＝次要字義</span><span>●●●○○＝現在記得的機率</span></div>
  <div class="row">
    <div><div class="w">absolute</div><div class="ph">/ˈæbsəluːt/</div><div class="st"><span class="lv">L4</span> ●○○○○ 忘1</div></div>
    <div>
      <div class="ss"><span class="pos">adj.</span> 完全的；十足的 <span class="sep">／</span> <span class="pos">adj.</span> <span class="dim">絕對的；無條件的</span></div>
      <div class="ex">The teacher gave us <b>absolute</b> freedom to choose a project topic.  <i>老師讓我們完全自由地選擇專題主題。</i></div>
      <div class="xs"><span class="tag">搭配</span>absolute silence <i>完全安靜</i>；an absolute pleasure <i>十分榮幸</i>　 <span class="tag">近</span>sheer <i>純粹的</i> · pure <i>純粹的</i>　 <span class="tag">反</span>partial <i>部分的</i></div>
    </div>
  </div>
</main></body></html>
```

- 沒有的欄位整個 `div` 拿掉，不要留空行。
- 頁尾用轉 PDF 工具的頁尾設定印 `範圍 · 份量` 與 `頁碼 / 總頁數`。
- 中文、音標（ɚ、ʃ、ŋ…）都要印得出來，不能有方塊字。
````
