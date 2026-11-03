# Changelog

## Unreleased

- Add Xiaomi Buds 4 Pro support after hardware verification on macOS: connection, battery/charging for both buds and the case, noise/transparency and depth, six EQ presets, dual-device, auto-answer, find, gestures, spatial audio and wear/in-case state, with fresh readback for every write. 新增 Xiaomi Buds 4 Pro 实机支持：连接、左右耳/盒电量与充电、降噪/通透与深度、6 个 EQ 预设、双设备、自动接听、查找、手势、空间音频、佩戴/入盒；每次写入都重新读取确认。
- Keep the existing Xiaomi/Redmi family behavior unchanged: family detection, RCSP battery and low-latency state readback. The new MMA path is model-gated to Buds 4 Pro. 其他 Xiaomi/Redmi 型号保持系列识别、RCSP 电量及低延迟状态回读；新 MMA 路径只对 Buds 4 Pro 启用。
- Try the Fast Connect and XiaoAi SDP routes in order, including when a route times out, and explain the usual causes when neither opens. 依次尝试快连与小爱两条 SDP 路由，单条路由超时也会切换；两条都失败时说明常见原因。
- Filter the paired-device list by identity rather than by name: a known Audio/Video Class of Device is accepted, a known computer/phone/LAN/peripheral/imaging/wearable class is rejected, and an unknown class requires an A2DP Sink or Hands-Free record because Bluetooth LE peripherals report no class at all. 按设备身份而不是名称筛选已配对列表：Class of Device 为音频类时接受，为电脑/手机/局域网/外设/成像/穿戴时排除；类别未知（BLE 外设常见）时要求存在 A2DP Sink 或 Hands-Free 记录。
- Add a manual fallback listing the filtered devices, so a misjudged earbud can be added back and a misdetected device hidden; both choices persist across launches. 增加手动兜底：列出被过滤的设备，可把误判的耳机加回来、把误识别的设备隐藏，两种选择都会持久保存。

### 致谢 / Thanks

感谢以下项目分享小米 MMA 协议资料。 Thanks to these projects for documenting the Xiaomi MMA protocol:

