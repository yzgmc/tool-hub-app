# ToolHub iOS 客户端

SwiftUI 编写的服务器总控台手机客户端，Anthropic 主题（米白 + 赤陶橙），适配 iPhone 12 / iPhone 15（iOS 16+）。

## 构建安装（需一台 Mac）

1. 安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
2. 生成工程：
   ```bash
   cd ToolHubMobile
   xcodegen generate
   ```
3. 打开 `ToolHubMobile.xcodeproj`，插入 iPhone（USB，首次需在手机上信任开发者证书：设置 → 通用 → VPN与设备管理）
4. 顶部选择你的 iPhone 设备 → Run（⌘R）

无需配置签名团队也可以用免费 Apple ID（Xcode → Settings → Accounts 添加）。

## 使用

1. 首次打开进入配置页：
   - 服务器地址：`http://192.168.1.15:7072`
   - Token：见服务器 `/opt/tools-hub/mobile/token.txt`（运行 `sudo cat /opt/tools-hub/mobile/token.txt`）
2. 点「测试连接」→「保存并进入」
3. 主界面 4 个固定标签：总览 / 服务 / 插件 / 设置；清单里 `pinned: true` 的插件会追加为动态标签

## OTA 插件同步

App 本体是服务器驱动 UI 框架：

- 每 30 秒轮询 `/api/manifest/version`，版本变化自动拉新清单，界面即时更新
- 服务器新增插件 = 往 `/opt/tools-hub/mobile/plugins/` 丢一个 JSON，**不重启服务、不重装 App**
- 插件两种形态：
  - `"type": "native"`：JSON 声明页面布局（11 种组件，见下表），App 原生渲染
  - `"type": "web"`：内置 WebView 打开子应用（经 `/proxy/` 反代）

## 组件类型（WidgetSpec.type）

| type | 用途 | 关键字段 |
|---|---|---|
| `stats` | 指标网格（2 列） | `items[{label,value,unit}]` |
| `gauge` | 单值进度条 | `value` `max` `unit` |
| `chart` | 折线趋势图 | `value` `history` `unit` |
| `list` | 键值列表，支持行级操作按钮 | `item{title,subtitle,value,valueUnit,actions}` |
| `keyvalue` | 指定路径键值对 | `items["$.a.b", …]` |
| `auto` | 任意 JSON 自动平铺 | – |
| `actions` | 操作按钮组（可带确认） | `actions[{label,endpoint,method,confirm,style,body}]` |
| `chat` | AI 对话（历史回放 + 流式轮替） | `endpoint` `inputField` `response` `placeholder` `history{endpoint,role,content}` |
| `upload` | 文件 / 图片上传（multipart） | `endpoint` `fileParam` `accept`(`image`\|`any`) `fields` |
| `imagegrid` | 3 列图片墙 | `listPath` `urlPath` `titlePath` |
| `progress` | 任务进度轮询（完成自动停） | `value` `status` `refresh` |

行级操作：`list` 的 `item.actions` 里每个动作除通用字段外可声明
`paramFrom`（从行数据取值的路径）、`paramKey`（注入请求体的键名）、
`encoding: "form"`（表单编码发送），点按后带确认与结果弹窗，
适用于 qBittorrent 暂停/恢复这类单行控制。

## 代码结构

| 文件 | 职责 |
|---|---|
| `ToolHubApp.swift` | 入口，注入全局 SettingsStore |
| `Theme.swift` | Anthropic 主题常量 + 卡片样式 |
| `Models.swift` | manifest/overview 契约模型（宽容解码，缺字段不崩） |
| `JSONPath.swift` | `$.a.b.0.c` 取值 + 显示格式化 |
| `APIClient.swift` | 网关 API 客户端（async/await，401 识别、multipart 上传、表单编码） |
| `SettingsStore.swift` | 配置持久化 + 清单缓存 + OTA 同步逻辑 |
| `RootView.swift` | 首次配置页 / 主界面路由 |
| `MainTabView.swift` | 底部标签栏（4 固定 + 动态钉选）+ 30s 轮询 |
| `DashboardView.swift` | 子应用健康 + 外部服务快捷管理 |
| `ServicesView.swift` | 外部服务启停（带二次确认） |
| `PluginsView.swift` | 插件网格 |
| `PluginPageView.swift` | 原生插件页（分页 + widget 布局） |
| `Widgets.swift` | 11 种 widget 渲染器（含 list 行级操作） |
| `WebPluginView.swift` | WebView 插件容器 |

## 已知限制

- VNC 桌面插件未收录（noVNC 的 WebSocket 裸转发无法经 HTTP 反代）
- 语音录音等需要麦克风/HTTPS 的子应用功能在 WebView 内可能受限（iOS WebView 需 HTTPS 才开放 getUserMedia）
- App 固定浅色主题
