# ToolHub Mobile — 服务器总控台手机客户端

为局域网服务器总控台（192.168.1.15:7070）配套的手机方案：

- **手机专用网关**（端口 **7072**）：聚合全部功能，插件清单（manifest）下发 + API 反向代理 + token 鉴权
- **iOS 客户端**（`ios/ToolHubMobile/`）：SwiftUI + Anthropic 主题，适配 iPhone 12 / iPhone 15（iOS 16+）

## 核心机制：插件 OTA 同步

App 本体是一个**服务器驱动 UI 框架**，装一次即可：

1. 网关从 `/opt/tools-hub/mobile/plugins/*.json` 热加载插件清单
2. App 每 30 秒轮询 `/api/manifest/version`，版本变化自动拉取新清单并刷新界面
3. **新增插件 = 往 plugins 目录丢一个 JSON 文件**，不重启任何服务，手机下拉刷新（或等 30 秒）即出现，无需重新安装 App

插件两种形态：
- `type: "native"`：JSON 声明页面布局（stats 卡片 / gauge / chart 曲线 / list 行级操作 / keyvalue / auto / actions 按钮 / chat 对话 / upload 上传 / imagegrid 图片墙 / progress 进度），App 原生渲染，数据经 JSONPath（`$.a.b.0.c`）从任意 API 取值
- `type: "web"`：App 内 WebView 直接打开子应用页面（走 `/proxy/<前缀>/` 反代）

**自动发现**：网关每 30 秒轮询总控台 `/api/cards`，往总控台新增任何子应用后，手机端 30 秒内自动出现对应插件（WebView 形态，`auto-<id>.json`）。手工插件优先——同 id 的手工/原生清单会覆盖自动注册。

## 当前插件（15 原生 + 4 WebView）

| 形态 | 插件 |
|---|---|
| 原生 | memclean 内存清理、monitor 服务器监控、port-scanner 端口巡检、trae-checkin 自动签到、wol 网络唤醒（行级一键开机）、traecode TraeCode 控制（6 按钮）、pvp-toolbox CS 战绩（战绩+对局+刷新）、qbittorrent 下载（行级暂停/恢复）、converter 格式转换（上传→进度→Safari 下载）、mctex 材质工坊（GPU 状态+画廊）、voice 语音工坊（录音/训练进度+稿件）、doc-scan 扫描王（拍照矫正+扫描画廊）、ai-agent AI 助手（原生聊天+历史）、immich-ai 相册找图（聊天+照片墙） |
| WebView | cad 3D 建模助手（WebGL 画布，硬性限制）、zzz-cloud ZZZ 云端（noVNC 串流画面，硬性限制）、server-monitor 监控面板（自动注册）、vnc-hub VNC 聚合（自动注册，仅入口） |

## 目录结构

```
server/
  mobile_gateway.py          # 网关主程序（Flask，7072，独立于总控台进程）
  toolhub-mobile.service     # systemd 单元
  plugins/*.json             # 19 个插件清单（15 原生 + 4 WebView），热加载
ios/ToolHubMobile/           # iOS 项目（XcodeGen，见其 README）
server-ref/app.py            # 总控台源码参考副本（只读，用于分析）
```

## 网关 API（7072）

鉴权：header `X-ToolHub-Token`（token 存 `/opt/tools-hub/mobile/token.txt`，首次启动自动生成；写入 `open` 可关闭鉴权）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/ping` | 连接测试（无需 token） |
| GET | `/api/manifest` | 插件清单（驱动整个 App UI） |
| GET | `/api/manifest/version` | 清单版本号（App 轮询用） |
| GET | `/api/overview` | 子应用健康 + 外部服务状态聚合 |
| POST | `/api/services/<sid>/<start\|stop\|restart>` | 外部服务启停 |
| ANY | `/proxy/<前缀>/<路径>` | 反代到总控台对应子应用 |
| POST | `/api/ai-chat` · GET `/api/ai-history` | AI 助手：SSE 聚合为整段回复 + 会话历史 |
| POST | `/api/find-chat` · GET `/api/find-cards` | 相册找图：SSE 聚合 + 结果照片墙 URL |
| POST | `/api/convert-upload` · GET `/api/convert-status` · GET `/api/convert-download` · POST `/api/convert-delete` | 转换器：上传记录 fid → 进度/下载(302)/删除桥接 |
| GET | `/api/mctex-gallery` | 已完成材质图片墙（URL 带 token 供 AsyncImage 直接加载） |
| POST | `/api/scan-upload` · GET `/api/scans` · GET `/files/<名>` | 扫描王：JPEG+元数据头 → JSON + 本地扫描结果图库 |

鉴权同时接受查询串 `?token=`（AsyncImage / Safari 打开等无法带 header 的场景）。

## 服务器部署（已执行）

```bash
# 文件已就位：/opt/tools-hub/mobile/{mobile_gateway.py, plugins/*.json}
systemctl enable --now toolhub-mobile
systemctl status toolhub-mobile
cat /opt/tools-hub/mobile/token.txt   # 填进手机 App
```

验证：

```bash
curl http://127.0.0.1:7072/api/ping
curl -H "X-ToolHub-Token: $(cat /opt/tools-hub/mobile/token.txt)" http://127.0.0.1:7072/api/manifest
```

## 新增插件示例

在服务器 `/opt/tools-hub/mobile/plugins/` 新建 `my-plugin.json`：

```json
{
  "id": "my-plugin",
  "name": "我的插件",
  "icon": "🚀",
  "color": "#D97757",
  "type": "native",
  "pages": [{
    "title": "状态",
    "layout": [
      {"type": "stats", "endpoint": "/proxy/memclean/api/overview", "refresh": 10,
       "items": [{"label": "内存", "value": "$.mem.percent", "unit": "%"}]},
      {"type": "actions", "title": "操作", "actions": [
        {"label": "执行", "endpoint": "/proxy/scan/api/scan", "method": "POST"}
      ]}
    ]
  }]
}
```

保存即生效。手机端 30 秒内自动出现（或下拉刷新）。

## 已知事项

- **VNC 桌面聚合未收录**：noVNC 需要 WebSocket 裸转发，HTTP 反代不支持，请在电脑浏览器使用 `/vnc/`（手机端仅自动注册了 WebView 入口）
- **cad / zzz-cloud 保留 WebView**：3D 建模依赖 WebGL 实时画布、ZZZ 云端是 noVNC 游戏串流画面，均无法原生化（硬性限制），App 内 WebView 可正常使用
- AI 助手 / 相册找图的对话在网关侧把 SSE 流聚合为整段回复（App 无流式渲染），AI 执行多轮工具时回复可能需要等待数十秒
- 转换器下载 / mctex 画廊 / 扫描结果图片的 URL 均内嵌 token，仅限局域网使用
- 总控台 `/monitor/api/metrics` 接口本身有 bug（`'float' object has no attribute 'bytes_recv'`），原生监控页已改用 memclean/wiztree/scan 三个接口组合
- 网关为 HTTP 明文 + token，仅限局域网使用；若要公网暴露，请在 nginx 上加 HTTPS 反代 7072
