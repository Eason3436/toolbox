import Foundation

/// read_docs 回傳的文件。pattern-guide 跟 MCP 的同一份（supabase/DEPLOY-4.md 第 3、5 節）；
/// pdf-handout 改成 App 內的版本：排版由 make_pdf 做，模型只要挑字
enum AssistantDocs {
    static let available = ["pattern-guide", "pdf-handout"]

    static func text(_ name: String) -> String? {
        switch name {
        case "pattern-guide": patternGuide
        case "pdf-handout": pdfHandout
        default: nil
        }
    }

    static let patternGuide = #"""
# 句型卡格式

## 句型內容（detail）

App 照這個格式顯示，欄位名稱一字不差：

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
| `anchors` | ● | 句型裡固定不變的英文字，依出現順序、原形；1–6 個，每個 1–60 字，只能有英文字母、空白、' 和 - |
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
"""#

    static let pdfHandout = #"""
# 單字 PDF（講義・自測卷・速查表）

使用者要把單字印出來時照這份做。排版由 App 完成，你只要挑字、選用途和份量，呼叫 make_pdf。

| 用途（kind） | 給誰 | App 排出來的樣子 |
|---|---|---|
| handout 講義（讀） | 想複習、要看完整內容 | 雙欄字卡：字義、例句、搭配、近義、反義、易混淆 |
| quiz 自測卷（考） | 想考自己 | 一題一列＋作答線，答案在右邊，沿虛線往後折就蓋住；例句裡的答案會挖空 |
| cheatsheet 速查表（查） | 考前快速掃過 | 照熟不熟分組，三欄，一行一字 |

使用者沒說用途就做講義；沒說份量就用 standard。自測卷不出句型卡。

## 挑字

- 使用者指定的字：先 lookup_words 或 list_words 拿 id（PDF 只能印牌組裡已經有的卡）
- 「最常忘」：list_words(sort="lapses", min_lapses=1) 或 analyze_learning 的 most_forgotten
- 「快忘了」「最弱」：list_words(sort="weakest") 或 analyze_learning 的 fading
- 「最近背的」：list_words(sort="recent", reviewed_within_days=7)
- 某個牌組：list_words(deck="牌組名稱")
- 數量照使用者說的；沒說就 30 個

## make_pdf 參數

- kind：handout／quiz／cheatsheet
- ids：要印的卡片 id（w:absolute、p:such as、pt:…、claude:…），照你想要的順序
- title：範圍名稱，例如「最常忘」「Level 4」「雜誌 11 月」，會印在頁首和檔名
- density（只有講義有差）：compact 精簡（字義、記憶點）／standard 標準（加音標、例句、搭配、近義、反義、易混淆）／full 完整（再加詞形變化、句型、常見錯誤、字源、同根）
- direction（只有自測卷）：zh_to_en 中→英（預設）／en_to_zh 英→中

字義、例句全部用 App 裡的資料，不要自己編。做好後畫面會出現 PDF 卡片（預覽、分享），你只要用一句話告訴使用者印了幾個字、幾頁。
"""#
}
