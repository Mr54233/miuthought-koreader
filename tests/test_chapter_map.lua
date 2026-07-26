local ChapterMap = require("miuthought.chapter_map")

local FILES = {
    ["OEBPS/c1.xhtml"] = [[<html><head><title>卷一</title></head><body>
<h2>第一章 春江潮水</h2>
<p>春江潮水连海平,
海上&amp;明月共潮生。</p></body></html>]],
    ["OEBPS/c2.xhtml"] = [[<html><body>
<h2>第二章 月照花林</h2>
<p>滟滟随波千万里,何处春江无月明。</p>
<p>江流宛转绕芳甸,月照花林皆似霰。</p></body></html>]],
}

local SPINE = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}}

local function read_text(href) return FILES[href] end

T.case("normalize 剥标签解实体去空白", function()
    T.eq(ChapterMap.normalize("<p>春江  潮水\n连海平</p>"), "春江潮水连海平", "标签+空白")
    T.eq(ChapterMap.normalize("海上&amp;明月"), "海上&明月", "实体")
end)

T.case("引文投票映射两章", function()
    local chapters = {
        {uid = "11", title = "第一章", underlines = {{range = "0-7", markText = "海上&明月共潮生"}}},
        {uid = "12", title = "第二章", underlines = {{range = "9-9", markText = "月照花林皆似霰"}}},
    }
    local mapped, unmatched = ChapterMap.build(SPINE, read_text, chapters)
    T.eq(#mapped, 2, "两章均命中")
    T.eq(#unmatched, 0, "无未命中")
    T.eq(mapped[1].href, "OEBPS/c1.xhtml", "第一章 → c1(实体+换行都不挡命中)")
    T.eq(mapped[2].href, "OEBPS/c2.xhtml", "第二章 → c2")
    T.eq(mapped[1].chapter_uid, "11", "chapter_uid 透传")
    T.ok(mapped[1].underlines and mapped[1].review_map, "underlines/review_map 透传")
end)

T.case("标题兜底", function()
    local chapters = {{
        uid = "21", title = "第二章 月照花林",
        underlines = {{range = "0-3", markText = "微信侧独有的文字不在本地书里"}},
    }}
    local mapped, unmatched = ChapterMap.build(SPINE, read_text, chapters)
    T.eq(#mapped, 1, "引文不中时标题兜底")
    T.eq(mapped[1].href, "OEBPS/c2.xhtml", "标题命中 c2")
    T.eq(#unmatched, 0, "无未命中")
end)

T.case("no_data 与 no_hit", function()
    local chapters = {
        {uid = "31", title = "空章", underlines = {}},
        {uid = "32", title = "查无此章", underlines = {{range = "0-3", markText = "完全不存在的引文文本"}}},
    }
    local mapped, unmatched = ChapterMap.build(SPINE, read_text, chapters)
    T.eq(#mapped, 0, "都不该命中")
    T.eq(unmatched[1].reason, "no_data", "无划线 → no_data")
    T.eq(unmatched[2].reason, "no_hit", "引文标题都不中 → no_hit")
    T.eq(unmatched[2].uid, "32", "uid 保留")
end)

T.case("多个微信章节命中同一文件且顺序保留", function()
    local chapters = {
        {uid = "41", title = "上半", underlines = {{range = "0-5", markText = "滟滟随波千万里"}}},
        {uid = "42", title = "下半", underlines = {{range = "6-9", markText = "江流宛转绕芳甸"}}},
    }
    local mapped = ChapterMap.build(SPINE, read_text, chapters)
    T.eq(#mapped, 2, "两章都映射")
    T.eq(mapped[1].href, "OEBPS/c2.xhtml", "同一文件")
    T.eq(mapped[2].href, "OEBPS/c2.xhtml", "同一文件")
    T.eq(mapped[1].chapter_uid, "41", "顺序保留")
    T.eq(mapped[2].chapter_uid, "42", "顺序保留")
end)
