-- 同步编排:拉取微信读书划线与想法 → 想法缓存 → 章节映射 → 注入副本。
-- 全部外部能力经 deps 注入,便于桌面测试;UI(进度/取消)由调用方通过 progress 提供。
--
-- deps:
--   doc_path        本地 EPUB 路径(原书)
--   book_id         微信读书 bookId
--   api             :chapters(book_id)
--   annotations     :fetch_chapter(book_id, uid) → 见 annotations.lua(网络重试在内部)
--   load_meta(path) → meta, err(epub_reader.load 的形状)
--   read_text(meta, href) → html|nil
--   save_thoughts(book_id, uid, review_groups)
--   inject(src, book_id, mapped_chapters) → stats, err(epub_inject.inject_copy 的形状)
--   progress(phase, i, n, text) → 返回 false 表示取消(可选)
local Binding = require("miuthought.binding")
local ChapterMap = require("miuthought.chapter_map")

local Sync = {}

function Sync.run(deps)
    local progress = deps.progress or function() return true end
    local function step(phase, i, n, text)
        return progress(phase, i, n, text) ~= false
    end

    local meta, meta_err = deps.load_meta(deps.doc_path)
    if not meta then return nil, meta_err end

    if not step("chapters", 0, 1, "获取章节列表") then return nil, "已取消" end
    local ok, chapters_raw = pcall(function() return deps.api:chapters(deps.book_id) end)
    if not ok then return nil, "获取章节列表失败:" .. tostring(chapters_raw) end
    local chapter_list = Binding.normalize_chapters(chapters_raw, deps.book_id)
    if #chapter_list == 0 then return nil, "微信读书返回的章节列表为空" end

    local fetched = {}
    local total_underlines = 0
    -- 硬失败=整章划线都没拉到(决定是否中止);部分失败=划线在手、想法批次有缺(只计报告)。
    local hard_failures, partial_errors, thoughts_saved = 0, 0, 0
    for i, ch in ipairs(chapter_list) do
        if not step("fetch", i, #chapter_list, ch.title) then return nil, "已取消" end
        local good, data = pcall(function()
            return deps.annotations:fetch_chapter(deps.book_id, ch.uid)
        end)
        if good and type(data) == "table" and data.underline_request_ok ~= false then
            if #(data.errors or {}) > 0 then partial_errors = partial_errors + 1 end
            total_underlines = total_underlines + (data.underline_count or 0)
            if (data.underline_count or 0) > 0 then
                fetched[#fetched + 1] = {
                    uid = ch.uid, title = ch.title,
                    underlines = data.underlines, review_map = data.review_map,
                }
            end
            if #(data.review_groups or {}) > 0 then
                local saved = pcall(deps.save_thoughts, deps.book_id, ch.uid, data.review_groups)
                if saved then thoughts_saved = thoughts_saved + 1 end
            end
        else
            hard_failures = hard_failures + 1
        end
    end
    if hard_failures >= #chapter_list then
        return nil, "划线拉取失败(共 " .. tostring(hard_failures) .. " 章),请检查网络后重试"
    end
    if total_underlines == 0 then return nil, "这本书在微信读书里没有划线" end

    if not step("map", 0, 1, "匹配本地章节") then return nil, "已取消" end
    local mapped, unmatched = ChapterMap.build(meta.spine, function(href)
        return deps.read_text(meta, href)
    end, fetched)
    if #mapped == 0 then
        return nil, "没有任何章节能匹配到本地书,请确认绑定的和本地打开的是同一本书"
    end

    if not step("inject", 0, 1, "生成觅想版副本") then return nil, "已取消" end
    local stats, inject_err = deps.inject(deps.doc_path, deps.book_id, mapped)
    if not stats then return nil, inject_err end

    return {
        dest = stats.dest,
        injected = stats.injected,
        marks = stats.marks,
        quote_aligned = stats.quote_aligned,
        dropped = stats.dropped,
        inject_unmatched = stats.unmatched,
        thoughts_saved = thoughts_saved,
        chapters_total = #chapter_list,
        chapters_with_data = #fetched,
        unmatched = unmatched,
        fetch_errors = hard_failures + partial_errors,
    }
end

return Sync
