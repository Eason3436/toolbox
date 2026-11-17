# 產生 EnRecall 的配色主題（Assets.xcassets/Themes/<名稱>/*.colorset）
#
# 色票都取自設計師公開的配色系統（淺色／深色各一套），只對應到 App 的顏色角色：
#   Nord（Arctic Ice Studio）          https://www.nordtheme.com
#   Rosé Pine（Dawn ／ Main）          https://rosepinetheme.com
#   Everforest（sainnhe）              https://github.com/sainnhe/everforest
#   Flexoki（Steph Ango）              https://stephango.com/flexoki
#   Radix Colors Sand ＋ Bronze（WorkOS）https://www.radix-ui.com/colors
#   Gruvbox Material（sainnhe）        https://github.com/sainnhe/gruvbox-material
#   Solarized（Ethan Schoonover）      https://ethanschoonover.com/solarized
#   Iceberg（cocopon）                 https://github.com/cocopon/iceberg.vim
#   Melange（savq）                    https://github.com/savq/melange-nvim
# 文字、按鈕、資訊色若對比不足，會往同一套的最深／最淺色微調到 WCAG 標準（mix），不另外發明顏色。
#
# 用法：python3 EnRecall/scripts/palettes.py
import json, os, shutil, sys

ASSETS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "EnRecall", "Assets.xcassets")


def rgb(hexstr):
    h = hexstr.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def mix(a, b, t):
    a, b = rgb(a) if isinstance(a, str) else a, rgb(b) if isinstance(b, str) else b
    return tuple(x * (1 - t) + y * t for x, y in zip(a, b))


def lum(c):
    def ch(v):
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(v) for v in c)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def ensure(color, against, minimum, toward):
    """對比不夠就一點一點往 toward 混，直到達標"""
    c = rgb(color) if isinstance(color, str) else color
    bg = rgb(against) if isinstance(against, str) else against
    t = rgb(toward) if isinstance(toward, str) else toward
    for _ in range(60):
        if contrast(c, bg) >= minimum:
            break
        c = mix(c, t, 0.04)
    return c


def solid(c):
    return (rgb(c) if isinstance(c, str) else c, 1.0)


def alpha(c, a):
    return (rgb(c) if isinstance(c, str) else c, a)


# 每個主題：light / dark 各一份 token → 顏色
def nord():
    n = ["#2E3440", "#3B4252", "#434C5E", "#4C566A", "#D8DEE9", "#E5E9F0", "#ECEFF4",
         "#8FBCBB", "#88C0D0", "#81A1C1", "#5E81AC", "#BF616A", "#D08770", "#EBCB8B", "#A3BE8C", "#B48EAD"]
    light = dict(
        background=n[6], surface=mix(n[6], "#FFFFFF", 0.7), surfaceHigh=mix(n[6], "#FFFFFF", 0.7),
        surfaceMuted=n[5], fill=n[5], outline=n[4], outlineStrong=mix(n[4], n[3], 0.3), mid=mix(n[4], n[3], 0.65),
        text=n[0], textSecondary=n[3], textTertiary=mix(n[3], n[4], 0.3),
        primary=n[10], onPrimary=n[6], accent=n[10], info=n[10],
        infoContainer=mix(n[8], n[6], 0.8), infoTrack=mix(n[8], n[6], 0.5),
        hero=n[0], heroTile=n[1], heroOutline=n[2], heroText=n[6], heroTextSecondary=n[4], heroMuted=mix(n[3], n[4], 0.5))
    dark = dict(
        background=n[0], surface=n[1], surfaceHigh=n[2], surfaceMuted=n[2], fill=n[2], outline=n[2],
        outlineStrong=n[3], mid=mix(n[3], n[4], 0.35),
        text=n[6], textSecondary=n[4], textTertiary=mix(n[4], n[3], 0.4),
        primary=n[8], onPrimary=n[0], accent=n[8], info=n[8], infoContainer=alpha(n[8], 0.14), infoTrack=alpha(n[8], 0.3),
        hero=n[1], heroTile=n[2], heroOutline=n[3], heroText=n[6], heroTextSecondary=n[4], heroMuted=mix(n[3], n[4], 0.5))
    return light, dark


