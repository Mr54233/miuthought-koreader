local script=arg and arg[0] or ""
local root=script:match("^(.*)/tools/[^/]+$") or "."
local function read(path)
    local f=assert(io.open(root.."/"..path,"rb")); local s=f:read("*a"); f:close(); return s
end
local main=read("miuread.koplugin/main.lua")
local sync=read("miuread.koplugin/miuread/sync.lua")
local config=read("miuread.koplugin/miuread/config.lua")

assert(config:find('VERSION = "5.9.0-beta.11"',1,true),"beta.11 version")
assert(config:find('POSITION_CLOCK_SKEW_GRACE_SECONDS = 30',1,true),"30s resolver guard retained")

local function slice(source,a,b)
    local i=assert(source:find(a,1,true),"missing "..a)
    local j=b and source:find(b,i+1,true) or nil
    return source:sub(i,(j and j-1) or #source)
end

-- All manual entry points keep a source tag but share one progress helper.
local actions=slice(main,"function Plugin:_home_action_entries()","function Plugin:_home_alerts()")
assert(actions:find('self:_sync_home_pending({source="home_quick"})',1,true),"home quick source")
assert(not actions:find('_home_sync_summary(true)',1,true),"Home quick still depends on summary preflight")
assert(main:find('self:_sync_home_pending({source="sync_status_all"})',1,true),"sync status source")
assert(main:find('self:_sync_home_pending({source="progress_issues"})',1,true),"progress menu source")
assert(main:find('function Plugin:_sync_progress_full_recovery',1,true),"shared progress recovery helper")
assert(main:find('[MiuRead][SyncAction] progress recovery begin',1,true),"progress begin diagnostics")
assert(main:find('[MiuRead][SyncAction] progress recovery end',1,true),"progress end diagnostics")

local recovery=slice(main,"function Plugin:_sync_home_pending(options)","function Plugin:sync_settings_menu()")
local manual_start=assert(recovery:find('-- beta.11: every explicit Sync entry',1,true),"manual beta11 block")
local manual=recovery:sub(manual_start)
local gate=manual:find('[MiuRead][SyncAction] gate',1,true)
local login=manual:find('if not logged_in then',1,true)
local radio=manual:find('if radio==false then',1,true)
local run=manual:find('return phase_progress()',1,true)
assert(gate and login and radio and run and gate<login and login<radio and radio<run,
    "manual recovery does not gate before progress")
assert(recovery:find('local started=self:_sync_progress_full_recovery(source,true',1,true),
    "phase_progress does not use shared helper")
assert(recovery:find('正在确认阅读进度同步状态',1,true),
    "zero-summary manual recovery no longer verifies progress")

-- Wake/resume auto reconciliation must wait for an actually usable link.
assert(main:find('local require_online=options.require_online==true',1,true),"online gate option")
assert(main:find('HomeData.quick_device_state(true,true)',1,true),"online probe is not explicit")
assert(main:find('if state.online==true then return true end',1,true),"explicit online confirmation")
assert(main:find('state.connected==true and phase=="connected" and elapsed>=minimum+2',1,true),
    "stable-connected grace fallback")
assert(main:find('self:_wait_for_network("reader-progress-online"',1,true),"shared reader online waiter")
assert(main:find('source=network_restored',1,true),"network restored diagnostics")
assert(main:find('source=resume_recheck',1,true),"resume diagnostics")
assert(main:find('[MiuRead][ResumeSync] reconcile_started',1,true),"reconcile start diagnostics")
assert(main:find('require_online=true',1,true),"reader wait does not require online readiness")

-- beta.11 intentionally does NOT adopt the alternate branch's immediate detach.
assert(sync:find('finish(false,"time_writer_preempt_timeout")',1,true),"time-writer timeout guard removed")
assert(not sync:find('state="time_writer_detached"',1,true),"high-risk time-writer detach was adopted")

print("beta11 sync contract: PASS")
