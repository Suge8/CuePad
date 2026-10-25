#!/usr/bin/env python3
"""界面文字的目录：App/Strings/Localizable.xcstrings（源语言简体中文，译文英文；App、小组件、分享与通知扩展共用，
CuePadKit 的字查主程序这份，String(localized:) 默认就是 main bundle）与 App/Sources/UI/Debug/Demo.xcstrings（演示库的内容，
表名 Demo，只进 Debug 构建）。键是编译器从字面量抽出的中文原文，不手写键。
  strings.py sync    用 mac 与 ios 构建留下的 .stringsdata 更新目录（xc.sh strings 先编两端再调它）：新字进来等翻译，代码里没了的删掉；
                     缺英文的写进 apple/.derived/strings-todo.json（键 → 出处）
  strings.py set     从标准输入读 {"中文键": "English" | {"one": "…", "other": "…"}} 写进英文（复数按第一个数字参数分）；占位符要与键一致
  strings.py check   xc.sh check 在 iOS 构建后调：这次构建抽到的字都在目录里，每条都有英文且占位符对得上
"""
import json, os, re, subprocess, sys
from glob import glob

APPLE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOGS = {"Localizable": f"{APPLE}/App/Strings/Localizable.xcstrings", "Demo": f"{APPLE}/App/Sources/UI/Debug/Demo.xcstrings"}
BUILD = f"{APPLE}/.derived/Build/Intermediates.noindex"
TODO = f"{APPLE}/.derived/strings-todo.json"
APP_TARGETS = ("CuePad", "CuePadWidget", "CuePadShare", "CuePadNotify")  # 测试目标与命令行工具的字不上界面
HAN = re.compile(r"[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]")
SPEC = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfeEgGcCsSpaA%])")


def stringsdata(configs):
    """各构建配置下 App 各目标与 Kit 各模块的 .stringsdata；源文件已删的（旧产物）不算。"""
    files = []
    for config in configs:
        for target in APP_TARGETS:
            files += glob(f"{BUILD}/CuePad.build/{config}/{target}.build/**/*.stringsdata", recursive=True)
        files += [f for f in glob(f"{BUILD}/CuePadKit.build/{config}/*-t.build/**/*.stringsdata", recursive=True) if "/CueTestSupport-t.build/" not in f]
    keep = []
    for f in files:
        data = json.load(open(f))
        if data.get("tables") and os.path.exists(data["source"]):
            keep.append((f, data))
    return keep


def load(table):
    return json.load(open(CATALOGS[table]))


def save(table, catalog):
    """与 Xcode 写的格式逐字相同（键按码位排序、空对象占三行、末尾无换行），免得 Xcode 打开一次就改动整个文件。"""
    text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "), sort_keys=True)
    text = re.sub(r"^( *)(.*)\{\}", lambda m: f"{m.group(1)}{m.group(2)}{{\n\n{m.group(1)}}}", text, flags=re.M)
    open(CATALOGS[table], "w").write(text)


def specs(text):
    return sorted(c for c in SPEC.findall(text) if c != "%")


def english(entry):
    """英文译文的各个变体；没有译文返回空表。"""
    en = entry.get("localizations", {}).get("en", {})
    if "stringUnit" in en:
        return [en["stringUnit"]["value"]] if en["stringUnit"]["state"] == "translated" else []
    return [v["stringUnit"]["value"] for v in en.get("variations", {}).get("plural", {}).values()]


def problems(key, entry):
    if entry.get("shouldTranslate") is False or not HAN.search(key):
        return None
    variants = english(entry)
    if not variants:
        return "缺英文"
    for v in variants:
        if HAN.search(v):
            return f"英文里有中文：{v}"
    want = specs(key)
    if specs(variants[-1]) != want or any(not set(specs(v)) <= set(want) for v in variants):
        return f"占位符与键不一致：{variants}"
    return None


def keep_source(key, entry):
    """每条都写上中文那一份：开发语言是英文，中文那边缺了整张表（演示内容、复数）时系统整张回落到英文，中文界面就显示英文。"""
    locs = entry.setdefault("localizations", {})
    if HAN.search(key) and "zh-Hans" not in locs:
        locs["zh-Hans"] = {"stringUnit": {"state": "translated", "value": key}}


