#!/opt/server-monitor/venv/bin/python
# -*- coding: utf-8 -*-
"""
服务器工具总控台 · 单进程单端口聚合版 (7070)
=============================================
把多个原本各自占端口的工具聚合到【一个进程、一个端口】：
  首页标签页切换；各工具挂载路径：
    /monitor  服务器监控面板 (原 5000)
    /ai       AI 服务器助手    (原 5001)
    /find     相册找图 AI      (原 5002)
    /scan     端口巡检          (原 5050)
    /scanner  全能扫描王        (文档扫描→PDF)
  wol(7000)、dsh(3080) 为独立服务，首页以外部链接卡片打开

实现要点：
  1) 各工具源码用通用模块名(config/core/store)，必须"隔离加载"避免串台
  2) Werkzeug DispatcherMiddleware 把各 Flask app 挂到不同前缀
  3) 对每个子应用做 after_request 改写：前端引用的根路径(/static、/api 等)
     自动加上前缀，保证内嵌后仍能取到正确资源与接口
"""
import hashlib
import importlib.util
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time

from flask import Flask, jsonify, redirect, render_template, request, send_from_directory
from werkzeug.middleware.dispatcher import DispatcherMiddleware
from werkzeug.serving import run_simple

HUB_PORT = int(os.environ.get("HUB_PORT", "7070"))
LAN_IP = os.environ.get("HUB_LAN_IP", "192.168.1.15")

# 前端展示信息
# ---------------------------------------------------------------------------
# 外部服务（独立进程 / 容器，非本进程内挂载）
#   ctl 描述"怎么启停"：
#     {"kind":"systemd",      "units":[...]}                系统级 systemd
#     {"kind":"user_systemd", "user":"yxp","uid":1000,
#                             "units":[...]}                yxp 用户级 systemd
#     {"kind":"docker",       "containers":[...]}           docker 容器
#     {"kind":"btpython",     "script":..., "pidfile":...,
#                             "match":...}                  宝塔 Python 项目
#   start 按 units/containers 顺序启动，stop 逆序停止；无 ctl 的只显示状态。
# ---------------------------------------------------------------------------
external_tools = [
    dict(id="dsh", external="http://%s:3080/" % LAN_IP, name="DeepSeek Harness", tag="AI",
         desc="DeepSeek 编程助手 Web 面板（3080）。一键启动/停止，局域网随时访问",
         icon="\U0001f9e0", color="#4d8dff", port=3080,
         ctl=dict(kind="systemd", units=["dsh-web", "dsh-lan-forward"])),
    dict(id="fllm", external="http://%s:3001/" % LAN_IP, name="FreeLLMAPI 路由", tag="AI",
         desc="统一 LLM 路由网关（3001）：多模型接入、负载均衡与 API 转发",
         icon="\U0001f500", color="#8b5cf6", port=3001,
         ctl=dict(kind="docker", containers=["freellmapi-freellmapi-1"])),
    dict(id="alist", external="http://%s:5244/" % LAN_IP, name="AList 网盘", tag="存储",
         desc="AList 网盘聚合（5244）：多存储源统一挂载，文件在线浏览与下载",
         icon="\U0001f5c4", color="#10b981", port=5244,
         ctl=dict(kind="systemd", units=["alist"])),
    dict(id="mcsm", external="http://%s:23333/" % LAN_IP, name="MCSManager", tag="游戏",
         desc="Minecraft 服务器管理面板（Web 23333 / 守护进程 24444）：控制台、玩家管理、插件与备份",
         icon="\u26cf", color="#65a30d", port=23333,
         ctl=dict(kind="systemd", units=["mcsm-web", "mcsm-daemon"])),
    dict(id="wvc", external="http://%s:8008/" % LAN_IP, name="WebVirtCloud", tag="虚拟化",
         desc="WebVirtCloud 虚拟化控制台（8008）：KVM 虚拟机/容器统一管理",
         icon="\U0001f5a5", color="#0ea5e9", port=8008,
         ctl=dict(kind="docker", containers=["webvirtcloud"])),
    dict(id="schulte", external="http://%s:7090/" % LAN_IP, name="舒尔特方格", tag="工具",
         desc="注意力训练小游戏（7090）：25 格舒尔特方格，反应力测试",
         icon="\U0001f522", color="#ec4899", port=7090,
         ctl=dict(kind="systemd", units=["schulte"])),
    dict(id="openclaw", external="http://%s:18789/" % LAN_IP, name="OpenClaw Control", tag="AI",
         desc="OpenClaw 网关控制台（18789）：Agent 会话管理与设备连接",
         icon="\U0001f99e", color="#ef4444", port=18789,
         ctl=dict(kind="user_systemd", user="yxp", uid=1000,
                  units=["openclaw-gateway"])),
    dict(id="llamacpp", external="http://%s:8081/" % LAN_IP, name="Llama.cpp (Qwen3.8 27B)", tag="AI",
         desc="llama.cpp 推理服务（WebUI/兼容 API 8081 → 原始 API 8082）：启动要等模型加载 1~2 分钟",
         icon="\U0001f999", color="#a3e635", port=8081,
         ctl=dict(kind="systemd", units=["llama-server", "llama-ctx-proxy"])),
    dict(id="glucose", external="http://%s:8761/" % LAN_IP, name="血糖监测 Dashboard", tag="健康",
         desc="血糖数据看板（8761）：血糖记录可视化与趋势分析（宝塔 Python 项目 backend）",
         icon="\U0001fa78", color="#f43f5e", port=8761,
         ctl=dict(kind="btpython",
                  script="/www/server/python_project/vhost/scripts/backend_cmd.sh",
                  pidfile="/www/server/python_project/vhost/pids/backend.pid",
                  match="/home/yxp/bloodblood/backend")),
    dict(id="novnc2", external="http://%s:8080/vnc.html" % LAN_IP, name="noVNC (容器桌面)", tag="运维",
         desc="浏览器 VNC（8080）：容器桌面画面（VNC 5901），与 ZZZ 云端控制台同容器",
         icon="\U0001f4bb", color="#84cc16", port=8080,
         ctl=dict(kind="docker", containers=["zzz-cloud"])),
    dict(id="comfyui", external="http://%s:8188/" % LAN_IP, name="ComfyUI 绘图", tag="AI",
         desc="ComfyUI 节点式绘图（8188）：Stable Diffusion 工作流，Qwen-Image 贴图生成后端（宝塔 Python 项目）",
         icon="\U0001f3a8", color="#f472b6", port=8188,
         ctl=dict(kind="btpython",
                  script="/www/server/python_project/vhost/scripts/ComfyUI_cmd.sh",
                  pidfile="/www/server/python_project/vhost/pids/ComfyUI.pid",
                  match="main.py --listen 0.0.0.0 --port 8188")),
    dict(id="immich", external="http://%s:2283/" % LAN_IP, name="Immich 相册", tag="存储",
         desc="自托管照片/视频库（2283）：相册找图 AI（/find）的后端，手机自动备份",
         icon="\U0001f5bc", color="#6366f1", port=2283,
         ctl=dict(kind="docker",
                  containers=["immich_postgres", "immich_redis",
                              "immich_machine_learning", "immich_server"])),
    dict(id="vdesktop", external="http://%s:6088/vnc.html" % LAN_IP, name="虚拟桌面 (noVNC)", tag="运维",
         desc="轻量虚拟桌面（6088）：Xvfb + IceWM + Trae/Chrome，浏览器里直接用",
         icon="\U0001fa9f", color="#94a3b8", port=6088,
         ctl=dict(kind="systemd", units=["vdesktop"])),
    dict(id="bilinote", external="http://%s:8462/" % LAN_IP, name="BiliNote AI 视频笔记", tag="AI",
         desc="AI 视频笔记神器（8462）：上传本地视频或 B站/YouTube 链接，Fast-Whisper 转写 + 大模型整理成 Markdown 笔记",
         icon="\U0001f4dd", color="#a855f7", port=8462,
         ctl=dict(kind="docker", containers=["bilinote"])),
    dict(id="qbittorrent", external="/qbt/", name="qBittorrent 下载", tag="下载",
         desc="qBittorrent 网页版 BT/磁力下载器：下载目录默认指向 AList 网盘 (/webstorage)，局域网随时添加种子/磁力链接",
         icon="\U0001f4e5", color="#f59e0b", port=8083,
         ctl=dict(kind="systemd", units=["qbittorrent"])),
    dict(id="wangp", external="http://%s:7860/" % LAN_IP, name="WanGP AI 视频", tag="AI",
         desc="WanGP 视频工作站（7860）：对话式 AI 剪辑（Deepy 助手，手机端 /deepy/），"
              "支持文生视频、配音、声音克隆、放大插帧。界面已汉化",
         icon="\U0001f3ac", color="#7c3aed", port=7860,
         ctl=dict(kind="systemd", units=["wangp"])),
]


