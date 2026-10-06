#!/opt/server-monitor/venv/bin/python
# -*- coding: utf-8 -*-
"""ToolHub 手机专用网关（端口 7072）

独立于总控台(7070)进程运行，总控台调试重启不影响手机连接。

功能：
  1. /api/manifest      下发插件清单（OTA 核心）：读 plugins/*.json，热加载，
                        丢一个 JSON 进目录，手机端 30 秒内自动出现新插件。
  2. /api/overview      聚合总览：子应用健康 + 外部服务状态。
  3. /api/services/...  外部服务启停（转发总控台）。
  4. /proxy/<前缀>/...  全量反代到总控台对应子应用（原生页面取数 + WebView 插件共用）。

鉴权：header X-ToolHub-Token；token 存于 mobile/token.txt（首次自动生成），
      写成 open 则关闭鉴权（纯内网图省事时用）。

systemd: /etc/systemd/system/toolhub-mobile.service
"""

import hashlib
import json
import os
import secrets
import threading
import time

import requests
from flask import Flask, Response, jsonify, redirect, request
from werkzeug.serving import run_simple

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PLUGINS_DIR = os.path.join(BASE_DIR, "plugins")
TOKEN_FILE = os.path.join(BASE_DIR, "token.txt")

HUB = "http://127.0.0.1:%d" % int(os.environ.get("MOBILE_HUB_PORT", "7070"))
MOBILE_PORT = int(os.environ.get("MOBILE_PORT", "7072"))
HTTP_TIMEOUT = int(os.environ.get("MOBILE_TIMEOUT", "60"))

_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length",
        "content-encoding"}

PROXY_METHODS = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]


# ------------------------------------------------------------------ token 鉴权
def _load_token():
    try:
        with open(TOKEN_FILE) as f:
            tok = f.read().strip()
        if tok:
            return tok
    except Exception:
        pass
    tok = secrets.token_hex(8)
    try:
        with open(TOKEN_FILE, "w") as f:
            f.write(tok)
        os.chmod(TOKEN_FILE, 0o600)
    except Exception:
        pass
    return tok


TOKEN = _load_token()
AUTH_ON = TOKEN.lower() != "open"


# ------------------------------------------------------------------ 插件清单
_manifest_cache = {"sig": None, "data": None}


def _dir_sig():
    """plugins 目录签名：任何文件增删/内容变化都会改变签名。"""
    sig = []
    try:
        for name in sorted(os.listdir(PLUGINS_DIR)):
            if not name.endswith(".json"):
                continue
            p = os.path.join(PLUGINS_DIR, name)
            try:
                st = os.stat(p)
                sig.append("%s:%d:%d" % (name, st.st_mtime_ns, st.st_size))
            except OSError:
                pass
    except OSError:
        pass
    return "|".join(sig)


def _build_manifest():
    plugins = []
    for name in sorted(os.listdir(PLUGINS_DIR)):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(PLUGINS_DIR, name), encoding="utf-8") as f:
                d = json.load(f)
            if isinstance(d, dict) and d.get("id"):
                d.setdefault("type", "web")
                plugins.append(d)
            else:
                print("[mobile] 跳过无效插件文件: %s" % name)
        except Exception as e:
            print("[mobile] 读取插件失败 %s: %s" % (name, e))
    sig = _dir_sig()
    version = int(hashlib.md5((sig or "empty").encode()).hexdigest()[:8], 16)
    return {"version": version, "name": "服务器总控台", "plugins": plugins}


def _manifest():
    sig = _dir_sig()
    if _manifest_cache["sig"] != sig or _manifest_cache["data"] is None:
        _manifest_cache["sig"] = sig
        _manifest_cache["data"] = _build_manifest()
    return _manifest_cache["data"]


# ------------------------------------------------------------------ Flask
app = Flask(__name__)


@app.after_request
def _cors(resp):
    resp.headers["Access-Control-Allow-Origin"] = "*"
    resp.headers["Access-Control-Allow-Headers"] = "Content-Type, X-ToolHub-Token"
    resp.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, PATCH, OPTIONS"
    return resp


def _authed():
    if not AUTH_ON:
        return True
    if request.headers.get("X-ToolHub-Token", "") == TOKEN:
        return True
    # 允许查询串带 token：AsyncImage / Safari 打开等无法自定义 header 的场景
    return request.args.get("token", "") == TOKEN


