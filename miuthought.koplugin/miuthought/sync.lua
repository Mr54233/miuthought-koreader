-- 同步编排:拉取微信读书划线与想法 → 想法缓存 → 章节映射 → 注入并替换原书。
-- 替换语义:首次同步把原书备份为 <path>.orig,注入版顶替原路径——KOReader 的
-- 阅读进度/侧车跟着路径走,进度得以保留;再次同步从 .orig 干净原书重新注入。
-- 全部外部能力经 deps 注入,便于桌面测试;UI(进度/取消)由调用方通过 progress 提供。
--
-- deps:
--   doc_path        本地 EPUB 路径(书架上正在用的路径)
--   book_id         微信读书 bookId
--   api             :chapters(book_id)
--   annotations     :fetch_chapter(book_id, uid) → 与 annotations.lua 同形
--   load_meta(path) → meta, err(epub_reader.load 的形状)
--   read_text(meta, href) → html|nil
--   save_thoughts(book_id, uid, review_groups)
--   inject(src, book_id, mapped_chapters, dest) → stats, err(epub_inject.inject_copy)
--   progress(phase, i, n, text) → 返回 false 表示取消(可选)
--   file_exists/rename/remove(可选,默认真实文件系统)
local Binding = require("miuthought.binding")
local ChapterMap = require("miuthought.chapter_map")
local EpubInject = require("miuthought.epub_inject")
local U = require("miuthought.util")

local Sync = {}

Sync.BACKUP_SUFFIX = ".orig"

function Sync.backup_path(doc_path) return tostring(doc_path) .. Sync.BACKUP_SUFFIX end

