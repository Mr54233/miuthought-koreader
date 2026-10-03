local script=arg and arg[0] or ""
local root=script:match("^(.*)/tools/[^/]+$") or "."
local function read(path)
    local f=assert(io.open(root.."/"..path,"rb")); local s=f:read("*a"); f:close(); return s
end
local main=read("miuread.koplugin/main.lua")

local function slice(source,a,b)
    local i=assert(source:find(a,1,true),"missing "..a)
    local j=b and source:find(b,i+1,true) or nil
    return source:sub(i,(j and j-1) or #source)
end

local actions=slice(main,"function Plugin:_home_action_entries()","function Plugin:_home_alerts()")
assert(actions:find('local refreshed=self:_home_sync_summary(true)',1,true),
    "Home quick Sync does not force a fresh Home sync summary")
assert(actions:find('self:_sync_home_pending({source="home_quick"})',1,true),
    "Home quick Sync lost the shared recovery pipeline")
assert(actions:find('[MiuRead][SyncAction] summary refreshed',1,true),
    "Home quick Sync refresh is not diagnosable")

local recovery=slice(main,"function Plugin:_sync_home_pending(options)","function Plugin:sync_settings_menu()")
for _,needle in ipairs({
    'local source=tostring(options.source or (manual and "manual_unspecified" or "background"))',
    '[MiuRead][SyncAction] start',
    '[MiuRead][SyncAction] progress snapshot',
    'stage=",tostring(stage or "unknown")',
    '[MiuRead][SyncAction] finish',
    'result=already_synced',
    'reason=login_required',
    'reason=wifi_off',
    'log_progress_snapshot("manual_preflight",progress_items)',
}) do assert(recovery:find(needle,1,true),"SyncAction diagnostics missing: "..needle) end

local status=slice(main,"function Plugin:show_sync_status(detail)","function Plugin:_relative_time")
-- show_sync_status appears after _relative_time in this file, so use a wider tail if needed.
if not status:find('source="sync_status_all"',1,true) then
    status=main:sub(assert(main:find("function Plugin:show_sync_status(detail)",1,true)))
end
assert(status:find('self:_sync_home_pending({source="sync_status_all"})',1,true),
    "Sync Status -> 全部重新同步 is not source-tagged")
assert(main:find('self:_sync_home_pending({source="progress_issues"})',1,true),
    "Progress issue menu lost its source-tagged shared recovery path")

print("beta9 home sync entry contract: PASS")