def rose_pine():
    dawn = dict(base="#faf4ed", surface="#fffaf3", overlay="#f2e9e1", muted="#9893a5", subtle="#797593", text="#464261",
                love="#b4637a", gold="#ea9d34", rose="#d7827e", pine="#286983", foam="#56949f", iris="#907aa9",
                low="#f4ede8", med="#dfdad9", high="#cecacd")
    main = dict(base="#191724", surface="#1f1d2e", overlay="#26233a", muted="#6e6a86", subtle="#908caa", text="#e0def4",
                love="#eb6f92", gold="#f6c177", rose="#ebbcba", pine="#31748f", foam="#9ccfd8", iris="#c4a7e7",
                low="#21202e", med="#403d52", high="#524f67")
    moon = dict(base="#232136", surface="#2a273f", overlay="#393552")
    d, m = dawn, main
    light = dict(
        background=d["base"], surface=d["surface"], surfaceHigh=d["surface"], surfaceMuted=d["overlay"], fill=d["overlay"],
        outline=d["med"], outlineStrong=d["high"], mid=d["muted"],
        text=d["text"], textSecondary=mix(d["text"], d["subtle"], 0.5), textTertiary=d["subtle"],
        primary=d["love"], onPrimary=d["surface"], accent=d["rose"], info=d["pine"],
        infoContainer=mix(d["foam"], d["base"], 0.82), infoTrack=mix(d["foam"], d["base"], 0.55),
        hero=moon["base"], heroTile=moon["surface"], heroOutline=moon["overlay"], heroText=m["text"],
        heroTextSecondary=mix(m["text"], m["subtle"], 0.5), heroMuted=m["subtle"])
    dark = dict(
        background=m["base"], surface=m["surface"], surfaceHigh=m["overlay"], surfaceMuted=m["overlay"], fill=m["overlay"],
        outline=mix(m["overlay"], m["med"], 0.5), outlineStrong=m["med"], mid=m["muted"],
        text=m["text"], textSecondary=m["subtle"], textTertiary=mix(m["subtle"], m["muted"], 0.3),
        primary=m["rose"], onPrimary=m["base"], accent=m["rose"], info=m["foam"],
        infoContainer=alpha(m["foam"], 0.14), infoTrack=alpha(m["foam"], 0.3),
        hero=m["surface"], heroTile=m["overlay"], heroOutline=m["med"], heroText=m["text"],
        heroTextSecondary=m["subtle"], heroMuted=mix(m["subtle"], m["muted"], 0.4))
    return light, dark


def everforest():
    # Light medium（bg_dim, bg0..bg5）、hard 的 bg0 當卡片
    lbg = dict(dim="#EFEBD4", bg0="#FDF6E3", bg1="#F4F0D9", bg2="#EFEBD4", bg3="#E6E2CC", bg4="#E0DCC7", bg5="#BDC3AF",
               hard="#FFFBEF", blue_bg="#E9F0E9")
    lfg = dict(fg="#5C6A72", grey0="#A6B0A0", grey1="#939F91", grey2="#829181",
               green="#8DA101", aqua="#35A77C", blue="#3A94C5")
    # Dark medium
    dbg = dict(dim="#232A2E", bg0="#2D353B", bg1="#343F44", bg2="#3D484D", bg3="#475258", bg4="#4F585E", bg5="#56635f")
    dfg = dict(fg="#D3C6AA", grey0="#7A8478", grey1="#859289", grey2="#9DA9A0",
               green="#A7C080", aqua="#83C092", blue="#7FBBB3")
    light = dict(
        background=lbg["bg0"], surface=lbg["hard"], surfaceHigh=lbg["hard"], surfaceMuted=lbg["bg1"], fill=lbg["bg2"],
        outline=lbg["bg3"], outlineStrong=mix(lbg["bg4"], lbg["bg5"], 0.4), mid=lfg["grey1"],
        text=lfg["fg"], textSecondary=lfg["grey2"], textTertiary=lfg["grey1"],
        primary=lfg["green"], onPrimary=lbg["hard"], accent=lfg["aqua"], info=lfg["blue"],
        infoContainer=lbg["blue_bg"], infoTrack=mix(lfg["blue"], lbg["bg0"], 0.65),
        hero=dbg["bg0"], heroTile=dbg["bg1"], heroOutline=dbg["bg2"], heroText=dfg["fg"],
        heroTextSecondary=dfg["grey2"], heroMuted=dfg["grey1"])
    dark = dict(
        background=dbg["bg0"], surface=dbg["bg1"], surfaceHigh=dbg["bg2"], surfaceMuted=dbg["bg2"], fill=dbg["bg2"],
        outline=dbg["bg3"], outlineStrong=dbg["bg4"], mid=dfg["grey0"],
        text=dfg["fg"], textSecondary=dfg["grey2"], textTertiary=dfg["grey1"],
        primary=dfg["green"], onPrimary=dbg["bg0"], accent=dfg["aqua"], info=dfg["blue"],
        infoContainer=alpha(dfg["blue"], 0.14), infoTrack=alpha(dfg["blue"], 0.3),
        hero=dbg["bg1"], heroTile=dbg["bg2"], heroOutline=dbg["bg3"], heroText=dfg["fg"],
        heroTextSecondary=dfg["grey2"], heroMuted=dfg["grey1"])
    return light, dark