def ext_public():
    """给模板用的外部服务视图：隐藏内部 ctl 细节，只暴露"可否启停"。"""
    out = []
    for e in external_tools:
        d = {k: v for k, v in e.items() if k != "ctl"}
        d["controllable"] = bool(e.get("ctl"))
        out.append(d)
    return out


TOOLS = [
    dict(id="server-monitor", prefix="/monitor", name="服务器监控面板", tag="监测",
         desc="CPU/内存/磁盘/网络/GPU 实时曲线 · Top进程 · 容器管理 · AI模型库",
         icon="📊", color="#22c55e"),
    dict(id="ai-agent", prefix="/ai", name="AI 服务器助手", tag="AI",
         desc="对话式控制服务器：执行命令、SSH远程、联网搜索、多会话记忆",
         icon="🤖", color="#3b82f6"),
    dict(id="immich-ai", prefix="/find", name="相册找图 AI", tag="AI",
         desc="多说法并集召回+本地视觉逐张复核，可全库深度扫描；删图先出清单确认",
         icon="📷", color="#f59e0b"),
    dict(id="port-scanner", prefix="/scan", name="端口巡检", tag="巡检",
         desc="定时扫描全部开放端口，识别网页标题并给出内网/公网访问路径",
         icon="🧭", color="#a855f7"),
    dict(id="converter", prefix="/convert", name="格式转换器", tag="媒体",
         desc="音频/视频/图片互转格式（ffmpeg + Pillow），上传后暂存临时目录，下载后自动清理",
         icon="🔄", color="#22d3ee"),
    dict(id="wol", prefix="/wol", name="网络唤醒", tag="运维",
         desc="Wake-on-LAN 多设备管理：保存常用电脑，一键发送魔法包唤醒，并自动检测是否上线（已集成，无需单独密码）",
         icon="⚡", color="#f43f5e"),
    dict(id="cad", prefix="/cad", name="3D 建模助手", tag="3D",
         desc="对话式生成参数化 3D 零件(毫米精度)：螺丝/盒/支架/圆管，本地 AI 驱动，实时渲染并可导出 STL/OBJ",
         icon="🧊", color="#d9a441"),
    dict(id="wiztree", prefix="/wiztree", name="磁盘空间分析", tag="运维",
         desc="WizTree 仿制：极速扫描磁盘占用，Treemap 色块图 + 目录树 + 大文件 TOP，支持一键删除释放空间（root 权限）",
         icon="💽", color="#22d3ee"),
    dict(id="pvp-toolbox", prefix="/pvp", name="CS 战绩工具箱", tag="游戏",
         desc="完美平台 CS 战绩聚合：比赛记录/数据总结/Demo 归档/完美时刻下载",
         icon="🎯", color="#e2b714"),
    dict(id="doc-scan", prefix="/scanner", name="全能扫描王", tag="扫描",
         desc="AI 文档扫描：自动找纸四角 + 透视矫正 + 画质增强；原色/扫描件/黑白/二值"
              "四种输出，自动伸缩成 A4 纸张，一键去手写，多页导出 PDF/Word",
         icon="📄", color="#0d9488"),

    dict(id="mctex", prefix="/mctex", name="图像生成工坊", tag="AI",
         desc="本机 WanGP（Qwen-Image 2.1）驱动的 AI 图像工坊：① AI 图像修改——上传一张图 + 说一句话即可改图，"
              "带逐步进度条与历史画廊；② MC 材质生成——1024× 高清物品贴图、自动清边抠图、PBR、一键导出资源包",
         icon="🎨", color="#c6613f"),
    dict(id="voice", prefix="/voice", name="语音训练工坊", tag="AI",
         desc="录朗读稿→逐条质检→一键训练 RVC v2 40k 音色模型：稿件浏览、试听复核、训练进度与日志全在站内"
              "（麦克风录音需 HTTPS，仍走 8800 端，数据互通）",
         icon="🎙", color="#c6613f"),
    dict(id="memclean", prefix="/memclean", name="自动内存清理", tag="运维",
         desc="实时内存占用排行，手动/自动结束高占用进程：阈值触发自动清理，支持目标名单与黑名单保护、程序一键启停",
         icon="🧹", color="#0d9488"),
    dict(id="zzz-cloud", prefix="/zzz", name="ZZZ 云端控制台", tag="工具",
         desc="Windows 程序云端控制台：浏览器串流桌面，远程启动绝区零/一条龙助手，一键置顶助手窗口（已并入 7070，无需单独访问 8000）",
         icon="🎮", color="#38bdf8"),
    dict(id="traecode", prefix="/trae", name="TraeCode 控制面板", tag="工具",
         desc="开发工具控制面板：独立启停 TraeCode 与腾讯 WorkBuddy 桌面端（互不影响），查看版本状态，配套 noVNC 虚拟桌面（已并入 7070）",
         icon="⚡", color="#f59e0b"),
    dict(id="vnc-hub", prefix="/vnc", name="VNC 桌面聚合", tag="远程",
         desc="三路 VNC 统一入口：TraeCode 桌面 / ZZZ 云端 / wxedge 虚拟机，卡片式切换、全屏操控、在线状态检测（WebSocket 由 7070 直接转发，无需直连各 VNC 端口）",
         icon="🖥️", color="#6366f1"),
    dict(id="trae-checkin", prefix="/checkin", name="TraeCode 自动签到", tag="工具",
         desc="每日自动领 Trial Code 100 积分：最小化桌面 → 重启 TraeCode → 等待右上角签到气泡 → 点击 → 关闭。可设每日定时，也可手动触发；带测试模式先验证定位再真点",
         icon="⚡", color="#f59e0b"),
]


