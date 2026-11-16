# Plezy 新版 UI 重设计思路与工程落地建议（Vidu / VidHub × Infuse）

## 1. 为什么选「Infuse + VidHub」作为参考方向？

对比当前工程的 `lib/theme/mono_theme.dart` 与 16 张实机截图（已归档至 `screenshots/`），原版 Plezy 采用的是 **Material 3 Expressive Monochrome** 极简黑白灰设计：
- **优点**：克制、统一、D-Pad 焦点系统（`lib/focus/`）非常扎实。
- **短板**：
  1. **缺少影院层次感**：全黑/灰纯色表面 + 纯白实心按钮（如首页 Play 胶囊、海报右上角纯白圆标 `87`）在视觉上偏硬、偏工具化，缺少 Infuse 那种「海报与剧照才是主角、UI 退居半透明液态毛玻璃」的通透感。
  2. **多源与刮削能力缺少视觉舞台**：你的分支已不再是单纯的 Plex 客户端，而是集成了 **本地/SMB/WebDAV/夸克网盘挂载 + TMDB/Bangumi/豆瓣刮削 + 未匹配人工纠偏 + Emby/Jellyfin 兼容** 的全能播放器。原版基于 M3 `ListTile` 的 `mounts_screen.dart` 与 `scraper_settings_screen.dart` 无法撑起核心卖点。
  3. **跨平台导航差异化不足**：Tablet 仍用底部栏（`tablet-home.png`），Desktop 窄图标侧栏看不出「本地五大分类 vs 外部 Emby 服务器」的层级关系。

因此，建议采用 **Infuse 的影院视觉质感** + **VidHub 的网盘/多源组织效率**，形成 **Cinematic Liquid Glass（影院级液态毛玻璃）** 体系。

---

## 2. 核心设计升级点（6 大维度）

### ① 材质与色彩系统（对应 `MonoTokens` / `MonoTheme`）
- **背景与表面**：保留深空影院暗底 `#0B0D12`（OLED 可选纯黑 `#000000`），所有悬浮栏、筛选胶囊、播放 HUD、设置卡片升级为半透明毛玻璃（`rgba(20,23,32,0.62)` + `BackdropFilter` 20–32px + `1px rgba(255,255,255,0.14)` 描边）。
- **海报微章降噪**：将现版刺眼的纯白圆形集数角标（`87`）替换为**暗色半透明毛玻璃胶囊**，仅在必要时于左上角叠加极小来源角标（`夸克` / `SMB` / `Emby`）。
- **语义化技术徽章**：仅在 Hero、详情页与播放器浮标集中展示 `4K`、`Dolby Vision`、`HDR10`、`Atmos`、`TMDB / 豆瓣评分`，保持海报墙本身的纯净度。

### ② 四端自适应导航模型（对应 `main_screen.dart` / `side_navigation_rail.dart`）
| 平台 | 现版形态 | 新版推荐形态 |
| --- | --- | --- |
| **Desktop** (`Windows/macOS/Linux`) | 纯图标窄黑条 | **可折叠毛玻璃树状侧栏**：顶部常用（首页/搜索/媒体源/下载）+ 本地五大库（电影/电视剧/动漫/综艺/纪录片/未匹配）+ 外部 Emby/Jellyfin |
| **Tablet** (`iPadOS/Android 平板`) | 与手机同款底部黑栏 | **紧凑毛玻璃侧栏 Rail + 顶部胶囊切换栏**，充分利用横向宽度 |
| **Mobile** (`iOS/Android`) | 不透明黑色底部栏 | **底部悬浮圆角毛玻璃 Dock**（参考 iOS 26 / Infuse 风格），释放底部安全区视野 |
| **TV** (`Android TV/tvOS`) | 左侧常驻图标条 | **顶部自动收起毛玻璃胶囊栏** + `1.06x` 焦点放大 & 发光白边 + 焦点卡片随动切换全屏剧照 |

### ③ 核心业务页面升级
1. **首页 (`01-home-discover.html`)**：Hero 区域增加左下角径向暗角渐变遮罩，解决亮色剧照下白色 Logo 看不清的问题；继续观看使用 16:9 横图 + 底部发光进度条；最近新增按本地分类与 Emby 独立成栏。
2. **媒体库 (`02-library-browse.html`)**：支持顶部「来源过滤（全部 / 夸克 / SMB / WebDAV / Emby）」，若存在刮削失败的条目，顶部显示轻量 Amber 提醒条一键跳转「未匹配纠偏」。
3. **影视详情页 (`03-media-detail.html`)**：Infuse 招牌双层设计（全幅剧照 + 悬浮竖版海报），在 Play 按钮上方显性提供 **多源/多版本切换胶囊**（如 `☁ 夸克 4K DV` vs `📁 SMB 1080p`），并展示视频编码/音轨/刮削数据源详情。
4. **播放器 (`04-video-player.html`)**：采用居中悬浮毛玻璃控制胶囊（代替整行黑底控制栏），右上角展示实时解码与流来源徽章，支持 `⏭ 跳过片头` 悬浮胶囊与右侧半透明音轨/字幕/倍速抽屉。
5. **存储挂载与刮削中心 (`06-storage-sources.html`)**：参考 VidHub 把 `mounts_screen.dart` 重构为可视化源卡片网格，明确显示夸克扫码授权状态、限速/增量扫描配置、TMDB/Bangumi/豆瓣连通性状态，并内嵌「未匹配文件人工纠偏队列」；TV 端默认提供夸克扫码大卡片。
6. **下载 / 设置 / 工作区切换 (`07-downloads-settings-profile.html`)**：下载页增加设备缓存占用条与多线程速度显示；设置页升级为双栏分组毛玻璃卡片；Profile 切换页改为影院居中大头像卡片，清晰标注每个工作区绑定的挂载源与 PIN 锁。

---

## 3. Flutter 工程落地建议（分阶段）

1. **Phase 1 · 扩展 Design Tokens（低风险）**
   - 在 `lib/theme/mono_tokens.dart` 新增 `glassSurface`、`glassBorder`、`glassBlurSigma`、`badgeBg`、`focusGlowColor` 等字段，保留原有 `MonoPalette` 8 套配色作为底层色板。
2. **Phase 2 · 抽取通用毛玻璃原语组件**
   - 新建 `GlassContainer` / `GlassPill` / `SpecBadge`（在 TV 与低性能设备可通过 `DevicePerformance` 开关动态降级 `BackdropFilter` 为半透明纯色以保 60fps）。
3. **Phase 3 · 重构重点高频页面**
   - 优先改造最显性的 3 个界面：**影视详情页（加多版本胶囊与媒体信息条）** → **媒体源与刮削中心（替换当前 640px 列表）** → **首页 Hero 与播放器悬浮胶囊 HUD**。
4. **Phase 4 · 平板与手机悬浮导航适配**
   - 调整 `lib/screens/main_screen.dart` 与 `lib/widgets/mobile_navigation_rail.dart`，让 Mobile 采用悬浮圆角胶囊底栏，Tablet 采用紧凑 Rail + 顶部胶囊。
