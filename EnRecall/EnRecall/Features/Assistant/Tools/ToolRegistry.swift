import Foundation

/// 工具清單（Gemini functionDeclarations，用 parametersJsonSchema）。
/// 參數照 MCP 的同名工具（supabase/DEPLOY.md、DEPLOY-3/4/5.md）；內容固定不變，放在請求最前面讓隱式快取命中
enum ToolRegistry {
    static let declarations: [JSONValue] = {
        guard let list = try? JSONDecoder().decode([JSONValue].self, from: Data(json.utf8)) else {
            assertionFailure("ToolRegistry.json 格式不對")
            return []
        }
        return list
    }()

    /// 用 JSON 寫（巢狀的 Swift 字典常值會讓型別檢查很慢）
    private static let json = #"""
[
  {
    "name": "report_image_content",
    "description": "使用者上傳圖片時必須最先呼叫。完整轉錄圖片中的英文內容（含手寫），供後續步驟使用。好幾張圖就合在一起轉錄，用空行分開。",
    "parametersJsonSchema": {
      "type": "object",
      "properties": {
        "transcript": {
          "type": "string",
          "description": "圖片中的完整內容，保留原本的條列與換行"
        },
        "image_type": {
          "type": "string",
          "enum": [
            "handwritten",
            "printed",
            "mixed",
            "article"
          ]
        },
        "uncertain": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "看不清楚、不確定的字"
        }
      },
      "required": [
        "transcript"
      ]
    }
  },
  {
    "name": "lookup_words",
    "description": "查單字庫（學測 Level 1–6、學測片語總表）裡有沒有這些字。found 的字直接用回傳的資料。",
    "parametersJsonSchema": {
      "type": "object",
      "properties": {
        "words": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "minItems": 1,
          "maxItems": 200,
          "description": "原形單字或片語（片語不要加 sb/sth）"
        }
      },
      "required": [
        "words"
      ]
    }
  },
  {
    "name": "add_words",
    "description": "把單字加進 App 的牌組（牌組不存在會自動建立）。會先給使用者看確認卡，使用者按加入才寫入；取消會回 cancelled。單字庫有的字一律用單字庫的內容。",
    "parametersJsonSchema": {
      "type": "object",
      "properties": {
        "deck": {
          "type": "string",
          "description": "目標牌組名稱，1–60 字"
        },
        "words": {
          "type": "array",
          "minItems": 1,
          "maxItems": 200,
          "items": {
            "type": "object",
            "properties": {
              "word": {
                "type": "string"
              },
              "pos": {
                "type": "string"
              },
              "zh": {
                "type": "string"
              },
              "example": {
                "type": "string"
              },
              "example_zh": {
                "type": "string"
              },
              "library_word_id": {
                "type": "string",
                "description": "lookup_words 回傳的 id；有就填"
              }
            },
            "required": [
              "word"
            ]
          }
        }
      },
      "required": [
        "deck",
        "words"
      ]
    }
  },
  {
    "name": "get_words",
    "description": "取單字庫的完整條目（音標、字義、例句、搭配、近義・反義、易混淆、常見錯誤、字源）和學習狀態。ids 和 words 至少給一個。",
    "parametersJsonSchema": {
      "type": "object",
      "properties": {
        "ids": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "maxItems": 120,
          "description": "w:absolute、p:such as 這種 id"
        },
        "words": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "也可以直接給原形單字"
        }
      }
    }
  },
  {
    "name": "list_words",
    "description": "列出 App 裡學過的字（和自訂牌組的字），挑要印、要複習的字。",
    "parametersJsonSchema": {
      "type": "object",
      "properties": {
        "deck": {
          "type": "string",
          "description": "牌組名稱或 id（選填）"
        },
        "state": {
          "type": "string",
          "enum": [
            "learning",
            "review",
            "mastered",
            "all"
          ],
          "description": "預設 all"
        },
        "sort": {
          "type": "string",
          "enum": [
            "weakest",
            "lapses",
            "recent",
            "due",
            "alphabet"
          ],
          "description": "預設 weakest：記得的機率低的在前"
        },
        "min_lapses": {
          "type": "integer",
          "minimum": 0
        },
        "reviewed_within_days": {
          "type": "integer",
          "minimum": 1,
          "description": "最近 N 天複習過的"
        },
        "limit": {
          "type": "integer",
          "minimum": 1,
          "maximum": 300,
          "description": "預設 50"
        }
      }
    }
  },
  {
    "name": "lookup_patterns",
    "description": "整理句型前先查 App 的句型庫。found：完全一樣；similar：可能是同一個句型，自己判斷；not_found 才要完整整理。",
    "parametersJsonSchema": {
      "type": "object",
      "properties": {
        "patterns": {
          "type": "array",
          "minItems": 1,
          "maxItems": 50,
          "items": {
            "type": "object",
            "properties": {
              "pattern": {
                "type": "string",
                "description": "公式（選填）"
              },
              "anchors": {
                "type": "array",
                "items": {
                  "type": "string"
                },
                "description": "固定不變的英文字，原形，依出現順序"
              }
            },
            "required": [
              "anchors"
            ]
          }
        }
      },
      "required": [
        "patterns"
      ]
    }
  },
  {
    "name": "add_patterns",
    "description": "把句型卡加進 App 的牌組。會先給使用者看確認卡。lookup 找到的只填 id；新的要給完整 detail（格式見 read_docs(\"pattern-guide\")）。",
    "parametersJsonSchema": {
      "type": "object",
      "properties": {
        "deck": {
          "type": "string",
          "description": "目標牌組名稱，1–60 字"
        },
        "patterns": {
          "type": "array",
          "minItems": 1,
          "maxItems": 50,
          "items": {
            "type": "object",
            "properties": {
              "id": {
                "type": "string",
                "description": "lookup_patterns 找到的 id（pt: 開頭）"
              },
              "detail": {
                "type": "object",
                "description": "句型內容，欄位照 pattern-guide：pattern、zh、anchors、slots、examples 必填"
              }
            }
          }
        },
        "update_library": {
          "type": "boolean",
          "description": "true：用新的 detail 覆蓋 App 裡同一個句型（使用者要確認）。預設 false"
        }
      },
      "required": [
        "deck",
        "patterns"
      ]
    }
  },
  {
    "name": "list_patterns",
    "description": "看 App 的句型庫存了哪些句型，最近加的在前。",
    "parametersJsonSchema": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "比對公式、中文或 key（選填）"
        },
        "limit": {
          "type": "integer",
          "minimum": 1,
          "maximum": 100,
          "description": "預設 30"
        }
      }
    }
  },
  {
    "name": "overview",
    "description": "學習總覽：今天複習幾張、答對率、到期數、連續天數、各牌組進度。",
    "parametersJsonSchema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "analyze_learning",
    "description": "學習細節：每天的量、評分分布、最常忘的字（most_forgotten）、快忘掉的字（fading）、各牌組答對率。",
    "parametersJsonSchema": {
      "type": "object",
      "properties": {
        "days": {
          "type": "integer",
          "minimum": 1,
          "maximum": 90,
          "description": "預設 14"
        },
        "top": {
          "type": "integer",
          "minimum": 1,
          "maximum": 50,
          "description": "最常忘、快忘掉各列幾個，預設 15"
        },
        "deck": {
          "type": "string",
          "description": "牌組名稱或 id（選填）"
        }
      }
    }
  },
  {
    "name": "read_docs",
    "description": "讀格式文件：pattern-guide（句型卡格式與整理規則）、pdf-handout（怎麼挑字做 PDF）。",
    "parametersJsonSchema": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string",
          "enum": [
            "pattern-guide",
            "pdf-handout"
          ]
        }
      },
      "required": [
        "name"
      ]
    }
  },
  {
    "name": "make_pdf",
    "description": "產生單字 PDF。你只決定要印哪些字和格式，排版由 App 完成。",
    "parametersJsonSchema": {
      "type": "object",
      "properties": {
        "kind": {
          "type": "string",
          "enum": [
            "handout",
            "quiz",
            "cheatsheet"
          ],
          "description": "講義／自測卷／速查表，使用者沒說就用 handout"
        },
        "ids": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "minItems": 1,
          "maxItems": 300,
          "description": "卡片 id，例如 w:absolute、p:such as"
        },
        "title": {
          "type": "string",
          "description": "範圍名稱，例如「最常忘」「Level 4」"
        },
        "density": {
          "type": "string",
          "enum": [
            "compact",
            "standard",
            "full"
          ],
          "description": "預設 standard，只有講義有差"
        },
        "direction": {
          "type": "string",
          "enum": [
            "zh_to_en",
            "en_to_zh"
          ],
          "description": "只有自測卷用，預設 zh_to_en"
        }
      },
      "required": [
        "kind",
        "ids"
      ]
    }
  }
]
"""#

    static let names: Set<String> = Set(declarations.compactMap { $0["name"]?.string })

    /// 執行中顯示的步驟
    static func progressTitle(_ name: String) -> String {
        switch name {
        case "report_image_content": "辨識圖片中…"
        case "lookup_words": "查詢單字庫…"
        case "add_words": "準備加入牌組…"
        case "get_words": "讀取單字內容…"
        case "list_words": "挑選單字…"
        case "lookup_patterns", "list_patterns": "查詢句型庫…"
        case "add_patterns": "準備加入句型…"
        case "overview", "analyze_learning": "整理學習紀錄…"
        case "read_docs": "讀取格式說明…"
        case "make_pdf": "製作 PDF…"
        default: "處理中…"
        }
    }
}
