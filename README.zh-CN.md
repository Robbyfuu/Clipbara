<p align="center">
  <img src="Copyd/Resources/Assets.xcassets/AppIcon.appiconset/256.png" width="128" height="128" alt="Copyd 图标">
</p>

<h1 align="center">Copyd</h1>

<p align="center">
  <strong>免费开源的 macOS 原生剪贴板管理器</strong>
  <br>
  卡片式界面类似付费应用 Paste，数据完全本地存储。
</p>

<p align="center">
  <a href="README.md">English</a> | 简体中文
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Robbyfuu/Clipbara?style=flat-square" alt="许可证"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square" alt="macOS 14+">
</p>

## 简介

Copyd 是一款免费开源（GPL-3.0）的 macOS 剪贴板管理器，用原生 Swift 6 + SwiftUI 编写，卡片式界面类似付费应用 Paste。数据完全本地存储，无账号、无服务器、无遥测。

## 主要功能

- **卡片式剪贴板历史**：支持文本、富文本、HTML、图片、链接、文件、颜色和代码片段
- **不打断工作流**：`⌘⇧V` 唤出非激活面板，当前应用保持焦点；单击卡片即复制到剪贴板并自动收起面板，回到当前应用直接 `⌘V` 粘贴
- **Pinboards 收藏夹**：把常用内容整理成命名收藏夹，支持拖拽排序
- **快速预览**：按 `空格` 进行 Quick Look 预览，支持全键盘操作
- **隐私控制**：可排除指定应用（如密码管理器），历史上限可配置、自动清理
- **对终端友好**：图片以 PNG + file URL 方式写入剪贴板，可以可靠地粘贴到 Ghostty / iTerm2（详见下方[终端中的图片剪贴](#终端中的图片剪贴)）
- **完全本地**：基于 SwiftData 本地存储，不包含更新组件

## 安装

要求 **macOS 14 Sonoma 或更高版本**。

### 从源码构建

需要 Xcode 16 或更高版本和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
git clone https://github.com/Robbyfuu/Clipbara.git ~/Code/Copyd && cd ~/Code/Copyd
brew install xcodegen
xcodegen generate
xcodebuild -project Copyd.xcodeproj -scheme Copyd -configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates build
open -n "$PWD/DerivedData/Build/Products/Debug/Copyd.app"
```

也可以打开 `Copyd.xcodeproj`，选择 `Copyd` scheme 后按 `⌘ R` 运行。

### Mac App Store

App Store 版本即将推出。

## 终端中的图片剪贴

选择图片剪贴项会把图片重新放回 macOS 剪贴板，但 shell 提示符本身无法接收图片数据。必须由终端中运行的应用或 CLI 支持剪贴板图片输入。

以 macOS 上的 Codex CLI 为例：

1. 按 `⌘ ⇧ V` 并选择需要复用的图片剪贴项。
2. 回到 Codex，中途不要再复制其他内容。
3. 在 Codex 中按 `Control + V` 附加剪贴板图片。

Codex 使用 `Control + V` 附加图片，而不是 macOS 常用的 `⌘ V` 文本粘贴快捷键。其他终端应用可能有不同的图片粘贴方式。

## 更多内容

键盘快捷键、隐私说明、参与贡献等完整文档请参阅 [英文 README](README.md)。

## 许可证

Copyd is a fork of [Clipbara](https://github.com/mobrava/Clipbara) by mobrava, licensed under GPL-3.0. 详见 [LICENSE](LICENSE)。