def _denied():
    return jsonify(ok=False, msg="token 无效，请在 App 设置里核对"), 401


@app.route("/")
def index():
    return jsonify(name="ToolHub Mobile Gateway", port=MOBILE_PORT,
                   hub=HUB, auth=AUTH_ON,
                   endpoints=["/api/ping", "/api/manifest", "/api/manifest/version",
                              "/api/overview", "/api/services/<sid>/<action>",
                              "/proxy/<prefix>/<path>"])


@app.route("/api/ping")
def api_ping():
    return jsonify(ok=True, name="服务器总控台", version=_manifest()["version"],
                   auth=AUTH_ON)


@app.route("/api/manifest")
def api_manifest():
    if not _authed():
        return _denied()
    return jsonify(_manifest())


@app.route("/api/manifest/version")
def api_manifest_version():
    return jsonify(version=_manifest()["version"])


def _hub_json(path, timeout=8):
    try:
        r = requests.get(HUB + path, timeout=timeout)
        if r.status_code == 200:
            return r.json()
    except Exception:
        pass
    return {}


@app.route("/api/overview")
def api_overview():
    if not _authed():
        return _denied()
    return jsonify(health=_hub_json("/api/health"),
                   services=_hub_json("/api/ext/state"))


@app.route("/api/services/<sid>/<action>", methods=["POST"])
def api_service_action(sid, action):
    if not _authed():
        return _denied()
    if action not in ("start", "stop", "restart"):
        return jsonify(ok=False, msg="不支持的操作"), 400
    try:
        r = requests.post("%s/api/ext/%s/%s" % (HUB, sid, action), timeout=300)
        return app.response_class(r.content, status=r.status_code,
                                  mimetype="application/json")
    except Exception as e:
        return jsonify(ok=False, msg="总控台不可达: %s" % e), 502


@app.route("/proxy/<prefix>", defaults={"rest": ""}, strict_slashes=False,
           methods=PROXY_METHODS)
@app.route("/proxy/<prefix>/<path:rest>", strict_slashes=False,
           methods=PROXY_METHODS)
def proxy(prefix, rest):
    if not _authed():
        return _denied()
    url = "%s/%s/%s" % (HUB, prefix.strip("/"), rest)
    if request.query_string:
        url += "?" + request.query_string.decode("latin-1")
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in _HOP}
    try:
        r = requests.request(request.method, url, headers=headers,
                             data=request.get_data(), timeout=HTTP_TIMEOUT,
                             allow_redirects=False)
    except requests.RequestException as e:
        return jsonify(ok=False, msg="总控台不可达: %s" % e), 502
    resp = app.response_class(r.content, status=r.status_code)
    for k, v in r.headers.items():
        if k.lower() not in _HOP:
            resp.headers[k] = v
    return resp


# ------------------------------------------------------------------ 原生页聚合端点
# 子应用里"整段拿不到 JSON"或"响应是二进制/流"的接口，在这里桥接成手机友好的
# JSON。SSE 流在网关侧聚合为最终文本；文件保存在本地 scans/ 后返回图片 URL。


def _read_sse(resp):
    """解析 text/event-stream，逐条 yield 事件 dict（data: 行 JSON）。"""
    for line in resp.iter_lines(decode_unicode=True):
        if line and line.startswith("data: "):
            try:
                yield json.loads(line[6:])
            except Exception:
                pass


def _fwd_multipart(target, timeout=600):
    """把当前请求原样（multipart 体 + 头）转发到总控台对应地址。"""
    headers = {k: v for k, v in request.headers.items() if k.lower() not in _HOP}
    return requests.post(target, data=request.get_data(), headers=headers, timeout=timeout)


# ---- AI 服务器助手（/ai SSE → 最终文本） ----

_ai_cid = {"id": None}


