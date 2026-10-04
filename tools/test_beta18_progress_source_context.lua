local script=arg and arg[0] or ""
local root=script:match("^(.*)/tools/[^/]+$") or "."
local function read(path)
    local f=assert(io.open(root.."/"..path,"rb")); local s=f:read("*a"); f:close(); return s
end
local reader=read("miuread.koplugin/miuread/reader.lua")
local source=read("miuread.koplugin/miuread/source_position.lua")
local config=read("miuread.koplugin/miuread/config.lua")
local sync=read("miuread.koplugin/miuread/sync.lua")

assert(config:find('VERSION = "5.9.0-beta.18"',1,true),"beta.18 version")
assert(sync:find('local READ_REPORT_SERVICE_VERSION = 30',1,true),"ReadReport v30 retained")

-- Progress source network refresh must use a target-chapter fresh Reader page/context.
assert(source:find('{images=false, fresh_context=true}',1,true),"progress source does not request fresh context")
assert(source:find('reader_context=fresh',1,true),"fresh-context diagnostic missing")

-- Every content path that may own state must honor the explicit fresh-context option.
local token='opt.translation==true or opt.fresh_context==true'
local _,count=reader:gsub(token,'')
assert(count==3,"fresh_context must reach _chapter_once/_epub_once/_txt_once; count="..tostring(count))
assert(reader:find('if fresh then',1,true),"chapter_state fresh bypass missing")
assert(reader:find('self:state(book_id,chapter_uid,keepalive,true)',1,true),"fresh chapter state does not fetch target Reader page")

-- Do not globally disable beta.23 context reuse: ordinary downloads still use the cache.
assert(reader:find('READER_CONTEXT_MAX_AGE',1,true),"reader context cache removed globally")
assert(reader:find('local cached=self._reader_context',1,true),"ordinary cached context path removed")

-- Exactness contract remains fail-closed; beta.18 does not introduce approximate co upload.
assert(source:find('source_anchor_not_found',1,true),"source anchor failure contract lost")
assert(not source:find('forward_16',1,true),"beta.18 unexpectedly changes anchor algorithm")

print("beta18 fresh progress source context contract: PASS")
