#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AI 生图脚本（线上版）—— 出图走官方服务器，按积分计费。

与直连版的区别：这里不需要你自己配任何生图 Key。
首次使用用邮箱注册一个账号（收 6 位验证码），之后凭 key 出图、充值续积分。
每个账号每天可免费出 1 张图（当日有效，没用完第二天会清零）。

用法
────────────────────────────────────────────
文生图（命令行传提示词，简单场景）：
    python gen.py --prompt "一只橘猫坐在窗边，暖光，写实摄影"

文生图（中文长提示词，推荐从文件读，避免命令行编码问题）：
    python gen.py --prompt-file prompt.txt --out 图1.png

图生图（带参考图，2-3 张通常最稳）：
    python gen.py --prompt-file prompt.txt --ref 产品图.png --ref 细节图.png --out 精修.png

常用参数：
    --size     1024x1024 / 1024x1536 / 1536x1024 / 1024x2048 / 2048x2048   默认 1024x1024
    --quality  low / medium / high                              默认 medium
    --model    模型名，默认由服务端决定（显式指定可覆盖）
    --n        生成张数，默认 1
    --out      输出文件名，默认按时间戳生成
    --rekey    手动换新 key（余额保留；不绑机后换电脑已无需此功能）

非交互参数（供 AI 助手代为执行；你只需提供邮箱 / 验证码 / key）：
    --send-code 你的邮箱            发送注册验证码
    --complete 你的邮箱 6位验证码   完成注册并自动保存 key
    --save-key sk-xxx               导入已有 key（换电脑场景）
    --check                         只登录查余额，不出图

首次使用流程：
    给邮箱 → 收到 6 位验证码给它 → 注册完成，key 自动保存在本机，
    以后不用再输。积分用完会提示充值链接。