def _ai_ensure_cid():
    """取最近会话，没有则建一个，保证手机端始终在同一会话里延续上下文。"""
    if _ai_cid["id"]:
        return _ai_cid["id"]
    try:
        r = requests.get(HUB + "/ai/api/conversations", timeout=8)
        convs = (r.json() or {}).get("conversations") or [] if r.status_code == 200 else []
        if convs:
            _ai_cid["id"] = convs[0].get("id")
    except Exception:
        pass
    if not _ai_cid["id"]:
        try:
            r = requests.post(HUB + "/ai/api/conversations",
                              json={"title": "手机快捷对话"}, timeout=8)
            if r.status_code in (200, 201):
                _ai_cid["id"] = (r.json().get("conversation") or {}).get("id")
        except Exception:
            pass
    return _ai_cid["id"]


@app.route("/api/ai-chat", methods=["POST"])
def api_ai_chat():
    if not _authed():
        return _denied()
    data = request.get_json(silent=True) or {}
    text = (data.get("content") or data.get("text") or "").strip()
    cid = _ai_ensure_cid()
    if not cid or not text:
        return jsonify(ok=False, reply="⚠️ 无法建立会话，请稍后重试"), 502
    reply, status = "", ""
    try:
        r = requests.post(HUB + "/ai/api/chat",
                          json={"conversation_id": cid, "content": text},
                          stream=True, timeout=(8, 300))
        for ev in _read_sse(r):
            t = ev.get("type")
            if t == "message":
                reply = ev.get("content") or reply
            elif t == "status":
                status = ev.get("msg") or status
            elif t == "error":
                reply = "⚠️ " + (ev.get("msg") or "执行出错")
    except Exception as e:
        return jsonify(ok=False, reply="⚠️ %s" % e), 502
    return jsonify(ok=True, reply=reply or status or "（无回复）")


@app.route("/api/ai-history")
def api_ai_history():
    if not _authed():
        return _denied()
    cid = _ai_ensure_cid()
    if not cid:
        return jsonify(history=[])
    try:
        r = requests.get(HUB + "/ai/api/conversations/" + cid, timeout=8)
        msgs = (r.json() or {}).get("api_msgs") or []
        return jsonify(history=[{"role": m.get("role"), "content": m.get("content")}
                                for m in msgs if m.get("content")])
    except Exception:
        return jsonify(history=[])


# ---- 相册找图 AI（/find SSE → 文本 + 照片墙） ----

_find_cards = {"items": []}


@app.route("/api/find-chat", methods=["POST"])
def api_find_chat():
    if not _authed():
        return _denied()
    text = ((request.get_json(silent=True) or {}).get("text") or "").strip()
    if not text:
        return jsonify(ok=False, reply="空消息"), 400
    reply, cards = "", []
    try:
        r = requests.post(HUB + "/find/api/chat", json={"text": text},
                          stream=True, timeout=(8, 300))
        for ev in _read_sse(r):
            t = ev.get("type")
            if t == "delta":
                reply += ev.get("text") or ""
            elif t == "card" and ev.get("items"):
                cards = ev["items"]
            elif t == "error":
                reply += "\n⚠️ " + (ev.get("msg") or "执行出错")
    except Exception as e:
        return jsonify(ok=False, reply="⚠️ %s" % e), 502
    if cards:
        _find_cards["items"] = [{"url": "/proxy/find/view/%s?token=%s" % (i.get("id"), TOKEN),
                                 "title": "%s %s" % (i.get("date_fmt") or "", i.get("cam") or "")}
                                for i in cards[:60]]
    return jsonify(ok=True, reply=reply or "（无回复）")


@app.route("/api/find-cards")
def api_find_cards():
    if not _authed():
        return _denied()
    return jsonify(items=_find_cards["items"])


# ---- 格式转换器（上传记录 fid → 进度/下载/删除桥接） ----

_convert = {"fid": None, "name": None}


@app.route("/api/convert-upload", methods=["POST"])
def api_convert_upload():
    if not _authed():
        return _denied()
    try:
        r = _fwd_multipart(HUB + "/convert/api/upload")
    except Exception as e:
        return jsonify(ok=False, msg=str(e)), 502
    try:
        d = r.json()
        if isinstance(d, dict) and d.get("id"):
            _convert["fid"] = str(d["id"])
            _convert["name"] = d.get("name")
    except Exception:
        pass
    return app.response_class(r.content, status=r.status_code, mimetype="application/json")


