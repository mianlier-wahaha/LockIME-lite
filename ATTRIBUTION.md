# 署名与许可说明 / Attribution & License / 署名與授權說明

## 图标来源 / App icon

LockIME-lite 的应用程序图标（`Resources/AppIcon.icns`）取自上游项目：

- **LockIME** — https://github.com/oomol-lab/LockIME
- Copyright © 2026 Hangzhou Wumou Software Co., Ltd.
- License: **GNU General Public License v3.0**

依据 GPL-3.0 第 5 条（Conveying Modified Source Versions）与第 4 条（Verbatim Copies），
本作品沿袭同一 GPL-3.0 许可进行分发，并在此保留原版权署名。
图标本身并未修改——原项目亦以程序化方式（SwiftUI 渲染）生成该图标。

Redistribution of the icon is permitted under GPL-3.0 §4/§5 with this notice retained.

本图标圖示取自 GPL-3.0 授權的 LockIME 專案，依同一授權轉載並保留原始著作權標示。

## 代码归属 / Code origin

`Sources/Daemon/main.m` 与 `Sources/GUI/LockIMELite.swift` 为本项目新撰写的实现，
但其中的核心机制（事件驱动的 TIS 输入源锁定、0.30s 抑制窗口、trailing reconcile、
冲突退避、macOS 安全输入豁免、CJKV 切换兜底）移植并简化了 LockIME 的实现思路，
故本项目整体上构成对 LockIME 的衍生作品，**整体以 GPL-3.0 授权发布**。

本项目与 LockIME 原作者无隶属关系，原作者对本项目不作任何担保。

This project is a derivative work of LockIME and is distributed under GPL-3.0 in whole.
