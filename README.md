# LolPing

[![Release](https://img.shields.io/github/v/release/icloudza/lol-ping)](https://github.com/icloudza/lol-ping/releases/latest)
![Platform](https://img.shields.io/badge/macOS-14%2B-blue)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**League of Legends ping wheel and emotes for the macOS desktop.**

把英雄联盟的信号轮盘和表情带到 macOS 桌面：在任何应用、任何显示器上发信号，并和朋友在同一个房间里互相看到。

原生 Swift 菜单栏应用（AppKit · SwiftUI · Core Animation），支持 Apple 芯片与 Intel。

## 功能

- **信号轮盘**：按住 ⌥ 拖动，在扇区上松开，信号带着动画和音效出现在光标处。
- **表情轮盘**：按住 ⌃ 拖动，可添加自己的图片（PNG、JPG、GIF、WebP）。
- **房间**：凭房间码加入，局域网直连或经互联网中继，内容端到端加密；与 [darrenprx/lolPing](https://github.com/darrenprx/lolPing) 的 Windows / Mac 客户端互通。
- **按键全部可改**：轮盘触发键支持修饰键组合、任意按键、鼠标侧键；暂停、静音、直接发送某个信号或表情都可绑定全局快捷键。
- **多显示器**、中英文界面、登录时启动。

## 安装

1. 从 [Releases](https://github.com/icloudza/lol-ping/releases/latest) 下载 `LolPing-<版本>.dmg`，把 LolPing 拖进“应用程序”。
2. 首次启动时，在 **系统设置 → 隐私与安全性 → 辅助功能** 中允许 LolPing。

需要 macOS 14 或更新版本，支持 Apple 芯片与 Intel。

## 默认按键

| 操作 | 按键 |
| --- | --- |
| 发信号 | 按住 **⌥** 拖动，在扇区上松开 |
| 发表情 | 按住 **⌃** 拖动，在表情上松开 |
| 取消 | 在中心松开、点右键或按 **Esc** |
| 暂停 / 恢复 | **⌃⌥P** |

在 **设置 → 快捷键** 中修改。

## 构建

需要 Xcode 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。工程文件由 `project.yml` 生成，增删源文件后重新生成。

```bash
xcodegen generate
```

```bash
xcodebuild -project LolPing.xcodeproj -scheme LolPing -configuration Release -derivedDataPath build build
```

测试：

```bash
swift test --package-path Packages/LPCore
```

```bash
swift test --package-path Packages/LPRooms
```

Debug 配置构建的是 **LolPing-Dev**（`com.cloudza.LolPing.dev`），设置和辅助功能授权与正式版互相独立。

## 项目结构

| 位置 | 内容 |
| --- | --- |
| `App/` | 应用本体：事件监听、置顶覆盖层与动画、音效、菜单栏、设置界面、文案 |
| `Packages/LPCore` | 手势识别、按键模型、偏好设置、信号与表情目录 |
| `Packages/LPRooms` | 房间协议、加密、局域网 UDP、Nostr 中继 |
| `Scripts/release/` | 发布脚本，说明见 [Scripts/release/README.md](Scripts/release/README.md) |

## 发布

推送 `vX.Y.Z` 标签后，GitHub Actions 自动测试、签名、公证、打包 DMG 并创建 Release。应用会检查本仓库的最新 Release，有新版本时提醒，不会自动下载或安装。

## 友情链接

- [LINUX DO](https://linux.do)

## 许可证

代码采用 [MIT 许可证](LICENSE)。`Packages/LPRooms` 移植自 [darrenprx/lolPing](https://github.com/darrenprx/lolPing)（© Danrui Meng，MIT）。

`App/Resources` 中的信号图标、表情和音效版权归 Riot Games 所有，不在 MIT 许可范围内，详见 [NOTICE.md](NOTICE.md)。

LolPing isn't endorsed by Riot Games and doesn't reflect the views or opinions of Riot Games or anyone officially involved in producing or managing Riot Games properties. Riot Games, and all associated properties are trademarks or registered trademarks of Riot Games, Inc.