def flexoki():
    b = {"paper": "#FFFCF0", 50: "#F2F0E5", 100: "#E6E4D9", 150: "#DAD8CE", 200: "#CECDC3", 300: "#B7B5AC",
         400: "#9F9D96", 500: "#878580", 600: "#6F6E69", 700: "#575653", 800: "#403E3C", 850: "#343331",
         900: "#282726", 950: "#1C1B1A", "black": "#100F0F"}
    light = dict(
        background=b["paper"], surface=mix(b["paper"], "#FFFFFF", 0.6), surfaceHigh=mix(b["paper"], "#FFFFFF", 0.6),
        surfaceMuted=b[50], fill=b[50], outline=b[100], outlineStrong=b[150], mid=b[500],
        text=b["black"], textSecondary=b[600], textTertiary=b[500],
        primary="#24837B", onPrimary=b["paper"], accent="#3AA99F", info="#205EA6",
        infoContainer="#E1ECEB", infoTrack="#C6DDE8",
        hero=b[950], heroTile=b[900], heroOutline=b[850], heroText=b[50], heroTextSecondary=b[300], heroMuted=b[500])
    dark = dict(
        background=b["black"], surface=b[950], surfaceHigh=b[900], surfaceMuted=b[900], fill=b[900],
        outline=b[850], outlineStrong=b[800], mid=b[600],
        text=b[200], textSecondary=b[400], textTertiary=b[500],
        primary="#3AA99F", onPrimary=b["black"], accent="#3AA99F", info="#4385BE",
        infoContainer=alpha("#4385BE", 0.14), infoTrack=alpha("#4385BE", 0.3),
        hero=b[950], heroTile=b[900], heroOutline=b[850], heroText=b[200], heroTextSecondary=b[400], heroMuted=b[500])
    return light, dark


def radix_sand_bronze():
    # Radix 的 12 階：1 頁面、2 次要底、3 元件底、6 細框、7 框、9 實心、11 次要文字、12 主要文字
    s = [None, "#fdfdfc", "#f9f9f8", "#f1f0ef", "#e9e8e6", "#e2e1de", "#dad9d6", "#cfceca", "#bcbbb5", "#8d8d86", "#82827c", "#63635e", "#21201c"]
    sd = [None, "#111110", "#191918", "#222221", "#2a2a28", "#31312e", "#3b3a37", "#494844", "#62605b", "#6f6d66", "#7c7b74", "#b5b3ad", "#eeeeec"]
    br = [None, "#fdfcfc", "#fdf7f5", "#f6edea", "#efe4df", "#e7d9d3", "#dfcdc5", "#d3bcb3", "#c2a499", "#a18072", "#957468", "#7d5e54", "#43302b"]
    bd = [None, "#141110", "#1c1917", "#262220", "#302a27", "#3b3330", "#493e3a", "#5a4c47", "#6f5f58", "#a18072", "#ae8c7e", "#d4b3a5", "#ede0d9"]
    light = dict(
        background=s[2], surface=s[1], surfaceHigh=s[1], surfaceMuted=s[3], fill=s[4], outline=s[6], outlineStrong=s[7], mid=s[9],
        text=s[12], textSecondary=s[11], textTertiary=s[10],
        primary=br[11], onPrimary=br[1], accent=br[9], info=br[11], infoContainer=br[3], infoTrack=br[6],
        hero=sd[2], heroTile=sd[3], heroOutline=sd[5], heroText=sd[12], heroTextSecondary=sd[11], heroMuted=sd[9])
    dark = dict(
        background=sd[1], surface=sd[2], surfaceHigh=sd[3], surfaceMuted=sd[3], fill=sd[4], outline=sd[6], outlineStrong=sd[7], mid=sd[8],
        text=sd[12], textSecondary=sd[11], textTertiary=sd[10],
        primary=bd[11], onPrimary=bd[1], accent=bd[10], info=bd[11], infoContainer=bd[3], infoTrack=bd[6],
        hero=sd[2], heroTile=sd[3], heroOutline=sd[6], heroText=sd[12], heroTextSecondary=sd[11], heroMuted=sd[9])
    return light, dark


