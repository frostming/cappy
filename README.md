# Cappy

一个原生 macOS 截图应用：截完立刻标注、打码、加装饰，不用先保存。

菜单栏应用，使用 Swift + AppKit/SwiftUI + ScreenCaptureKit + Vision 编写，需要 macOS 14 或更高版本。

## 功能

| 功能 | 快捷键 | 说明 |
|---|---|---|
| 区域截图 | ⌃⌥1 | 拖拽框选；按空格切换到窗口模式 |
| 窗口截图 | ⌃⌥2 | 悬停高亮、点击截取 |
| 全屏截图 | ⌃⌥3 | 截鼠标所在的显示器 |
| 滚动长截图 | ⌃⌥4 | 框选区域后向下滚动（可自动滚动），自动拼接 |
| 截取文字 | ⌃⌥5 | 框选后把识别出的文字复制到剪贴板 |

截图后直接进入编辑器：

- **标注**：箭头、直线、矩形、椭圆、画笔、文字、马赛克
- **OCR**：识别中英文文字
- **智能马赛克**：自动给邮箱、电话、证件号、IP、密钥和人脸打码
- **装饰**：渐变 / 纯色 / 透明背景、颗粒噪点、留白、圆角、阴影、边框
- **最近截图**：保留最近 5 张截图及其标注，可随时重新编辑
- **画布**：滚轮缩放、按住空格拖拽平移

编辑完 ⌘C 复制或 ⌘S 保存。

## 安装

从 [Releases](../../releases) 下载 `Cappy.app.zip`，解压后拖到「应用程序」。

应用未经 Apple 公证，首次打开需要在 Finder 中右键选择「打开」，或执行：

```sh
xattr -dr com.apple.quarantine /Applications/Cappy.app
```

首次截图时系统会请求「屏幕录制」权限，授权后重新启动 Cappy。自动滚动另需「辅助功能」权限。

## 从源码构建

需要 Xcode 命令行工具（Swift 5.9+）。

```sh
./build.sh          # 生成 build/Cappy.app
open build/Cappy.app
```

默认使用临时签名，每次重新构建后屏幕录制权限会失效。设置 `CAPPY_SIGN_ID` 为固定的签名证书可以避免：

```sh
CAPPY_SIGN_ID="Apple Development: you@example.com" ./build.sh
```

离线自测（渲染、OCR、长图拼接、最近截图存储，不需要屏幕录制权限）：

```sh
build/Cappy.app/Contents/MacOS/Cappy --selftest /tmp/cappy-selftest
```
