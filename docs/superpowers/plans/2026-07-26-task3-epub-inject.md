# Task 3: epub_inject(EPUB 想法注入)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给定本地 EPUB + 每章想法/划线数据,生成注入了想法锚点的「撷思版」副本 EPUB,不动原书。

**Architecture:** 两个新模块。`epub_reader.lua` 在 `ffi/archiver`(libarchive)之上做 EPUB 元数据解析(container.xml → OPF → manifest/spine);`epub_inject.lua` 做编排:匹配章节 → 复用 `annotations.lua` 的注入引擎打锚点 → 往 `<head>` 内联虚线样式 → 用 Archiver.Writer 按 wikipedia.lua 模板重打包(mimetype 首条 store、其余 deflate)→ 写入 marker 条目防止二次注入。桌面测试用 LuaJIT + KOReader 模块 stub + Archiver 内存 mock。

**Tech Stack:** LuaJIT (Lua 5.1)、KOReader `ffi/archiver`(见 docs/task3-zip-feasibility.md)、复用 pickthought.{annotations,thoughts,annotation_style,util,json}。

## Global Constraints

- 运行环境:KOReader ≥ **v2025.08**(`ffi/archiver` 版本门槛);启动用 `pcall(require, "ffi/archiver")` 探测,缺失时返回中文错误 `"需要 KOReader v2025.08 或更新版本"`。
- **禁止** `os.execute`/`io.popen` 调用外部 unzip/zip;zip 读写只走 `require("ffi/archiver")`。
- 不修改原书文件;副本先写 `dest .. ".tmp"` 再 `os.rename`。
- 模块放 `pickthought.koplugin/pickthought/`,require 前缀 `pickthought.*`,4 空格缩进,错误消息用中文,风格与现有模块一致(紧凑、返回 `nil, err`)。
- 不修改现有模块(annotations/thoughts/annotation_style/util/json 原样复用)。
- 每个 Task 完成即 `git commit`(用户纪律:出问题好回滚)。
- 测试:`luajit tests/run.lua` 必须全绿;KOReader 专属模块(logger、libs/libkoreader-lfs、ffi/archiver)在 tests/stubs.lua 里 stub/mock。

## 上下文速查(实现者必读)

- **Archiver 真实 API**(koreader-base ffi/archiver.lua,已核验):
  `Reader:new()` / `r:open(path)` / `r:iterate()` 迭代 `{path, mode, size, index}` / `r:seek(key)`(路径或序号,倒序自动重开重扫)/ `r:extractToMemory(key)` → string / `r:close()`;
  `Writer:new{}` / `w:open(path, "epub")` / `w:setZipCompression("store"|"deflate")` / `w:addFileFromMemory(entry_path, content, mtime)` / `w:close()`。
  模板抄 wikipedia.lua L921-935;**勿抄** newsdownloader 的 4 参 addFileFromMemory(上游遗留 bug)。
- **注入引擎**:`local Annotations = require("pickthought.annotations"); Annotations:new(nil):apply(html, data)` → `rendered, css, stats`。离线纯函数;`data` 形状:`{book_id, chapter_uid, underlines(数组,元素含 range/markText…), review_map(range→texts数组), underline_count(必填,0 则直接原样返回), thought_count, errors={}}`。引擎内部先引文对齐(locate_quote)后数字偏移,产出 `<a class="pickthought-link" href="#pickthought-<hex>.<hex>.<hex>"><span class="pickthought-mark pickthought-mark-<hex>" data-miu-range="...">` 锚点。
- **样式**:`require("pickthought.annotation_style").inline_style_tag()` 返回 `<style id="pickthought-annotation-style">…</style>`(虚线下划线 CSS)。现有 `ensure_inline_style` 以 `data-pickthought-book=` 标记为前提,**不适用于任意本地书**,epub_inject 自带插入逻辑。
- **util 可用函数**:`U.url_decode / U.xml / U.trim / U.copy / U.file_exists / U.read_file`(util 顶层 require lfs,测试须 stub)。

## File Structure

- Create: `pickthought.koplugin/pickthought/epub_reader.lua` — EPUB 元数据读取(available/load/read)
- Create: `pickthought.koplugin/pickthought/epub_inject.lua` — 注入编排(copy_path/is_copy/inject_copy)
- Create: `tests/stubs.lua` — package.preload stub:logger、libs/libkoreader-lfs、ffi/archiver mock(内存 zip)
- Create: `tests/run.lua` — 极简断言测试跑器
- Create: `tests/test_epub_reader.lua`、`tests/test_epub_inject.lua`
- 不修改任何现有文件