"""

import argparse
import base64
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

DEFAULT_MODEL = "gpt-image-2.5"   # 静态兜底模型名（模型可传；正常值来自服务端 /auth/login 下发）

# 官方服务器（出图 / 注册 / 登录 / 充值都走它）。渠道锁定，不提供换渠道参数。
WORKER = (os.environ.get("CD_VERIFY_URL") or "https://verify.evomindd.top").rstrip("/")
GEN_URL = WORKER + "/gen"
PAY_URL = WORKER + "/pay"
GUIDE_URL = WORKER + "/guide"   # 图文使用说明书（2026-10-27 上线，脚本直接把它打出来）
CRED_PATH = pathlib.Path.home() / ".creative-design" / "license.json"

# 所有请求必须带浏览器 UA：服务端网关默认按 User-Agent 拦截脚本流量，
# Python urllib 默认 UA（Python-urllib/x.x）会被直接 403，表现成"连不上服务器"。
HEADERS = {
    "Content-Type": "application/json",
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"),
}
# 国内直连偶发 TLS 握手超时，网络类失败必须自动重试。
# 网络类失败自动重试，重试是刚需不是锦上添花。
NET_TRIES = 3

# 出图请求（/gen）必须带浏览器 UA：缺了会被服务端网关按指纹 403/1010 拦。
# 单独抽出来供 do_gen 显式使用。
GEN_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

# 国内直连偶发网络抖动：等一会再试大概率就通了。客户端侧能做的是
# 「更多次数 + 更长退避」；IP 池切换需 http.client 手工注入 socket，
# 增加复杂度，暂不做——先靠次数兜底。
NET_TRIES = 5   # 出图请求从 3 次提到 5 次（覆盖网络抖动恢复窗口）
NET_BACKOFF = [2, 4, 8, 15, 30]  # 每次重试前的等待秒数（共 5 次，累计 ~60s）

DEFAULT_BASE_NOTE = ""  # 线上版没有直连渠道概念，占位防旧调用方 KeyError

SIZE_HINTS = {
    "1024x1536": "画面宽 1024 像素、高 1536 像素，竖版构图，高大于宽",
    "1024x1024": "画面宽 1024 像素、高 1024 像素，正方形构图",
    "1536x1024": "画面宽 1536 像素、高 1024 像素，横版构图，宽大于宽".replace("宽大于宽", "宽大于高"),
    "1024x2048": "画面宽 1024 像素、高 2048 像素，长条竖版构图，高是宽的两倍",
    "2048x2048": "画面宽 2048 像素、高 2048 像素，正方形构图",
}


def anchor_size(prompt, size):
    """把 --size 转成提示词里的尺寸锚定句。

    服务端会把 --size 映射成输出比例（1024x1536 → 940x1672 竖版），
    但产物像素由服务端枚举决定、并非逐字精确——提示词里再写一句尺寸描述能稳住构图，两层保险。
    参数仍然照传，两种渠道都覆盖。已经在提示词里写了尺寸就别重复追加。
    """
    hint = SIZE_HINTS.get(size)
    if not hint or len(prompt) >= 4000:
        return prompt
    if any(k in prompt for k in ("像素", "构图", "比例", "画幅")):
        return prompt  # 提示词已自带尺寸约束，不动
    return prompt.rstrip() + "。" + hint


# 中文输出分两种情况：**控制台**用本地编码（中文 Windows 是 GBK，强制 UTF-8 反而乱码）；
# **管道/被捕获时统一 UTF-8**（批量出图的子进程、助手用 shell 捕获输出都走这条），
# 否则父进程按 UTF-8 解到的是 GBK 字节 → 满屏乱码。
# errors 放宽到 replace，保证遇到个别不能编码的字符时不会崩。
_force_utf8 = os.environ.get("CD_FORCE_UTF8") == "1"
for _stream in (sys.stdout, sys.stderr):
    try:
        if _force_utf8 or not _stream.isatty():
            _stream.reconfigure(encoding="utf-8", errors="replace")
        else:
            _stream.reconfigure(errors="replace")
    except Exception:
        pass


def die(msg, code=1):
    print(f"\n[错误] {msg}\n", file=sys.stderr)
    sys.exit(code)


def show_guide():
    """说明书入口（2026-10-27 买家实测）：原来「注册后推使用说明」只写在 SKILL.md 里，
    而走 --login / --save-key 的人不经过 --complete，整个会话拿不到任何入口。
    现在由脚本在三个成功出口的最后打印，模型只要把这一行转述给用户。"""
    print("\n[使用说明] 第一次用可以先看这份图文说明（点开看，图多，手机上也能看）：\n"
          f"           {GUIDE_URL}", flush=True)


def login_probe(key, timeout=20):
    """登录 / 验活：badkey 是服务端 KV 偶发读失败时的误报（2026-10-27 买家实测：
    同一把 key 11:2x 连续三次回 badkey、11:4x 同一把 key 直接 ok）。
    服务端已改成 4 次退避重试并新增 reason=temp；客户端再补两次，别一句话把 key 判死。"""
    r, neterr = http_json(WORKER + "/auth/login", {"key": key, "n": 1}, timeout=timeout)
    for i, ms in enumerate((300, 900)):
        if r is None:
            break
        if r.get("reason") not in ("badkey", "temp"):
            break
        time.sleep(ms / 1000.0)
        r, neterr = http_json(WORKER + "/auth/login", {"key": key, "n": 1}, timeout=timeout)
    return r, neterr


def die_nolimit(r):
    """积分不够。给买家能直接照做的下一步，而不是一句『失败』就结束。"""
    pay = r.get("pay") or PAY_URL   # 3.34：服务端 pay 字段已是 claim 票据链接（URL 不含 key）；兜底不带 key
    free = int(r.get("free") or 0)
    have = int(r.get("credits") or 0) + free
    extra = f"（其中今日免费 {free}）" if free else ""
    trial = "，今日免费额度已用完" if r.get("trialUsedToday") else ""
    print(f"\n[提示] 这次要 {r.get('need', '?')} 积分，"
          f"你的账号还剩 {have} 积分{extra}{trial}，先充值再跑。\n"
          f"       打开这个链接充值（自动认账号，填个金额付款就行；链接 30 分钟内有效）：\n"
          f"       {pay}\n"
          f"       付完款回来重新跑一次刚才的命令。\n", file=sys.stderr)
    sys.exit(2)


def http_json(url, payload, timeout=30, tries=NET_TRIES):
    """POST JSON。网络类失败自动重试；服务器明确响应（含业务失败）直接返回。

    返回 (响应dict, 网络错误串或 None)。
    """
    body = json.dumps(payload).encode("utf-8")
    last = None
    for i in range(tries):
        req = urllib.request.Request(url, data=body, method="POST", headers=HEADERS)
        try:
            return json.loads(urllib.request.urlopen(req, timeout=timeout).read()
                              .decode("utf-8")), None
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:300]
            try:
                return json.loads(detail), None   # 服务器返回的业务错误也是 JSON
            except Exception:
                return {"ok": False, "msg": f"服务器返回 HTTP {e.code}：{detail}"}, None
        except Exception as e:
            last = e
            if i < tries - 1:
                time.sleep(1 + i * 1.5)
    return None, str(last)


def _http_get_json(url, timeout=2):
    req = urllib.request.Request(url, method="GET",
                                 headers={"User-Agent": HEADERS["User-Agent"]})
    return json.loads(urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8"))


def http_get_json(url, timeout=30, headers=None):
    """GET JSON，可带自定义请求头（如账户 token）。返回 (dict, 网络错误串或 None)。"""
    h = {"User-Agent": HEADERS["User-Agent"]}
    if headers:
        h.update(headers)
    try:
        req = urllib.request.Request(url, method="GET", headers=h)
        return json.loads(urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8")), None
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        try:
            return json.loads(detail), None
        except Exception:
            return {"ok": False, "msg": f"服务器返回 HTTP {e.code}：{detail}"}, None
    except Exception as e:
        return None, str(e)


def local_version():
    """本地版本号来自技能自身的 SKILL.md（不写死）。"""
    try:
        txt = SKILL_MD.read_text(encoding="utf-8")
    except Exception:
        return ""
    m = re.search(r'(?m)^version:\s*"?([0-9]+\.[0-9]+)"?\s*$', txt)
    return m.group(1) if m else ""


def compare_ver(a, b):
    """两段式数值比较：3.10 > 3.9（字符串比是错的）。"""
    if not (re.match(r"^[0-9]+\.[0-9]+$", a or "") and re.match(r"^[0-9]+\.[0-9]+$", b or "")):
        return 0
    aa = [int(x) for x in a.split(".")]
    bb = [int(x) for x in b.split(".")]
    return (aa > bb) - (aa < bb)


def remote_version(timeout=2):
    if os.environ.get("CD_NO_UPDATE_CHECK") == "1":
        return None
    try:
        return _http_get_json(f"{VERSION_URL}?t={int(time.time())}", timeout=timeout)
    except Exception:
        return None


def show_update_hint():
    """出图前调用：超时/失败一律静默，绝不阻断出图；同版本 24h 只提示一次。"""
    if os.environ.get("CD_NO_UPDATE_CHECK") == "1":
        return
    rv = remote_version(2)
    if not rv or rv.get("ok") is not True:
        return
    latest = str(rv.get("latest") or "")
    local = local_version()
    if not latest or not local:
        return
    if compare_ver(latest, local) <= 0:
        return
    now = int(time.time())
    last_ver, last_at = "", 0
    try:
        j = json.loads(UPDATE_CHECK_PATH.read_text(encoding="utf-8"))
        last_ver, last_at = str(j.get("version", "")), int(j.get("at", 0))
    except Exception:
        pass
    if last_ver == latest and now - last_at < 86400:
        return
    print("")
    print(f"[版本] 技能有新版本：本地 v{local} -> 最新 v{latest}")
    print("       更新命令：scripts\\gen.cmd update   （约 10 秒）")
    print("       更新后请重启 opencode 或新开会话，技能才会重新加载。")
    print("")
    try:
        UPDATE_CHECK_PATH.parent.mkdir(parents=True, exist_ok=True)
        UPDATE_CHECK_PATH.write_text(json.dumps({"version": latest, "at": now}), encoding="utf-8")
    except Exception:
        pass


def do_update():
    import shutil as _sh
    import tempfile
    import zipfile
    lv = local_version()
    rv = remote_version(10)
    if not rv or rv.get("ok") is not True or not rv.get("latest"):
        die(f"查不到最新版本（网络或服务端不可达）。可稍后重试，或手动下载覆盖安装：\n"
            f"       {WORKER}/skill/super-design.zip")
    latest = str(rv["latest"])
    if lv and compare_ver(latest, lv) <= 0:
        print(f"[OK] 已是最新版本 v{lv}，无需更新。")
        return
    print(f">> 本地 v{lv}  ->  最新 v{latest}，开始下载…")
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="cd_update_"))
    try:
        zpath = tmp / "pkg.zip"
        ok = False
        ts = int(time.time())
        for url in (f"{WORKER}/skill/super-design-v{latest}.zip?t={ts}",
                    f"{WORKER}/skill/super-design.zip?t={ts}"):
            try:
                req = urllib.request.Request(url, headers={"User-Agent": HEADERS["User-Agent"]})
                with urllib.request.urlopen(req, timeout=180) as r, open(zpath, "wb") as f:
                    _sh.copyfileobj(r, f)
                ok = True
                break
            except Exception:
                continue
        if not ok:
            die(f"下载失败（网络不通或被拦截）。可稍后重试，或手动下载覆盖安装：\n"
                f"       {WORKER}/skill/super-design.zip")
        # 3.34（云鼎安全整改③）：先验制品哈希（对照 /skill/version 返回的 sha256）再解压，
        # 链路被篡改 / 内容被替换时中止覆盖；服务端未提供 sha256（旧版）时跳过校验保持兼容。
        exp_sha = str(rv.get("sha256") or "").lower()
        if exp_sha:
            import hashlib
            got_sha = hashlib.sha256(zpath.read_bytes()).hexdigest()
            if got_sha != exp_sha:
                die(f"更新包哈希与服务器不符（疑似被篡改或下载不完整），已中止覆盖，本机文件未改动。"
                    f"可稍后重试，或手动下载官方包核对：\n"
                    f"       {WORKER}/skill/super-design.zip")
        with zipfile.ZipFile(zpath) as z:
            z.extractall(tmp)
        new_root = tmp / "super-design"
        new_md = new_root / "SKILL.md"
        if not new_md.is_file():
            die("更新包结构异常（缺 SKILL.md），已中止，本机文件未改动。")
        m = re.search(r'(?m)^version:\s*"?([0-9]+\.[0-9]+)"?\s*$', new_md.read_text(encoding="utf-8"))
        nv = m.group(1) if m else ""
        if nv != latest:
            die(f"下载到的包版本是 v{nv}，与预期的 v{latest} 不一致，已中止（本机文件未改动）。")
        n = 0
        failed = []
        for f in new_root.rglob("*"):
            if not f.is_file():
                continue
            rel = f.relative_to(new_root)
            dst = SKILL_ROOT / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            try:
                _sh.copy2(f, dst)
                n += 1
            except Exception:
                failed.append(str(rel))
        if failed:
            die(f"有 {len(failed)} 个文件被占用，未能覆盖：\n       {', '.join(failed)}\n"
                f"       请重启 opencode 后再运行一次")
        print("")
        print(f"[OK] 已更新到 v{latest}（共 {n} 个文件）。")
        print("     请重启 opencode 或新开一个会话，技能才会重新加载生效。")
    finally:
        _sh.rmtree(tmp, ignore_errors=True)


def load_cred():
    """本地凭证有效才算数。

    凭证在买家用户目录，不随安装包走；2026-10-19 起不绑机、不采集机器指纹——
    拷到别的电脑上也能直接用，无需重新注册或换绑。
    旧 U 盘版凭证（有 order 无 key）自然不被识别，会重走注册。
    """
    try:
        c = json.loads(CRED_PATH.read_text(encoding="utf-8"))
        # 2026-10-19 起不绑机、不采集机器指纹：凭证可在任意机器直接用
        if c.get("ok") is True and str(c.get("key", "")).startswith("sk-"):
            return c
    except Exception:
        pass
    return None


def save_cred(key, email=""):
    CRED_PATH.parent.mkdir(parents=True, exist_ok=True)
    CRED_PATH.write_text(json.dumps({"ok": True, "key": key,
                                     "email": email,
                                     "time": time.strftime("%Y-%m-%d")},
                                    ensure_ascii=False), encoding="utf-8")



# ── 出图任务持久化－－－－－－－－－－－－－－－－－－－－－－－
# 客户端读响应超时 ≠ 服务端失败：出图 30-60s 期间本地断网，服务端仍会把
# 图生成完并扣费，但 rid 原本只在内存里 → 买家白扣积分、图找不回来。
# 现在每次出图前把 {key, rid} 写入 pending.json；成功/失败退款后清掉；
# 再跑同 key 的出图命令时自动用同一 rid 重放——服务端幂等，不重复扣费。
PENDING_PATH = CRED_PATH.parent / "pending.json"
VERSION_URL = WORKER + "/skill/version"
# 技能根目录 = scripts 的上一级（不写死路径，买家装在哪儿都能自更新）
SKILL_ROOT = pathlib.Path(__file__).resolve().parent.parent
SKILL_MD = SKILL_ROOT / "SKILL.md"
UPDATE_CHECK_PATH = CRED_PATH.parent / "update-check.json"


def _pending_slot(key):
    """按 key 尾 8 位做槽位，避免多账户互相覆盖（本机上正常只有一个账户）。"""
    return key[-8:]


def save_pending(key, rid, params):
    PENDING_PATH.parent.mkdir(parents=True, exist_ok=True)
    try:
        dd = json.loads(PENDING_PATH.read_text(encoding="utf-8"))
    except Exception:
        dd = {}
    dd[_pending_slot(key)] = {"key": key, "rid": rid, "params": params,
                             "ts": int(time.time())}
    PENDING_PATH.write_text(json.dumps(dd, ensure_ascii=False), encoding="utf-8")


def clear_pending(key):
    try:
        dd = json.loads(PENDING_PATH.read_text(encoding="utf-8"))
        dd.pop(_pending_slot(key), None)
        PENDING_PATH.write_text(json.dumps(dd, ensure_ascii=False), encoding="utf-8")
    except Exception:
        pass


def find_pending(key):
    """同 key 48h 内的未完成任务；过期当单元忽略，返回 None。"""
    try:
        dd = json.loads(PENDING_PATH.read_text(encoding="utf-8"))
        pp = dd.get(_pending_slot(key))
    except Exception:
        return None
    if not pp or pp.get("key") != key or time.time() - pp.get("ts", 0) > 48 * 3600:
        return None
    return pp


def register_flow():
    """首次使用：邮箱注册拿 key（6 位验证码，30 分钟内有效；邮箱可能要等 1-2 分钟）。"""
    print("首次使用，先用邮箱注册一个账号（不收任何费用，只是用来管你的积分）。\n")
    try:
        email = input("你的邮箱（QQ 邮箱、163、Outlook 都行）：").strip()
    except EOFError:
        die("没有输入邮箱。")
    if not re.match(r"^[^\s@]+@[^\s@]+\.[^\s@]+$", email):
        die(f"邮箱格式不对：{email}")
    print("正在发送验证码，请稍候…", flush=True)
    r, neterr = http_json(WORKER + "/reg/send", {"email": email}, timeout=30)
    if r is None:
        die(f"连不上服务器（{neterr}）。检查网络后重新运行本命令。")
    if r.get("ok") is not True:
        die(f"验证码发送失败：{r.get('msg', r)}")
    print(f"[OK] 验证码已发到 {email}，请查收邮箱（可能要等 1-2 分钟，30 分钟内有效）。\n", flush=True)

    for attempt in range(3):
        try:
            code = input(f"填入邮箱里的 6 位验证码（第 {attempt + 1} 次机会）：").strip()
        except EOFError:
            die("没有输入验证码。")
        r, neterr = http_json(WORKER + "/reg/complete",
                              {"email": email, "code": code}, timeout=30)
        if r is None:
            die(f"连不上服务器（{neterr}）。检查网络后重新运行本命令。")
        if r.get("ok") is True and str(r.get("key", "")).startswith("sk-"):
            save_cred(r["key"], email)
            print(f"\n[OK] 注册成功！你的 key 已自动保存在本机，以后不用再管。\n"
                  f"     请把这串 key 备份到记事本里（换电脑时要用）：\n\n"
                  f"     {r['key']}\n", flush=True)
            return r["key"]
        print(f"       {r.get('msg', '验证码不对')}，请重试。", flush=True)
    die("连续 3 次没通过。重新运行本命令可以再收一封验证码。")


def login_gate(key):
    """每次运行的门：只带 key 登录（2026-10-19 起不绑机、不采集机器指纹）。
    余额不够直接引导充值。换电脑 / 重装系统均无需任何操作。"""
    r, neterr = login_probe(key, timeout=20)
    if r is None:
        # 与旧版复验同思路：连不上先放行——出图本身要联网，真有问题 /gen 会拦。
        print("[提醒] 连不上验证服务器（已重试），先照常用。", flush=True)
        return
    if r.get("reason") == "temp":
        print("[提醒] 服务器这会儿读不到你的 key 记录（不是 key 坏了），先照常出图；\n"
              "       如果出图也报同样的错，等 1-2 分钟重跑一次就行。", flush=True)
        return
    if r.get("ok") is True:
        bal = r.get("credits", 0)
        free = int(r.get("free") or 0)
        per = int(r.get("perImage") or 0)
        globals()["PER_IMAGE"] = per
        globals()["ACCOUNT_BAL"] = int(bal)
        if r.get("defaultModel"):
            globals()["DEFAULT_MODEL_NAME"] = str(r.get("defaultModel"))
        # 免费额度每次都显示：free=0 说「已用完」，不能静默
        free_txt = f"还剩 {free} 积分" if free > 0 else "已用完"
        line = f">> 账号就绪，余额 {bal} 积分，今日免费额度{free_txt}"
        if per > 0:
            line += f"，每张 {per} 积分"
        print(line, flush=True)
        return
    if r.get("reason") == "nolimit":
        # 免费额度已用完时，/auth/login 也会返回 nolimit —— 但此时并非"积分不够"，
        # 而是"今天 1 张免费额度已经用掉了"。给一个不带 die 的温和提示，
        # 让 --check 这类"查余额"命令能正常退出（exit 0），而不是 exit 2。
        free = int(r.get("free") or 0)
        bal = int(r.get("credits") or 0)
        state = f"还剩 {free} 积分" if free > 0 else "已用完"
        per_img = f"，每张 {int(r.get('perImage') or 0)} 积分" if r.get("perImage") else ""
        print(f"[提示] 这次的积分不够：余额 {bal} 积分，今日免费额度{state}{per_img}。")
        pay = r.get("pay") or PAY_URL   # 3.34：服务端 pay 字段已是 claim 票据链接（URL 不含 key）
        print(f"       如需继续出图，打开充值链接（自动认账号，填个金额付款就行；链接 30 分钟内有效）：")
        print(f"       {pay}")
        return
    if r.get("reason") == "used":
        # 历史遗留：旧版服务端返回此值；不绑机后正常不会再出现，保留兜底提示
        print("[提示] key 状态异常，请重新运行出图命令；若持续出现请联系卖家。", flush=True)
        return
    die(f"key 无效或已失效：{r.get('msg', r)}\n"
        f"       核对一下 key 有没有复制错（sk- 开头一整串）；"
        f"实在不行重新注册一个，或联系卖家。")


def rekey_flow(key):
    """手动换 key（余额保留）。2026-10-19 起不绑机，换电脑不再需要此功能；
    保留入口供手动换 key 值用（如怀疑 key 泄露）。"""
    print("正在换 key（余额会保留，旧 key 立即作废）…", flush=True)
    r, neterr = http_json(WORKER + "/auth/rekey", {"key": key}, timeout=30)
    if r is None:
        die(f"连不上服务器（{neterr}）。检查网络后重新运行。")
    if r.get("ok") is not True or not str(r.get("key", "")).startswith("sk-"):
        die(f"换 key 失败：{r.get('msg', r)}")
    save_cred(r["key"], load_cred().get("email", "") if load_cred() else "")
    print(f"\n[OK] 换好了。新 key 已保存在本机，请备份：\n\n"
          f"     {r['key']}\n", flush=True)
    return r["key"]


def read_prompt(args):
    if args.prompt_file:
        p = pathlib.Path(args.prompt_file)
        if not p.exists():
            die(f"提示词文件不存在：{p}")
        return p.read_text(encoding="utf-8")
    if args.prompt:
        return args.prompt
    if not sys.stdin.isatty():
        return sys.stdin.read()
    die("没有提示词。请用 --prompt、--prompt-file，或从管道输入。")


def check_refs(paths):
    """校验参考图存在与体积——超限会被服务端拒绝，先在本地拦一道。"""
    ok = []
    for f in paths:
        p = pathlib.Path(f)
        if not p.exists():
            die(f"参考图不存在：{f}")
        size = p.stat().st_size
        if size > 5 * 1024 * 1024:
            die(f"参考图过大（{size//1024//1024}MB）：{f}\n       请压缩到 5MB 以内再传。")
        ok.append(p)
    return ok


def build_multipart(fields, files):
    """手工拼 multipart/form-data。只用标准库，不装依赖。

    files 是 [(字段名, Path, 文件名, MIME), ...] 的列表，不接受 dict——
    官方文档要求多图时「重复传多个 image 字段」，同名键必须能共存；
    用 dict 会因同键覆盖静默丢掉除最后一张外的所有参考图。
    """
    boundary = "----opencodeimg" + uuid.uuid4().hex
    lines = []
    for k, v in fields.items():
        if v is None:
            continue
        lines += [
            f"--{boundary}".encode(),
            f'Content-Disposition: form-data; name="{k}"'.encode(),
            b"",
            str(v).encode("utf-8"),
        ]
    for k, path, name, ctype in files:
        lines += [
            f"--{boundary}".encode(),
            f'Content-Disposition: form-data; name="{k}"; filename="{name}"'.encode(),
            f"Content-Type: {ctype}".encode(),
            b"",
            path.read_bytes(),
        ]
    lines += [f"--{boundary}--".encode(), b""]
    return b"\r\n".join(lines), f"multipart/form-data; boundary={boundary}"


def fetch_url(url, out_path):
    """下载返回的公网直链。

    必须带 UA / Referer —— 裸 urlretrieve 常被图片 CDN 直接拒。
    这类链接有效期有限，拿到就得立刻存盘。
    """
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0",
        "Accept": "image/*,*/*;q=0.8",
        "Referer": "/".join(url.split("/")[:3]) + "/",
    })
    data = urllib.request.urlopen(req, timeout=120).read()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(data)
    return len(data)


def decode_and_save(b64, out_path):
    data = base64.b64decode(b64)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(data)
    return len(data)


LOAD_RETRIED = [False]   # 负载类错误只自动重试一次（2026-10-20）


def do_gen(cred, body, ctype, n, timeout):
    """调官方服务器出图。网络失败自动重试（同一 rid，服务端幂等：不会重复扣费）。

    返回服务端响应 dict；致命业务失败直接 die。
    """
    # 先查本地是否有同 key 的未完成任务（上一次请求丢了响应但服务端可能已受理）
    pending = find_pending(cred["key"])
    if pending:
        print(">> 发现上次出图任务未确认完成，自动用同一任务号重放"
              "（服务端幂等，不会重复扣费）…", flush=True)
        rid = pending["rid"]
    else:
        rid = uuid.uuid4().hex
    url = (f"{GEN_URL}?key={urllib.parse.quote(cred['key'])}"
           f"&rid={rid}&n={int(n)}")
    # 任务已发出去但还没拿到确认结果之前，先把 rid 落盘——
    # 本地断网/超时后，下次出图命令会自动带着同一个 rid 重放找回结果。
    if not pending:
        save_pending(cred["key"], rid, {"n": int(n)})
    last = None
    for i in range(NET_TRIES):
        req = urllib.request.Request(url, data=body, method="POST")
        req.add_header("Authorization", "Bearer " + cred["key"])
        req.add_header("Content-Type", ctype)
        req.add_header("User-Agent", GEN_UA)
        try:
            r = json.loads(urllib.request.urlopen(req, timeout=timeout).read()
                           .decode("utf-8"))
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:400]
            die(f"服务器返回 HTTP {e.code}：{detail}\n"
                f"       这是服务器侧的问题，稍等几分钟再试；持续出现请联系卖家。")
        except Exception as e:
            last = e
            if i < NET_TRIES - 1:
                wait = NET_BACKOFF[i] if i < len(NET_BACKOFF) else 15
                print(f">> 网络没连上（{type(e).__name__}），{wait} 秒后重试"
                      f"（第 {i + 2}/{NET_TRIES} 次）…", flush=True)
                time.sleep(wait)
            continue
        if r.get("ok") is True:
            clear_pending(cred["key"])
            if r.get("dup"):
                print(">> 服务器确认上次已受理，返回原结果（未重复扣费）", flush=True)
            return r
        if r.get("reason") == "nolimit":
            clear_pending(cred["key"])
            die_nolimit(r)
        if r.get("reason") == "used":
            clear_pending(cred["key"])
            die("这把 key 状态异常（服务器拒绝出图）。"
                "重新运行一次命令试试；持续出现请联系卖家。")
        msg = r.get("msg", json.dumps(r, ensure_ascii=False)[:200])
        if r.get("refunded"):
            # 主通道负载类错误（excessive system load 等）是间歇性的：等 25 秒自动重试一次
            # （失败任务不扣积分，重试对买家零成本；同 rid 会被服务端幂等返回，故先清 pending 换新 rid）
            up_err = str(r.get("upstream_error") or "")
            is_load = bool(re.search(r"excessive|overload|busy|system load|rate.?limit", up_err, re.I)) \
                or "出图服务当前负载过高" in str(msg)
            if is_load and not LOAD_RETRIED[0]:
                LOAD_RETRIED[0] = True
                clear_pending(cred["key"])
                print(">> 出图服务当前负载过高（间歇性问题），25 秒后自动重试一次…", flush=True)
                time.sleep(25)
                return do_gen(cred, body, ctype, n, timeout)
            clear_pending(cred["key"])
            free = int(r.get("free") or 0)
            note = f" + 今日免费 {free}" if free else ""
            die(f"这次没出成图，积分已退回（余额 {r.get('credits', '?')}{note}）。\n"
                f"       原因：{msg}\n"
                f"       稍等片刻重新运行刚才的命令即可。")
        die(f"出图失败：{msg}")
    # 三次全网络失败：rid 已落盘。服务端的任务可能仍在排队/生成中——
    # 不要断言扣了钱，只提示用户重跑即可找回。
    print("\n>> 注意：这次网络中断，任务本身可能已经在服务器上跑起来了"
          "（服务端幂等，重跑不会重复扣费）。\n"
          ">> 等网络恢复后重新运行刚才那条命令即可找回结果。", flush=True)
    die(f"连试 {NET_TRIES} 次都没连上服务器（{type(last).__name__}）。"
        f"检查网络后重新运行；积分不会多扣。")


def do_batch(manifest_path, progress_file=None, size="1024x1024", quality="medium",
             model=None, cli_refs=None, concurrency=3):
    """批量出图：逐项用子进程跑同一套单图命令，失败不中断整批。

    清单（UTF-8 JSON）：
      { "outDir": "out",
        "defaults": { "size": "1024x1024", "quality": "medium", "refs": ["a.jpg"] },
        "items": [ { "out": "01_x.png", "prompt": "…" },
                   { "out": "02_y.png", "prompt": "…", "size": "1024x1536" } ] }
    相对路径都相对**清单文件所在目录**解析。
    """
    mp = pathlib.Path(manifest_path)
    if not mp.is_file():
        die(f"清单文件不存在：{manifest_path}")
    mp = mp.resolve()
    mroot = mp.parent
    try:
        man = json.loads(mp.read_text(encoding="utf-8"))
    except Exception as e:
        die(f"清单解析失败（要 UTF-8 的 JSON）：{e}")
    items = man.get("items") or []
    if not items:
        die("清单里 items 是空的。")
    out_dir = mroot
    if man.get("outDir"):
        out_dir = pathlib.Path(man["outDir"])
        if not out_dir.is_absolute():
            out_dir = mroot / out_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    out_dir = out_dir.resolve()
    defaults = man.get("defaults") or {}
    prog = pathlib.Path(progress_file) if progress_file else (out_dir / "_batch_progress.txt")
    if not prog.is_absolute():
        prog = mroot / prog
    prog.parent.mkdir(parents=True, exist_ok=True)
    prog.write_text(f"start {time.strftime('%Y-%m-%d %H:%M:%S')} total={len(items)}\n",
                    encoding="utf-8")
    print(f">> 批量出图：共 {len(items)} 张 -> {out_dir}")
    print(f"   进度文件：{prog}")
    # 额度机械核算（2026-10-21）：总额与余量算好，别让 agent 自己估、也别闷声报「生成失败」
    per_img = int(globals().get("PER_IMAGE") or 0)
    if per_img > 0:
        need = per_img * len(items)
        bal_now = int(globals().get("ACCOUNT_BAL") or 0)
        room = bal_now // per_img
        print(f"   本次共 {len(items)} 张 × {per_img} 积分 = {need} 积分；当前余额 {bal_now} 积分（约可出 {room} 张）")
        if room < len(items):
            print(f"   ⚠️ 额度不够出完整批：只够 {room} 张。**先出优先级最高的几张**，并把充值链接给用户（不要硬跑）")
        elif room == len(items):
            print("   ⚠️ 额度刚好够这一批、**没有余量**：若中途有图要重做，得先充值")
    print("")
    okc = failc = 0
    env = dict(os.environ)
    env["CD_NO_UPDATE_CHECK"] = "1"      # 版本检查父进程已做过
    env["CD_FORCE_UTF8"] = "1"          # 子进程走管道，输出必须是 UTF-8
    conc = max(1, int(concurrency or 1))
    if conc > len(items):
        conc = max(1, len(items))
    print(f"   并发：{conc}（完成即交付，按完成顺序写入进度文件）")
    # ── 阶段一：解析清单，逐项准备子进程命令（不启动）──
    plan = []          # (ix, out_name, cmd, tmp_p, size, qual)
    for ix, it in enumerate(items, 1):
        out_name = str(it.get("out") or f"img_{ix}")
        ptxt = ""
        if it.get("promptFile"):
            pp = pathlib.Path(str(it["promptFile"]))
            if not pp.is_absolute():
                pp = mroot / pp
            if not pp.is_file():
                print(f"---- [{ix}/{len(items)}] {out_name} ----")
                print(f"[跳过] 提示词文件不存在：{pp}")
                failc += 1
                with prog.open("a", encoding="utf-8") as f:
                    f.write(f"FAIL {ix}/{len(items)} {out_name} (promptFile missing)\n")
                continue
            ptxt = pp.read_text(encoding="utf-8")
        elif it.get("prompt"):
            ptxt = str(it["prompt"])
        if not ptxt.strip():
            print(f"---- [{ix}/{len(items)}] {out_name} ----")
            print("[跳过] 这一项没有 prompt / promptFile。")
            failc += 1
            with prog.open("a", encoding="utf-8") as f:
                f.write(f"FAIL {ix}/{len(items)} {out_name} (no prompt)\n")
            continue
        it_size = str(it.get("size") or defaults.get("size") or size)
        it_qual = str(it.get("quality") or defaults.get("quality") or quality)
        it_model = str(it.get("model") or defaults.get("model") or model or "")
        ref_src = it.get("refs")
        if ref_src is None:
            ref_src = defaults.get("refs")
        if ref_src is None:
            ref_src = cli_refs or []
        ref_list = []
        for r in ref_src:
            rp = pathlib.Path(str(r))
            if not rp.is_absolute():
                rp = mroot / rp
            if rp.is_file():
                ref_list.append(str(rp.resolve()))
        tmp_p = pathlib.Path(tempfile.gettempdir()) / ("cd_b_" + uuid.uuid4().hex + ".txt")
        tmp_p.write_text(ptxt, encoding="utf-8")
        cmd = [sys.executable, str(pathlib.Path(__file__).resolve()),
               "--prompt-file", str(tmp_p), "--out", out_name,
               "--size", it_size, "--quality", it_qual]
        if it_model:
            cmd += ["--model", it_model]
        for r in ref_list:
            cmd += ["--ref", r]
        # 每张用独立 pending 文件：并发时共享 pending.json 会竞态（可能重放错 rid → 串图）
        pend = CRED_PATH.parent / ("pending_b%d.json" % ix)
        cmd += ["--pending-file", str(pend)]
        plan.append((ix, out_name, cmd, tmp_p, it_size, it_qual))
        print(f"---- [{ix}/{len(items)}] {out_name}  ({it_size}, {it_qual}) ----", flush=True)

    # ── 阶段二：并发执行，按完成顺序交付 ──
    def _run(entry):
        ix, out_name, cmd, tmp_p, it_size, it_qual = entry
        buf = []
        code = 1
        try:
            proc = subprocess.Popen(cmd, cwd=str(out_dir), env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            for raw_line in proc.stdout:
                buf.append(raw_line.decode("utf-8", "replace"))
            code = proc.wait()
        except Exception as e:
            buf.append("[子进程失败] %s\n" % e)
        try:
            tmp_p.unlink()
        except Exception:
            pass
        return (ix, out_name, code, "".join(buf), it_size, it_qual)

    from concurrent.futures import ThreadPoolExecutor, as_completed
    with ThreadPoolExecutor(max_workers=conc) as ex:
        futs = [ex.submit(_run, e) for e in plan]
        for fut in as_completed(futs):
            ix, out_name, code, out, it_size, it_qual = fut.result()
            if out:
                sys.stdout.write(out)
                sys.stdout.flush()
            out_path = out_dir / out_name
            stamp = time.strftime("%H:%M:%S")
            if code == 0 and out_path.is_file():
                okc += 1
                line = f"OK   {ix}/{len(items)} {out_name}  {stamp}  {out_path}"
            else:
                failc += 1
                line = f"FAIL {ix}/{len(items)} {out_name}  {stamp}  (exit={code})"
            with prog.open("a", encoding="utf-8") as f:
                f.write(line + "\n")
            print("", flush=True)
    with prog.open("a", encoding="utf-8") as f:
        f.write(f"DONE {time.strftime('%Y-%m-%d %H:%M:%S')} ok={okc} fail={failc}\n")
    print(f"[批量完成] 成功 {okc} / 共 {len(items)}，失败 {failc}")
    print(f"   进度文件：{prog}")
    sys.exit(1 if failc else 0)


def main():
    ap = argparse.ArgumentParser(
        description="AI 生图（线上版）：官方渠道，按积分计费",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--prompt"); ap.add_argument("--prompt-file")
    ap.add_argument("--concurrency", type=int, default=3,
                    help="批量出图并发数（默认 3；1 = 串行）")
    ap.add_argument("--pending-file", default="",
                    help="覆盖 pending.json 路径（并发批量时每张用独立文件，避免竞态）")
    ap.add_argument("--ref", action="append", default=[], help="参考图，可多次指定")
    ap.add_argument("--size", default="1024x1024")
    ap.add_argument("--quality", default="medium", choices=["low", "medium", "high"])
    ap.add_argument("--n", type=int, default=1)
    ap.add_argument("--model")
    ap.add_argument("--out"); ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--rekey", action="store_true",
                    help="手动换新 key（余额保留；不绑机后换电脑已无需此功能）")
    ap.add_argument("--send-code", metavar="EMAIL",
                    help="向指定邮箱发送注册验证码（供 AI 助手代为执行）")
    ap.add_argument("--complete", nargs=2, metavar=("EMAIL", "CODE"),
                    help="邮箱 + 6 位验证码完成注册，自动保存 key")
    ap.add_argument("--login", nargs=2, metavar=("EMAIL", "CODE"),
                    help="用邮箱+验证码取回已注册账号的 key")
    ap.add_argument("--save-key", metavar="KEY",
                    help="导入已有 key（换电脑场景）")
    ap.add_argument("--check", action="store_true",
                    help="只登录查余额，不出图")
    ap.add_argument("--pay-link", action="store_true",
                    help="取一次性充值链接（30 分钟有效，URL 不含 key 明文；发链接给用户前跑它）")
    ap.add_argument("--batch", metavar="MANIFEST",
                    help="批量出图（UTF-8 JSON 清单，含 items 数组）")
    ap.add_argument("--progress-file", metavar="PATH",
                    help="批量出图的进度文件（默认 <输出目录>/_batch_progress.txt）")
    ap.add_argument("--version", action="store_true",
                    help="查看本地版本与最新版本")
    ap.add_argument("--update", action="store_true",
                    help="更新到最新版本（更新后请重启 opencode）")
    args = ap.parse_args()

    # ── 非交互子命令（供 AI 助手驱动；交互版 register_flow 保留作控制台兜底）──
    if args.send_code:
        email = args.send_code.strip()
        if not re.match(r"^[^\s@]+@[^\s@]+\.[^\s@]+$", email):
            die(f"邮箱格式不对：{email}")
        r, neterr = http_json(WORKER + "/reg/send", {"email": email}, timeout=30)
        if r is None:
            die(f"连不上服务器（{neterr}）。检查网络后重新运行本命令。")
        if r.get("ok") is not True:
            msg = str(r.get("msg", r))
            if "已注册" in msg:
                # 已注册 → 自动改发登录验证码（原来只能让 agent 自己用 curl 打网页接口）
                r2, net2 = http_json(WORKER + "/account/sendcode", {"email": email}, timeout=30)
                if r2 is not None and r2.get("ok") is True:
                    print(f"[OK] 这个邮箱已经注册过了 → 已改发**登录验证码**到 {email}"
                          f"（可能要等 1-2 分钟，30 分钟内有效）。")
                    print("     收到 6 位验证码发给我，我会用它登录并把你原来的 key 取回来"
                          "（不用重新注册，余额也还在）。")
                    return
            die(f"验证码发送失败：{msg}")
        print(f"[OK] 验证码已发到 {email}（可能要等 1-2 分钟，30 分钟内有效）。")
        print("     收到后把 6 位验证码发给我即可。")
        return
    if args.login:
        email, code = args.login[0].strip(), args.login[1].strip()
        if not re.match(r"^[^\s@]+@[^\s@]+\.[^\s@]+$", email):
            die(f"邮箱格式不对：{email}")
        if not re.fullmatch(r"\d{6}", code):
            die(f"验证码应为 6 位数字：{code}")
        r, neterr = http_json(WORKER + "/account/login",
                              {"email": email, "code": code}, timeout=30)
        if r is None:
            die(f"连不上服务器（{neterr}）。检查网络后重新运行本命令。")
        if r.get("ok") is not True:
            die(f"登录失败：{r.get('msg', r)}")
        token = str(r.get("token", ""))
        if not token:
            die("登录失败：服务器没有返回登录凭证，请重新运行本命令。")
        acc, neterr = http_get_json(WORKER + "/account", timeout=30,
                                    headers={"x-account-token": token})
        if acc is None:
            die(f"取账户信息失败（{neterr}）。")
        if acc.get("ok") is not True:
            die(f"取账户信息失败：{acc.get('msg', acc)}")
        keys = acc.get("keys") or []
        if not keys:
            die("这个邮箱下还没有 key（可能只注册过没建 key）。\n"
                "       换个邮箱重新注册，或在账户页新建一把 key。")
        # 逐把核验（2026-10-27 买家实测）：原来直接拿第 1 把就宣布「已生效」，
        # 而第 1 把可能是已删除 / 已过期的死 key，买家紧接着出图被拒。
        print(f"\n已登录 {email}，账号下共 {len(keys)} 把 key，正在逐把核验…", flush=True)
        chosen = ""
        rows = []
        unknown = 0
        for i, k in enumerate(keys, 1):
            kk = str((k or {}).get("key", ""))
            if not kk.startswith("sk-"):
                continue
            short = kk if len(kk) <= 18 else kk[:10] + "…" + kk[-4:]
            pr, _ = login_probe(kk)
            if pr is None:
                unknown += 1
                state = "读取超时（服务器这会儿没响应）"
            elif pr.get("ok") is True:
                fq = int(pr.get("free") or 0)
                state = (f"可用（余额 {int(pr.get('credits') or 0)} 积分，"
                         f"今日免费额度{'还剩 %d 积分' % fq if fq else '已用完'}）")
                chosen = chosen or kk
            elif pr.get("reason") == "nolimit":
                state = (f"可用但余额为 0（余额 {int(pr.get('credits') or 0)} 积分），"
                         f"充值后即可出图")
                chosen = chosen or kk
            elif pr.get("reason") == "expired":
                state = "已过期（到账户页点「改期」可续上）"
            elif pr.get("reason") == "temp":
                unknown += 1
                state = "服务器暂时读不到（不是 key 坏了）"
            else:
                state = "服务器上已经没有这把 key"
            rows.append(f"     {i}) {short}   {state}")
        for row in rows:
            print(row, flush=True)

        if not chosen:
            print("")
            if rows and unknown == len(rows):
                print("[提示] 服务器暂时读不到这些 key 的记录 —— 这不代表 key 坏了，也不是你操作错了。\n"
                      "       等 1-2 分钟，重新运行同一条命令即可。")
            elif unknown:
                print("[提示] 有几把 key 暂时读不到（服务器那边的问题，不是 key 坏了），先等 1-2 分钟重跑一次；\n"
                      "       重跑后仍全部不可用，再跟卖家核对 key。")
            else:
                print("[提示] 这个邮箱下的 key 都不在可出图状态（已过期或已被删除）。\n"
                      "       到账户页新建一把 key：https://verify.evomindd.top/login ；或跟卖家核对。")
            sys.exit(1)

        save_cred(chosen, email)
        print(f"\n[OK] 已用邮箱 + 验证码登录，并取回你原来的 key（已自动保存在本机）：\n\n"
              f"     {chosen}\n\n"
              f"     账号余额 {acc.get('balance', '?')} 积分。这把 key 已核验可用，直接出图即可。", flush=True)
        if len(keys) > 1:
            print(f"     这个邮箱下共 {len(keys)} 把 key，当前用的是第一把可用的；"
                  f"要换另一把可以跟助手说「导入这个 key」。")
        show_guide()
        return
    if args.complete:
        email, code = args.complete[0].strip(), args.complete[1].strip()
        if not re.match(r"^[^\s@]+@[^\s@]+\.[^\s@]+$", email):
            die(f"邮箱格式不对：{email}")
        if not re.fullmatch(r"\d{6}", code):
            die(f"验证码应为 6 位数字：{code}")
        r, neterr = http_json(WORKER + "/reg/complete",
                              {"email": email, "code": code}, timeout=30)
        if r is None:
            die(f"连不上服务器（{neterr}）。检查网络后重新运行本命令。")
        if r.get("ok") is not True or not str(r.get("key", "")).startswith("sk-"):
            die(f"注册失败：{r.get('msg', r)}")
        save_cred(r["key"], email)
        print(f"\n[OK] 注册成功！key 已自动保存在本机，以后不用再管。\n"
              f"     请把这串 key 备份到记事本里（换电脑时要用）：\n\n"
              f"     {r['key']}\n", flush=True)
        login_gate(r["key"])
        show_guide()
        return
    if args.save_key:
        key = args.save_key.strip()
        if not key.startswith("sk-"):
            die(f"key 格式不对（应以 sk- 开头）：{key}")
        save_cred(key)
        login_gate(key)
        show_guide()
        return
    if args.check:
        c = load_cred()
        if c is None:
            print("[提示] 本机还没有 key，请先完成注册：")
            print("       把你的邮箱发给我，我帮你发验证码；"
                  "或自己运行：python gen.py --send-code 你的邮箱")
            return
        login_gate(c["key"])
        return
    if args.pay_link:
        # 3.34（云鼎安全整改①）：充值链接改服务端一次性 claim 票据，URL 不再带 key 明文。
        c = load_cred()
        if c is None:
            print("[提示] 本机还没有 key，先完成注册（把你的邮箱发给我即可），注册完再跑本命令取充值链接。")
            return
        r, neterr = http_json(WORKER + "/pay/claim", {"key": c["key"]}, timeout=30)
        if r is None:
            die(f"连不上服务器（{neterr}）。检查网络后重新运行本命令。")
        if r.get("ok") is not True:
            die(f"取充值链接失败：{r.get('msg', r)}\n"
                "       可到账户页点任意一把 key 的「去充值」：https://verify.evomindd.top/login")
        print("[充值链接] 一次性、30 分钟内有效（URL 不含 key 明文）：")
        print(r.get("url", ""))
        print("把上面这行链接发给用户（独占一行），让他打开填金额付款；付完款回来查余额。")
        return

    if args.version:
        lv = local_version()
        print("本地版本：" + (f"v{lv}" if lv else "未知"))
        rv = remote_version(5)
        if not rv or rv.get("ok") is not True:
            print("最新版本：查询失败（网络或服务端不可达；不影响出图）")
            return
        latest = str(rv.get("latest") or "")
        print(f"最新版本：v{latest}")
        if lv:
            if compare_ver(latest, lv) > 0:
                print("")
                print("有新版本可用。更新命令：scripts\\gen.cmd update")
            else:
                print("已是最新。")
        return

    if args.update:
        do_update()
        return
    if args.pending_file:
        global PENDING_PATH
        PENDING_PATH = pathlib.Path(args.pending_file)
        PENDING_PATH.parent.mkdir(parents=True, exist_ok=True)
    if args.batch:
        do_batch(args.batch, progress_file=args.progress_file, size=args.size,
                 concurrency=args.concurrency,
                 quality=args.quality, model=args.model, cli_refs=args.ref)

    # 出图前查一次版本：超时 2 秒、失败静默；同版本 24h 只提示一次
    show_update_hint()

    if not (1 <= args.n <= 8):
        die("一次最多出 8 张（--n 1~8）。")

    # 账号门：有凭证静默登录；没有先注册。--rekey 单独走换 key 流程。
    cred = load_cred()
    if args.rekey:
        if not cred:
            die("本机还没有 key，不需要换。直接运行出图命令即可完成注册。")
        cred = {"key": rekey_flow(cred["key"])}
    if cred is None:
        key = register_flow()
        cred = {"key": key}
    login_gate(cred["key"])

    prompt = read_prompt(args).strip()
    if not prompt:
        die("提示词是空的。")
    prompt = anchor_size(prompt, args.size)
    # 4000 字符上限来自服务端的硬约束，超了会被直接拒。
    if len(prompt) > 4000:
        die(f"提示词 {len(prompt)} 字符，超过服务端 4000 字符上限，会被直接拒。\n"
            f"       怎么减：把必须原样出现的中文文案和构图写在前段，\n"
            f"       砍掉光影氛围、材质质感、背景细节这类装饰性描述。")

    # 模型取值顺序：显式 --model → 环境变量 IMAGE_MODEL → **服务端 /auth/login 下发的 defaultModel**
    # （= 运营在 KV config.mainModel 里配的当前模型，改配置后买家下一次出图即生效）→ 静态兜底
    model = args.model or os.environ.get("IMAGE_MODEL") or \
        globals().get("DEFAULT_MODEL_NAME") or DEFAULT_MODEL
    refs = check_refs(args.ref)
    if len(refs) > 3:
        print(f"[提醒] 传了 {len(refs)} 张参考图。多图上限各线路不同，"
              f"超限会直接报参数错误。\n       如果报错，先减到 3 张以内再试。\n")

    print(f">> 模型  {model}   尺寸 {args.size}   质量 {args.quality}   张数 {args.n}", flush=True)
    if refs:
        print(f">> 参考图 {len(refs)} 张：{', '.join(p.name for p in refs)}", flush=True)
    print(">> 生成中（高清档可能需要 1–2 分钟，请耐心等待）…\n", flush=True)

    t0 = time.time()
    if refs:
        # 同名 "image" 字段重复出现 = 多图（见 build_multipart 说明）
        files = [
            ("image", p, p.name,
             "image/png" if p.suffix.lower() == ".png" else "image/jpeg")
            for p in refs
        ]
        body, ctype = build_multipart(
            {"model": model, "prompt": prompt, "size": args.size,
             "quality": args.quality, "n": args.n}, files)
    else:
        body = json.dumps({"model": model, "prompt": prompt, "size": args.size,
                           "quality": args.quality, "n": args.n}).encode("utf-8")
        ctype = "application/json"

    result = do_gen(cred, body, ctype, args.n, args.timeout)

    items = result.get("data") or []
    # 备援通道提示（2026-10-20）：主通道繁忙时会自动切到备援通道，如实告知
    if result.get("channel") and str(result.get("channel")) == "backup":
        _note = str(result.get("note") or "本次由备援通道出图")
        print(f"[说明] {_note}", flush=True)
    if not items:
        die(f"服务端没返回图片数据。原始返回：\n{json.dumps(result, ensure_ascii=False)[:600]}")

    # 用户已经写了 .png/.jpg 时不要重复追加，否则 --out a.png 会存成 a.png.png
    stem = str(args.out or f"img_{time.strftime('%Y%m%d_%H%M%S')}")
    if pathlib.Path(stem).suffix.lower() in {".png", ".jpg", ".jpeg", ".webp"}:
        stem = str(pathlib.Path(stem).with_suffix(""))
    written = []
    for i, item in enumerate(items):
        outp = pathlib.Path(f"{stem}.png" if i == 0 else f"{stem}_{i+1}.png")
        if item.get("b64_json"):
            size = decode_and_save(item["b64_json"], outp)
        elif item.get("url"):
            size = fetch_url(item["url"], outp)
        else:
            continue
        written.append((outp.name, size))

    # 服务端可能改写 prompt，提示词原样没生效时要能看出来（响应会带 revised_prompt 字段）
    if items[0].get("revised_prompt"):
        rp = items[0]["revised_prompt"]
        shown = rp if len(rp) <= 300 else rp[:300] + " ..."
        print(f"\n[注意] 服务端把提示词改写成了：\n  {shown}")
        print("       如果改写后中文文案变了，把关键文字在提示词里逐字写死再跑。")
        print("       另：出图后请**亲眼看图确认中文文字没写错**——出图线路可能")
        print("       静默降级模型，中文会变乱码。")

    dt = time.time() - t0
    free = int(result.get("free") or 0)
    note = f" + 今日免费 {free}" if free else ""
    print(f"\n[完成] 用时 {dt:.1f}s   剩余 {result.get('credits', '?')} 积分{note}")
    for name, size in written:
        print(f"  {name}  ({size//1024} KB)")
    if not written:
        die("没有解析到图片，请检查服务端返回格式。")


if __name__ == "__main__":
    main()