import requests as _requests

_HOP_HEADERS = {"connection", "keep-alive", "proxy-authenticate",
                "proxy-authorization", "te", "trailers",
                "transfer-encoding", "upgrade", "host", "content-length",
                "content-encoding"}


# Anthropic 统一主题：由 tools-hub 注入到每个子应用页面（见 static/anthropic-unify.css）。
# 改样式版本号即可强制浏览器刷新缓存。
UNIFY_CSS_URL = "/anthropic-unify.css?v=20261006a"


def _inject_unify(txt, appid):
    """给子应用 HTML 注入统一主题：<html class="app-<id>"> + <link>，只注入一次。
    兼容缺少 </head> 闭合标签的页面（如 wol）：此时紧跟 <head...> 之后插入。
    """
    if "anthropic-unify.css" in txt:
        return txt
    txt = txt.replace("<html", '<html class="app-%s"' % appid, 1)
    link = '<link rel="stylesheet" href="%s">' % UNIFY_CSS_URL
    if "</head>" in txt:
        return txt.replace("</head>", link + "\n</head>", 1)
    m = re.search(r"<head[^>]*>", txt)
    if m:
        return txt[:m.end()] + "\n" + link + txt[m.end():]
    if "<body" in txt:
        return txt.replace("<body", link + "\n<body", 1)
    return link + "\n" + txt


def _install_rewrite(subapp, prefix, patterns):
    """路径前缀改写 + 统一主题注入（2026-10-06 恢复 09-26 验证过的实现）。"""
    appid = prefix.strip("/")

    @subapp.before_request
    def _no_conditional():
        # send_file 的 ETag/Last-Modified 只按源文件计算，改了前端文件后浏览器
        # 带旧 ETag 重新验证会拿到 304、永远复用旧 HTML（"改了没生效"的根因）。
        # 对 HTML 文档导航请求剥离条件头，强制全量 200。
        if "text/html" in request.headers.get("Accept", ""):
            request.environ.pop("HTTP_IF_NONE_MATCH", None)
            request.environ.pop("HTTP_IF_MODIFIED_SINCE", None)

    @subapp.after_request
    def _rw(resp):
        ct = resp.headers.get("Content-Type", "")
        if "text/html" in ct or "javascript" in ct:
            try:
                # 文件响应 direct_passthrough=True 时 get_data/set_data 会抛
                # RuntimeError 被静默吞掉（pvp 注入失效根因），先转普通字节序列。
                if resp.direct_passthrough:
                    resp.direct_passthrough = False
                    resp.make_sequence()
                txt = resp.get_data(as_text=True)
                for p in patterns:
                    # 幂等改写：先剥掉已存在的本前缀再加回去（防 /ai/ai/api 双包）。
                    txt = txt.replace(prefix + p, p)
                    txt = txt.replace(p, prefix + p)
                if "text/html" in ct:
                    # HTML 不许启发式缓存 + 注入统一主题。
                    resp.headers["Cache-Control"] = "no-cache"
                    txt = _inject_unify(txt, appid)
                resp.set_data(txt)
                if "text/html" in ct and resp.status_code == 200:
                    resp.headers["ETag"] = '"%s"' % hashlib.md5(
                        resp.get_data()).hexdigest()
                    resp.headers.pop("Last-Modified", None)
                    resp.headers["Cache-Control"] = "no-cache"
            except Exception:
                pass
        return resp