---

### Task 1: 桌面测试基建(LuaJIT + stub + 跑器)

**Files:**
- Create: `tests/stubs.lua`
- Create: `tests/run.lua`
- Create: `tests/test_smoke.lua`

**Interfaces:**
- Consumes: 无
- Produces: `stubs.archiver_mock(files)` → 假 Archiver 模块(files = 有序数组 `{{path=,content=}}`);`stubs.written(writer)` → mock Writer 收到的条目;run.lua 的 `T.eq(got, want, label)` / `T.ok(cond, label)` / `T.case(name, fn)` 断言接口。

- [ ] **Step 1: 安装 LuaJIT 并验证**

```bash
winget install --id=DEVCOM.LuaJIT -e --accept-package-agreements --accept-source-agreements
```

然后新开 shell 验证(winget 装完 PATH 可能未刷新,用完整路径亦可,典型位置 `%LOCALAPPDATA%\Microsoft\WinGet\Packages\DEVCOM.LuaJIT...\luajit.exe`):

Run: `luajit -v`
Expected: `LuaJIT 2.1.x`

- [ ] **Step 2: 写 stubs + 跑器 + 冒烟测试(此步即失败测试:先跑必红)**

`tests/stubs.lua`:

```lua
-- 桌面(LuaJIT)测试环境:stub 掉 KOReader 专属模块,mock ffi/archiver。
-- 用法:tests/run.lua 最先 require 本文件。
local M = {}

package.path = "pickthought.koplugin/?.lua;" .. package.path

package.preload["logger"] = function()
    local function noop() end
    return {dbg = noop, info = noop, warn = noop, err = noop}
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function() return nil end,
        symlinkattributes = function() return nil end,
        dir = function() return function() return nil end end,
        mkdir = function() return true end,
        rmdir = function() return true end,
    }
end

-- 内存版 ffi/archiver:与真实 API 同形(Reader:new/open/iterate/seek/extractToMemory/close,
-- Writer:new/open/setZipCompression/addFileFromMemory/close)。
-- files: 有序数组 {{path=..., content=...}, ...} 模拟 zip 条目顺序。
function M.archiver_mock(files)
    local Reader = {}
    Reader.__index = Reader
    function Reader:new() return setmetatable({}, self) end
    function Reader:open(path)
        self.path = path
        self.by_path = {}
        for _, f in ipairs(files) do self.by_path[f.path] = f end
        return true
    end
    function Reader:iterate()
        local i = 0
        return function()
            i = i + 1
            local f = files[i]
            if not f then return nil end
            return {path = f.path, mode = "file", size = #f.content, index = i}
        end
    end
    function Reader:seek(key)
        local f = type(key) == "number" and files[key] or self.by_path[key]
        return f and {path = f.path, mode = "file", size = #f.content} or nil
    end
    function Reader:extractToMemory(key)
        local f = type(key) == "number" and files[key] or self.by_path[key]
        return f and f.content or nil
    end
    function Reader:close() end

    local Writer = {}
    Writer.__index = Writer
    function Writer:new() return setmetatable({entries = {}, compression = "deflate"}, self) end
    function Writer:open(path, format)
        self.opened_path, self.format = path, format
        return true
    end
    function Writer:setZipCompression(method) self.compression = method end
    function Writer:addFileFromMemory(entry_path, content, mtime)
        self.entries[#self.entries + 1] = {
            path = entry_path, content = content, mtime = mtime, compression = self.compression,
        }
    end
    function Writer:close() self.closed = true end

    return {Reader = Reader, Writer = Writer}
end

function M.written(writer) return writer.entries end

return M
```

`tests/run.lua`:

```lua
-- 用法:luajit tests/run.lua
local T = {passed = 0, failed = 0}
function T.case(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        T.passed = T.passed + 1
    else
        T.failed = T.failed + 1
        print("FAIL: " .. name .. "\n  " .. tostring(err))
    end
end
function T.ok(cond, label)
    if not cond then error(tostring(label or "assertion failed"), 2) end
end
function T.eq(got, want, label)
    if got ~= want then
        error(string.format("%s\n  got:  %s\n  want: %s",
            tostring(label or "not equal"), tostring(got), tostring(want)), 2)
    end
end
_G.T = T
_G.STUBS = require("tests.stubs")

local files = {"tests.test_smoke", "tests.test_epub_reader", "tests.test_epub_inject"}
for _, name in ipairs(files) do
    local ok, err = pcall(require, name)
    if not ok and not tostring(err):find("module '" .. name .. "' not found", 1, true) then
        T.failed = T.failed + 1
        print("FAIL(load): " .. name .. "\n  " .. tostring(err))
    end
end

print(string.format("passed=%d failed=%d", T.passed, T.failed))
os.exit(T.failed == 0 and 0 or 1)
```