# 两端构建里各自要有抽取结果的目标（CuePi 只在 Mac 上编）
EXPECTED = {"Debug": ("CuePad", "CueStore", "CueSync", "CuePi", "CueEditor"), "Debug-iphonesimulator": ("CuePad", "CueStore", "CueSync", "CueEditor")}


def sync():
    configs = list(EXPECTED)
    # 少了哪一份抽取，那一份里的字就会被当成代码里没了、连同英文一起删掉
    lacking = [f"{c} 的 {t}" for c, targets in EXPECTED.items() for t in targets
               if not glob(f"{BUILD}/{'CuePad.build' if t == 'CuePad' else 'CuePadKit.build'}/{c}/{t if t == 'CuePad' else t + '-t'}.build/**/*.stringsdata", recursive=True)]
    if lacking:
        sys.exit("这些目标没有抽取结果，不收（先 xc.sh build mac 与 ios）：" + "、".join(lacking))
    files = stringsdata(configs)
    subprocess.run(["xcrun", "xcstringstool", "sync", *CATALOGS.values(), "--stringsdata", *[f for f, _ in files]], check=True)
    where = {(t, s["key"]): f"{os.path.relpath(d['source'], APPLE)}:{s['location']['startingLine']}"
             for _, d in files for t, strings in d["tables"].items() for s in strings}
    todo = {}
    for table in CATALOGS:
        catalog = load(table)
        strings = catalog["strings"]
        for key in [k for k, e in strings.items() if e.get("extractionState") == "stale"]:
            del strings[key]
        for key, entry in strings.items():
            keep_source(key, entry)
            if not HAN.search(key) and not english(entry):
                entry["shouldTranslate"] = False
            elif problems(key, entry):
                todo[key] = where.get((table, key), table)
        save(table, catalog)
    json.dump(todo, open(TODO, "w"), ensure_ascii=False, indent=1)
    print(f"缺英文 {len(todo)} 条，见 {os.path.relpath(TODO, os.getcwd())}" if todo else "每条都有英文")


def put():
    """同一个键可能两份目录里都有（界面与演示内容共用一句）：有它的每一份都写。"""
    catalogs = {t: load(t) for t in CATALOGS}
    unit = lambda v: {"stringUnit": {"state": "translated", "value": v}}
    bad = []
    for key, value in json.load(sys.stdin).items():
        holders = [c["strings"] for c in catalogs.values() if key in c["strings"]]
        if not holders:
            bad.append(f"目录里没有：{key}")
            continue
        en = unit(value) if isinstance(value, str) else {"variations": {"plural": {k: unit(v) for k, v in value.items()}}}
        for strings in holders:
            trial = {**strings[key], "localizations": {**strings[key].get("localizations", {}), "en": en}}
            if why := problems(key, trial):
                bad.append(f"{key}：{why}")
                break
            keep_source(key, trial)
            strings[key] = trial
    for table, catalog in catalogs.items():
        save(table, catalog)
    if bad:
        sys.exit("没写进去的：\n" + "\n".join(bad))


def check():
    catalogs = {t: load(t)["strings"] for t in CATALOGS}
    bad = [f"{os.path.relpath(d['source'], APPLE)}:{s['location']['startingLine']} 「{s['key']}」不在目录里"
           for _, d in stringsdata(["Debug-iphonesimulator"]) for t, strings in d["tables"].items() for s in strings
           if s["key"] not in catalogs.get(t, {})]
    bad += [f"「{k}」{why}" for c in catalogs.values() for k, e in c.items() if (why := problems(k, e))]
    if bad:
        sys.exit("\n".join(sorted(set(bad))) + "\n界面文字没对齐：xc.sh strings 收进目录，strings.py set 补英文（见头注释）")


if __name__ == "__main__":
    {"sync": sync, "set": put, "check": check}[sys.argv[1] if len(sys.argv) > 1 else ""]()
