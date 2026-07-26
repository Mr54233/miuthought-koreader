local EpubInject = require("miuthought.epub_inject")
local Json = require("miuthought.json")

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
    T.eq(EpubInject.copy_path("/books/书.epub"), "/books/书.觅想.epub", "标准 .epub")
    T.eq(EpubInject.copy_path("/books/书.EPUB"), "/books/书.觅想.epub", "大写后缀")
    T.eq(EpubInject.copy_path("/books/书"), "/books/书.觅想.epub", "无后缀")
end)

T.case("端到端注入", function()
    local stats, err, Arc, renames = run_inject(book_files(), CHAPTERS)
    T.ok(stats, "inject_copy 应成功: " .. tostring(err))
    T.eq(stats.injected, 1, "注入 1 章")
    T.ok(stats.marks >= 1, "至少 1 处锚点")
    T.eq(#stats.unmatched, 0, "无未匹配章节")
    T.eq(stats.dest, "/books/书.觅想.epub", "dest 默认命名")

    local w = Arc._last_writer
    local entries = STUBS.written(w)
    T.eq(entries[1].path, "mimetype", "mimetype 首条")
    T.eq(entries[1].compression, "store", "mimetype 用 store")
    T.eq(entries[1].content, "application/epub+zip", "mimetype 内容原样")

    local by_path = {}
    for _, e in ipairs(entries) do by_path[e.path] = e end
    local ch1 = by_path["OEBPS/Text/ch1.xhtml"]
    T.ok(ch1.compression == "deflate", "正文用 deflate")
    T.ok(ch1.content:find('class="miu-thought-mark', 1, true), "锚点 span 注入")
    T.ok(ch1.content:find('href="#miuthought-', 1, true), "想法链接注入")
    T.ok(ch1.content:find('id="miuread-annotation-style"', 1, true), "内联样式注入 head")
    T.ok(ch1.content:find("</title>", 1, true) and ch1.content:find("春江潮水", 1, true), "原结构保留")
    T.eq(by_path["OEBPS/Text/ch2.xhtml"].content, CH2, "未涉及章节逐字节原样")

    local marker = by_path[EpubInject.MARKER]
    T.ok(marker, "marker 条目存在")
    local decoded = Json.decode(marker.content)
    T.eq(decoded.book_id, "b001", "marker 记录 book_id")
    T.eq(decoded.created, 1234567890, "marker 用注入的 now")

    T.eq(w.opened_path, "/books/书.觅想.epub.tmp", "先写 tmp")
    T.eq(renames[1][1], "/books/书.觅想.epub.tmp", "rename src")
    T.eq(renames[1][2], "/books/书.觅想.epub", "rename dest")
end)

T.case("拒绝二次注入(is_copy)", function()
    local files = book_files()
    files[#files + 1] = {path = EpubInject.MARKER, content = "{}"}
    T.ok(EpubInject.is_copy("x.epub", STUBS.archiver_mock(files)), "is_copy 识别 marker")
    local stats, err = run_inject(files, CHAPTERS)
    T.ok(stats == nil and tostring(err):find("觅想", 1, true), "对副本注入应拒绝并报中文错")
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
    local style_at = ch1.content:find('id="miuread-annotation-style"', 1, true)
    local body_at = ch1.content:find("<body", 1, true)
    T.ok(style_at and body_at and style_at > body_at, "样式落在 body 之后")
end)