- **XiaomiTWS**（[web1n/android_packages_apps_XiaomiTWS](https://github.com/web1n/android_packages_apps_XiaomiTWS)，Apache-2.0）：MMA 配置 ID 与佩戴／手势／查找／型号字段布局参考，未复制源代码。
- **TWS-Pods-PC**（[Zhaoyi-ya/TWS-Pods-PC](https://github.com/Zhaoyi-ya/TWS-Pods-PC)，GPL-3.0）：仅用于交叉核对 MMA 帧结构与配置语义，未复制源代码。

## 0.5.0 — 2026-10-26

新增 16 款耳机的初步支持，保留原有型号与功能。所有新增型号的 HeyBuds/macOS 实机兼容性仍待验证；具体功能取决于型号、固件和设备响应。

Initial support for 16 additional models, retaining existing models and features. HeyBuds/macOS hardware compatibility for all new models remains unverified; available controls depend on the model, firmware and device responses.

- **Samsung Galaxy Buds2 / Buds2 Pro / Buds4 Pro**：电量、降噪和预设 EQ；Buds2/2 Pro 触控锁，Buds4 Pro 降噪强度。 Battery, noise control and preset EQ; touch lock on Buds2/2 Pro and ANC strength on Buds4 Pro.
- **Google Pixel Buds Pro / Pro 2**：电量、降噪和五组 EQ 预设。 Battery, noise control and five EQ presets.
- **Bose QuietComfort 45 / QuietComfort Ultra Headphones (2nd Gen) / QuietComfort Ultra Earbuds (2nd Gen)**：电量、Quiet / Aware 模式及设备可确认的降噪级别。 Battery, Quiet / Aware modes and device-confirmed cancellation levels.
- **Nothing Ear (a) / Headphone (1) / CMF Buds 2 / Buds Pro 2**：电量、降噪与通透；预设 EQ 按型号及设备响应开放。 Battery and noise control; preset EQ where supported by the model and device responses.
- **Sony WH-1000XM3 / WH-1000XM4 / WH-XB910N / ULT WEAR**：电量、降噪、通透和语音聚焦；ULT WEAR 暂无通透强度调节。 Battery, noise control and Focus on Voice; ambient-level adjustment is unavailable on ULT WEAR.

### 致谢 / Thanks

感谢以下项目分享对应型号的协议资料与实现参考。 Thanks to these projects for model-specific protocol documentation and implementation references:

- **Samsung**：[Budsy](https://github.com/vedatkilic/budsy)、[GalaxyBudsClient](https://github.com/timschneeb/GalaxyBudsClient)。
- **Google**：[PixelBudsMacOS](https://github.com/KashaMalaga/PixelBudsMacOS)、[pbpctrl](https://github.com/qzed/pbpctrl)。
- **Bose**：[bosectl](https://github.com/aaronsb/bosectl)、[bozo](https://github.com/NerdySouth/bozo)、[bosectl-android](https://github.com/depau/bosectl-android)。
- **Nothing / CMF**：[swift-nothing-ear](https://github.com/bestK1ngArthur/swift-nothing-ear)、[nothing-x-macos](https://github.com/nikiomori/nothing-x-macos)、[openNothing](https://github.com/Evergaster/openNothing)（协议事实参考 / protocol facts）。
- **Sony**：[SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient)、[sonyctl](https://github.com/DaanHessen/sonyctl)（协议事实参考 / protocol facts）、[sony-ult-ctl](https://github.com/Leonard013/sony-ult-ctl)。


## 0.4.7 — 2026-10-25

- Add initial Sony WF-1000XM5, WH-1000XM5 and WH-CH720N support for battery, noise cancellation and ambient sound.
- Add ambient sound levels 1–20 and Focus on Voice for these Sony models. Real-device verification remains pending.
- Thanks to [SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient), [SonyBridge](https://github.com/AmitRajput-Dev/SonyBridge), [HeadBridge](https://github.com/herenickname/HeadBridge) and [Sony Device Center](https://github.com/marconvcm/sony-device-center) for Sony protocol and model references.

## 0.4.6 — 2026-10-25

- Fix noise, equalizer and sound settings being reported as successful without a valid response from the earbuds.
- Prevent connection conflicts during consecutive controls and improve cancellation and reconnection reliability.
- Fix busy indicators after switching earbuds and close outdated EQ editors when the device disconnects or changes.
- Restrict manual model selection to compatible devices to prevent incorrect connections.
- Fix missing low-battery notifications when switching between different earbuds.

## 0.4.5 — 2026-10-22

- Make the connection pop-up more compact with less top spacing and balanced battery columns.
- Align the dismiss button with the header, add a subtle circular background and move battery-loading status into the connection line.

## 0.4.4 — 2026-10-22

- Fix the menu-bar panel covering native update windows when checking for updates.
- Place Reconnect automatically above Background mode in General settings.

## 0.4.3 — 2026-10-22

- Fix switches briefly turning dark or bright when opening Settings by removing the whole-panel page transition.

## 0.4.2 — 2026-10-22

- Use the native popover material for connection cards, synchronize their appearance and smooth the dark-mode edges.
- Use consistent system text sizing and regular weight for settings labels and selected values.
- Replace nested picker menus with native popup controls containing only choices and selection marks; remove duplicate headings.

## 0.4.1 — 2026-10-22

- Combine the Settings footer into one row: app name and compact license, GitHub, diagnostics and Quit at the far right.
- Show Alipay QR codes for ¥5 / ¥10 / ¥20 / ¥50 and any amount, selected directly in the coffee support popover.

## 0.4.0 — 2026-10-22

- Provide a DMG installer that opens directly and supports dragging HeyBuds to Applications.
- Download and install updates in a native macOS window, with progress, cancellation and restart.
- Make Settings more compact, merge the version into the update action and move diagnostics to the bottom right.
- Use a small GitHub footer icon and a separate coffee support entry with Alipay amounts of ¥5 / ¥10 / ¥20 / ¥50, direct links and sharing to a phone.

## 0.3.4 — 2026-10-22

- Use circular glass back buttons across secondary pages.
- Move setting explanations into clickable information buttons beside their labels, with hover help and accessible descriptions. Keep help available when the model selector is disabled.

## 0.3.3 — 2026-10-22

- Add manual update checking, the GitHub project link and a text-only donation link to Diagnostics.
- Compare stable release versions numerically, show update-check failures clearly and open downloads only at the user's request.

## 0.3.2 — 2026-10-22

- Add OPPO Enco X4 (`06EC10`) and its Enco Bohr alias from EncoDeck, with the model's noise modes, EQ presets, ten-band custom EQ and existing sound/device controls.
- Recognize X4 parent/child noise reports and require a Hi-Res-off readback before enabling spatial audio. X4 adaptive noise uses the parent button; individual adaptive levels are not exposed.
- Remove Apple / Beats catalogs and passive advertisement support; macOS provides their native integration.
- Set the minimum deployment target to macOS 26 and update both READMEs, placing disconnected and connection pop-up previews first.
- Keep local agent instructions out of Git tracking and source releases. Preserve the X4 source excerpt and GPL notice.

### Thanks

Thanks to [EncoDeck](https://github.com/TIANLI0/EncoDeck) and its contributors for publishing the OPPO Enco X4 model configuration and protocol tests used for this adaptation.

## 0.3.1 — 2026-10-22

- Show the menu bar entry before background catalog loading; create the panel on first use.
- Index model names and aliases once and reuse the catalog during discovery.
- Reduce background discovery wakeups and omit the idle loading indicator.
- Strip release symbols, losslessly compress the icon, compact runtime catalogs, exclude reference-only data and keep developer preview/check code in debug builds.
- Simplify bilingual READMEs, consolidate compatibility/release notes and verify exact app/ZIP contents in CI.

## 0.3.0 — 2026-10-17

- Rename EncoBar to **HeyBuds**, including the app, Swift package and modules, resources, diagnostics and `heybuds-probe`.
- Use `local.heybuds.app` and migrate recognized legacy preferences once, without replacing existing HeyBuds settings.
- Preserve the native interface and the six brand backends from 0.2.0.
- Prepare a public source archive, bilingual documentation, contribution and release guides, issue templates and GitHub Actions.

## 0.2.0 — 2026-10-17

- Add vivo / iQOO, Huawei, Xiaomi / Redmi, Edifier and read-only Apple / Beats backends alongside OPPO / OnePlus / realme.
- Import 226 catalog records, including model IDs and family rules. Keep hardware-validation claims separate from catalog and simulated-protocol coverage.
- Validate 61 automated tests before the rename.
