# Paster — macOS 原生剪贴板管理工具

一款 macOS 原生剪贴板历史工具。后台实时记录剪贴板，全局热键呼出面板，支持文本 / 富文本 / 图片 / 文件 / 链接，本地存储、不联网。

> 本工程通过多轮增量迭代完成 V1.0（macOS 端），代码全部基于上一轮成果扩展，未推翻重写。

## 功能特性

- **剪贴板历史持久化**：后台监听系统剪贴板，自动记录纯文本、富文本、图片、文件路径、URL；每条附带类型标签、时间戳、来源应用名称与图标；数据 100% 本地（SwiftData），不联网、不上传。
- **全局热键呼出**：默认 `⌘⇧V`，任意应用内呼出面板；**可在设置中自定义热键**；失焦自动隐藏，`Esc` 或再次按热键关闭。
- **呼出位置可选**：跟随光标悬浮、屏幕底部 / 顶部 / 左侧 / 右侧 / 中央，均带从对应边缘滑入的动画。
  - 选「底部 / 顶部」时为**全宽横向平铺条**，从屏幕边缘升起；横向条高度可通过**设置里的滑块（带可视化预览）**或**直接拖拽面板上边缘**调整，卡片内容随高度自适应放大；横向条内可用**鼠标滚轮 / 触控板左右切换选中项**。
  - 选「左侧 / 右侧」时为**占满屏幕高度的竖向侧栏**。
- **多模式粘贴**：保留原格式粘贴、纯文本粘贴（剥离格式）、重新复制；卡片右键菜单与键盘操作；**无格式粘贴快捷键可在设置中切换**（默认 `⌘⇧↩`）。
- **搜索与分类**：顶部实时关键词搜索、来源应用筛选；Pin 固定独立分组（Pinboard）置顶。
- **键盘全操作**：`↑↓`（横向条为 `←→`）选择、`Home`/`End` 跳到首/尾、回车粘贴、`⌘⇧↩` 无格式粘贴、`⌘⌫` 删除、`⌘P` 固定、`⌘Y` 全屏预览、`Esc` 关闭，呼出后搜索框自动聚焦。
- **隐私与配置**：排除应用列表（敏感应用不记录）、历史留存数量上限、一键清空、开机自启、菜单栏常驻。
- **体验**：卡片式布局、图片缩略图、悬停 / 选中动效、呼出滑入 / 升起动画、深色 / 浅色与多屏适配。
- **关于页**：应用简介与赞赏码（微信 / 支付宝 / PayPal）。

## 技术栈

| 项 | 选型 |
| --- | --- |
| 语言 | Swift 5+ |
| UI | SwiftUI 为主，AppKit 辅助（全局热键、剪贴板监听、状态栏、NSPanel） |
| 存储 | SwiftData（本地） |
| 架构 | MVVM 分层 |
| 最低系统 | macOS 14.0 |

## 工程结构

```
Paster/
  App/         PasterApp.swift（入口）, AppDelegate.swift（状态栏/热键/面板/预览/设置）
  Models/      ClipboardItem.swift（@Model）, ClipboardItemType.swift, PanelPosition.swift,
               PlainPasteShortcut.swift
  Services/    PersistenceManager.swift, ClipboardMonitor.swift, HotKeyManager.swift,
               PasteService.swift, AppSettings.swift
  ViewModels/  ClipboardViewModel.swift, SettingsViewModel.swift
  Views/       PanelRootView.swift, ClipboardCardView.swift, SearchBarView.swift,
               SettingsView.swift, PreviewView.swift, AboutView.swift, HotKeyRecorder.swift
  Window/      FloatingPanel.swift（NSPanel）
  Utilities/   ImageUtils.swift, AppIconProvider.swift, KeyCodeTranslator.swift
  Resources/   Assets.xcassets, Paster.entitlements, Paster.icns, Donate/（赞赏码）
scripts/       build_check.sh（编译/类型检查校验）, build_app.sh（手动打包 .app）,
               make_icon.swift / make_icns.swift（图标生成）
```

## 数据流

```
NSPasteboard --changeCount 轮询--> ClipboardMonitor --写入--> SwiftData
                                                              |
HotKey(⌘⇧V) --呼出--> FloatingPanel --PanelRootView(@Query)<--+
                                          |
                       回车/双击 --> 隐藏面板 -> 激活目标应用 -> PasteService 模拟 ⌘V
```

## 编译与运行

环境：macOS 14.0+，Xcode 16+。

1. 双击打开 `Paster.xcodeproj`。
2. 选择 `Paster` scheme，`⌘R` 运行。
3. 首次运行需授权：
   - **辅助功能**（系统设置 → 隐私与安全性 → 辅助功能）：用于模拟 `⌘V` 粘贴。
   - 应用以菜单栏图标常驻（无 Dock 图标），点击图标或按 `⌘⇧V` 呼出面板。

> 注意：每次重新打包（ad-hoc 签名会变化）后，系统可能要求**重新授权辅助功能**。若列表里已有旧的 Paster，请先移除再重新添加新的一份，否则模拟 `⌘V` 会被系统静默忽略（表现为只替换了剪贴板但没粘贴进去）。

### 命令行校验

```bash
bash scripts/build_check.sh
```

脚本优先调用 `xcodebuild` 完整构建；若当前机器的 Xcode 命令行工具异常（插件 / 私有框架损坏），自动回退到带 SwiftData 宏插件的 `swiftc -typecheck`，对全部源码做完整类型检查（含宏展开）。

### 打包为 .app

```bash
bash scripts/build_app.sh
```

直接用 `swiftc` 编译全部源码、组装 `build/Paster.app`（嵌入图标与赞赏码、ad-hoc 签名）并产出 `build/Paster.zip`。若图标在 Finder 未刷新，执行：

```bash
touch build/Paster.app && killall Finder Dock
```

## 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 呼出 / 隐藏面板 | `⌘⇧V`（可自定义） |
| 关闭面板 | `Esc` |
| 选择 | `↑` / `↓`（横向条 `←` / `→`，或鼠标滚轮 / 触控板） |
| 跳到首 / 尾 | `Home` / `End` |
| 粘贴选中项（保留格式） | `回车` |
| 无格式粘贴 | `⌘⇧↩`（可在设置中切换） |
| 删除选中项 | `⌘⌫` |
| 固定 / 取消固定 | `⌘P` |
| 全屏预览 | `⌘Y` |
| 打开设置 | `⌘,` |

## 隐私说明

所有剪贴板数据仅保存在本机 SwiftData 存储中，应用不发起任何网络请求。可在设置中将密码管理器等敏感应用加入排除列表，其复制内容不会被记录。

## 赞赏支持

如果觉得好用，欢迎请作者喝杯咖啡 ☕️

<table>
  <tr>
    <td align="center"><img src="Paster/Resources/Donate/donate_wechat.png" width="220" alt="微信支付"><br/>微信支付</td>
    <td align="center"><img src="Paster/Resources/Donate/donate_alipay.png" width="220" alt="支付宝"><br/>支付宝</td>
  </tr>
</table>

或通过 [PayPal](https://www.paypal.com/paypalme/yinxu0619) 支持。

## 路线图

- V1.0（本仓库）：macOS 原生版。
- V2.0（规划中）：Windows 11 版（WinUI 3 + C#），对齐 macOS 端核心功能与交互。

## License

MIT
