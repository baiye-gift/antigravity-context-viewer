# Antigravity Context Viewer (`Telemetry Pod HUD`)

**100% 原生 Antigravity Sidecar 插件架构 · 免修改 `app.asar` · 零外部依赖**

一个专为 **Google Antigravity 2.x** 设计的无侵入上下文窗口与模型额度遥测插件。采用官方标准的 `plugin.json` + `sidecar.json` + `sidecar_sdk` 机制构建，**不改动客户端任何二进制/asar 文件**，客户端更新不失效；平时以紧凑挂件常驻于主窗口角落或标题栏，完全不占用右侧辅助栏空间。

> **English Summary:** A zero-dependency, non-invasive native Sidecar UI plugin for Google Antigravity 2.x. It tracks active context window usage, 5-hour quota & countdowns, and weekly quota status without patching `app.asar`. Features a docked glassmorphic Telemetry Pod HUD (bottom-left above Settings or top-center Dynamic Island pill) plus an optional on-demand side pane dashboard.

---

## 核心特性

### 1. 常驻不干扰的桌面挂件（零右侧栏占用）
- **Win32 附属窗体挂载**：通过 `WindowInteropHelper.Owner` 附着于 Antigravity 主窗口，随客户端自动最小化/恢复，切换至浏览器或聊天软件时**绝不遮挡其他窗口**。
- **两个黄金停靠位一键切换（`⇅`）**：
  - **左下角停靠（默认）**：紧贴左侧栏底部 `⚙ 设置` 按钮正上方（`204px` 宽），展开模型明细时自动向上生长，不遮挡任何按钮。
  - **顶部正中停靠**：一键切换为顶部标题栏正中央的“灵动岛”单行胶囊（`27px` 高），居中不干扰两侧菜单与窗口控制键。

### 2. Telemetry Pod 高级遥测视觉与实时状态
- **双环同心轨道仪表**：外环实时显示当前上下文窗口占用率，内环显示当前模型的 5 小时剩余额度。
- **活体推演卫星动画**：检测到会话日志近 8 秒内有写入（AI 正在思考或调用工具）时，发光卫星沿外环轨道平滑巡航并显示 **`⚡ 跃迁推演中...`**；空闲后自动零开销待机并动态切换状态文案（`✨ 算力充沛` / `🛸 反重力巡航` / `🚀 引擎高负载` / `🌡 核心升温 /compact` / `🔋 配额偏低`）。
- **14 段微缩光谱波形**：直观反映最近 14 步模型调用的上下文增长曲线。
- **10 格分段能量矩阵 + 5h/周额度**：直接调用 Language Server 本地接口 `GetUserStatus`（15s 缓存）匹配当前会话模型，展示 **5 小时剩余额度与刷新倒计时**、**周额度状态**；点击 **`▾`** 展开精选的各模型配额明细抽屉。
- **4 套玻璃拟态主题皮肤（`🎨`）**：`星际暗玻`、`赛博霓虹`、`琥珀机能`、`极光紫晶` 一键切换并自动保存偏好。

### 3. 可选侧边栏完整看板（极简模式 + 三标签深度分析）
平时可随时关闭右侧边栏；需要查看历史曲线或过往会话时，通过 `sidecar://context-viewer/viewer/` 按需打开：
- **极简模式（面板默认）** ↔ **完整模式**：
  - **概览**：上下文进度条（>=70% 提示 `/compact`）、5h 与周额度详情、缓存命中率、SVG 步进趋势图、内容构成字节占比。
  - **步进明细**：高频工具调用统计与每步模型调用的上下文增量（`+Δ` 超过 10K 高亮）。
  - **全局统计**：今日 / 近 7 天 / 全部历史用量、按模型汇总及最近 30 条历史会话快速切换。

---

## 快速安装

### 方式一：一行命令直接克隆到 Antigravity 插件目录（推荐）

在 PowerShell 中运行：

```powershell
git clone https://github.com/baiye-gift/antigravity-context-viewer.git "$HOME\.gemini\config\plugins\context-viewer"
```

### 方式二：下载仓库后双击安装

1. 克隆或下载本项目压缩包并解压；
2. 双击运行 **`install.bat`**（或在 PowerShell 执行 `.\install.ps1`），脚本会自动安装到 `%USERPROFILE%\.gemini\config\plugins\context-viewer\`；
3. 打开 Antigravity → **个性化定制（Customizations）** → 确认 **`context-viewer`** 为开启状态（若升级覆盖，切换一次「停用 → 启用」即可热重启后台），左下角挂件会自动出现。

> 如需在无 Sidecar 环境下单独预览挂件（仅显示上下文与本地记录），也可直接双击 `launch-capsule.bat`。

---

## 操作速查

| 操作 | 位置 | 作用 |
| :--- | :--- | :--- |
| 点击 `🎨` | 挂件顶栏 / 右键菜单 | 切换 4 套玻璃拟态皮肤（星际暗玻 / 赛博霓虹 / 琥珀机能 / 极光紫晶） |
| 点击 `⇅` | 挂件顶栏 / 右键菜单 | 一键切换停靠位置：**左下角（设置上方）** ↔ **顶部标题栏正中** |
| 点击 `/ 100万` | 挂件数值旁 / 右键菜单 | 循环切换上下文窗口上限（`128K` / `200K` / `256K` / `100万` / `200万`） |
| 点击 `▾` 或双击 | 挂件主体 | 展开/收起当前会话摘要与各模型 5h/周额度明细抽屉 |
| 右键菜单 | 挂件任意位置 | 切换停靠模式（含自由拖动）、皮肤、上下文上限、刷新配额或隐藏挂件 |
| 点击 `×` | 挂件顶栏 | 隐藏挂件（之后可在侧边栏面板点 `📌 唤醒挂件` 随时唤回） |

---

## 目录结构

```text
context-viewer/
├── plugin.json                  # Antigravity 官方插件清单
├── hud-overlay.ps1              # 纯 ASCII PowerShell + WPF Telemetry Pod 桌面挂件
├── install.ps1 / install.bat    # 一键安装/更新脚本
├── launch-capsule.bat           # 独立拉起挂件快捷入口
├── assets/logo.svg              # 插件图标
├── skills/context-viewer/       # 内置 Agent Skill（快捷唤起与管理指南）
└── sidecars/viewer/
    ├── sidecar.json             # Sidecar UI 注册配置（AUX_PANE）
    ├── main.mjs                 # Sidecar HTTP 服务与挂件进程托管
    ├── analyzer.mjs             # 只读本地 transcript.jsonl 上下文与历史分析引擎
    ├── quota.mjs                # Language Server GetUserStatus 5h/周额度解析器
    └── index.html               # 自包含单文件侧边栏界面（极简 + 完整三标签模式）
```

## 技术原理与隐私说明

- **只读本地日志**：上下文数据通过增量缓存解析本机 `<appData>/brain/<convId>/.system_generated/logs/transcript.jsonl`，不修改任何会话文件。
- **本地回环配额查询**：模型额度通过本机 Language Server 回环接口 `/exa.language_server_pb.LanguageServerService/GetUserStatus` 获取，不向任何第三方服务器发送数据。
- **零侵入生命周期**：由 Antigravity 官方 Sidecar 机制自动拉起与回收进程，不修改 `app.asar`、不注入客户端 DOM。

## License

[MIT](LICENSE) © 2026 [baiye-gift](https://github.com/baiye-gift)
