import Foundation

/// 預覽用的完整內容（從學測 Level 4、片語總表節錄）
extension PreviewData {
    static let abstractDetail = Data(#"""
{
 "word": {
  "word": "abstract",
  "phonetic": "/ˈæbstrækt/",
  "forms": "abstractly · abstraction",
  "meanings": [
   {
    "pos": "adj.",
    "zh": "抽象的；理論的",
    "ext": "把具體事物的細節抽掉 → 只剩概念，看不見也摸不到",
    "group": 0,
    "examples": [
     {
      "en": "The teacher used pictures to explain an abstract idea.",
      "zh": "老師用圖片解釋一個抽象的概念。"
     },
     {
      "en": "Freedom and love are abstract ideas that are hard to draw.",
      "zh": "自由和愛是很難畫出來的抽象概念。"
     }
    ],
    "patterns": [
     {
      "pattern": "abstract + N",
      "en": "The class discussed abstract ideas about time and space.",
      "zh": "全班討論了關於時間和空間的抽象概念。"
     }
    ],
    "collocations": [
     {
      "en": "abstract idea",
      "zh": "抽象概念",
      "star": true
     },
     {
      "en": "abstract concept",
      "zh": "抽象概念",
      "star": true
     },
     {
      "en": "abstract art",
      "zh": "抽象藝術",
      "star": false
     },
     {
      "en": "abstract painting",
      "zh": "抽象畫",
      "star": false
     },
     {
      "en": "abstract thinking",
      "zh": "抽象思考",
      "star": false
     },
     {
      "en": "abstract noun",
      "zh": "抽象名詞",
      "star": false
     },
     {
      "en": "in the abstract",
      "zh": "抽象地；理論上",
      "star": false
     }
    ]
   },
   {
    "pos": "n.",
    "zh": "摘要；概要",
    "ext": "從全文抽出重點 → 放在前面的簡短摘要",
    "group": 1,
    "examples": [
     {
      "en": "Read the abstract first to see what the study is about.",
      "zh": "先讀摘要，看看這項研究在談什麼。"
     },
     {
      "en": "The abstract of Jenny's report is only about one hundred words.",
      "zh": "Jenny 的報告摘要只有大約一百個字。"
     }
    ],
    "patterns": [
     {
      "pattern": "the abstract of + N",
      "en": "Please write an abstract of your report.",
      "zh": "請替你的報告寫一份摘要。"
     }
    ],
    "collocations": [
     {
      "en": "read the abstract",
      "zh": "閱讀摘要",
      "star": true
     },
     {
      "en": "write an abstract",
      "zh": "寫摘要",
      "star": true
     },
     {
      "en": "submit an abstract",
      "zh": "提交摘要",
      "star": false
     },
     {
      "en": "a conference abstract",
      "zh": "研討會摘要",
      "star": false
     },
     {
      "en": "an abstract of a paper",
      "zh": "論文摘要",
      "star": false
     }
    ]
   }
  ],
  "synonyms": [
   {
    "word": "abstract",
    "note": "指概念或藝術不直接呈現具體事物。",
    "example": "abstract idea",
    "tag": [
     "gsat"
    ]
   },
   {
    "word": "theoretical",
    "note": "指依據理論而非實際經驗，常用於學術討論。",
    "example": "theoretical question",
    "tag": [
     "gsat"
    ]
   },
   {
    "word": "conceptual",
    "note": "強調與概念或思考有關，較正式。",
    "example": "conceptual framework",
    "tag": [
     "beyond"
    ]
   },
   {
    "word": "summary",
    "note": "泛指任何內容的簡短總結；abstract 專指論文、報告開頭的摘要。",
    "example": "a summary of the article",
    "tag": [
     "gsat"
    ]
   },
   {
    "word": "synopsis",
    "note": "",
    "example": "",
    "zh": "概要；梗概",
    "tag": [
     "beyond",
     "formal"
    ]
   }
  ],
  "antonyms": [
   {
    "word": "concrete",
    "zh": "具體的"
   },
   {
    "word": "practical",
    "zh": "實際的"
   }
  ],
  "confusables": [
   {
    "words": "abstract vs extract",
    "note": "abstract 作形容詞意為「抽象的」；extract 作動詞常指「取出、提取」。",
    "wrong": "The class studied an extract idea.",
    "right": "The class studied an abstract idea."
   }
  ],
  "commonErrors": [],
  "breakdown": [
   {
    "part": "abs-",
    "type": "字首",
    "gloss": "離開；抽出"
   },
   {
    "part": "-tract-",
    "type": "字根",
    "gloss": "拉；拖"
   }
  ],
  "origin": "源自拉丁文 abstractus，意為「抽離的」，由 abs-「離開」和 trahere「拉」組成。",
  "related": [
   {
    "word": "attract",
    "note": "吸引"
   },
   {
    "word": "extract",
    "note": "取出；提取"
   },
   {
    "word": "distract",
    "note": "使分心"
   }
  ],
  "phrases": []
 },
 "similar": [
  {
   "a": "abstract",
   "b": "extract",
   "aZh": "n. 摘要；概要",
   "bZh": "n. 摘錄；v. 取出；提取",
   "diff": "abstract 是整篇文章的摘要；extract 是從原文直接截取的一段摘錄。兩字都有 -tract，只差字首。",
   "points": [
    "詞性：abstract 可作 adj.「抽象的」和 n.「摘要」；extract 是 v.「取出」，也可作 n.「摘錄」",
    "內容：abstract 是用自己的話概括全文；extract 是原文的一小段",
    "拼字：兩字都有 -tract-，差在字首 abs- 和 ex-"
   ],
   "tip": "abstract 濃縮成重點，extract 原封不動摘出來（ex- 是向外取出）。",
   "exA": {
    "en": "The abstract at the top of the report is short and clear.",
    "zh": "報告最上方的摘要簡短又清楚。"
   },
   "exB": {
    "en": "Our teacher read an extract from the novel to the class.",
    "zh": "老師對全班朗讀了小說的一段摘錄。"
   }
  }
 ]
}
"""#.utf8)

    static let suchAsDetail = Data(#"""
{
 "phrase": {
  "p": "such as",
  "zh": "例如；像是",
  "pos": "轉折／連接用語",
  "group": "轉折、連接用語",
  "tier": 1,
  "use": "舉例｜such as＋名詞（不放句首，不加逗號後的子句）",
  "ex": "Fruits such as apples and oranges are rich in vitamins.",
  "exZh": "蘋果和柳橙等水果富含維生素。",
  "mix": "such A as B＝像 B 這樣的 A",
  "years": "103 105 106 107 108 109 110 111 112 113 114 115"
 }
}
"""#.utf8)

    static let notUntilDetail = Data(#"""
{
 "pattern": {
  "pattern": "It is not until + 時間／子句 + that + S + V",
  "zh": "直到…才…",
  "anchors": ["it is not until", "that"],
  "level": "進階",
  "register": "正式，寫作常用",
  "explanation": "強調「到某個時間點才發生」。not until 後面放時間或子句，that 後面接完整的句子，而且用肯定句。",
  "slots": [
   { "slot": "時間／子句", "accepts": "時間名詞片語，或 until 後面接完整子句", "examples": ["midnight", "last year", "she moved to Taipei"] },
   { "slot": "S + V", "accepts": "完整的肯定句，時態跟著前面", "examples": ["I realized the truth", "he started to practice"] }
  ],
  "examples": [
   { "en": "It was not until the 1990s that the internet became popular.", "zh": "直到 1990 年代網路才普及。", "source": "Studio Classroom 2026/11" },
   { "en": "It is not until we lose our health that we know its value.", "zh": "直到失去健康，我們才知道它的可貴。" }
  ],
  "variations": [
   { "form": "Not until + 時間／子句 + 助動詞 + S + V", "note": "倒裝：Not until 放句首，後面主要子句要倒裝", "en": "Not until midnight did he finish his report.", "zh": "直到半夜他才寫完報告。" },
   { "form": "S + did not + V + until + 時間", "note": "一般寫法", "en": "He did not finish his report until midnight.", "zh": "他直到半夜才寫完報告。" }
  ],
  "collocations": [
   { "en": "It was not until later that …", "zh": "直到後來才…" }
  ],
  "similar": [
   { "pattern": "Only when + 子句 + 助動詞 + S + V", "diff": "only when 強調「只有在…的時候」，一樣要倒裝", "en": "Only when you try will you know.", "zh": "只有試了才會知道。" }
  ],
  "errors": [
   { "wrong": "It was not until midnight that he didn't finish his report.", "right": "It was not until midnight that he finished his report.", "note": "that 後面用肯定句，否定已經在 not until 裡" }
  ],
  "tips": "not until 先講時間，that 後面才是「終於發生的事」。"
 }
}
"""#.utf8)
}