`tests/test_smoke.lua`:

```lua
T.case("stub 环境能加载现有纯 Lua 模块", function()
    local U = require("pickthought.util")
    T.eq(U.trim("  x  "), "x", "util.trim")
    local Thoughts = require("pickthought.thoughts")
    T.eq(Thoughts.href("b1", "c2", "3-9"), "#pickthought-6231.6332.332d39", "thoughts.href hex")
    local Annotations = require("pickthought.annotations")
    local html = "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
    local data = {
        book_id = "b1", chapter_uid = "c2",
        underlines = {{range = "0-6", markText = "春江潮水连海平"}},
        review_map = {["0-6"] = {{content = "好句", author = "我"}}},
        underline_count = 1, thought_count = 1, errors = {},
    }
    local rendered = Annotations:new(nil):apply(html, data)
    T.ok(rendered:find("pickthought-link", 1, true), "注入引擎离线可用,应产出想法锚点")
end)

T.case("archiver mock 读写同形", function()
    local Arc = STUBS.archiver_mock({{path = "mimetype", content = "application/epub+zip"}})
    local r = Arc.Reader:new()
    T.ok(r:open("fake.epub"), "open")
    T.eq(r:extractToMemory("mimetype"), "application/epub+zip", "extractToMemory")
    local w = Arc.Writer:new{}
    w:open("out.epub", "epub")
    w:setZipCompression("store")
    w:addFileFromMemory("mimetype", "application/epub+zip", 0)
    T.eq(STUBS.written(w)[1].compression, "store", "writer 记录压缩方式")
end)
```

- [ ] **Step 3: 运行测试确认全绿**

Run: `luajit tests/run.lua`(在仓库根目录)
Expected: `passed=2 failed=0`(若 annotations 注入断言失败,排查 stub 缺失,不改动 annotations.lua)

- [ ] **Step 4: Commit**

```bash
git add tests/
git commit -m "test: 桌面测试基建(LuaJIT + KOReader stub + Archiver 内存 mock)"
```

---

### Task 2: epub_reader.lua(EPUB 元数据读取)

**Files:**
- Create: `pickthought.koplugin/pickthought/epub_reader.lua`
- Test: `tests/test_epub_reader.lua`

**Interfaces:**
- Consumes: `ffi/archiver`(可经参数注入 mock)
- Produces(Task 3 依赖,签名固定):
  - `EpubReader.available() → boolean, err`(pcall require ffi/archiver)
  - `EpubReader.load(path, archiver?) → meta, err`;meta = `{path, names(有序数组), has(name→true), opf_path, opf_dir, spine = {{idref, href(已解析为 zip 内全路径,已 url_decode+规范化), media_type}...}}`
  - `EpubReader.read(meta, name, archiver?) → content, err`(一次性 seek+extract)
  - `EpubReader.resolve(base_dir, href) → zip_path`(拼接 + `../` 规范化 + url_decode,导出供测试)

- [ ] **Step 1: 写失败测试**

`tests/test_epub_reader.lua`:

```lua
local EpubReader = require("pickthought.epub_reader")

local CONTAINER = [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>]]

local OPF = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">测试书</dc:title></metadata>
  <manifest>
    <item href="Text/ch%201.xhtml" id="c1" media-type="application/xhtml+xml"/>
    <item id="c2" media-type="application/xhtml+xml" href="Text/../Text/ch2.xhtml"/>
    <item id="css" href="style.css" media-type="text/css"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2" linear="no"/></spine>
</package>]]

local function fake_book()
    return STUBS.archiver_mock({
        {path = "mimetype", content = "application/epub+zip"},
        {path = "META-INF/container.xml", content = CONTAINER},
        {path = "OEBPS/content.opf", content = OPF},
        {path = "OEBPS/Text/ch 1.xhtml", content = "<html><head></head><body>一</body></html>"},
        {path = "OEBPS/Text/ch2.xhtml", content = "<html><head></head><body>二</body></html>"},
        {path = "OEBPS/style.css", content = "body{}"},
    })
end

T.case("resolve 路径规范化", function()
    T.eq(EpubReader.resolve("OEBPS", "Text/ch%201.xhtml"), "OEBPS/Text/ch 1.xhtml", "url_decode+拼接")
    T.eq(EpubReader.resolve("OEBPS", "Text/../Text/ch2.xhtml"), "OEBPS/Text/ch2.xhtml", "../ 折叠")
    T.eq(EpubReader.resolve("", "ch.xhtml"), "ch.xhtml", "根目录 OPF")
    T.eq(EpubReader.resolve("OEBPS", "/abs/ch.xhtml"), "abs/ch.xhtml", "绝对路径去除首斜杠")
end)

T.case("load 解析 container/OPF/spine", function()
    local meta, err = EpubReader.load("fake.epub", fake_book())
    T.ok(meta, "load 应成功: " .. tostring(err))
    T.eq(meta.opf_path, "OEBPS/content.opf", "opf_path")
    T.eq(meta.opf_dir, "OEBPS", "opf_dir")
    T.eq(#meta.names, 6, "全部条目入列")
    T.ok(meta.has["OEBPS/style.css"], "has 索引")
    T.eq(#meta.spine, 2, "spine 数量")
    T.eq(meta.spine[1].href, "OEBPS/Text/ch 1.xhtml", "spine1 href 解析(属性乱序+转义)")
    T.eq(meta.spine[2].href, "OEBPS/Text/ch2.xhtml", "spine2 href 规范化")
    T.eq(meta.spine[1].media_type, "application/xhtml+xml", "media_type")
end)

T.case("read 取单条目", function()
    local meta = EpubReader.load("fake.epub", fake_book())
    local body = EpubReader.read(meta, "OEBPS/Text/ch2.xhtml", fake_book())
    T.ok(body and body:find("二", 1, true), "read 内容")
    local missing, err = EpubReader.read(meta, "不存在", fake_book())
    T.ok(missing == nil and err ~= nil, "缺失条目返回 nil, err")
end)

T.case("坏包报错", function()
    local no_container = STUBS.archiver_mock({{path = "mimetype", content = "application/epub+zip"}})
    local meta, err = EpubReader.load("bad.epub", no_container)
    T.ok(meta == nil and tostring(err):find("container", 1, true), "缺 container.xml 报中文错")
end)
```

- [ ] **Step 2: 运行确认失败**

Run: `luajit tests/run.lua`
Expected: FAIL(load): tests.test_epub_reader,`module 'pickthought.epub_reader' not found`

- [ ] **Step 3: 实现 epub_reader.lua**

```lua
-- EPUB 元数据读取:ffi/archiver (libarchive) 之上解析 container.xml → OPF → spine。
-- 要求 KOReader >= v2025.08;详见 docs/task3-zip-feasibility.md。
local U = require("pickthought.util")

local E = {}

local function get_archiver(archiver)
    if archiver then return archiver end
    local ok, mod = pcall(require, "ffi/archiver")
    if not ok then return nil, "需要 KOReader v2025.08 或更新版本(缺少 ffi/archiver)" end
    return mod
end

function E.available()
    local mod, err = get_archiver(nil)
    return mod ~= nil, err
end

function E.resolve(base_dir, href)
    local raw = U.url_decode(tostring(href or ""))
    raw = raw:gsub("^/+", "")
    local joined = (tostring(base_dir or "") ~= "" and not tostring(href or ""):match("^/"))
        and (base_dir .. "/" .. raw) or raw
    local parts = {}
    for seg in joined:gmatch("[^/]+") do
        if seg == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return table.concat(parts, "/")
end

local function attr(tag, name)
    return tag:match(name .. '%s*=%s*"([^"]*)"') or tag:match(name .. "%s*=%s*'([^']*)'")
end

local function open_reader(path, archiver)
    local mod, err = get_archiver(archiver)
    if not mod then return nil, err end
    local reader = mod.Reader:new()
    if not reader:open(path) then return nil, "无法打开 EPUB:" .. tostring(path) end
    return reader
end

function E.load(path, archiver)
    local reader, err = open_reader(path, archiver)
    if not reader then return nil, err end
    local names, has = {}, {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            names[#names + 1] = entry.path
            has[entry.path] = true
        end
    end
    local container = has["META-INF/container.xml"] and reader:extractToMemory("META-INF/container.xml")
    if not container then
        reader:close()
        return nil, "EPUB 缺少 META-INF/container.xml,不是有效的 EPUB"
    end
    local rootfile = container:match("<rootfile%s[^>]*>") or ""
    local opf_path = attr(rootfile, "full%-path")
    opf_path = opf_path and E.resolve("", opf_path) or nil
    if not opf_path or not has[opf_path] then
        reader:close()
        return nil, "EPUB 的 container.xml 未指向有效 OPF"
    end
    local opf = reader:extractToMemory(opf_path)
    reader:close()
    if not opf then return nil, "无法读取 OPF:" .. opf_path end

    local opf_dir = opf_path:match("^(.*)/[^/]+$") or ""
    local manifest = {}
    for tag in opf:gmatch("<item[%s/][^>]*>") do
        local id = attr(tag, "id")
        local href = attr(tag, "href")
        if id and href then
            manifest[id] = {href = E.resolve(opf_dir, href), media_type = attr(tag, "media%-type") or ""}
        end
    end
    local spine = {}
    for tag in opf:gmatch("<itemref[%s/][^>]*>") do
        local idref = attr(tag, "idref")
        local item = idref and manifest[idref]
        if item then
            spine[#spine + 1] = {idref = idref, href = item.href, media_type = item.media_type}
        end
    end
    if #spine == 0 then return nil, "OPF 中没有可用的 spine 章节" end
    return {path = path, names = names, has = has, opf_path = opf_path, opf_dir = opf_dir, spine = spine}
end

function E.read(meta, name, archiver)
    local reader, err = open_reader(meta.path, archiver)
    if not reader then return nil, err end
    local content = reader:seek(name) and reader:extractToMemory(name) or nil
    reader:close()
    if content == nil then return nil, "EPUB 中不存在条目:" .. tostring(name) end
    return content
end

return E
```

