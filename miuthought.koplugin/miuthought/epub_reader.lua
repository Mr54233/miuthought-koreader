-- EPUB 元数据读取:ffi/archiver (libarchive) 之上解析 container.xml → OPF → spine。
-- 要求 KOReader >= v2025.08;详见 docs/task3-zip-feasibility.md。
local U = require("miuthought.util")

local E = {}

local function get_archiver(archiver)
    if archiver then return archiver end
    local ok, mod = pcall(require, "ffi/archiver")
    if not ok then return nil, "需要 KOReader v2025.08 或更新版本(缺少 ffi/archiver)" end
    return mod
end

function E.available()
    local mod, err = get_archiver(nil)
    return mod ~= nil, err
end

function E.resolve(base_dir, href)
    local raw = U.url_decode(tostring(href or ""))
    raw = raw:gsub("^/+", "")
    local joined = (tostring(base_dir or "") ~= "" and not tostring(href or ""):match("^/"))
        and (base_dir .. "/" .. raw) or raw
    local parts = {}
    for seg in joined:gmatch("[^/]+") do
        if seg == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return table.concat(parts, "/")
end

local function attr(tag, name)
    return tag:match(name .. '%s*=%s*"([^"]*)"') or tag:match(name .. "%s*=%s*'([^']*)'")
end

local function open_reader(path, archiver)
    local mod, err = get_archiver(archiver)
    if not mod then return nil, err end
    local reader = mod.Reader:new()
    if not reader:open(path) then return nil, "无法打开 EPUB:" .. tostring(path) end
    return reader
end

function E.load(path, archiver)
    local reader, err = open_reader(path, archiver)
    if not reader then return nil, err end
    local names, has = {}, {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            names[#names + 1] = entry.path
            has[entry.path] = true
        end
    end
    local container = has["META-INF/container.xml"] and reader:extractToMemory("META-INF/container.xml")
    if not container then
        reader:close()
        return nil, "EPUB 缺少 META-INF/container.xml,不是有效的 EPUB"
    end
    local rootfile = container:match("<rootfile%s[^>]*>") or ""
    local opf_path = attr(rootfile, "full%-path")
    opf_path = opf_path and E.resolve("", opf_path) or nil
    if not opf_path or not has[opf_path] then
        reader:close()
        return nil, "EPUB 的 container.xml 未指向有效 OPF"
    end
    local opf = reader:extractToMemory(opf_path)
    reader:close()
    if not opf then return nil, "无法读取 OPF:" .. opf_path end

    local opf_dir = opf_path:match("^(.*)/[^/]+$") or ""
    local manifest = {}
    for tag in opf:gmatch("<item[%s/][^>]*>") do
        local id = attr(tag, "id")
        local href = attr(tag, "href")
        if id and href then
            manifest[id] = {href = E.resolve(opf_dir, href), media_type = attr(tag, "media%-type") or ""}
        end
    end
    local spine = {}
    for tag in opf:gmatch("<itemref[%s/][^>]*>") do
        local idref = attr(tag, "idref")
        local item = idref and manifest[idref]
        if item then
            spine[#spine + 1] = {idref = idref, href = item.href, media_type = item.media_type}
        end
    end
    if #spine == 0 then return nil, "OPF 中没有可用的 spine 章节" end
    return {path = path, names = names, has = has, opf_path = opf_path, opf_dir = opf_dir, spine = spine}
end

function E.read(meta, name, archiver)
    local reader, err = open_reader(meta.path, archiver)
    if not reader then return nil, err end
    local content = reader:seek(name) and reader:extractToMemory(name) or nil
    reader:close()
    if content == nil then return nil, "EPUB 中不存在条目:" .. tostring(name) end
    return content
end

return E
