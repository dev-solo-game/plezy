# 上游同步审查与合入记录（Upstream Sync Log）

- **上游仓库（`upstream`）**：<https://github.com/edde746/plezy.git>
- **当前分叉基线**：`77f11b86f`（Tag `2.26.0`）
- **同步策略**：由于本仓库进行了本地媒体库、网盘/SMB/WebDAV 挂载、扫描刮削及多端同步等深度二开，不直接合并 `upstream/main`，而是定期通过 `git cherry-pick -x` 择优合入通用的播放器性能、帧率切换、UI/遥控器交互及分页等修复，并在此记录每次审查范围、合入结果与跳过原因。

## 后续增量审查命令速查

每次准备检查上游新提交时，可运行以下命令查看自上次已审查终点以来的新增提交：

```powershell
git fetch upstream --tags
git log 02eeba697..upstream/main --oneline
```

---

## 第 1 批审查记录（2026-11-18）

- **审查范围**：`77f11b86f..02eeba697`（共 18 个上游提交）
- **上次已审查终点**：`02eeba697`（2026-11-16）

### 1. 已合入提交（Cherry-picked，共 5 个）

| 合入日期 | 上游 Commit | 本地 `main` Commit | 提交标题 | 合入原因与影响模块 |
| --- | --- | --- | --- | --- |
| 2026-11-18 | `4c3c25b82` | `120f818f6` | `perf(player): leave mpv's unused builtin scripts unloaded on Android (#3035)` | Android 初始化 mpv 前禁用 7 个无用内置 Lua 脚本，降低内存与首帧开销（`MpvPlayerCore.kt`） |
| 2026-11-18 | `3bf8c2752` | `06f7d51e9` | `perf(player): give downloads in app storage a demuxer read-ahead hysteresis (#3033)` | 本地离线下载播放设置 `demuxer-hysteresis-secs=0.5`，减少解复用唤醒 CPU 占用（`playback_open.dart`、`video_player_screen.dart`、`stream_buffer_sizing.dart`） |
| 2026-11-18 | `891600029` | `0cc3d62d5` | `fix(paging): stop re-requesting the end of a library whose count outruns its items` | 防止服务端返回总数大于实际条目时尾部空页死循环重刷（`paginated_item_loader.dart`） |
| 2026-11-18 | `e883c3ca5` | `ad15ee496` | `feat(player): switch 25/30 fps content to 50/60 Hz instead of 25/30 Hz` | 25/30fps 与 25i 内容倍频匹配 50/60Hz，改善 OSD/字幕流畅度并减少 HDMI 切换卡顿（`DisplayModeSelector.kt`、`display_mode_service.dart`） |
| 2026-11-18 | `408da1ab8` | `bebccd537` | `fix(player): keep the remote working when a reload unmounts the focused control` | 修复 TV 屏保恢复或切换画质重载时控件卸载导致的遥控器方向键/OK 失灵（`visibility.dart`、`video_controls.dart`） |

### 2. 已审查并跳过提交（Skipped，共 13 个）