- [ ] **Step 4: 运行确认全绿**

Run: `luajit tests/run.lua`
Expected: `passed=6 failed=0`

- [ ] **Step 5: Commit**

```bash
git add pickthought.koplugin/pickthought/epub_reader.lua tests/test_epub_reader.lua
git commit -m "feat: epub_reader — ffi/archiver 之上的 EPUB 元数据解析(container/OPF/spine)"
```

---

### Task 3: epub_inject.lua(注入编排 + 重打包)

**Files:**
- Create: `pickthought.koplugin/pickthought/epub_inject.lua`
- Test: `tests/test_epub_inject.lua`

**Interfaces:**
- Consumes: `EpubReader.load/read/resolve`(Task 2 签名);`Annotations:new(nil):apply(html, data)`;`AnnotationStyle.inline_style_tag()`;`Json.encode/decode`
- Produces(Task 6 同步流程依赖):
  - `EpubInject.MARKER = "pickthought.json"`
  - `EpubInject.copy_path(src) → dest`(`/a/书.epub` → `/a/书.撷思.epub`;无 .epub 后缀则直接追加 `.撷思.epub`)
  - `EpubInject.is_copy(path, archiver?) → boolean`
  - `EpubInject.inject_copy(src, book_id, chapters, opts?) → stats, err`;chapters = 数组 `{chapter_uid, href, underlines, review_map}`(href 可为 zip 全路径、相对 OPF 路径或纯文件名,依次精确/resolve/后缀匹配);opts = `{archiver, dest, rename(默认 os.rename), now(默认 os.time)}`;stats = `{dest, injected, marks, unmatched(数组 uid), quote_aligned, dropped}`

- [ ] **Step 1: 写失败测试**

`tests/test_epub_inject.lua`:

```lua
local EpubInject = require("pickthought.epub_inject")
local Json = require("pickthought.json")

local CONTAINER = [[<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>]]
local OPF = [[<package><manifest>
<item id="c1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
<item id="c2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
</manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>]]
local CH1 = "<html><head><title>一</title></head><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
local CH2 = "<html><head><title>二</title></head><body><p>滟滟随波千万里,何处春江无月明。</p></body></html>"

local function book_files()
    return {
        {path = "mimetype", content = "application/epub+zip"},
        {path = "META-INF/container.xml", content = CONTAINER},
        {path = "OEBPS/content.opf", content = OPF},
        {path = "OEBPS/Text/ch1.xhtml", content = CH1},
        {path = "OEBPS/Text/ch2.xhtml", content = CH2},
    }
end

local CHAPTERS = {{
    chapter_uid = "42", href = "Text/ch1.xhtml",
    underlines = {{range = "0-7", markText = "春江潮水连海平"}},
    review_map = {["0-7"] = {{content = "开篇即巅峰", author = "读者甲"}}},
}}

local function run_inject(files, chapters, opts)
    local Arc = STUBS.archiver_mock(files)
    local renames = {}
    opts = opts or {}
    opts.archiver = Arc
    opts.rename = function(a, b) renames[#renames + 1] = {a, b}; return true end
    opts.now = function() return 1234567890 end
    local stats, err = EpubInject.inject_copy("/books/书.epub", "b001", chapters, opts)
    return stats, err, Arc, renames
end

T.case("copy_path 命名", function()
    T.eq(EpubInject.copy_path("/books/书.epub"), "/books/书.撷思.epub", "标准 .epub")
    T.eq(EpubInject.copy_path("/books/书.EPUB"), "/books/书.撷思.epub", "大写后缀")
    T.eq(EpubInject.copy_path("/books/书"), "/books/书.撷思.epub", "无后缀")
end)

T.case("端到端注入", function()
    local stats, err, Arc, renames = run_inject(book_files(), CHAPTERS)
    T.ok(stats, "inject_copy 应成功: " .. tostring(err))
    T.eq(stats.injected, 1, "注入 1 章")
    T.ok(stats.marks >= 1, "至少 1 处锚点")
    T.eq(#stats.unmatched, 0, "无未匹配章节")
    T.eq(stats.dest, "/books/书.撷思.epub", "dest 默认命名")

    local w = Arc._last_writer
    local entries = STUBS.written(w)
    T.eq(entries[1].path, "mimetype", "mimetype 首条")
    T.eq(entries[1].compression, "store", "mimetype 用 store")
    T.eq(entries[1].content, "application/epub+zip", "mimetype 内容原样")

    local by_path = {}
    for _, e in ipairs(entries) do by_path[e.path] = e end
    local ch1 = by_path["OEBPS/Text/ch1.xhtml"]
    T.ok(ch1.compression == "deflate", "正文用 deflate")
    T.ok(ch1.content:find('class="pickthought-mark', 1, true), "锚点 span 注入")
    T.ok(ch1.content:find('href="#pickthought%-', 1) or ch1.content:find('href="#pickthought-', 1, true), "想法链接注入")
    T.ok(ch1.content:find('id="pickthought-annotation-style"', 1, true), "内联样式注入 head")
    T.ok(ch1.content:find("</title>", 1, true) and ch1.content:find("春江潮水", 1, true), "原结构保留")
    T.eq(by_path["OEBPS/Text/ch2.xhtml"].content, CH2, "未涉及章节逐字节原样")

    local marker = by_path[EpubInject.MARKER]
    T.ok(marker, "marker 条目存在")
    local decoded = Json.decode(marker.content)
    T.eq(decoded.book_id, "b001", "marker 记录 book_id")
    T.eq(decoded.created, 1234567890, "marker 用注入的 now")

    T.eq(w.opened_path, "/books/书.撷思.epub.tmp", "先写 tmp")
    T.eq(renames[1][1], "/books/书.撷思.epub.tmp", "rename src")
    T.eq(renames[1][2], "/books/书.撷思.epub", "rename dest")
end)

T.case("拒绝二次注入(is_copy)", function()
    local files = book_files()
    files[#files + 1] = {path = EpubInject.MARKER, content = "{}"}
    T.ok(EpubInject.is_copy("x.epub", STUBS.archiver_mock(files)), "is_copy 识别 marker")
    local stats, err = run_inject(files, CHAPTERS)
    T.ok(stats == nil and tostring(err):find("撷思", 1, true), "对副本注入应拒绝并报中文错")
end)

T.case("章节匹配:后缀与未匹配", function()
    local chapters = {
        {chapter_uid = "42", href = "ch1.xhtml", underlines = CHAPTERS[1].underlines,
         review_map = CHAPTERS[1].review_map},
        {chapter_uid = "99", href = "nope.xhtml", underlines = {{range = "0-3", markText = "xx"}}, review_map = {}},
    }
    local stats, err = run_inject(book_files(), chapters)
    T.ok(stats, "应成功: " .. tostring(err))
    T.eq(stats.injected, 1, "纯文件名后缀匹配成功")
    T.eq(stats.unmatched[1], "99", "未匹配章节记入 unmatched")
end)

T.case("无 head 的章节:样式插到 body 开头", function()
    local files = book_files()
    files[4] = {path = "OEBPS/Text/ch1.xhtml",
        content = "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"}
    local stats, _, Arc = run_inject(files, CHAPTERS)
    T.eq(stats.injected, 1, "无 head 也能注入")
    local entries = STUBS.written(Arc._last_writer)
    local ch1
    for _, e in ipairs(entries) do if e.path == "OEBPS/Text/ch1.xhtml" then ch1 = e end end
    local style_at = ch1.content:find('id="pickthought-annotation-style"', 1, true)
    local body_at = ch1.content:find("<body", 1, true)
    T.ok(style_at and body_at and style_at > body_at, "样式落在 body 之后")
end)
```

