# LockIME-lite

LockIME 的精简重构版：全局输入法锁定守护进程 + 按需启动的设置面板。

## 架构

```
┌─────────────────────┐         ┌──────────────────────────┐
│  GUI（按需启动）      │         │  daemon（系统常驻）        │
│  LockIME-lite.app   │         │  lockime-lite-daemon     │
│                     │  写入→  │                          │
│  · 查看/修改配置      │ config.json │ 全局锁定引擎（TIS）      │
│  · 查看运行状态       │  ←读取  │  · 防自激抑制窗口          │
│  · 安装/停止/卸载服务 │  state  │  · 冲突退避               │
└─────────────────────┘         │  · 密码框豁免              │
        ↕ launchctl             │  · CJKV nudge            │
        └──────── LaunchAgent ──┘                          │
            RunAtLoad 随登录启动 / KeepAlive 崩溃自愈        │
```

- **GUI 不常驻**：只在打开时占用内存，关窗即退出。
- **daemon 常驻**：由 LaunchAgent 托管，纯 Objective-C，仅链 Foundation/AppKit/Carbon。

## 构建

```sh
./build.sh          # 产物在 build/LockIME-lite.app
open build/LockIME-lite.app
```

要求：macOS 14+，Xcode Command Line Tools（clang / swiftc）。

## 使用

1. 打开 GUI，选择锁定目标输入法，打开「启用」开关。
2. 点「安装并启动」→ 服务注册为 LaunchAgent，登录自动启动。
3. 「停止」暂停服务（保留安装）；「卸载」移除服务与 daemon。

**注意**：与原版 LockIME 或其他输入法管理器同时运行会互相冲突（触发退避机制）。启用 lite 前请先退出原版 LockIME。

## 与原版 LockIME 的取舍

保留：全局锁定、防自激、trailing reconcile、冲突退避、密码框豁免、CJKV nudge。
移除：per-app/URL 规则、增强模式（无需 Accessibility 授权）、9 语言 i18n、URL scheme 自动化、Sparkle 自动更新、第三方依赖（Sparkle / KeyboardShortcuts / PermissionFlow）、菜单栏常驻图标。

---

# LockIME-lite (English)

A minimal rewrite of LockIME: a global input-source lock daemon plus an on-demand settings GUI.

- **Daemon** (`lockime-lite-daemon`): pure Objective-C, links only Foundation/AppKit/Carbon. Event-driven via TIS notifications — no polling, no third-party deps. Runs as a per-user LaunchAgent (`RunAtLoad` + crash-restart `KeepAlive`).
- **GUI** (`LockIME-lite.app`): SwiftUI settings window. Only reads/writes `config.json` and `state.plist` and drives `launchctl` (install / start / stop / uninstall). Quits when the window closes.

Build & run:

```sh
./build.sh
open build/LockIME-lite.app
```

Requires macOS 14+ and Xcode Command Line Tools. Do not run alongside the original LockIME — the two lock engines will fight each other.

Kept: global lock, anti-echo suppression window, trailing reconcile, conflict backoff, secure-input exemption, CJKV nudge.
Removed: per-app/URL rules, enhanced mode (no Accessibility grant needed), 9-language i18n, URL-scheme automation, Sparkle auto-update, all third-party packages, menu-bar resident icon.

---

# LockIME-lite（繁體中文）

LockIME 精簡重構版：全域輸入法鎖定守護行程 + 按需啟動的設定面板。

- **守護行程**（`lockime-lite-daemon`）：純 Objective-C，僅連結 Foundation/AppKit/Carbon，採 TIS 事件驅動，零輪詢、零第三方依賴；以使用者級 LaunchAgent 託管（登入自動啟動、當機自動重啟）。
- **GUI**（`LockIME-lite.app`）：SwiftUI 設定視窗，僅負責讀寫 `config.json` / `state.plist` 與呼叫 `launchctl`（安裝／啟動／停止／解除安裝），關閉視窗即結束。

建置與執行：

```sh
./build.sh
open build/LockIME-lite.app
```

需求：macOS 14+ 與 Xcode Command Line Tools。請勿與原版 LockIME 同時執行，兩套鎖定引擎會互相衝突。

保留：全域鎖定、防自激抑制視窗、trailing reconcile、衝突退避、密碼框豁免、CJKV nudge。
移除：單一 App／URL 規則、增強模式（無需輔助使用授權）、九國語言、URL scheme 自動化、Sparkle 自動更新、全部第三方套件、常駐選單列圖示。