def gruvbox_material():
    # medium 背景、material 前景
    lb = dict(dim="#f2e5bc", bg0="#fbf1c7", bg1="#f4e8be", bg2="#f2e5bc", bg3="#eee0b7", bg4="#e5d5ad", bg5="#ddccab",
              visual_blue="#dadec0")
    lf = dict(fg0="#654735", fg1="#4f3829", grey0="#a89984", grey1="#928374", grey2="#7c6f64",
              aqua="#4c7a5d", blue="#45707a", orange="#c35e0a")
    db = dict(dim="#1b1b1b", bg0="#282828", bg1="#32302f", bg3="#45403d", bg5="#5a524c")
    df = dict(fg0="#d4be98", fg1="#ddc7a1", grey0="#7c6f64", grey1="#928374", grey2="#a89984",
              aqua="#89b482", blue="#7daea3", orange="#e78a4e")
    light = dict(
        background=lb["bg0"], surface=mix(lb["bg0"], "#FFFFFF", 0.55), surfaceHigh=mix(lb["bg0"], "#FFFFFF", 0.55),
        surfaceMuted=lb["bg1"], fill=lb["bg2"], outline=lb["bg4"], outlineStrong=lb["bg5"], mid=lf["grey1"],
        text=lf["fg1"], textSecondary=lf["fg0"], textTertiary=lf["grey2"],
        primary=lf["blue"], onPrimary=lb["bg0"], accent=lf["aqua"], info=lf["blue"],
        infoContainer=lb["visual_blue"], infoTrack=mix(lf["blue"], lb["bg0"], 0.6),
        hero=db["bg0"], heroTile=db["bg1"], heroOutline=db["bg3"], heroText=df["fg1"],
        heroTextSecondary=df["fg0"], heroMuted=df["grey2"])
    dark = dict(
        background=db["bg0"], surface=db["bg1"], surfaceHigh=db["bg3"], surfaceMuted=db["bg3"], fill=db["bg3"],
        outline=db["bg3"], outlineStrong=db["bg5"], mid=df["grey0"],
        text=df["fg1"], textSecondary=df["fg0"], textTertiary=df["grey2"],
        primary=df["blue"], onPrimary=db["bg0"], accent=df["aqua"], info=df["blue"],
        infoContainer=alpha(df["blue"], 0.14), infoTrack=alpha(df["blue"], 0.3),
        hero=db["bg1"], heroTile=db["bg3"], heroOutline=db["bg5"], heroText=df["fg1"],
        heroTextSecondary=df["fg0"], heroMuted=df["grey2"])
    return light, dark