注意:mock 需要记录最后创建的 Writer 供断言。给 `tests/stubs.lua` 的 `archiver_mock` 返回表加一行——在 `Writer:new` 里 `mod._last_writer = self`(mod 为返回的 `{Reader=…, Writer=…}` 表;实现方式:`archiver_mock` 里先声明 `local mod = {}`,Writer:new 里赋 `mod._last_writer`,最后 `mod.Reader, mod.Writer = Reader, Writer; return mod`)。

- [ ] **Step 2: 运行确认失败**

Run: `luajit tests/run.lua`
Expected: FAIL(load): tests.test_epub_inject,`module 'pickthought.epub_inject' not found`

- [ ] **Step 3: 实现 epub_inject.lua**

```lua
-- 注入编排:本地 EPUB + 想法数据 → 撷思版副本。
-- 原书只读;副本先写 dest..".tmp" 再 rename。zip 读写只走 ffi/archiver。
local Annotations = require("pickthought.annotations")
local AnnotationStyle = require("pickthought.annotation_style")
local EpubReader = require("pickthought.epub_reader")
local Json = require("pickthought.json")

local M = {}

M.MARKER = "pickthought.json"

function M.copy_path(src)
    src = tostring(src or "")
    local stem = src:match("^(.*)%.[eE][pP][uU][bB]$") or src
    return stem .. ".撷思.epub"
end

function M.is_copy(path, archiver)
    local meta = EpubReader.load(path, archiver)
    return meta ~= nil and meta.has[M.MARKER] == true
end

local function ensure_style(html)
    if html:find('id="' .. AnnotationStyle.INLINE_STYLE_ID .. '"', 1, true) then return html end
    local tag = AnnotationStyle.inline_style_tag()
    local head_end = html:find("</head>", 1, true)
    if head_end then
        return html:sub(1, head_end - 1) .. tag .. html:sub(head_end)
    end
    local body_open = html:find("<body[^>]*>")
    if body_open then
        local close = html:find(">", body_open, true)
        return html:sub(1, close) .. tag .. html:sub(close + 1)
    end
    return tag .. html
end

-- href 匹配:精确 zip 路径 → 相对 OPF 解析 → 文件名后缀。
local function match_entry(meta, href)
    href = tostring(href or "")
    if href == "" then return nil end
    if meta.has[href] then return href end
    local resolved = EpubReader.resolve(meta.opf_dir, href)
    if meta.has[resolved] then return resolved end
    local tail = "/" .. href:gsub("^/+", "")
    for _, item in ipairs(meta.spine) do
        if item.href:sub(-#tail) == tail then return item.href end
    end
    return nil
end

local function chapter_data(book_id, ch)
    local underlines = ch.underlines or {}
    local review_map = ch.review_map or {}
    local thought_count = 0
    for _ in pairs(review_map) do thought_count = thought_count + 1 end
    return {
        book_id = book_id, chapter_uid = tostring(ch.chapter_uid or ""),
        underlines = underlines, review_map = review_map,
        underline_count = #underlines, thought_count = thought_count, errors = {},
    }
end

function M.inject_copy(src, book_id, chapters, opts)
    opts = opts or {}
    local rename = opts.rename or os.rename
    local now = opts.now or os.time

    local meta, err = EpubReader.load(src, opts.archiver)
    if not meta then return nil, err end
    if meta.has[M.MARKER] then return nil, "该文件已是撷思版副本,请对原书执行注入" end

    -- 先算好每章的注入结果,全部成功后才写包。
    local targets, stats = {}, {
        injected = 0, marks = 0, unmatched = {}, quote_aligned = 0, dropped = 0,
    }
    local marker_chapters = {}
    for _, ch in ipairs(chapters or {}) do
        local entry_path = match_entry(meta, ch.href)
        if not entry_path then
            stats.unmatched[#stats.unmatched + 1] = tostring(ch.chapter_uid or ch.href or "?")
        else
            local html, read_err = EpubReader.read(meta, entry_path, opts.archiver)
            if not html then return nil, read_err end
            local data = chapter_data(book_id, ch)
            local rendered, _, ch_stats = Annotations:new(nil):apply(html, data)
            local mark_count = (ch_stats.underlines or 0) - (ch_stats.dropped or 0)
            if mark_count > 0 then
                targets[entry_path] = ensure_style(rendered)
                stats.injected = stats.injected + 1
                stats.marks = stats.marks + mark_count
                stats.quote_aligned = stats.quote_aligned + (ch_stats.quote_aligned or 0)
                stats.dropped = stats.dropped + (ch_stats.dropped or 0)
                marker_chapters[#marker_chapters + 1] = {
                    uid = data.chapter_uid, href = entry_path, marks = mark_count,
                }
            else
                stats.dropped = stats.dropped + (ch_stats.dropped or 0)
            end
        end
    end
    if stats.injected == 0 then return nil, "没有可注入的章节(未匹配或定位全部失败)" end

    local mod, arc_err = (function()
        if opts.archiver then return opts.archiver end
        local ok, m = pcall(require, "ffi/archiver")
        if not ok then return nil, "需要 KOReader v2025.08 或更新版本(缺少 ffi/archiver)" end
        return m
    end)()
    if not mod then return nil, arc_err end

    local dest = opts.dest or M.copy_path(src)
    local tmp = dest .. ".tmp"
    local mtime = now()
    local writer = mod.Writer:new{}
    if not writer:open(tmp, "epub") then return nil, "无法创建副本:" .. tmp end

    writer:setZipCompression("store")
    local mime = meta.has["mimetype"] and EpubReader.read(meta, "mimetype", opts.archiver)
        or "application/epub+zip"
    writer:addFileFromMemory("mimetype", mime, mtime)
    writer:setZipCompression("deflate")

    for _, name in ipairs(meta.names) do
        if name ~= "mimetype" and name ~= M.MARKER then
            local content
            if targets[name] then
                content = targets[name]
            else
                local raw, e = EpubReader.read(meta, name, opts.archiver)
                if not raw then
                    writer:close()
                    os.remove(tmp)
                    return nil, e
                end
                content = raw
            end
            writer:addFileFromMemory(name, content, mtime)
        end
    end
    writer:addFileFromMemory(M.MARKER, Json.encode({
        version = 1, book_id = tostring(book_id or ""), created = mtime,
        source = src, chapters = marker_chapters,
    }), mtime)
    writer:close()

    local ok, rename_err = rename(tmp, dest)
    if not ok then
        os.remove(tmp)
        return nil, "无法生成副本:" .. tostring(rename_err or "重命名失败")
    end
    stats.dest = dest
    return stats
end

return M
```

