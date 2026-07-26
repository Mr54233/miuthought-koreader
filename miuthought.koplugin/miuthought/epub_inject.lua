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

-- 无 DRM 书也常带 encryption.xml 做字体混淆,这两种算法不影响注入,放行。
local FONT_OBFUSCATION_ALGOS = {
    ["http://www.idpf.org/2008/embedding"] = true,
    ["http://ns.adobe.com/pdf/enc#RC"] = true,
}

function M.copy_path(src)
    src = tostring(src or "")
    local stem = src:match("^(.*)%.[eE][pP][uU][bB]$") or src
    return stem .. ".觅想.epub"
end

function M.is_copy(path, archiver)
    local meta = EpubReader.load(path, archiver)
    return meta ~= nil and meta.has[M.MARKER] == true
end

local function drm_blocked(meta, archiver)
    if not meta.has["META-INF/encryption.xml"] then return false end
    local enc = EpubReader.read(meta, "META-INF/encryption.xml", archiver)
    if not enc then return true end
    local found = false
    for algo in enc:gmatch('Algorithm%s*=%s*"([^"]*)"') do
        found = true
        if not FONT_OBFUSCATION_ALGOS[algo] then return true end
    end
    for algo in enc:gmatch("Algorithm%s*=%s*'([^']*)'") do
        found = true
        if not FONT_OBFUSCATION_ALGOS[algo] then return true end
    end
    return not found
end

local function ensure_style(html)
    if html:find('id="' .. AnnotationStyle.INLINE_STYLE_ID .. '"', 1, true) then return html end
    local tag = AnnotationStyle.inline_style_tag()
    local head_end = html:find("</[Hh][Ee][Aa][Dd]%s*>")
    if head_end then
        return html:sub(1, head_end - 1) .. tag .. html:sub(head_end)
    end
    local _, body_end = html:find("<[Bb][Oo][Dd][Yy][^>]*>")
    if body_end then
        return html:sub(1, body_end) .. tag .. html:sub(body_end + 1)
    end
    -- 无 head/body 的碎片:插在 <html> 或 XML 声明之后,不能顶在 <?xml?> 前面。
    local _, html_end = html:find("<[Hh][Tt][Mm][Ll][^>]*>")
    if html_end then
        return html:sub(1, html_end) .. tag .. html:sub(html_end + 1)
    end
    local _, decl_end = html:find("^%s*<%?[^>]*%?>")
    if decl_end then
        return html:sub(1, decl_end) .. tag .. html:sub(decl_end + 1)
    end
    return tag .. html
end