@app.route("/api/convert-status")
def api_convert_status():
    if not _authed():
        return _denied()
    fid = _convert["fid"]
    if not fid:
        return jsonify(state="idle", name=None, msg="尚未上传文件")
    try:
        r = requests.get(HUB + "/convert/api/progress/" + fid, timeout=8)
        if r.status_code == 404:
            return jsonify(state="done", pct=100, name=_convert["name"],
                           download="/api/convert-download")
        d = r.json()
        d["download"] = "/api/convert-download"
        return jsonify(d)
    except Exception as e:
        return jsonify(state="error", msg=str(e))


@app.route("/api/convert-download")
def api_convert_download():
    if not _authed():
        return _denied()
    fid = _convert["fid"]
    if not fid:
        return jsonify(ok=False, msg="还没有转换完成的文件"), 404
    name = _convert["name"] or ("file-" + fid)
    return redirect("/proxy/convert/api/download/%s/%s?token=%s" % (fid, name, TOKEN))


@app.route("/api/convert-delete", methods=["POST"])
def api_convert_delete():
    if not _authed():
        return _denied()
    fid = str((request.get_json(silent=True) or {}).get("id") or "")
    if not fid:
        return jsonify(ok=False, msg="缺少 id"), 400
    try:
        r = requests.post(HUB + "/convert/api/delete/" + fid, timeout=30)
        return app.response_class(r.content, status=r.status_code, mimetype="application/json")
    except Exception as e:
        return jsonify(ok=False, msg=str(e)), 502


# ---- 图像生成工坊（jobs → 已完成材质画廊） ----


@app.route("/api/mctex-gallery")
def api_mctex_gallery():
    if not _authed():
        return _denied()
    try:
        r = requests.get(HUB + "/mctex/api/jobs", timeout=8)
        jobs = (r.json() or {}).get("jobs") or []
    except Exception:
        jobs = []
    items = [{"name": j.get("name"), "title": j.get("name"),
              "url": "/proxy/mctex/api/img/out/%s.png?token=%s" % (j.get("name"), TOKEN)}
             for j in jobs if j.get("status") == "done" and j.get("name")]
    return jsonify(items=items)


# ---- 全能扫描王（二进制 JPEG + X-Scan-Meta 头 → JSON + 本地图片服务） ----

_SCANS_DIR = os.path.join(BASE_DIR, "scans")


@app.route("/api/scan-upload", methods=["POST"])
def api_scan_upload():
    if not _authed():
        return _denied()
    try:
        r = _fwd_multipart(HUB + "/scanner/api/scan", timeout=120)
    except Exception as e:
        return jsonify(ok=False, msg=str(e)), 502
    meta = {}
    try:
        meta = json.loads(r.headers.get("X-Scan-Meta", "{}"))
    except Exception:
        pass
    if r.status_code != 200 or not r.content:
        return jsonify(ok=False, msg="扫描失败 HTTP %s" % r.status_code), 502
    try:
        os.makedirs(_SCANS_DIR, exist_ok=True)
        fn = "scan-%d.jpg" % int(time.time())
        with open(os.path.join(_SCANS_DIR, fn), "wb") as f:
            f.write(r.content)
    except OSError as e:
        return jsonify(ok=False, msg="保存失败: %s" % e), 502
    return jsonify(ok=True, file=fn, url="/files/%s?token=%s" % (fn, TOKEN),
                   width=meta.get("width"), height=meta.get("height"),
                   confidence=meta.get("confidence"), mode=meta.get("mode"))


@app.route("/api/scans")
def api_scans():
    if not _authed():
        return _denied()
    try:
        names = sorted(os.listdir(_SCANS_DIR), reverse=True)[:60]
    except OSError:
        names = []
    return jsonify(items=[{"title": n.replace("scan-", "").replace(".jpg", ""),
                           "url": "/files/%s?token=%s" % (n, TOKEN)} for n in names])


@app.route("/files/<name>")
def files(name):
    if not _authed():
        return _denied()
    p = os.path.join(_SCANS_DIR, os.path.basename(name))
    if not os.path.isfile(p):
        return jsonify(ok=False, msg="文件不存在"), 404
    with open(p, "rb") as f:
        data = f.read()
    return app.response_class(data, mimetype="image/jpeg")


@app.route("/jump/<path:rest>")
def jump(rest):
    """带鉴权的 302 跳转：Safari 打开总控台原页面（noVNC 等需要 WebSocket 的场景）。"""
    if not _authed():
        return _denied()
    return redirect("%s/%s" % (HUB, rest))