实现提醒:
- `EpubReader.read` 每次调用开一个新 Reader——真实 Archiver 上顺序遍历 meta.names 时 seek 都是前向,成本可接受;若设备实测慢,后续再优化为单 Reader 流式(不在本 Task 范围)。
- 逐章 read → 注入 → 写入,任一步失败:close writer、删 tmp、返回 `nil, 中文错误`。
- 大条目(图片)整块过内存,与 archiveviewer 的 extractAll 行为一致,可在循环里 `collectgarbage("step", 200)`。

- [ ] **Step 4: 运行确认全绿**

Run: `luajit tests/run.lua`
Expected: `passed=11 failed=0`(6 前置 + 本任务 5 例)

- [ ] **Step 5: Commit**

```bash
git add pickthought.koplugin/pickthought/epub_inject.lua tests/test_epub_inject.lua tests/stubs.lua
git commit -m "feat: epub_inject — 注入想法锚点并重打包为撷思版副本(Task 3 核心)"
```

---

### Task 4: 收尾(文档 + 自审)

**Files:**
- Modify: `docs/task3-zip-feasibility.md`(勾掉待确认项,补一行"已按本结论实现")
- Modify: `README.md`(如有模块清单段落则补两行;没有则跳过)

- [ ] **Step 1: 全量测试**

Run: `luajit tests/run.lua`
Expected: `passed=11 failed=0`

- [ ] **Step 2: 自审清单**

- 全局约束逐条核对:无 os.execute/io.popen;未改现有模块;错误消息全中文;tmp+rename;4 空格。
- 接口一致性:Task 2 的 `load/read/resolve` 签名与 Task 3 调用处一致;`chapters` 契约写进 epub_inject.lua 顶部注释,供 Task 5/6 引用。

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs: Task 3 完成收尾(文档更新与自审)"
```

---

## 后续(不在本计划)

- **设备冒烟**:真机 KOReader 上对一本真实 EPUB 跑 inject_copy(需 Task 6 的菜单接线或临时调试入口);验证 crengine 打开副本、虚线可见、tap 弹窗。
- Task 4(绑定微信读书)、Task 5(章节映射:微信章节 → 本地 spine)、Task 6(同步编排:拉数据 → Thoughts.save → inject_copy → 子进程包装)。
