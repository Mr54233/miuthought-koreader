-- 章节映射:用划线引文在本地 spine 文档里投票,把微信读书章节映射到 zip 内 href。
-- 引文和文档正文走同一套 normalize(剥标签、解实体、去全部空白),
-- 这样换行/排版/实体化差异不影响命中;引文全不中时用章节标题兜底(避开目录页)。
local logger = require("logger")

local ChapterMap = {}

local ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
    nbsp = "", ensp = "", emsp = "", thinsp = "", hellip = "…",
    mdash = "—", ndash = "–", ldquo = "“", rdquo = "”", lsquo = "‘", rsquo = "’",
}

local function utf8_char(code)
    if not code or code < 0 or code > 0x10FFFF
        or (code >= 0xD800 and code <= 0xDFFF) then
        return ""
    end
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    end
    if code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000),
        0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

function ChapterMap.normalize(value)
    local text = tostring(value or ""):gsub("<[^>]*>", " ")
    -- 数值实体解码成字面 UTF-8:实体化编码的中文正文(&#x8FD9; 之类)必须还原,
    -- 否则整章 normalize 成空串,引文永不命中。
    text = text:gsub("&#[xX](%x+);", function(hex) return utf8_char(tonumber(hex, 16)) end)
    text = text:gsub("&#(%d+);", function(dec) return utf8_char(tonumber(dec, 10)) end)
    text = text:gsub("&(%a+);", function(name) return ENTITIES[name] or "" end)
    -- 去掉 ASCII 空白与常见排版空白(nbsp、全角空格、零宽、BOM)。
    text = text:gsub("%s+", "")
    text = text:gsub("\194\160", ""):gsub("\227\128\128", "")
    text = text:gsub("\226\128\139", ""):gsub("\226\128\140", ""):gsub("\226\128\141", "")
    text = text:gsub("\239\187\191", "")
    return text
end

local function scalar_str(v)
    local kind = type(v)
    if kind == "string" or kind == "number" then return tostring(v) end
    return ""
end

-- 参与投票的引文至少 12 字节(约 4 个汉字):太短的句子在多个文件里都会出现,只会投错票。
local MIN_QUOTE_BYTES = 12
-- 引文只取前缀窗口:微信对长引文的 abstract 会做中段省略/跨段拼接,
-- 整条拿去匹配必失败(真机实证 573-1314 字节的引文全部 0 命中,
-- 截前 90 字节后恢复命中);省略点几乎不出现在开头,前缀最保真。
local MAX_QUOTE_BYTES = 90

local function utf8_prefix(text, max_bytes)
    if #text <= max_bytes then return text end
    local cut = max_bytes
    -- 退到完整 UTF-8 字符边界:下一字节若是续字节(0x80-0xBF)说明切在字符中间。
    while cut > 1 do
        local next_byte = text:byte(cut + 1)
        if not next_byte or next_byte < 0x80 or next_byte >= 0xC0 then break end
        cut = cut - 1
    end
    return text:sub(1, cut)
end

function ChapterMap.quotes_of(underlines, limit)
    limit = tonumber(limit) or 5
    local out, seen = {}, {}
    for _, row in ipairs(underlines or {}) do
        if type(row) == "table" then
            for _, key in ipairs({"markText", "bookmarkText", "rangeText", "abstract", "text", "content"}) do
                local quote = utf8_prefix(ChapterMap.normalize(scalar_str(row[key])), MAX_QUOTE_BYTES)
                if #quote >= MIN_QUOTE_BYTES and not seen[quote] then
                    seen[quote] = true
                    out[#out + 1] = quote
                    break
                end
            end
        end
    end
    table.sort(out, function(a, b) return #a > #b end)
    while #out > limit do table.remove(out) end
    return out
end

-- 单文件流式:内存里同一时刻只保留一个正文文件的文本(百兆大书在
-- 256MB 的老设备上不能把全书文本都攥在手里),对它一次性统计所有章节的
-- 引文命中与标题命中,然后立刻释放。
function ChapterMap.build(spine, read_text, chapters)
    chapters = chapters or {}
    -- 预计算每章引文与规范化标题;全部标题用于识别目录页
    -- (一个文件若包含大半章节标题,它是目录/导航页,标题兜底绝不能落在上面)。
    local quotes_list, titles = {}, {}
    local all_titles, seen_titles = {}, {}
    for ci, ch in ipairs(chapters) do
        quotes_list[ci] = #(ch.underlines or {}) > 0 and ChapterMap.quotes_of(ch.underlines) or {}
        local title = ChapterMap.normalize(ch.title)
        titles[ci] = #title >= 6 and title or nil
        if titles[ci] and not seen_titles[title] then
            seen_titles[title] = true
            all_titles[#all_titles + 1] = title
        end
    end
    local toc_threshold = math.max(2, math.ceil(#all_titles * 0.5))

    local scores = {}       -- [ci] = {{href, score}, ...}(spine 顺序)
    local title_hits = {}   -- [ci] = {href, ...}(已排除目录页)
    for _, item in ipairs(spine or {}) do
        local ok, html = pcall(read_text, item.href)
        local text = (ok and html) and ChapterMap.normalize(html) or nil
        if not text then
            logger.warn("[MiuThought][ChapterMap] 读取章节失败",
                "href=", tostring(item.href), "err=", tostring(html))
        elseif text ~= "" then
            -- 目录页检测不再单独扫 all_titles(大书是 千标题×千文件 的天文数字):
            -- 复用下面每章标题命中的结果,统计本文件命中了多少个「不同标题」,
            -- 超过阈值判为目录页,整批命中作废。
            local file_title_cis = {}
            local distinct_titles = {}
            local distinct_count = 0
            for ci in ipairs(chapters) do
                local quotes = quotes_list[ci]
                if #quotes > 0 then
                    local score = 0
                    for _, quote in ipairs(quotes) do
                        if text:find(quote, 1, true) then score = score + 1 end
                    end
                    if score > 0 then
                        scores[ci] = scores[ci] or {}
                        scores[ci][#scores[ci] + 1] = {href = item.href, score = score}
                    end
                end
                local title = titles[ci]
                if title and text:find(title, 1, true) then
                    file_title_cis[#file_title_cis + 1] = ci
                    if not distinct_titles[title] then
                        distinct_titles[title] = true
                        distinct_count = distinct_count + 1
                    end
                end
            end
            if distinct_count < toc_threshold then
                for _, ci in ipairs(file_title_cis) do
                    title_hits[ci] = title_hits[ci] or {}
                    title_hits[ci][#title_hits[ci] + 1] = item.href
                end
            end
        end
        text = nil
        collectgarbage("step", 400)
    end

    local mapped, unmatched = {}, {}
    for ci, ch in ipairs(chapters) do
        local underlines = ch.underlines or {}
        if #underlines == 0 then
            unmatched[#unmatched + 1] = {uid = tostring(ch.uid or ""), title = ch.title, reason = "no_data"}
        else
            local best_href, best_score, tied = nil, 0, false
            for _, entry in ipairs(scores[ci] or {}) do
                if entry.score > best_score then
                    best_href, best_score, tied = entry.href, entry.score, false
                elseif entry.score == best_score and entry.score > 0 and entry.href ~= best_href then
                    tied = true
                end
            end
            if tied then best_href = nil end
            if not best_href then
                local hits = title_hits[ci] or {}
                if #hits == 1 then best_href = hits[1] end
            end
            if best_href then
                mapped[#mapped + 1] = {
                    chapter_uid = tostring(ch.uid or ""), href = best_href,
                    underlines = underlines, review_map = ch.review_map or {},
                }
            else
                unmatched[#unmatched + 1] = {uid = tostring(ch.uid or ""), title = ch.title, reason = "no_hit"}
            end
        end
    end
    return mapped, unmatched
end

return ChapterMap