def _make_proxy(target):
    """生成一个把全部请求转发到 target 的 Flask 反代应用。"""
    px = Flask(__name__)

    @px.route("/", defaults={"path": ""},
              methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"])
    @px.route("/<path:path>",
              methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"])
    def forward(path):
        url = "%s/%s" % (target, path)
        if request.query_string:
            url += "?" + request.query_string.decode("latin-1")
        headers = {k: v for k, v in request.headers.items()
                   if k.lower() not in _HOP_HEADERS}
        try:
            r = _requests.request(request.method, url, headers=headers,
                                  data=request.get_data(), timeout=600)
        except _requests.RequestException as e:
            return jsonify(ok=False, msg="%s 不可达: %s" % (target, e)), 502
        resp = px.response_class(r.content, status=r.status_code)
        for k, v in r.headers.items():
            if k.lower() not in _HOP_HEADERS:
                resp.headers[k] = v
        return resp

    return px


class _ProxyNs:
    """包装成与 _load_app 载入的模块一致的形态（健康检查取 .app）。"""

    def __init__(self, px):
        self.app = px


def _load_app(path, alias, clear_names):
    for n in clear_names:
        sys.modules.pop(n, None)
    d = os.path.dirname(os.path.abspath(path))
    if d not in sys.path:
        sys.path.insert(0, d)
    spec = importlib.util.spec_from_file_location(alias, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[alias] = mod
    spec.loader.exec_module(mod)
    return mod


_CORE_COMMON = ["config", "core", "core.agent", "core.tools"]
monitor_mod = _load_app(
    "/opt/tools-hub/server-monitor/app.py", "hub_monitor_app",
    ["config", "core", "core.registry", "core.collector", "core.services",
     "core.dockerctl", "core.comfyui_scan"])
ai_mod = _load_app("/opt/tools-hub/ai-agent/app.py", "hub_ai_app", list(_CORE_COMMON) + ["store"])
find_mod = _load_app("/opt/tools-hub/immich-ai/app.py", "hub_find_app",
                     list(_CORE_COMMON) + ["core.immich", "core.session", "core.vision"])
scan_mod = _load_app("/opt/tools-hub/port-scanner/app.py", "hub_scan_app", [])
convert_mod = _load_app("/opt/tools-hub/convert/app.py", "hub_convert_app", [])
wol_mod = _load_app("/opt/tools-hub/wol-web/wol_flask.py", "hub_wol_flask", [])
cad_mod = _load_app("/opt/tools-hub/cad-assistant/app.py", "hub_cad_app", [])
wiztree_mod = _load_app("/opt/tools-hub/wiztree-web/app.py", "hub_wiztree_app", [])
pvp_mod = _load_app("/opt/tools-hub/pvp-toolbox/app.py", "hub_pvp_app", [])
# doc-scan 改为网络反代到 7071 独立服务（不再进程内加载）：
#   1) 总控台被频繁 restart（其他会话调试改码时）不再杀掉进行中的扫描任务
#      —— 之前手机上传扫描到一半总控台重启，前端直接"处理失败，显示原图"；
#   2) hub 进程不再加载 torch/视觉模型，避免与 7071 服务各装一份。
docsn_proxy = _make_proxy("http://127.0.0.1:7071")
docsn_mod = _ProxyNs(docsn_proxy)
mctex_mod = _load_app("/opt/tools-hub/mctex/app.py", "hub_mctex_app", [])
# 语音训练工坊：源码在 yxp 工作区，与 8800 的 FastAPI 版共用同一份 data/。
# clear_names 留空 —— app_hub.py 用绝对路径加载本地模块（core_vt/quality/prompts），
# 不按模块名 import，所以不会和 doc-scan 的 pipeline.py 等同名模块串台。
voice_mod = _load_app("/opt/tools-hub/voice-trainer/app_hub.py", "hub_voice_app", [])
# 载完立刻把自己的目录移出 sys.path：其余子应用仍可能在请求里惰性 import，
# 不能让它们误命中本仓库的 prompts.py / pipeline.py。
try:
    sys.path.remove("/opt/tools-hub/voice-trainer")
except ValueError:
    pass
# 自动内存清理：单文件子应用（/opt/tools-hub/memclean/app.py），无同名模块依赖，不会串台
memclean_mod = _load_app("/opt/tools-hub/memclean/app.py", "hub_memclean_app", [])
# TraeCode 自动签到（/opt/tools-hub/trae-checkin）：单目录子应用，
# 内部 import core（同目录），加载后把自己的目录移出 sys.path 防止串台。
checkin_mod = _load_app("/opt/tools-hub/trae-checkin/app.py", "hub_checkin_app", ["core"])
try:
    sys.path.remove("/opt/tools-hub/trae-checkin")
except ValueError:
    pass

monitor_mod.init_registry()
threading.Thread(target=scan_mod.loop, daemon=True, name="scan-loop").start()


# Anthropic 统一主题恢复由 hub 注入（2026-10-06）：所有子应用页面统一套
# /anthropic-unify.css 覆盖层（调色板与总控台一致），插件里的旧深色/旧配色
# 全部被覆盖层压住，不再可见。

# 注意：monitor 的 app.js 用运行时 APP_PREFIX（从 location.pathname 推导
# /monitor）拼接 '/api/...'，这里若再改写 '/api/' 文本，浏览器执行时会
# 二次叠加成 /monitor/monitor/api/*（09-26 06:11 空白页根因）。
# 因此 monitor 只改写 /static/，API 前缀交给前端 APP_PREFIX 处理。
_install_rewrite(monitor_mod.app, "/monitor", ["/static/"])
_install_rewrite(ai_mod.app, "/ai", ["/static/", "/api/"])
_install_rewrite(find_mod.app, "/find", ["/static/", "/api/", "/thumb/", "/view/", "/orig/"])
_install_rewrite(scan_mod.app, "/scan", ["/api/"])
_install_rewrite(convert_mod.app, "/convert", ["/api/"])
_install_rewrite(wol_mod.app, "/wol", ["/api/", "/login", "/manifest.json", "/icon.svg"])
_install_rewrite(cad_mod.app, "/cad", ["/api/"])
_install_rewrite(wiztree_mod.app, "/wiztree", ["/api/"])
_install_rewrite(pvp_mod.app, "/pvp", ["/api/", "/media/"])
# doc-scan 前端用运行时前缀(P=location.pathname 推导)拼接 /api/pdf，
# 若再改写 '/api/' 文本会二次叠加成 /scanner/scanner/api/pdf，故 patterns 留空，
# 仍保留统一主题注入与 ETag 刷新逻辑。
_install_rewrite(docsn_mod.app, "/scanner", [])
_install_rewrite(mctex_mod.app, "/mctex", [])
# 语音训练工坊前端一律用根相对 /api/...（独立跑 8800 时也是这些路径），
# 这里统一改写成 /voice/api/...，HTML 由 hub 注入统一主题。
_install_rewrite(voice_mod.app, "/voice", ["/api/"])
# 自动内存清理：前端一律用根相对 /api/...，统一改写为 /memclean/api/...
_install_rewrite(memclean_mod.app, "/memclean", ["/api/"])
# 自动签到前端用根相对 api/...，统一改写为 /checkin/api/...
# 注意 core 名字通用，加载时已用 clear_names 清过并移出 sys.path
_install_rewrite(checkin_mod.app, "/checkin", ["/api/"])


app = Flask(__name__)

# ---------------------------------------------------------------- VNC 桌面聚合
# 把三路 VNC 统一聚合到 7070 一个端口：
#   /vnc/           卡片式选择页（templates/vnc.html，内嵌 noVNC 1.6）
#   /vnc/ws/<name>  WebSocket ↔ TCP 裸转发（flask-sock），浏览器无需直连 VNC 端口
#   /vnc/novnc/...  noVNC 前端静态资源（/opt/novnc）
#   /vnc/api/state  三路目标 TCP 可达性检测（供卡片状态点轮询）
from flask_sock import Sock

VNC_TARGETS = {
    "traecode": dict(host="127.0.0.1", port=5902, name="TraeCode 桌面"),
    "zzz":      dict(host="127.0.0.1", port=5901, name="ZZZ 云端"),
    "wxedge":   dict(host="127.0.0.1", port=5900, name="wxedge 虚拟机"),
}

_sock = Sock(app)
_vnc_state_cache = {"t": 0.0, "data": None}


@app.route("/vnc/")
def vnc_hub_page():
    return render_template("vnc.html")


@app.route("/vnc/api/state")
def vnc_hub_state():
    # 前端每 ~10s 轮询一次：加 3s TTL 缓存，全挂时也不至于每次都串行等 3 个 TCP 超时
    now = time.time()
    if now - _vnc_state_cache["t"] < 3 and _vnc_state_cache["data"] is not None:
        return jsonify(ok=True, targets=_vnc_state_cache["data"])
    out = {}
    for name, t in VNC_TARGETS.items():
        try:
            s = socket.create_connection((t["host"], t["port"]), timeout=1.0)
            s.close()
            out[name] = True
        except Exception:
            out[name] = False
    _vnc_state_cache.update(t=now, data=out)
    return jsonify(ok=True, targets=out)


@app.route("/vnc/novnc/<path:p>")
def vnc_hub_novnc(p):
    return send_from_directory("/opt/novnc", p)


@_sock.route("/vnc/ws/<name>")
def vnc_hub_ws(ws, name):
    t = VNC_TARGETS.get(name)
    if t is None:
        try:
            ws.close()
        except Exception:
            pass
        return
    try:
        vnc = socket.create_connection((t["host"], t["port"]), timeout=8)
    except Exception:
        try:
            ws.close()
        except Exception:
            pass
        return
    vnc.settimeout(None)

    def _pump():
        # VNC 服务器 → 浏览器（后台线程）
        try:
            while True:
                data = vnc.recv(65536)
                if not data:
                    break
                ws.send(data)
        except Exception:
            pass
        finally:
            try:
                ws.close()
            except Exception:
                pass

    threading.Thread(target=_pump, daemon=True).start()
    try:
        # 浏览器 → VNC 服务器（当前线程）
        while True:
            data = ws.receive()
            if data is None:
                break
            if isinstance(data, str):
                data = data.encode("latin-1")
            vnc.sendall(data)
    except Exception:
        pass
    finally:
        try:
            vnc.close()
        except Exception:
            pass


_health_cache = {"t": 0.0, "data": None}
_SUBS = [("server-monitor", monitor_mod), ("ai-agent", ai_mod), ("immich-ai", find_mod), ("port-scanner", scan_mod), ("converter", convert_mod), ("wol", wol_mod), ("cad", cad_mod), ("wiztree", wiztree_mod), ("pvp-toolbox", pvp_mod), ("doc-scan", docsn_mod), ("mctex", mctex_mod), ("voice", voice_mod), ("memclean", memclean_mod), ("trae-checkin", checkin_mod)]


# ---------- DSH (DeepSeek Harness) 一键启动 ----------
_DSH_SERVICES = ["dsh-web", "dsh-lan-forward"]


_RE_DSH_TOKEN = re.compile(r"[?&]token=([A-Za-z0-9_-]+)")


def _dsh_state():
    # 一条命令同时查两个 unit（is-active 支持多参数，按行输出），省一半子进程
    rc, out, _ = _run(["systemctl", "is-active"] + _DSH_SERVICES, 8)
    lines = out.splitlines()
    st = {svc: (i < len(lines) and lines[i].strip() == "active")
          for i, svc in enumerate(_DSH_SERVICES)}
    return {"web": st.get("dsh-web", False), "lan": st.get("dsh-lan-forward", False),
            "running": st.get("dsh-web", False) and st.get("dsh-lan-forward", False)}


@app.route("/api/dsh/state")
def api_dsh_state():
    return jsonify(**_dsh_state())


@app.route("/api/dsh/start", methods=["POST"])
def api_dsh_start():
    logs = []
    for svc in _DSH_SERVICES:
        r = subprocess.run(["systemctl", "start", svc],
                           capture_output=True, text=True, timeout=30)
        logs.append(f"{svc}: {'OK' if r.returncode == 0 else (r.stderr or r.stdout or 'FAIL')}")
    return jsonify(ok=True, logs=logs, **_dsh_state())


@app.route("/api/dsh/stop", methods=["POST"])
def api_dsh_stop():
    logs = []
    for svc in reversed(_DSH_SERVICES):
        r = subprocess.run(["systemctl", "stop", svc],
                           capture_output=True, text=True, timeout=30)
        logs.append(f"{svc}: {'OK' if r.returncode == 0 else (r.stderr or r.stdout or 'FAIL')}")
    return jsonify(ok=True, logs=logs, **_dsh_state())


def _dsh_token():
    """从 dsh-web 启动日志中提取当前启动 token（每次启动随机生成）。"""
    try:
        r = subprocess.run(["journalctl", "-u", "dsh-web", "--no-pager", "-o", "cat"],
                           capture_output=True, text=True, timeout=10)
        for line in reversed(r.stdout.splitlines()):
            m = _RE_DSH_TOKEN.search(line)
            if m:
                return m.group(1)
    except Exception:
        pass
    return None


@app.route("/api/dsh/open")
def api_dsh_open():
    """携带最新 token 打开 DSH 面板，浏览器自动完成验证，免手动输入。"""
    url = "http://%s:3080/" % LAN_IP
    tok = _dsh_token()
    if tok:
        url += "?token=" + tok
    return redirect(url)


def _health():
    now = time.time()
    if _health_cache["data"] is not None and now - _health_cache["t"] < 12:
        return _health_cache["data"]
    data = {}
    for key, mod in _SUBS:
        try:
            c = mod.app.test_client()
            r = c.get("/")
            data[key] = r.status_code < 500
        except Exception:
            data[key] = False
    _health_cache.update(t=now, data=data)
    return data


# ------------------------------------------------------------------ 外部服务启停
# 说明：tools-hub 以 root 运行，因此可直接调用 systemctl / docker / runuser。
# 所有命令都由本文件的注册表产生，不接受前端传入的命令，避免注入。
def _run(cmd, timeout=180):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "").strip(), (r.stderr or "").strip()
    except subprocess.TimeoutExpired:
        return 124, "", "命令超时"
    except Exception as e:  # noqa: BLE001
        return 1, "", str(e)


def _port_open(port, timeout=1.0):
    if not port:
        return None
    try:
        with socket.create_connection(("127.0.0.1", int(port)), timeout=timeout):
            return True
    except OSError:
        return False


def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def _read_pid(path):
    try:
        with open(path or "", "r") as f:
            return f.read().strip()
    except OSError:
        return ""


def _svc_base(ctl):
    """返回 (命令前缀, 单元列表)：区分系统级与 yxp 用户级 systemd。"""
    if ctl.get("kind") == "user_systemd":
        base = ["runuser", "-u", ctl.get("user") or "yxp", "--", "env",
                "XDG_RUNTIME_DIR=/run/user/%d" % int(ctl.get("uid") or 1000),
                "systemctl", "--user"]
    else:
        base = ["systemctl"]
    return base, list(ctl.get("units") or [])


def _svc_running(e):
    """判断服务是否在运行：以服务管理器状态为准，端口探测兜底。"""
    ctl = e.get("ctl") or {}
    kind = ctl.get("kind")
    if kind in ("systemd", "user_systemd"):
        base, units = _svc_base(ctl)
        if not units:
            return bool(_port_open(e.get("port")))
        return all(_run(base + ["is-active", u], 8)[1] == "active" for u in units)
    if kind == "docker":
        conts = list(ctl.get("containers") or [])
        if not conts:
            return bool(_port_open(e.get("port")))
        # 一次 inspect 全部容器（逐个 spawn docker 子进程在多容器服务上太慢）
        rc, out, _ = _run(["docker", "inspect", "-f",
                           "{{.Name}}|{{.State.Running}}"] + conts, 15)
        if rc != 0:
            return False
        running = {}
        for line in out.splitlines():
            if "|" in line:
                name, state = line.rsplit("|", 1)
                running[name.lstrip("/")] = state.strip() == "true"
        return all(running.get(c, False) for c in conts)
    if kind == "btpython":
        pid = _read_pid(ctl.get("pidfile"))
        if pid and _pid_alive(pid):
            return True
        return bool(_port_open(e.get("port")))
    return bool(_port_open(e.get("port")))


def _svc_action(e, action):
    """对单个外部服务执行 start / stop / restart，返回日志行列表。"""
    ctl = e.get("ctl") or {}
    kind = ctl.get("kind")
    logs = []
    if kind in ("systemd", "user_systemd"):
        base, units = _svc_base(ctl)
        label = "%s --user" % ctl.get("user") if kind == "user_systemd" else "systemd"
        order = list(units)
        if action == "stop":
            order.reverse()
        for u in order:
            rc, out, err = _run(base + [action, u], 240)
            logs.append("%s %s %s: %s" % (
                label, action, u, "OK" if rc == 0 else (err or out or "FAIL")))
    elif kind == "docker":
        conts = list(ctl.get("containers") or [])
        if action == "stop":
            conts.reverse()
        for c in conts:
            rc, out, err = _run(["docker", action, c], 240)
            logs.append("docker %s %s: %s" % (
                action, c, "OK" if rc == 0 else (err or out or "FAIL")))
    elif kind == "btpython":
        # 宝塔 Python 项目：用 systemd-run 起成独立 transient unit，
        # 避免进程留在 tools-hub 的 cgroup 里被 hub 重启连带杀掉。
        unit = ctl.get("unit") or ("ext-" + e["id"])
        if action in ("stop", "restart"):
            _run(["systemctl", "stop", unit], 60)
            _run(["systemctl", "reset-failed", unit], 20)
            # 兜底：服务也可能是宝塔自己拉起的，不在我们的 unit 里，
            # 用 pidfile / 进程名 / 端口逐个清理。
            pid = _read_pid(ctl.get("pidfile"))
            if pid and _pid_alive(pid):
                _run(["kill", "-TERM", pid], 20)
                for _ in range(15):
                    if not _pid_alive(pid):
                        break
                    time.sleep(0.4)
                if _pid_alive(pid):
                    _run(["kill", "-KILL", pid], 20)
            if ctl.get("match"):
                _run(["pkill", "-f", ctl["match"]], 20)
            if e.get("port"):
                _run(["fuser", "-k", "%d/tcp" % int(e["port"])], 20)
            for _ in range(20):
                if not _port_open(e.get("port")):
                    break
                time.sleep(0.5)
            logs.append("[%s] 已停止" % e["name"])
        if action in ("start", "restart"):
            # 先清掉残留 unit（应用可能已死但 unit 还 active），再重新拉起
            _run(["systemctl", "stop", unit], 30)
            _run(["systemctl", "reset-failed", unit], 20)
            rc, out, err = _run([
                "systemd-run", "--unit", unit, "--collect",
                "--property=Type=oneshot", "--property=RemainAfterExit=yes",
                "--property=KillMode=control-group",
                "bash", ctl["script"]], 240)
            logs.append("[%s] 启动 %s" % (
                e["name"], "OK" if rc == 0 else "FAIL：" + (err or out or "")))
    else:
        logs.append("该服务未配置启停方式")
    return logs


def _find_ext(sid):
    for e in external_tools:
        if e["id"] == sid:
            return e
    return None


_ext_state_cache = {"t": 0.0, "data": None}


@app.route("/api/ext/state")
def api_ext_state():
    # 前端轮询接口：3s TTL 合并并发轮询；启停动作走 api_ext_action 内的
    # _svc_running() 直查，不经过本缓存，状态切换不受影响
    now = time.time()
    if now - _ext_state_cache["t"] < 3 and _ext_state_cache["data"] is not None:
        return jsonify(_ext_state_cache["data"])
    states = {}
    for e in external_tools:
        states[e["id"]] = {
            "running": _svc_running(e),
            "port": e.get("port"),
            "port_open": _port_open(e.get("port")),
            "controllable": bool(e.get("ctl")),
        }
    data = dict(states=states, total=len(external_tools),
                controllable=sum(1 for e in external_tools if e.get("ctl")))
    _ext_state_cache.update(t=now, data=data)
    return jsonify(data)


@app.route("/api/ext/<sid>/<action>", methods=["POST"])
def api_ext_action(sid, action):
    if action not in ("start", "stop", "restart"):
        return jsonify(ok=False, msg="不支持的操作"), 400
    e = _find_ext(sid)
    if not e:
        return jsonify(ok=False, msg="未知服务: %s" % sid), 404
    if not e.get("ctl"):
        return jsonify(ok=False, msg="该服务未配置启停方式"), 400
    running = _svc_running(e)
    if action == "start" and running:
        return jsonify(ok=True, msg="已在运行", running=True,
                       logs=["已在运行，无需启动"])
    if action == "stop" and not running:
        return jsonify(ok=True, msg="本来就已停止", running=False,
                       logs=["本来就已停止"])
    logs = _svc_action(e, action)
    time.sleep(1.5)              # 给服务管理器一点时间切换状态
    running = _svc_running(e)
    return jsonify(ok=True, logs=logs, running=running, name=e["name"],
                   port_open=_port_open(e.get("port")))


@app.route("/")
def index():
    return render_template("index.html", tools=TOOLS, external=ext_public(), lan=LAN_IP)


@app.route("/ext")
def ext_page():
    return render_template("ext.html", external=ext_public(), lan=LAN_IP)


@app.route("/anthropic-unify.css")
def anthropic_unify_css():
    """Anthropic 统一主题（自动注入所有子应用页面，勿手改）。"""
    resp = send_from_directory(app.static_folder, "anthropic-unify.css",
                               mimetype="text/css")
    resp.headers["Cache-Control"] = "no-cache"
    return resp


@app.route("/api/health")
def api_health():
    h = _health()
    up = sum(1 for v in h.values() if v)
    return jsonify(up=up, total=len(h), tools=[
        dict(id=k, up=h.get(k, False)) for k, _ in _SUBS
    ])


@app.route("/healthz")
def healthz():
    return jsonify(_health())


# ---------------------------------------------------------------- 子服务反代
# 把独立端口的子服务统一挂到 7070 的路径下：公网只转发 7070 一个端口即可访问全部。
#   /zzz  -> ZZZ 云端控制台（容器 8000；串流 8055 / noVNC 8080 页面内直连）
#   /trae -> TraeCode 控制面板（8090；noVNC 桌面 6088 页面内直连）
# 反代的前端页面均带路径自适应（fetch 按 location.pathname 推导前缀）。

dispatcher_map = {}


def _mount_proxy(sub_id, prefix, target):
    """反代 + 统一主题注入 + 纳入健康检查 + 挂到总控台，一步到位。"""
    px = _make_proxy(target)
    _install_rewrite(px, prefix, [])
    mod = _ProxyNs(px)
    _SUBS.append((sub_id, mod))
    dispatcher_map[prefix] = px
    return mod


zzz_mod = _mount_proxy("zzz-cloud", "/zzz", "http://127.0.0.1:8000")
trae_mod = _mount_proxy("traecode", "/trae", "http://127.0.0.1:8090")


# ---- qBittorrent 自动登录反代：点卡片即免密进入，不再弹 Unauthorized ----
def _make_qbt_proxy(target):
    """带服务端自动登录的 qBittorrent 反代。
    浏览器无需输入密码，也不会被失败次数封 IP；凭证仅在服务端持有。
    qBittorrent 4.6 经典 WebUI 用的是相对路径，可直接挂在 /qbt 子路径下，无需改写 URL。
    """
    _auth_path = "/opt/tools-hub/.qbt_auth"
    try:
        with open(_auth_path) as _f:
            _auth = json.load(_f)
    except Exception:
        _auth = {"username": "admin", "password": ""}

    _px = Flask(__name__)
    _sid_lock = threading.Lock()
    _sid = {"value": None, "ts": 0.0}

    def _login():
        try:
            r = _requests.post(target + "/api/v2/auth/login",
                               data={"username": _auth["username"], "password": _auth["password"]},
                               headers={"Referer": target + "/"}, timeout=10)
        except _requests.RequestException:
            return None
        sid = None
        for c in r.cookies:
            if c.name == "SID":
                sid = c.value
        if not sid:
            m = re.search(r"SID=([^;]+)", r.headers.get("Set-Cookie", ""))
            if m:
                sid = m.group(1)
        if sid:
            _sid["value"] = sid
            _sid["ts"] = time.time()
        return sid

    @_px.route("/", defaults={"path": ""}, strict_slashes=False,
               methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"])
    @_px.route("/<path:path>", strict_slashes=False,
               methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"])
    def _qbt_fwd(path):
        with _sid_lock:
            if not _sid["value"] or time.time() - _sid["ts"] > 1500:
                _login()
            sid = _sid["value"]
        # 根路径（页面入口）额外做一次会话有效性探测，避免 qBittorrent 重启后 SID 失效导致浏览器看到登录框
        if path == "":
            try:
                _probe = _requests.get(target + "/api/v2/app/version",
                                       headers={"Referer": target + "/"},
                                       cookies={"SID": sid} if sid else {}, timeout=10)
            except _requests.RequestException:
                _probe = None
            if not _probe or _probe.status_code != 200:
                with _sid_lock:
                    _sid["value"] = None
                    _login()
                    sid = _sid["value"]
        url = "%s/%s" % (target, path)
        if request.query_string:
            url += "?" + request.query_string.decode("latin-1")
        headers = {k: v for k, v in request.headers.items()
                   if k.lower() not in _HOP_HEADERS}
        headers["Referer"] = target + "/"
        headers["Origin"] = target
        cookies = {k: v for k, v in request.cookies.items()}
        if sid:
            cookies["SID"] = sid
        try:
            r = _requests.request(request.method, url, headers=headers, cookies=cookies,
                                  data=request.get_data(), timeout=180, allow_redirects=False)
        except _requests.RequestException as e:
            return jsonify(ok=False, msg="qBittorrent 不可达: %s" % e), 502
        # API 返回 401/403 -> 会话失效，强制重新登录并重试一次
        if path.startswith("api/") and r.status_code in (401, 403):
            with _sid_lock:
                _sid["value"] = None
                _login()
                sid = _sid["value"]
            if sid:
                cookies["SID"] = sid
                try:
                    r = _requests.request(request.method, url, headers=headers, cookies=cookies,
                                          data=request.get_data(), timeout=180, allow_redirects=False)
                except _requests.RequestException:
                    pass
        resp = _px.response_class(r.content, status=r.status_code)
        for k, v in r.headers.items():
            if k.lower() not in _HOP_HEADERS:
                resp.headers[k] = v
        return resp

    return _px


qbt_mod = _make_qbt_proxy("http://127.0.0.1:8083")
_install_rewrite(qbt_mod, "/qbt", [])
dispatcher_map["/qbt"] = qbt_mod



dispatcher = DispatcherMiddleware(app, {
    "/monitor": monitor_mod.app,
    "/ai": ai_mod.app,
    "/find": find_mod.app,
    "/scan": scan_mod.app,
    "/convert": convert_mod.app,
    "/wol": wol_mod.app,
    "/cad": cad_mod.app,
    "/wiztree": wiztree_mod.app,
    "/pvp": pvp_mod.app,
    "/scanner": docsn_mod.app,
    "/mctex": mctex_mod.app,
    "/voice": voice_mod.app,
    "/memclean": memclean_mod.app,
    "/checkin": checkin_mod.app,
    **dispatcher_map,
})


def main():
    print("=" * 56)
    print("服务器工具总控台(单进程)启动中")
    print("监听: http://0.0.0.0:%d" % HUB_PORT)
    for t in TOOLS:
        print("  %-16s -> %s" % (t["name"], t["prefix"]))
    for t in external_tools:
        print("  %-16s -> %s (外部链接)" % (t["name"], t["external"]))
    print("=" * 56)
    run_simple("0.0.0.0", HUB_PORT, dispatcher, threaded=True, use_reloader=False)


if __name__ == "__main__":
    main()
