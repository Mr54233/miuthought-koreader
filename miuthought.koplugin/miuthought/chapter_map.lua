-- 章节映射:用划线引文在本地 spine 文档里投票,把微信读书章节映射到 zip 内 href。
-- 引文和文档正文走同一套 normalize(剥标签、解常用实体、去全部空白),
-- 这样换行/排版差异不影响命中;引文全不中时用章节标题兜底。
local ChapterMap = {}

local ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
    nbsp = "", ensp = "", emsp = "", thinsp = "", hellip = "…",
    mdash = "—", ndash = "–", ldquo = "“", rdquo = "”", lsquo = "‘", rsquo = "’",
}

function ChapterMap.normalize(value)
    local text = tostring(value or ""):gsub("<[^>]*>", " ")
    text = text:gsub("&#[xX](%x+);", function(hex)
        local code = tonumber(hex, 16)
        return (code and code < 0x80) and string.char(code) or ""
    end)
    text = text:gsub("&#(%d+);", function(dec)
        local code = tonumber(dec, 10)
        return (code and code < 0x80) and string.char(code) or ""
    end)
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

function ChapterMap.quotes_of(underlines, limit)
    limit = tonumber(limit) or 5
    local out, seen = {}, {}
    for _, row in ipairs(underlines or {}) do
        if type(row) == "table" then
            for _, key in ipairs({"markText", "bookmarkText", "rangeText", "abstract", "text", "content"}) do
                local quote = ChapterMap.normalize(scalar_str(row[key]))
                if #quote >= 6 and not seen[quote] then
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

function ChapterMap.build(spine, read_text, chapters)
    local cache = {}
    local function text_of(href)
        if cache[href] == nil then
            local ok, html = pcall(read_text, href)
            cache[href] = (ok and html) and ChapterMap.normalize(html) or false
        end
        return cache[href] or nil
    end

    local mapped, unmatched = {}, {}
    for _, ch in ipairs(chapters or {}) do
        local underlines = ch.underlines or {}
        if #underlines == 0 then
            unmatched[#unmatched + 1] = {uid = tostring(ch.uid or ""), title = ch.title, reason = "no_data"}
        else
            local quotes = ChapterMap.quotes_of(underlines)
            local best_href, best_score = nil, 0
            for _, item in ipairs(spine or {}) do
                local text = text_of(item.href)
                if text and text ~= "" then
                    local score = 0
                    for _, quote in ipairs(quotes) do
                        if text:find(quote, 1, true) then score = score + 1 end
                    end
                    if score > best_score then best_href, best_score = item.href, score end
                end
            end
            if best_score == 0 then
                local title = ChapterMap.normalize(ch.title)
                if #title >= 6 then
                    for _, item in ipairs(spine or {}) do
                        local text = text_of(item.href)
                        if text and text:find(title, 1, true) then best_href = item.href; break end
                    end
                end
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