def solarized():
    b03, b02, b01, b00 = "#002b36", "#073642", "#586e75", "#657b83"
    b0, b1, b2, b3 = "#839496", "#93a1a1", "#eee8d5", "#fdf6e3"
    violet, blue, cyan = "#6c71c4", "#268bd2", "#2aa198"
    light = dict(
        background=b3, surface=mix(b3, "#FFFFFF", 0.5), surfaceHigh=mix(b3, "#FFFFFF", 0.5),
        surfaceMuted=b2, fill=b2, outline=mix(b2, b1, 0.3), outlineStrong=mix(b2, b1, 0.55), mid=b1,
        text=b02, textSecondary=b01, textTertiary=b00,
        primary=violet, onPrimary=b3, accent=cyan, info=blue,
        infoContainer=mix(blue, b3, 0.88), infoTrack=mix(blue, b3, 0.65),
        hero=b03, heroTile=b02, heroOutline=mix(b02, b01, 0.35), heroText=b2, heroTextSecondary=b1, heroMuted=b0)
    dark = dict(
        background=b03, surface=b02, surfaceHigh=mix(b02, b01, 0.2), surfaceMuted=mix(b02, b01, 0.2),
        fill=mix(b02, b01, 0.2), outline=mix(b02, b01, 0.3), outlineStrong=mix(b02, b01, 0.55), mid=b01,
        text=b2, textSecondary=b1, textTertiary=b0,
        primary=mix(violet, b2, 0.25), onPrimary=b03, accent=cyan, info=mix(blue, b2, 0.2),
        infoContainer=alpha(blue, 0.16), infoTrack=alpha(blue, 0.32),
        hero=b02, heroTile=mix(b02, b01, 0.2), heroOutline=mix(b02, b01, 0.45), heroText=b2, heroTextSecondary=b1, heroMuted=b0)
    return light, dark


def iceberg():
    light = dict(
        background="#e8e9ec", surface=mix("#e8e9ec", "#FFFFFF", 0.65), surfaceHigh=mix("#e8e9ec", "#FFFFFF", 0.65),
        surfaceMuted="#dcdfe7", fill="#dcdfe7", outline="#cad0de", outlineStrong="#a7b2cd", mid="#8389a3",
        text="#33374c", textSecondary="#606374", textTertiary="#757ca3",
        primary="#2d539e", onPrimary="#e8e9ec", accent="#3f83a6", info="#2d539e",
        infoContainer="#ced9e1", infoTrack="#acc5d3",
        hero="#161821", heroTile="#1e2132", heroOutline="#272c42", heroText="#c6c8d1", heroTextSecondary="#a0a3b1", heroMuted="#6b7089")
    dark = dict(
        background="#161821", surface="#1e2132", surfaceHigh="#272c42", surfaceMuted="#272c42", fill="#272c42",
        outline="#272c42", outlineStrong="#444b71", mid="#6b7089",
        text="#c6c8d1", textSecondary=mix("#c6c8d1", "#6b7089", 0.35), textTertiary="#6b7089",
        primary="#84a0c6", onPrimary="#161821", accent="#89b8c2", info="#84a0c6",
        infoContainer=alpha("#84a0c6", 0.14), infoTrack=alpha("#84a0c6", 0.3),
        hero="#1e2132", heroTile="#272c42", heroOutline="#444b71", heroText="#c6c8d1",
        heroTextSecondary=mix("#c6c8d1", "#6b7089", 0.35), heroMuted="#6b7089")
    return light, dark


def melange():
    la = dict(bg="#F1F1F1", float="#E9E1DB", sel="#D9D3CE", ui="#A98A78", com="#7D6658", fg="#54433A")
    lb = dict(yellow="#A06D00", green="#3A684A", cyan="#3D6568", blue="#465AA4")
    ld = dict(yellow="#CCA478", cyan="#CDE8E7", blue="#E0E2E8")
    da = dict(bg="#292522", float="#34302C", sel="#403A36", ui="#867462", com="#C1A78E", fg="#ECE1D7")
    db = dict(yellow="#EBC06D", green="#85B695", cyan="#89B3B6", blue="#A3A9CE")
    light = dict(
        background=la["bg"], surface=mix(la["bg"], "#FFFFFF", 0.7), surfaceHigh=mix(la["bg"], "#FFFFFF", 0.7),
        surfaceMuted=la["float"], fill=la["float"], outline=la["sel"], outlineStrong=mix(la["sel"], la["ui"], 0.35), mid=la["ui"],
        text=la["fg"], textSecondary=la["com"], textTertiary=mix(la["com"], la["ui"], 0.4),
        primary=lb["yellow"], onPrimary=la["bg"], accent=ld["yellow"], info=lb["cyan"],
        infoContainer=ld["cyan"], infoTrack=mix(lb["cyan"], la["bg"], 0.6),
        hero=da["bg"], heroTile=da["float"], heroOutline=da["sel"], heroText=da["fg"], heroTextSecondary=da["com"], heroMuted=da["ui"])
    dark = dict(
        background=da["bg"], surface=da["float"], surfaceHigh=da["sel"], surfaceMuted=da["sel"], fill=da["sel"],
        outline=da["sel"], outlineStrong=mix(da["sel"], da["ui"], 0.4), mid=da["ui"],
        text=da["fg"], textSecondary=da["com"], textTertiary=mix(da["com"], da["ui"], 0.4),
        primary=db["yellow"], onPrimary=da["bg"], accent=db["yellow"], info=db["cyan"],
        infoContainer=alpha(db["cyan"], 0.14), infoTrack=alpha(db["cyan"], 0.3),
        hero=da["float"], heroTile=da["sel"], heroOutline=mix(da["sel"], da["ui"], 0.4), heroText=da["fg"],
        heroTextSecondary=da["com"], heroMuted=da["ui"])
    return light, dark


