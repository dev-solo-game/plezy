# 夸克网盘全盘扫描与增量更新方案说明

- **日期**：2026-11-13
- **涉及模块**：
  - `lib/storage/drivers/quark_storage_driver.dart`
  - `lib/library/library_scanner.dart`
  - `lib/library/library_scan_service.dart`
  - `lib/database/app_database.dart`

---

## 1. 背景与现状分析

### 1.1 当前扫描机制的局限性
目前 Plezy 的 `LibraryScanner` 虽然在**数据库写入与刮削层面**实现了增量（文件未变更时不重复刮削），但在**网盘文件列表遍历层面依然是全量深度优先遍历（DFS）**：
- 每次触发扫库，都必须从挂载根目录开始，递归调用 `/file/sort` 遍历所有层级的每一个子文件夹；
- 当网盘内积累了数百上千个影视文件夹时，单次扫库需要发起数百次 API 请求，结合 `RequestThrottle` 节流控制，耗时动辄数分钟；
- 高频全量遍历容易消耗大量无效请求配额，也无法实现“打开客户端即秒级上新”的体验。

### 1.2 核心目标
设计一套**“全盘初始化 + 秒级增量更新 + 低频全量兜底”**的混合扫描方案：
- 日常追剧上新：通过夸克官方更新时间接口，仅用 **1~2 次请求（约 1 秒内）** 精准获取全部新入库或变更的影视文件；
- 长期准确性：兼顾重命名、移动目录、以及被删除文件的清理。

---

## 2. 夸克网盘增量接口实测结论

通过真实已登录账号的 PC 端凭证直接调用夸克 API 进行探测，得出以下关键实测结论：

### 2.1 可用的增量接口：`/file/search` 全盘时间倒序
- **接口地址**：`GET https://drive-pc.quark.cn/1/clouddrive/file/search`
- **关键参数**：
  - `q`: `""`（空字符串，检索全盘）
  - `_sort`: `updated_at:desc`（按服务端修改时间倒序排列）
  - `_size`: `100`（单页条数）
  - `_page`: `1, 2, ...`（支持深度翻页回溯，实测全盘 4,600 条文件时 `_page=5` 仍正常返回 `code: 0`）
- **其他探测结果（不可用/有缺陷）**：
  - `/file/recent`：返回 HTTP 404（无此接口）；
  - `/file/sync/list`：返回 HTTP 400（参数/业务不适用）；
  - 目录级 `updated_at` 剪枝：实测发现深层子目录新增剧集时，顶层父目录的 `updated_at` **并不总是实时冒泡更新**，直接拿顶层目录时间戳做剪枝会导致漏扫新剧集；
  - `category=1` 过滤：实测 `/file/search` 会忽略 `category` 参数（依然返回全盘所有类型），需由客户端在内存中进行后缀过滤。

### 2.2 夸克 `updated_at` 时间戳标准验证
通过对比实测返回的 4 个时间字段：
```text
走马上任 - S01E24 - 第 24 集.mkv
  updated_at  : 2026-11-12 19:48:46  <-- 转存/上传到当前网盘的服务器时间
  created_at  : 2026-11-12 19:48:46  <-- 在当前网盘创建的时间
  l_updated_at: 2026-11-12 19:47:33  <-- 原文件自身修改时间
  operated_at : 2026-11-12 19:48:46  <-- 最近操作时间
```
> **实测验证**：即使是几年前拍摄的照片（如 `IMG_20230429_152657.jpg`）或几十年前的老电影，只要近期转存/上传进当前网盘，其 `updated_at` 就是**转存/上传这一刻的服务器时间**，并会排在列表最前列。

**触发 `updated_at` 更新的操作包括**：
1. 新上传、手机备份、离线下载完成入盘；
2. 通过分享链接**转存**进网盘；
3. 在网盘内对文件进行**重命名**或**移动目录**。

---

## 3. “全盘 + 增量”核心架构设计