function Sync.run(deps)
    local progress = deps.progress or function() return true end
    local function step(phase, i, n, text)
        return progress(phase, i, n, text) ~= false
    end
    local file_exists = deps.file_exists or U.file_exists
    local rename = deps.rename or os.rename
    local remove = deps.remove or os.remove

    -- 源解析:书架路径若已是注入版(有 .orig 备份),从干净备份重新注入。
    local doc_path = tostring(deps.doc_path)
    local backup = Sync.backup_path(doc_path)
    local src = file_exists(backup) and backup or doc_path

    local meta, meta_err = deps.load_meta(src)
    if not meta then return nil, meta_err end
    if meta.has and meta.has[EpubInject.MARKER] then
        if src == doc_path then
            return nil, "这本书已被注入过,但找不到原书备份(" .. backup .. "),无法重新同步"
        end
        return nil, "原书备份本身是注入版,数据异常;请手动恢复原书后重试"
    end

    if not step("chapters", 0, 1, "获取章节列表") then return nil, "已取消" end
    local ok, chapters_raw = pcall(function() return deps.api:chapters(deps.book_id) end)
    if not ok then return nil, "获取章节列表失败:" .. tostring(chapters_raw) end
    local chapter_list = Binding.normalize_chapters(chapters_raw, deps.book_id)
    if #chapter_list == 0 then return nil, "微信读书返回的章节列表为空" end

    local fetched = {}
    local total_underlines = 0
    -- 硬失败=整章划线都没拉到(决定是否中止);部分失败=划线在手、想法批次有缺(只计报告)。
    local hard_failures, partial_errors = 0, 0
    local thoughts_saved, save_failures = 0, 0
    local consecutive_hard = 0
    -- 记住最后一次真实错误:失败消息必须告诉用户到底错在哪,不能只说「网络失败」。
    local last_error
    local function short_err(text)
        text = tostring(text or "未知错误"):gsub("^.-%.lua:%d+:%s*", "")
        if #text > 160 then text = text:sub(1, 160) .. "…" end
        return text
    end
    for i, ch in ipairs(chapter_list) do
        if not step("fetch", i, #chapter_list, ch.title) then return nil, "已取消" end
        local good, data = pcall(function()
            return deps.annotations:fetch_chapter(deps.book_id, ch.uid)
        end)
        if good and type(data) == "table" and data.underline_request_ok ~= false then
            -- 断点缓存命中(resumed)不算网络成功,不能复位熔断计数:
            -- 离线续传时散布的缓存命中会把计数清零,让熔断永不触发。
            if not data.resumed then consecutive_hard = 0 end
            if #(data.errors or {}) > 0 then partial_errors = partial_errors + 1 end
            total_underlines = total_underlines + (data.underline_count or 0)
            if (data.underline_count or 0) > 0 then
                fetched[#fetched + 1] = {
                    uid = ch.uid, title = ch.title,
                    underlines = data.underlines, review_map = data.review_map,
                }
            end
            if #(data.review_groups or {}) > 0 then
                local ok_save, saved = pcall(deps.save_thoughts, deps.book_id, ch.uid, data.review_groups)
                if ok_save and saved then
                    thoughts_saved = thoughts_saved + 1
                else
                    save_failures = save_failures + 1
                end
            end
        else
            hard_failures = hard_failures + 1
            consecutive_hard = consecutive_hard + 1
            if not good then
                last_error = tostring(data)
            elseif type(data) == "table" then
                last_error = tostring((data.errors or {})[1] or last_error or "接口返回异常")
            end
            -- 断网熔断:连续多章整章失败(每章重试要吃满超时)不能逐章磨完全书。
            -- 最后一章失败时不熔断,让已取到的数据走完正常出口。
            if consecutive_hard >= 3 and i < #chapter_list then
                return nil, string.format("连续 %d 章拉取失败,已中止同步。\n最后错误:%s",
                    consecutive_hard, short_err(last_error))
            end
        end
    end
    if hard_failures >= #chapter_list then
        return nil, string.format("划线拉取失败(共 %d 章)。\n最后错误:%s",
            hard_failures, short_err(last_error))
    end
    if total_underlines == 0 then
        if hard_failures > 0 then
            return nil, string.format("有 %d 章拉取失败,已成功的章节没有划线。\n最后错误:%s",
                hard_failures, short_err(last_error))
        end
        return nil, "这本书在微信读书里没有划线"
    end

    if not step("map", 0, 1, "匹配本地章节") then return nil, "已取消" end
    -- 每读一个 spine 文件发一次心跳(只作活动信号,不在文件中途响应取消),
    -- 免得特大书的纯 CPU 匹配被看门狗当成死吊。
    local map_count = 0
    local spine_total = #(meta.spine or {})
    local mapped, unmatched = ChapterMap.build(meta.spine, function(href)
        map_count = map_count + 1
        step("map", map_count, spine_total, href)
        return deps.read_text(meta, href)
    end, fetched)
    if #mapped == 0 then
        return nil, "没有任何章节能匹配到本地书,请确认绑定的和本地打开的是同一本书"
    end

    if not step("inject", 0, 1, "生成划线版") then return nil, "已取消" end
    -- 注入到中间文件(无 .epub 后缀,不会闪现在书架),成功后原子换位。
    local temp_dest = doc_path .. ".miuthought-new"
    local stats, inject_err = deps.inject(src, deps.book_id, mapped, temp_dest)
    if not stats then return nil, inject_err end

    if src == doc_path then
        -- 首次:原书让位为备份,注入版顶上原路径(进度侧车不动)。
        local ok_backup, backup_err = rename(doc_path, backup)
        if not ok_backup then
            remove(temp_dest)
            return nil, "无法备份原书:" .. tostring(backup_err or "重命名失败")
        end
    end
    local ok_swap, swap_err = rename(temp_dest, doc_path)
    if not ok_swap then
        remove(doc_path)
        ok_swap, swap_err = rename(temp_dest, doc_path)
    end
    if not ok_swap then
        remove(temp_dest)
        -- 回滚:无论首次还是重同步,书架路径上必须留有可读的书。
        if not file_exists(doc_path) then rename(backup, doc_path) end
        return nil, "无法替换原书:" .. tostring(swap_err or "重命名失败")
    end

    return {
        dest = doc_path,
        backup = backup,
        injected = stats.injected,
        marks = stats.marks,
        quote_aligned = stats.quote_aligned,
        dropped = stats.dropped,
        inject_unmatched = stats.unmatched,
        thoughts_saved = thoughts_saved,
        save_failures = save_failures,
        chapters_total = #chapter_list,
        chapters_with_data = #fetched,
        unmatched = unmatched,
        fetch_errors = hard_failures + partial_errors,
    }
end

return Sync
