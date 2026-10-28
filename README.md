# ToolHub · 原生 iPhone 客户端

2.0 从头重写 SwiftUI 客户端，沿用本仓库和 iOS Build 工作流。首页展示全部工具，支持搜索、分类、收藏、即时刷新、服务启停及操作记录。没有内嵌网页。

## 连接与动态组件

在设置中填写手机可以访问的手机网关地址和令牌；令牌保存在本机钥匙串，不内置服务器凭据。网关源码唯一维护于 `yzgmc/tools-hub` 的 `mobile/` 和 `hub/mobile_native.py`，本仓库不再保存服务器参考副本。

App 从 `GET /api/v1/native/manifest` 读取 schemaVersion 2 清单，并从 `/api/v1/overview` 获取服务状态；使用 `X-ToolHub-Token` 认证。刷新时服务器同步读取总控台服务目录和原生插件配置；每次进入前台及前台每 30 秒也会刷新。刷新失败保留旧目录并明确提示，新增或删除工具无需重新安装 App。

原生页面支持 stats、gauge、chart、list、keyvalue、auto、actions、chat、upload、imagegrid、progress、form、notice。插件以本地 API 路径配置数据与操作；尚未配置原生页面的工具仍出现在目录中，明确显示待配置，外部服务可使用真实 API 启停。原始网页不会自动转为原生功能。

相机、系统照片选择器、文件选择器和系统分享面板用于上传与保存结果。请求不将令牌传给其他域名，不将带令牌的图片地址交给浏览器。

## 构建

`ios/ToolHubMobile/project.yml` 使用 XcodeGen，最低 iOS 17。iOS 26 及更新系统采用系统 Liquid Glass 导航与玻璃操作区域；旧系统和降低透明度模式提供材质回退，跟随系统深浅色。

运行仓库 Actions → iOS Build，或推送 ios/ 改动。工作流选择 Xcode 26.3，生成项目、编译真实设备 arm64 应用并上传未签名 IPA 和 SHA-256。下载后必须用有效开发证书与包含目标设备的描述文件在本地签名安装；不向 Actions 上传个人证书、账号、配对文件或生产令牌。

## 发布规则

源码与工作流可提交；IPA、截图、账号、令牌、私钥、描述文件、设备标识及测试日志只留本机。发布前检查差异并运行 `.git-redact/redact.py guard`，不得绕过敏感检查或强推。完整旧源码及 Git 历史保留本机；真实安装测试结果另行记录，不将编译通过当成真机验收。
