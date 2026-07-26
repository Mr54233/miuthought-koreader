-- 本地书 ↔ 微信读书书目的绑定:搜索/章节响应规范化 + 按文档路径持久化。
-- store 只需 get(k, default) / set(k, v) 两个方法。
local Binding = {}

local KEY = "bindings"

local function scalar_str(v)
    local kind = type(v)
    if kind == "string" or kind == "number" then return tostring(v) end
    return ""
end

local function rows_of(data, names)
    if type(data) ~= "table" then return {} end
    for _, name in ipairs(names) do
        if type(data[name]) == "table" then return data[name] end
    end
    if #data > 0 then return data end
    return {}
end

function Binding.normalize_search(data)
    local out = {}
    for _, row in ipairs(rows_of(data, {"books", "results", "updated"})) do
        if type(row) == "table" then
            local info = type(row.bookInfo) == "table" and row.bookInfo or row
            local book_id = scalar_str(info.bookId or info.book_id)
            if book_id ~= "" then
                out[#out + 1] = {
                    book_id = book_id,
                    title = scalar_str(info.title),
                    author = scalar_str(info.author),
                }
            end
        end
    end
    return out
end

function Binding.normalize_chapters(data)
    local out = {}
    for index, row in ipairs(rows_of(data, {"data", "updated", "chapters"})) do
        if type(row) == "table" then
            local uid = scalar_str(row.chapterUid or row.chapterId or row.uid)
            if uid ~= "" then
                out[#out + 1] = {
                    uid = uid,
                    title = scalar_str(row.title),
                    idx = tonumber(row.chapterIdx) or index,
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.idx < b.idx end)
    return out
end

function Binding.get(store, doc_path)
    local all = store:get(KEY, {})
    return all[tostring(doc_path or "")]
end

function Binding.save(store, doc_path, record)
    local all = store:get(KEY, {})
    record = record or {}
    if not record.bound_at then record.bound_at = os.time() end
    all[tostring(doc_path or "")] = record
    store:set(KEY, all)
end

function Binding.clear(store, doc_path)
    local all = store:get(KEY, {})
    all[tostring(doc_path or "")] = nil
    store:set(KEY, all)
end

return Binding