-- href 匹配:精确 zip 路径 → 相对 OPF 解析 → 文件名后缀(多个命中视为歧义,不注入)。
local function match_entry(meta, href)
    href = tostring(href or "")
    if href == "" then return nil end
    if meta.has[href] then return href end
    local resolved = EpubReader.resolve(meta.opf_dir, href)
    if meta.has[resolved] then return resolved end
    local tail = "/" .. href:gsub("^/+", "")
    local found
    for _, item in ipairs(meta.spine) do
        if item.href:sub(-#tail) == tail then
            if found and found ~= item.href then return nil end
            found = item.href
        end
    end
    return found
end

local function range_of(row)
    if type(row) ~= "table" then return "" end
    local value = row.range or row.markRange or row.bookmarkRange
    local kind = type(value)
    return (kind == "string" or kind == "number") and tostring(value) or ""
end

-- 实际落进正文的锚点数:按划线 range 逐个在渲染结果里找 data-miu-range。
-- (annotations 的 dropped 不含去重叠环节丢弃的划线,直接数结果才准。)
local function count_marks(rendered, underlines)
    local n, seen = 0, {}
    for _, row in ipairs(underlines or {}) do
        local key = range_of(row)
        if key ~= "" and not seen[key] then
            seen[key] = true
            if rendered:find('data-miu-range="' .. key .. '"', 1, true) then n = n + 1 end
        end
    end
    return n
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
    if drm_blocked(meta, opts.archiver) then return nil, "该 EPUB 受 DRM 保护,无法注入想法" end

    -- 先算好每章的注入结果,全部成功后才写包。
    local targets, stats = {}, {
        injected = 0, marks = 0, unmatched = {}, quote_aligned = 0, dropped = 0,
    }
    local marker_chapters = {}
    local total_underlines = 0
    for _, ch in ipairs(chapters or {}) do
        total_underlines = total_underlines + #(ch.underlines or {})
        local entry_path = match_entry(meta, ch.href)
        if not entry_path or targets[entry_path] then
            -- 未匹配、歧义、或与前面章节撞到同一文件,都不能安静吞掉。
            stats.unmatched[#stats.unmatched + 1] = tostring(ch.chapter_uid or ch.href or "?")
        else
            local html, read_err = EpubReader.read(meta, entry_path, opts.archiver)
            if not html then return nil, read_err end
            local data = chapter_data(book_id, ch)
            local rendered, _, ch_stats = Annotations:new(nil):apply(html, data)
            local mark_count = count_marks(rendered, data.underlines)
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
    if stats.injected == 0 then
        if total_underlines == 0 then return nil, "没有划线数据,无需生成副本" end
        return nil, string.format("没有可注入的章节(未匹配 %d 章,定位失败 %d 条划线)",
            #stats.unmatched, stats.dropped)
    end

    local mod, arc_err = get_archiver(opts.archiver)
    if not mod then return nil, arc_err end

    local dest = opts.dest or M.copy_path(src)
    local tmp = dest .. ".tmp"
    local mtime = now()
    local writer = mod.Writer:new{}
    if not writer:open(tmp, "epub") then
        return nil, "无法创建副本:" .. tostring(writer.err or tmp)
    end

    local reader
    local function fail(message)
        local detail = writer.err
        writer:close()
        if reader then reader:close() end
        os.remove(tmp)
        return nil, message .. (detail and ("(" .. detail .. ")") or "")
    end

    writer:setZipCompression("store")
    local mime = meta.has["mimetype"] and EpubReader.read(meta, "mimetype", opts.archiver)
        or "application/epub+zip"
    if not writer:addFileFromMemory("mimetype", mime, mtime) then
        return fail("写入副本失败:mimetype")
    end
    writer:setZipCompression("deflate")

    -- 单遍流式复制:迭代中就地提取当前条目(与 archiveviewer 的 extractAll 同款),
    -- 避免每条目重开重扫整包。
    reader = mod.Reader:new()
    if not reader:open(src) then
        reader = nil
        return fail("无法打开 EPUB:" .. tostring(src))
    end
    local written = {["mimetype"] = true, [M.MARKER] = true}
    for entry in reader:iterate() do
        if entry.mode == "file" and not written[entry.path] then
            written[entry.path] = true
            local content = targets[entry.path] or reader:extractToMemory(entry.path)
            if not content then
                local read_err = reader.err
                return fail("无法读取 EPUB 条目:" .. entry.path
                    .. (read_err and ("(" .. read_err .. ")") or ""))
            end
            if not writer:addFileFromMemory(entry.path, content, mtime) then
                return fail("写入副本失败:" .. entry.path)
            end
            content = nil
            collectgarbage("step", 200)
        end
    end
    reader:close()
    reader = nil

    if not writer:addFileFromMemory(M.MARKER, Json.encode({
        version = 1, book_id = tostring(book_id or ""), created = mtime,
        source = src, chapters = marker_chapters,
    }), mtime) then
        return fail("写入副本失败:" .. M.MARKER)
    end
    writer:close()

    local ok, rename_err = rename(tmp, dest)
    if not ok then
        -- Windows 上 rename 不覆盖已存在目标:清掉旧副本重试一次。
        os.remove(dest)
        ok, rename_err = rename(tmp, dest)
    end
    if not ok then
        os.remove(tmp)
        return nil, "无法生成副本:" .. tostring(rename_err or "重命名失败")
    end
    stats.dest = dest
    return stats
end

return M
