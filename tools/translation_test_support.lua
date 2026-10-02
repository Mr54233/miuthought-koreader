-- Load selected production integration methods without booting KOReader.
-- Shared by the display, generation and real-archive translation regressions.
local M={}

function M.load_plugin_methods(root, names, env)
    local file=assert(io.open(root..'/main.lua','rb'))
    local source=file:read('*a')
    file:close()
    for _,name in ipairs(names) do
        local start=assert(source:find('function Plugin:'..name..'(',1,true),name..' missing')
        local finish=source:find('\nfunction Plugin:',start+1,true) or #source+1
        local fn=assert(loadstring(source:sub(start,finish-1),name))
        setfenv(fn,env)
        fn()
    end
end

return M
