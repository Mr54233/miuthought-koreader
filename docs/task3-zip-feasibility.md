# Task 3 (epub_inject) zip 可行性验证结论

> 2026-07-26 验证,证据均已在 KOReader 上游源码逐条核实。

## 判定:可行,推荐路线为 `ffi/archiver`

KOReader ≥ **v2025.08** 起,koreader-base 内建 `ffi/archiver.lua`(libarchive 3.8.8 的 FFI 封装),
解包 + 重打包 EPUB 全部有官方 API,零外部依赖,全平台(Kindle/Kobo/Android)随包携带。

### 解包(原最大风险点,已消除)

```lua
local Archiver = require("ffi/archiver")
local r = Archiver.Reader:new()
r:open(epub_path)                -- 格式探测/central directory/deflate 全在 C 层
for entry in r:iterate() do
    if entry.mode == "file" then
        local data = r:extractToMemory(entry.path)  -- 或 extractToPath(entry.path, dest)
    end
end
r:close()
```

- 现成参考:上游 `plugins/archiveviewer.koplugin/main.lua` 的 extractAll 就是这个十行循环。
- 外部 `unzip` 二进制**不可依赖**:Android 没有系统 unzip(KOReader 惯例是把外部程序编进 APK 的
  nativeLibraryDir),Kobo 固件不确定,仅 Kindle 有把握。上游 2025-05 的 commit f63c76d(PR #13782)
  正是以"摆脱 unzip"为动机把 archiveviewer/readerui 全面迁移到 Archiver。
  → 原 miuread `epub_style_repair_task.lua` 的 `os.execute("unzip ...")` 方案应弃用。

### 重打包

模板照抄 `frontend/ui/wikipedia.lua` L921-935(**勿抄** newsdownloader 的图片分支——它残留旧
ZipWriter 的 4 参调用 `addFileFromMemory(path, content, no_compression, mtime)`,布尔值会被当成
mtime,是上游迁移遗留缺陷):

```lua
local epub = Archiver.Writer:new{}
epub:open(path_tmp, "epub")                 -- FORMAT_ALIASES: epub → zip
epub:setZipCompression("store")
epub:addFileFromMemory("mimetype", "application/epub+zip", mtime)  -- 必须第一个、store
epub:setZipCompression("deflate")
-- 逐个 addFileFromMemory(entry_path, content, mtime)
epub:close()
os.rename(path_tmp, path)
```

### 版本门槛与决策

- `ffi/archiver` 由 koreader-base commit 60145efe(2025-05-23)引入,首个正式版 **v2025.08**
  (v2025.04 及更早没有;`ffi/zlib` 只有 compress2/uncompress/crc32,没有 raw inflate,旧版
  解不了 zip 的 deflate 条目)。
- **决策:插件要求 KOReader ≥ v2025.08,不做旧版 fallback**(旧版只剩外部 unzip 或自写纯 Lua
  inflate 两条烂路)。启动时 `pcall(require, "ffi/archiver")` 探测,失败给友好报错。
- 原 miuread 纯 Lua zip 写入器(`.recovered/epub.lua` 的 `_stream_zip`)与上游已删除的
  ffi/zipwriter 同思路,可随之退役。

### 子进程

`FFIUtil.runInSubProcess` 是裸 `C.fork()`,无平台守卫,Android 也可用(上游 newsdownloader/
wikipedia 经 `Trapper:dismissableRunInSubprocess` 在全平台使用)。耗时的整本重打包可沿用
repair task 的子进程 + 轮询骨架。

## Task 3 复用清单(源自 git 历史盘点,commit 9273cf5)

| 状态 | 模块 | 说明 |
|---|---|---|
| 直接用(当前树) | annotations.lua 注入引擎 | tokenize/文本索引/locate_quote/inject 纯 Lua 离线可用;只需与微信 API 解耦(`fetch_chapter` 是网络侧,`apply/inject` 只吃数据表) |
| 直接用(当前树) | thoughts / thought_popup / annotation_style / main.lua tap 拦截 | 锚点 `#miuthought-<hex>.<hex>.<hex>` + `miu-thought-mark` 虚线样式 + tap_link 拦截弹窗,链路完整 |
| 直接用(当前树) | util.lua | repair task 依赖的 7 个函数(copy/file_exists/read_file/mkdir/atomic_write/remove_tree/shell_quote)全部健在 |
| 改造复用 | epub_style_repair_task.lua | 子进程+轮询+超时+防休眠骨架保留;去掉 unzip(换 Archiver.Reader)、去掉备份/原地替换(Task 3 写副本,不动原书,反而更简单)、通用化对任意 EPUB 布局(解析 container.xml→OPF,不再假定 OEBPS/style.css) |
| 不需要 | internal_links.lua / codec.lua / downloader.lua | 内链修复是针对重排章节文件名的场景,Task 3 原位注入不改结构;codec 是微信章节解密;downloader 是下载编排 |
| 新写 | EPUB 读取层 | container.xml → OPF → spine 解析(Archiver.Reader 之上薄薄一层) |
| 新写 | Task 3 编排层 | 想法数据 → 章节定位(微信 range 是其自家字符偏移,本地书需以 locate_quote 引文对齐为主)→ 注入 → 副本路径管理 |

## 待确认

- [x] 用户设备上的 KOReader 版本 ≥ v2025.08(唯一前提)——已确认没问题

> 2026-07-26:已按本结论实现 `epub_reader.lua` + `epub_inject.lua`(计划见
> docs/superpowers/plans/2026-07-26-task3-epub-inject.md,桌面测试 `luajit tests/run.lua`)。

> `.recovered/` 目录是从 `git show 9273cf5:...` 导出的被删源码,仅供参考,不入库;
> 需要时可随时重新导出。