采用工业界标准的 **服务端高水位线（High-Watermark）** 模型：

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 1. 首次挂载 / 低频兜底：全盘扫描 (Full Scan)                              │
│    - 开始前先调 /file/search?_size=1 记下当前服务端最新 updated_at = T0  │
│    - 递归遍历挂载根目录，全量入库并清理已从网盘删除的幽灵记录               │
│    - 成功完成后，将本地记录的增量水位线 watermark 置为 T0                   │
└────────────────────────────────────┬────────────────────────────────────┘
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 2. 日常刷新 / 打开 App：秒级增量 (Incremental Scan)                       │
│    - 从 _page=1 开始拉取 /file/search?q=&_size=100&_sort=updated_at:desc │
│    - 计算安全截断线：threshold = watermark - 60,000ms (回溯 60 秒)        │
│    - 遇到 updated_at < threshold 立即停止翻页                            │
│    - 对拉取到的文件做：类型过滤 -> 挂载根目录归属校验 -> 写入/更新 DB       │
│    - 全部顺利完成后，将第 1 页第 1 条的 updated_at 更新为新的 watermark    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 4. 关键工程细节与防坑指南

### 4.1 严禁使用客户端本地时间作为基准
- **错误做法**：在扫描结束时记录 `DateTime.now()`。若用户电脑时钟比夸克服务器快几分钟，或全量扫描期间有新文件转存，都会导致新文件被永久跳过。
- **正确做法**：
  - 全程只比较**服务端返回的 `updated_at`**；
  - 全量扫描**开始前**先抓一次服务端最新 `updated_at` 作为初始 `watermark`（扫描期间的新文件会在下次增量时被安全补捞）；
  - 每次增量成功结束时，更新为本次拉取到的**最大 `updated_at`**（即第 1 页第 1 条）。

### 4.2 60 秒安全重叠窗口（防同秒批量转存漏集）
- 一次性转存一整部 40 集电视剧时，多集可能拥有完全相同的毫秒/秒级 `updated_at`，且可能刚好横跨分页边界。
- 停止条件设置为 `updated_at < (watermark - 60 * 1000)`，多回溯 60 秒数据，再利用数据库已有文件的 `remote_id` (`fid`) 与 `updated_at` 做精确幂等去重，**既保证绝不漏集，也不会重复刮削**。

### 4.3 全盘数据过滤与挂载目录归属校验
由于 `/file/search` 返回的是整个夸克账号下的文件（包含相册、文档等非挂载目录数据），且单条数据只包含直接父目录 `pdir_fid` 而无完整路径，入库前需执行三步过滤：
1. **媒体类型过滤**：跳过 `dir == true` 的文件夹；仅保留 `videoExtensions` 与 `subtitleExtensions` 匹配的后缀；
2. **目录归属还原与校验**：
   - 维护本地文件夹映射表（`folder_fid -> (parent_fid, folder_name, full_path)`）；
   - 拿到文件的 `pdir_fid` 后查表：若命中已知的挂载子树路径，直接拼出完整路径；
   - 若遇到新建的未知文件夹 `pdir_fid`，沿父目录向上回溯查询（利用夸克路径查询或目录接口），判断其祖先是否命中用户配置的挂载根目录（`rootFolderId`）。若不在挂载根目录下则直接丢弃。
3. **新增 vs 移动/重命名判定**：
   - `fid` 不在本地 `library_files` $\rightarrow$ 新增入库并触发刮削；
   - `fid` 已存在但 `path` 或 `name` 变化 $\rightarrow$ 原地更新文件路径，保留观看进度与历史刮削元数据。

### 4.4 异常保护与删除文件清理
1. **中断保护**：增量拉取翻页过程中如果发生网络错误、Token 过期或用户手动取消，**绝对不能更新 `watermark`**，保证下次仍从原断点重新拉取。
2. **深翻页降级阈值**：若用户数月未打开客户端，且期间网盘暴增超过阈值（如翻页超过 20~50 页仍未触达 `watermark`），可直接中止增量并切换为全盘扫描。
3. **删除文件感知（低频全量兜底）**：`/file/search` 不会返回已被删除或移入回收站的文件。因此应保留周期性全量扫描（如每 7 天自动执行一次，或保留用户手动“完整扫库”按钮），用于清理本地库中对应的失效条目。

---

## 5. 预期收益对比