# ------------------------------------------------------------------ 动作垫片
# 行级操作只能注入一个动态字段，需要补静态字段的接口在这里中转。


def _forward(path, payload):
    try:
        r = requests.post(HUB + path, json=payload, timeout=HTTP_TIMEOUT)
        return app.response_class(r.content, status=r.status_code,
                                  mimetype="application/json")
    except requests.RequestException as e:
        return jsonify(ok=False, msg="总控台不可达: %s" % e), 502


@app.route("/shim/monitor/docker/<action>", methods=["POST"])
def shim_docker(action):
    """{name} → {name, action}，容器 启动/停止/重启。"""
    if not _authed():
        return _denied()
    if action not in ("start", "stop", "restart"):
        return jsonify(ok=False, msg="不支持的操作"), 400
    d = request.get_json(silent=True) or {}
    return _forward("/monitor/api/docker/action",
                    {"name": d.get("name"), "action": action})


@app.route("/shim/memclean/kill", methods=["POST"])
def shim_kill():
    """{pid} → {pid, sig:15}，友好结束进程。"""
    if not _authed():
        return _denied()
    d = request.get_json(silent=True) or {}
    return _forward("/memclean/api/kill", {"pid": d.get("pid"), "sig": 15})


# ------------------------------------------------------------------ 新插件自动发现
# 轮询总控台 /api/cards（TOOLS 卡片清单），发现新子应用即自动注册为
# auto-<id>.json（WebView 形态）。手工/原生插件优先：同 id 已存在则跳过。
# 效果：以后往总控台加任何新工具，手机端 30 秒内自动出现，零操作。


def _known_ids():
    ids = set()
    try:
        for name in os.listdir(PLUGINS_DIR):
            if name.endswith(".json"):
                try:
                    with open(os.path.join(PLUGINS_DIR, name), encoding="utf-8") as f:
                        d = json.load(f)
                    if isinstance(d, dict) and d.get("id"):
                        ids.add(d["id"])
                except Exception:
                    pass
    except OSError:
        pass
    return ids


def _cards_sync_loop():
    while True:
        try:
            r = requests.get(HUB + "/api/cards", timeout=8)
            if r.status_code == 200:
                known = _known_ids()
                for t in (r.json().get("tools") or []):
                    tid = t.get("id")
                    if not tid or tid in known:
                        continue
                    prefix = t.get("prefix") or ("/" + tid)
                    entry = {
                        "id": tid,
                        "name": t.get("name") or tid,
                        "tag": t.get("tag") or "工具",
                        "icon": t.get("icon") or "🧩",
                        "color": t.get("color") or "#D97757",
                        "desc": t.get("desc") or "",
                        "type": "web",
                        "auto": True,
                        "url": "/proxy%s/" % prefix,
                    }
                    path = os.path.join(PLUGINS_DIR, "auto-%s.json" % tid)
                    try:
                        with open(path, "w", encoding="utf-8") as f:
                            json.dump(entry, f, ensure_ascii=False, indent=2)
                        print("[mobile] 自动注册新插件: %s -> %s" % (tid, prefix))
                        known.add(tid)
                    except OSError as e:
                        print("[mobile] 写入自动插件失败 %s: %s" % (tid, e))
        except Exception:
            pass  # 总控台未升级（无 /api/cards）或暂不可达：静默跳过
        time.sleep(30)


def main():
    print("=" * 56)
    print("ToolHub 手机网关启动")
    print("  监听   : http://0.0.0.0:%d" % MOBILE_PORT)
    print("  总控台 : %s" % HUB)
    print("  鉴权   : %s" % ("开启" if AUTH_ON else "关闭(open)"))
    if AUTH_ON:
        print("  token  : %s  (mobile/token.txt)" % TOKEN)
    print("  插件   : %d 个 (plugins/*.json 热加载)" % len(_manifest()["plugins"]))
    print("=" * 56)
    threading.Thread(target=_cards_sync_loop, daemon=True,
                     name="cards-sync").start()
    run_simple("0.0.0.0", MOBILE_PORT, app, threaded=True, use_reloader=False)


if __name__ == "__main__":
    main()
