T.case("stub 环境能加载现有纯 Lua 模块", function()
    local U = require("miuthought.util")
    T.eq(U.trim("  x  "), "x", "util.trim")
    local Thoughts = require("miuthought.thoughts")
    T.eq(Thoughts.href("b1", "c2", "3-9"), "#miuthought-6231.6332.332d39", "thoughts.href hex")
    local Annotations = require("miuthought.annotations")
    local html = "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
    local data = {
        book_id = "b1", chapter_uid = "c2",
        underlines = {{range = "0-6", markText = "春江潮水连海平"}},
        review_map = {["0-6"] = {{content = "好句", author = "我"}}},
        underline_count = 1, thought_count = 1, errors = {},
    }
    local rendered = Annotations:new(nil):apply(html, data)
    T.ok(rendered:find("miu-thought-link", 1, true), "注入引擎离线可用,应产出想法锚点")
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
    T.eq(Arc._last_writer, w, "_last_writer 记录")
end)