THEMES = [
    ("Nord", nord),
    ("RosePine", rose_pine),
    ("Everforest", everforest),
    ("Flexoki", flexoki),
    ("Sand", radix_sand_bronze),
    ("GruvboxMaterial", gruvbox_material),
    ("Solarized", solarized),
    ("Iceberg", iceberg),
    ("Melange", melange),
]


def finalize(tokens, is_dark):
    """補對比：文字、按鈕、資訊色"""
    out = {k: (v if isinstance(v, tuple) and len(v) == 2 and isinstance(v[1], float) else solid(v)) for k, v in tokens.items()}
    bg = out["surface"][0]
    far = out["text"][0]
    extreme = "#FFFFFF" if is_dark else "#000000"

    def fix(key, against, minimum, toward):
        out[key] = (ensure(out[key][0], against, minimum, toward), out[key][1])

    fix("text", out["background"][0], 7.0, extreme)
    fix("textSecondary", bg, 4.5, far)
    fix("textTertiary", bg, 3.6, far)
    fix("primary", out["onPrimary"][0], 4.5, far)
    fix("info", bg, 4.5, far)
    fix("heroText", out["hero"][0], 7.0, "#FFFFFF")
    fix("heroTextSecondary", out["hero"][0], 4.5, out["heroText"][0])
    fix("heroMuted", out["hero"][0], 3.0, out["heroText"][0])
    return out


NAMES = dict(background="ERBackground", surface="ERSurface", surfaceHigh="ERSurfaceHigh", surfaceMuted="ERSurfaceMuted",
             fill="ERFill", outline="EROutline", outlineStrong="EROutlineStrong", mid="ERMid",
             text="ERText", textSecondary="ERTextSecondary", textTertiary="ERTextTertiary",
             primary="ERPrimary", onPrimary="EROnPrimary", accent="ERAccent", info="ERInfo",
             infoContainer="ERInfoContainer", infoTrack="ERInfoTrack",
             hero="ERHero", heroTile="ERHeroTile", heroOutline="ERHeroOutline", heroText="ERHeroText",
             heroTextSecondary="ERHeroTextSecondary", heroMuted="ERHeroMuted")


def comp(value):
    (r, g, b), a = value
    return {"color-space": "srgb", "components": {"red": "%.3f" % r, "green": "%.3f" % g, "blue": "%.3f" % b, "alpha": "%.3f" % a}}


def write(path, data):
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, "Contents.json"), "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def hexof(value):
    (r, g, b), _ = value
    return "#%02X%02X%02X" % (round(r * 255), round(g * 255), round(b * 255))


root = os.path.join(ASSETS, "Themes")
shutil.rmtree(root, ignore_errors=True)
write(root, {"info": {"author": "xcode", "version": 1}})
for name, make in THEMES:
    light, dark = make()
    assert set(light) == set(NAMES) and set(dark) == set(NAMES), name
    light, dark = finalize(light, False), finalize(dark, True)
    folder = os.path.join(root, name)
    write(folder, {"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": True}})
    for key, asset in NAMES.items():
        write(os.path.join(folder, asset + ".colorset"), {"colors": [
            {"idiom": "universal", "color": comp(light[key])},
            {"idiom": "universal", "appearances": [{"appearance": "luminosity", "value": "dark"}], "color": comp(dark[key])},
        ], "info": {"author": "xcode", "version": 1}})
    print("%-11s primary %s / %s  hero %s  bg %s / %s  text %s" % (
        name, hexof(light["primary"]), hexof(dark["primary"]), hexof(light["hero"]),
        hexof(light["background"]), hexof(dark["background"]), hexof(light["text"])))
