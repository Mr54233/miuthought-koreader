-- 桌面(LuaJIT)测试环境:stub 掉 KOReader 专属模块,mock ffi/archiver。
-- 用法:tests/run.lua 最先 require 本文件。
local M = {}

package.path = "miuthought.koplugin/?.lua;" .. package.path

package.preload["logger"] = function()
    local function noop() end
    return {dbg = noop, info = noop, warn = noop, err = noop}
end

-- 最小 JSON 引擎,满足 miuthought.json 的 encode/decode 需求(测试数据范围内)。
package.preload["json"] = function()
    local J = {}
    local ESC = {['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
        ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t"}
    local function is_array(t)
        local n = 0
        for k in pairs(t) do
            if type(k) ~= "number" then return false end
            n = n + 1
        end
        return n == #t
    end
    function J.encode(v)
        local kind = type(v)
        if v == nil then return "null" end
        if kind == "boolean" or kind == "number" then return tostring(v) end
        if kind == "string" then
            return '"' .. v:gsub('[%z\1-\31"\\]', function(c)
                return ESC[c] or string.format("\\u%04x", c:byte())
            end) .. '"'
        end
        if kind == "table" then
            local out = {}
            if is_array(v) then
                for _, item in ipairs(v) do out[#out + 1] = J.encode(item) end
                return "[" .. table.concat(out, ",") .. "]"
            end
            for k, item in pairs(v) do
                out[#out + 1] = J.encode(tostring(k)) .. ":" .. J.encode(item)
            end
            return "{" .. table.concat(out, ",") .. "}"
        end
        error("无法编码类型:" .. kind)
    end
    function J.decode(text)
        local pos = 1
        local function skip()
            local _, e = text:find("^[ \t\r\n]*", pos)
            pos = e + 1
        end
        local parse_value
        local function parse_string()
            local out = {}
            pos = pos + 1
            while true do
                local c = text:sub(pos, pos)
                if c == "" then error("字符串未闭合") end
                if c == '"' then pos = pos + 1; return table.concat(out) end
                if c == "\\" then
                    local n = text:sub(pos + 1, pos + 1)
                    local map = {b = "\b", f = "\f", n = "\n", r = "\r", t = "\t"}
                    if n == "u" then
                        local hex = text:sub(pos + 2, pos + 5)
                        local cp = tonumber(hex, 16) or 0
                        out[#out + 1] = cp < 0x80 and string.char(cp) or "?"
                        pos = pos + 6
                    else
                        out[#out + 1] = map[n] or n
                        pos = pos + 2
                    end
                else
                    out[#out + 1] = c
                    pos = pos + 1
                end
            end
        end
        parse_value = function()
            skip()
            local c = text:sub(pos, pos)
            if c == '"' then return parse_string() end
            if c == "{" then
                pos = pos + 1
                local obj = {}
                skip()
                if text:sub(pos, pos) == "}" then pos = pos + 1; return obj end
                while true do
                    skip()
                    local key = parse_string()
                    skip()
                    pos = pos + 1 -- ':'
                    obj[key] = parse_value()
                    skip()
                    local sep = text:sub(pos, pos)
                    pos = pos + 1
                    if sep == "}" then return obj end
                end
            end
            if c == "[" then
                pos = pos + 1
                local arr = {}
                skip()
                if text:sub(pos, pos) == "]" then pos = pos + 1; return arr end
                while true do
                    arr[#arr + 1] = parse_value()
                    skip()
                    local sep = text:sub(pos, pos)
                    pos = pos + 1
                    if sep == "]" then return arr end
                end
            end
            local literal = text:match("^[%w%.%+%-]+", pos)
            pos = pos + #literal
            if literal == "true" then return true end
            if literal == "false" then return false end
            if literal == "null" then return nil end
            return tonumber(literal)
        end
        return parse_value()
    end
    return J
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function() return nil end,
        symlinkattributes = function() return nil end,
        dir = function() return function() return nil end end,
        mkdir = function() return true end,
        rmdir = function() return true end,
    }
end

-- 内存版 ffi/archiver:与真实 API 同形(Reader:new/open/iterate/seek/extractToMemory/close,
-- Writer:new/open/setZipCompression/addFileFromMemory/close)。
-- files: 有序数组 {{path=..., content=...}, ...} 模拟 zip 条目顺序。
-- mod._last_writer 记录最后创建的 Writer 供测试断言。
function M.archiver_mock(files)
    local mod = {}

    local Reader = {}
    Reader.__index = Reader
    function Reader:new() return setmetatable({}, self) end
    function Reader:open(path)
        self.path = path
        self.by_path = {}
        for _, f in ipairs(files) do self.by_path[f.path] = f end
        return true
    end
    function Reader:iterate()
        local i = 0
        return function()
            i = i + 1
            local f = files[i]
            if not f then return nil end
            return {path = f.path, mode = "file", size = #f.content, index = i}
        end
    end
    function Reader:seek(key)
        local f = type(key) == "number" and files[key] or self.by_path[key]
        return f and {path = f.path, mode = "file", size = #f.content} or nil
    end
    function Reader:extractToMemory(key)
        local f = type(key) == "number" and files[key] or self.by_path[key]
        return f and f.content or nil
    end
    function Reader:close() end

    local Writer = {}
    Writer.__index = Writer
    function Writer:new()
        local w = setmetatable({entries = {}, compression = "deflate"}, self)
        mod._last_writer = w
        return w
    end
    function Writer:open(path, format)
        self.opened_path, self.format = path, format
        return true
    end
    function Writer:setZipCompression(method) self.compression = method end
    function Writer:addFileFromMemory(entry_path, content, mtime)
        self.entries[#self.entries + 1] = {
            path = entry_path, content = content, mtime = mtime, compression = self.compression,
        }
    end
    function Writer:close() self.closed = true end

    mod.Reader, mod.Writer = Reader, Writer
    return mod
end

function M.written(writer) return writer.entries end

return M