| 上游 Commit | 提交标题 | 跳过原因 |
| --- | --- | --- |
| `847842c3d` | `perf(player): give mpv a constant title on iOS and tvOS (#3032)` | iOS/tvOS 专属优化；当前首版平台不含 iOS/tvOS，且在 `ios/RunnerTests/RunnerTests.swift` 存在冲突 |
| `e8074c452` | `perf(ios): activate the audio session while the video core is created (#3034)` | iOS/tvOS 专属音频会话优化，暂不涉及 |
| `8cda18705` | `fix(ios): start Picture in Picture on a tap that also creates its controller` | iOS 专属画中画修复，暂不涉及 |
| `ca916ebb2` | `fix(player): arm auto-PiP when a Live TV channel starts` | Live TV 直播自动画中画修复，当前未使用 Live TV |
| `10bcdf38f` | `fix(livetv): re-check Live TV access after a Plex Home profile switch` | Plex Home + Live TV 专属修复，二开已停用 Plex 登录 |
| `4640404ce` | `fix(plex): retry a server that was unreachable at launch instead of waiting for Reconnect` | Plex 服务器专属退避重连（原提交已明确将 MediaBrowser/Jellyfin 排除在外），二开已停用 Plex |
| `b17944045` | `fix(plex): keep a server's client when it reconnects from offline` | Plex 服务器重连复用客户端修复，二开已停用 Plex |
| `a4f1b4f31` | `fix(player): strip every Samsung HDR10+ message before the Fire TV DV decoder` | 仅针对 Fire TV Stick 4K Max 上 ExoPlayer 播放特定混合片源黑屏；暂未用到，后续若需可单独补合 |
| `a597bcbee` | `fix(search): rank an artist's albums above titles that merely contain the artist` | 音乐库专辑搜索权重修复；二开首版暂未接入音乐库 |
| `d78b6d806` | `fix(watch-together): create and join rooms when the package version is unreadable` | Linux 分包环境下 Watch Together 的版本号回退，改动波及 Jellyfin/Simkl/日志多处且当前不依赖该场景 |
| `b478fbc7c` | `chore(release): install the macOS app from the official Homebrew cask` | 上游官方 Homebrew Cask 发布迁移，与二开自用分发无关 |
| `36f9ae3e3` | `ci(ios): build the GitHub IPA with Xcode 27.1 so it is optimized for iPhone Duo` | 上游 GitHub Actions iOS 打包 CI 配置 |
| `02eeba697` | `fix(profiles): keep PIN-protected profiles off the TV home screen shelf while asking for a profile on open` | 原版多用户档案（Profile）+ 4 位 PIN 密码锁在 TV 桌面推荐栏的隐私修复；二开版不需要此功能（见下文说明） |

---

## 专项说明：什么是 Profile PIN 以及二开版为何不需要

1. **原版中的 PIN 是什么**：
   - 在上游原版 Plezy 中，同一个电视或客户端可以创建多个本地用户档案（`LocalProfile`），或绑定多个 Plex Home 家庭成员（`PlexHomeProfile`）。
   - 用户可以在 [profile_detail_screen.dart](../lib/screens/profile/profile_detail_screen.dart#L314-L333) 中为本地 Profile 设置一个 **4 位数字 PIN 密码锁**（哈希保存在 `pinHash` 字段），并配合设置项 `requireProfileSelectionOnOpen`（“打开应用时选择用户资料”）以及 [pin_entry_dialog.dart](../lib/screens/profile/pin_entry_dialog.dart)，防止家里其他成员在电视上随意切入受保护的个人 Profile（比如家长控制或隐私隔离）。
   - 上游提交 `02eeba697` 修复的是：即便设置了 PIN 和“启动时选择用户资料”，Apple TV Top Shelf / Android TV Watch Next 桌面推荐栏仍会显示该受保护 Profile 的“继续观看”内容。

2. **二开版是否需要 PIN**：
   - **不需要**。在二开版的提交 `09d8c9163` 中，首页右上角菜单与设置页已经将原有的“多 Profile 管理/切换入口（`ProfileSwitchScreen`）”改造为**多端账号同步与局域网设备管理**，本地媒体库、挂载源和播放记录都运行在单默认工作区（或同步账号作用域）下。
   - **当前代码保留情况**：底层 `profiles` 表、`pin_entry_dialog.dart`、`ProfileSwitchScreen` 及 `requireProfileSelectionOnOpen` 设置项目前仍在代码中保留作为启动/连接绑定过渡层（见 [fork-plan.md](fork-plan.md#L177)），但普通用户界面已不再暴露本地多 Profile 与 PIN 设置入口。因此本次直接跳过 `02eeba697` 即可；如果将来阶段 6 彻底清理旧 Profile UI，可连带移除 [pin_entry_dialog.dart](../lib/screens/profile/pin_entry_dialog.dart)、[profile_switch_screen.dart](../lib/screens/profile/profile_switch_screen.dart) 及相关设置项。
