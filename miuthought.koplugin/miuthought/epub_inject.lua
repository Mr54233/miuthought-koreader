-- 注入编排:本地 EPUB + 想法数据 → 觅想版副本。
-- 原书只读;副本先写 dest..".tmp" 再 rename。zip 读写只走 ffi/archiver。
--
-- chapters 契约(Task 5/6 供数):数组,每项
--   {chapter_uid=..., href=...(zip 全路径/相对 OPF 路径/纯文件名,依次精确、resolve、后缀匹配),
--    underlines={{range="a-b", markText=...}, ...}, review_map={[range]={{content,author,...}}}}
local Annotations = require("miuthought.annotations")
local AnnotationStyle = require("miuthought.annotation_style")
local EpubReader = require("miuthought.epub_reader")
local Json = require("miuthought.json")

local M = {}

M.MARKER = "miuthought.json"

function M.copy_path(src)
    src = tostring(src or "")
    local stem = src:match("^(.*)%.[eE][pP][uU][bB]$") or src
    return stem .. ".觅想.epub"
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

local function get_archiver(archiver)
    if archiver then return archiver end
    local ok, mod = pcall(require, "ffi/archiver")
    if not ok then return nil, "需要 KOReader v2025.08 或更新版本(缺少 ffi/archiver)" end
    return mod
end

function M.inject_copy(src, book_id, chapters, opts)
    opts = opts or {}
    local rename = opts.rename or os.rename
    local now = opts.now or os.time

    local meta, err = EpubReader.load(src, opts.archiver)
    if not meta then return nil, err end
    if meta.has[M.MARKER] then return nil, "该文件已是觅想版副本,请对原书执行注入" end

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

    local mod, arc_err = get_archiver(opts.archiver)
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
                local raw, read_err = EpubReader.read(meta, name, opts.archiver)
                if not raw then
                    writer:close()
                    os.remove(tmp)
                    return nil, read_err
                end
                content = raw
            end
            writer:addFileFromMemory(name, content, mtime)
            content = nil
            collectgarbage("step", 200)
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
