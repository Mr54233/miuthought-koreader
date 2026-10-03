local script=arg and arg[0] or ""
local root=script:match("^(.*)/tools/[^/]+$") or "."
local function read(path)
    local f=assert(io.open(root.."/"..path,"rb")); local s=f:read("*a"); f:close(); return s
end
local main=read("miuread.koplugin/main.lua")
local sync=read("miuread.koplugin/miuread/sync.lua")
local source=read("miuread.koplugin/miuread/source_position.lua")
local config=read("miuread.koplugin/miuread/config.lua")

assert(config:find('VERSION = "5.9.0-beta.12"',1,true),"beta.12 version")
assert(config:find('POSITION_CLOCK_SKEW_GRACE_SECONDS = 30',1,true),"30s resolver guard retained")

local function slice(text,a,b)
    local i=assert(text:find(a,1,true),"missing "..a)
    local j=b and text:find(b,i+1,true) or nil
    return text:sub(i,(j and j-1) or #text)
end

-- beta.11 manual recovery convergence stays intact.
local actions=slice(main,"function Plugin:_home_action_entries()","function Plugin:_home_alerts()")
assert(actions:find('self:_sync_home_pending({source="home_quick"})',1,true),"home quick source")
assert(not actions:find('_home_sync_summary(true)',1,true),"Home quick still depends on summary preflight")
assert(main:find('self:_sync_home_pending({source="sync_status_all"})',1,true),"sync status source")
assert(main:find('self:_sync_home_pending({source="progress_issues"})',1,true),"progress menu source")
assert(main:find('function Plugin:_sync_progress_full_recovery',1,true),"shared progress recovery helper")
assert(main:find('HomeData.quick_device_state(true,true)',1,true),"wake online probe retained")
assert(main:find('require_online=true',1,true),"wake online readiness retained")

-- beta.12: the network recovery phase must be a real source refresh, not a
-- second read of the exact/legacy cache that just failed anchor resolution.
assert(source:find('local refresh_uid = tostring(options.force_refresh_uid or "")',1,true),"force refresh option missing")
assert(source:find('options.force_refresh == true and (refresh_uid == "" or refresh_uid == uid)',1,true),"targeted force refresh missing")
assert(source:find('if not force_refresh then',1,true),"cache bypass guard missing")
assert(source:find('reason=force_source_refresh',1,true),"cache bypass diagnostic missing")
assert(sync:find('SourcePosition.locate(reader, record_snapshot, anchor,{cache_only=false,force_refresh=true,force_refresh_uid=tostring(anchor.chapter_uid or \"\")})',1,true),
    "network recovery does not force fresh coord_html")
assert(source:find('source_kind=network_refresh',1,true),"network refresh diagnostic missing")

-- beta.12: retain single-writer safety, but let KOReader's subprocess runtime
-- confirm an exited/reaped child before kill(pid,0) can misclassify it alive.
assert(sync:find('local function subprocess_done(pid)',1,true),"subprocess completion helper missing")
assert(sync:find('FFIUtil.isSubProcessDone,pid,false',1,true),"KOReader subprocess completion API unused")
local preempt=slice(sync,'function Sync:preempt_reading_time_for_progress','function Sync:_cancel_record_retry()')
assert(preempt:find('subprocess_done(pid) or not process_alive(pid)',1,true),"preempt does not consult subprocess completion")
assert(preempt:find('finish(false,"time_writer_preempt_timeout")',1,true),"timeout safety guard removed")
assert(not preempt:find('state="time_writer_detached"',1,true),"unsafe immediate detach adopted")
assert(preempt:find('signal_process,pid,9',1,true),"hard-kill fallback removed")

print("beta12 sync contract: PASS")
