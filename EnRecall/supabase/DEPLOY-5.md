# EnRecall iOS：一張卡多個牌組（App 0.12.0）

App 0.12.0 起，同一張卡可以同時在好幾個牌組（例如 crispy 在「學測 Level 3」也在「Enjoy English 11/16」），複習進度只有一份。
**後端不用改資料表、不用新的 RPC**；只有 MCP 讀快照的地方要跟著改。

## 1. App 怎麼做

- 卡片有一個「原本的牌組」：單字庫的字是等級牌組，Claude 寫的字是第一次匯入的牌組。放進別的牌組只加一筆連結（App 本機的 `DeckLink`），不建新卡。
- 從收件匣匯入（`ios_claim_inbox`）時：
  - `library_word_id` 的卡 App 裡已經有、但不在 `deck_name` 這個牌組 → 連過去（以前是略過）
  - 已經在這個牌組 → 略過
  - App 裡沒有 → 建新卡（跟以前一樣）
  - 句型卡（`pt:` id）一樣
- 下載單字包時，字已經在 Claude 牌組裡的，也會連到等級牌組。
- 從牌組移除：在 App 裡（牌組列表往左滑、單字詳細的「所在牌組」）。只拿掉連結；原本的牌組不能移除，所以卡片不會沒有牌組。
- 複習：同一張卡一天只會出一次；`logs` 不變。

## 2. 快照（`ios_push_snapshot`）多兩個欄位，`v` 還是 1

```json
"cards": [
  { "id": "w:crispy", "deck": "gsat-3", "decks": ["gsat-3", "custom:9F2C…"], "word": "crispy", … }
],
"card_ids": ["w:crispy", "w:ability", "claude:…", "pt:it is not until|that", …]
```

- `cards[].decks`：所在的所有牌組，原本的在最前面。沒有這個欄位（舊版 App）就當成 `[deck]`。
- `cards`：同一張卡只出現一次。自訂牌組裡的卡（不管是不是連過去的）都在裡面，沒背過的也是。
- `decks[].total／new／learning／review／mastered`：算牌組裡所有的卡，包含連過去的（雜誌牌組會顯示 37）。
- `card_ids`：App 裡所有卡的 id，包含還沒背的單字庫字（最多幾千個字串）。

## 3. MCP 要改的地方

| 工具 | 改法 |
|---|---|
| `list_words` | 每個字回傳 `decks`（牌組名稱陣列）；`deck` 篩選改成「`decks` 裡有這個牌組」。沒有 `decks` 的舊快照就放 `[deck]` 一個值 |
| `analyze_learning` | 牌組的答對率：一筆複習算進那張卡的每一個牌組（用 `decks`）；`most_forgotten[].deck` 改成 `decks` |
| `overview` | `decks[]` 直接用快照的數字（已經含連過去的卡） |
| `add_words`／`add_patterns` | 參數不變。回傳可以多 `already_in_app`：有快照時，`library_word_id` 在 `card_ids` 裡的字數（會被連過去、進度照舊）；**沒有快照就不要回這個欄位**，不要猜。實際結果以 App 匯入時的提示為準（「…其中 33 個本來就在背，進度照舊」） |
| `remove_from_deck` | **先不做**。伺服器沒有牌組關係表，App 也不收「移除」的指令；要移除請使用者在 App 裡滑掉。真的需要再另外規劃（收件匣加 `kind = 'remove'`，要改 `ios_inbox_kind_check`） |
| `check_inbox` | 不用改 |

建議順序：先改 `list_words`、`analyze_learning` 讀 `decks`（舊快照當成一個值，不會壞），再加 `add_words` 的 `already_in_app`。

## 4. 已經略過的字

收件匣的字被 App 領走後就從 `ios_inbox` 刪掉了，App 也沒有記下當時略過哪些字，所以**不會自己連過去**。
App 更新到 0.12.0 後，請 Claude 把同一批字（例如「Enjoy English 11/16」的 37 個）用 `add_words` 再送一次到同一個牌組：
本來就在的 4 個字和 2 個句型會略過，另外 33 個會連過去，進度照舊。

## 5. 驗收

1. 送 37 個字（33 個 App 裡已有＋4 個新字）到新牌組 → App 提示「從 Claude 匯入 37 個單字到〈…〉，其中 33 個本來就在背，進度照舊」，牌組顯示 37 個，App 的卡片總數只多 4。
2. 在雜誌牌組複習 crispy → 學測 Level 3 的 crispy 到期日一起變，當天不會再出。
3. 同一批字再送一次 → 全部略過。
4. 在雜誌牌組把 crispy 往左滑「移出牌組」→ 學測 Level 3 還有 crispy，進度還在。
5. 快照上傳後，`list_words` 用 `deck: "Enjoy English 11/16"` 篩選 → 37 個字，每個都有 `decks`。