| 维度 | 现行全量目录遍历 (`_listFolder`) | 优化后（增量为主 + 全量兜底） |
| :--- | :--- | :--- |
| **日常追更请求数** | 数百 ~ 上千次 API 请求 | **1 ~ 3 次 API 请求** |
| **日常扫库耗时** | 数分钟（受限于目录数与节流器） | **约 1 秒**（打开软件即完成） |
| **N 天未用后补扫** | 全盘重扫 | 翻几页即可精准找回这 N 天全部更新 |
| **风控与限流风险** | 较高（连续密集调用 `/file/sort`） | 极低 |
| **删除文件清理** | 每次扫库自动清理 | 低频周期全量兜底清理 |

---

## 6. 夸克 Web 端兼容性实测与架构评估

初期实现出于保守策略，在 `LibraryScanService.supportsIncremental` 与 `LibraryScanner.scan` 中将增量更新限制为仅 `QuarkMode.pc` 可用。2026-11-13 针对真实夸克 Web 凭证进行了实测与全盘架构评估。

### 6.1 真实 Web Cookie 实测结果
通过 `QuarkQrLogin` 扫码获取真实 Web Cookie，完全按 `QuarkWebTransport` 的请求头（Electron UA、`Cookie`、`Referer: https://pan.quark.cn`）与基础参数（`pr=ucpro&fr=pc`）请求 `https://drive-pc.quark.cn/1/clouddrive`：

| 探测项 | 接口与参数 | 实测结果 |
| :--- | :--- | :--- |
| 会话校验 | `GET /config` | `HTTP 200` / `code=0` |
| 全盘更新时间倒序 | `GET /file/search?q=&_sort=updated_at:desc&_page=1&_size=10` | `HTTP 200` / `code=0`，耗时 **88 ms**，返回 10 条 |
| 排序与字段完整性 | 返回条目检查 | 严格按 `updated_at` 倒序排列，`fid` 与非空 `pdir_fid` 均正常返回 |
| 父目录路径回溯 | `GET /file/sort?...&_fetch_full_path=1` | `HTTP 200` / `code=0`，耗时 **173 ms**，正常返回 `full_path` |

**实测结论**：夸克 Web 凭证**完全支持**当前这套增量扫描所需的全部接口，数据格式与排序行为和 PC 端一致。

### 6.2 传输层共性原因
在 `QuarkStorageDriver` 中，`QuarkMode.web` 与 `QuarkMode.pc` 除了登录态鉴权（纯 Cookie + `__puus/__pus` 轮换 vs WSG 签名头）及播放域名（Web 的 `/file/v2/play` 使用 `drive.quark.cn`）不同外，其余目录与文件接口共用同一个 `_apiBase`（`https://drive-pc.quark.cn/1/clouddrive`）。

### 6.3 是否需要独立算法或拆分 Driver 层
1. **不需要为 Web 单独设计增量算法**：
   - 既然 Web Cookie 可直接稳定调用 `/file/search` 与 `_fetch_full_path=1`，现有的“全局服务端水位线 + 60 秒重叠窗口”算法可直接复用。
   - （注：若假设未来某些后端确实不支持全局搜索，如靠父目录 `updated_at` 剪枝已实测不可靠，只能降级为“定向追更目录刷新 + 低频全量兜底”，这属于策略层降级而非本场景需要。）
2. **不需要拆分 `StorageDriver` 实现**：
   - 现有 `QuarkStorageDriver` 的路径映射、限流（`RequestThrottle`）、分片并发读（`ParallelReadSource`）与条目解析均与登录模式解耦（*mode-agnostic*），协议与签名差异已收敛在 `QuarkTransport`（`QuarkWebTransport` / `QuarkPcTransport`）。
   - 唯一可优化的抽象边界是：**不要在 `LibraryScanService` / `LibraryScanner` 中硬编码判断 `QuarkMode.pc`**，而应沿用 `storage_driver.dart` 的 Capability Interface 模式（如由 Driver 自身或能力接口声明是否支持增量变更流）。

### 6.4 后续放开 Web 增量的最小改动点（记录）
- `lib/library/library_scan_service.dart`：放开 `supportsIncremental` 对 `QuarkMode.pc` 的限制（改为支持 `QuarkMode.supported`）。
- `lib/library/library_scanner.dart`：`scan` 中去掉 `driver.mode == QuarkMode.pc` 限制。
- `lib/widgets/quark_update_controls.dart` 与 `lib/i18n/*.i18n.json`：更新不再限制“仅 PC 登录”的相关 UI 文案。

