#!/usr/bin/env python3
"""把 LiveContainer/strings/<語言>.json 的翻譯合併進上游的 Localizable.xcstrings。

用法：merge_strings.py <strings 資料夾> <Localizable.xcstrings>

- 檔名就是語言代號（zh-Hant.json → zh-Hant），內容是 {key: 翻譯}
- 上游沒有的 key 直接失敗，上游改名時才會發現
- 上游已經有這個語言的翻譯就不蓋掉（上游自己補了翻譯時以上游為準）
"""
import json
import pathlib
import sys


def main() -> int:
    strings_dir = pathlib.Path(sys.argv[1])
    catalog_path = pathlib.Path(sys.argv[2])
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    entries = catalog["strings"]

    missing = []
    for lang_file in sorted(strings_dir.glob("*.json")):
        lang = lang_file.stem
        translations = json.loads(lang_file.read_text(encoding="utf-8"))
        added = kept = 0
        for key, value in translations.items():
            entry = entries.get(key)
            if entry is None:
                missing.append(f"{lang}: {key}")
                continue
            localizations = entry.setdefault("localizations", {})
            if lang in localizations:
                kept += 1
                print(f"keep upstream {lang} {key} = {json.dumps(localizations[lang], ensure_ascii=False)}")
                continue
            localizations[lang] = {"stringUnit": {"state": "translated", "value": value}}
            added += 1
        print(f"{lang}: added {added}, kept upstream {kept}")

    if missing:
        print("keys not found in upstream catalog:", *missing, sep="\n  ")
        return 1

    catalog_path.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : ")) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
