local script=arg and arg[0] or ""
local root=script:match("^(.*)/tools/[^/]+$") or "."
local function read(path)
    local f=assert(io.open(root.."/"..path,"rb")); local s=f:read("*a"); f:close(); return s
end
local function slice(text,a,b)
    local i=assert(text:find(a,1,true),"missing "..a)
    local j=b and text:find(b,i+1,true) or nil
    return text:sub(i,(j and j-1) or #text)
end
local config=read("miuread.koplugin/miuread/config.lua")
local store=read("miuread.koplugin/miuread/store.lua")
local main=read("miuread.koplugin/main.lua")
local sync=read("miuread.koplugin/miuread/sync.lua")
local worker=read("miuread.koplugin/miuread/legacy/read_report_worker.lua")

assert(config:find('VERSION = "5.9.0-beta.17"',1,true),"beta.17 version")
assert(sync:find('local READ_REPORT_SERVICE_VERSION = 30',1,true),"read-report v30 retained")

-- beta.17 fixes the beta.16 reset resurrection bug: epoch dominates old seq.
assert(store:find('progress_state_reset_beta17',1,true),"beta17 reset marker missing")
assert(store:find('beta17_epoch_authoritative_clean_state',1,true),"beta17 reset reason missing")
assert(store:find('if disk_epoch>memory_epoch then',1,true),"epoch does not dominate merge")
assert(store:find('PROGRESS_EPOCH_CONTROL_FIELDS',1,true),"epoch control fields missing")
assert(store:find('stale progress generation suppressed',1,true),"epoch suppression diagnostic missing")
local reset=slice(store,'local PROGRESS_SYNC_RESET_KEYS={','local function emergency_compact_sessions')
assert(reset:find('"pending_unresolved_position"',1,true),"unresolved snapshot survives reset")
assert(reset:find('"local_read_event_at"',1,true),"old local freshness survives reset")
assert(not reset:find('local_display_progress',1,true),"reset must preserve local display progress")

-- Authority conflicts are terminal automatic states: no Home retry may choose a side.
local issues=slice(main,'function Plugin:_progress_sync_issue_items','function Plugin:_reading_time_sync_issue_items')
assert(issues:find('authority_conflict=pending_reason:find("^write_fenced:conflict:")~=nil',1,true),"authority conflict classification missing")
assert(issues:find('local can_send=can_replay and not authority_conflict',1,true),"conflict can auto-send")
assert(issues:find('local can_verify=can_replay and not can_send and not authority_conflict',1,true),"conflict can auto-verify")
assert(issues:find('local can_resubmit=not authority_conflict',1,true),"conflict can auto-resubmit")
assert(issues:find('requires_choice=authority_conflict',1,true),"choice-required state missing")

local remote=slice(main,'function Plugin:_adopt_remote_progress_issue','function Plugin:_force_local_progress_issue')
assert(remote:find('self.sync:remote(book_id,function(remote,err)',1,true),"remote authority does not fresh GET")
assert(remote:find('self.store:reset_progress_sync_state(book_id,"user_adopt_remote_authority",true)',1,true),"remote authority does not invalidate old generation")
assert(remote:find('progress_sync_state="remote_baseline"',1,true),"remote baseline state missing")
assert(remote:find('remote=remote_snapshot,position_state=state,remote_checked_at=os.time()',1,true),"remote scalar baseline not restored after reset")

local localwin=slice(main,'function Plugin:_force_local_progress_issue','function Plugin:_show_progress_sync_issue_detail')
assert(localwin:find('snapshot_epoch~=current_epoch',1,true),"local choice accepts stale generation")
assert(localwin:find('force_write=true',1,true),"explicit local authority does not force exact write")
assert(localwin:find('exact_native_coordinate_required',1,true),"local authority does not require native wr_data_co")
assert(localwin:find('_progress_snapshot_replayable(current)',1,true),"local choice does not require replayable exact snapshot")

local detail=slice(main,'function Plugin:_show_progress_sync_issue_detail','function Plugin:show_progress_sync_issues')
assert(detail:find('{text="以云端为准"',1,true),"remote authority UI missing")
assert(detail:find('{text="以本机为准"',1,true),"local authority UI missing")
assert(detail:find('{text="清除失效记录"',1,true),"stale delete UI missing")

-- Retain beta.15/16 reading-time safety.
local compat=slice(worker,'if reading_time_compat then','local accepted, result')
assert(compat:find('local refreshed=refresh_remote_anchor(client, book_id, book)',1,true),"fresh GET before time POST lost")
assert(compat:find('fresh cloud reading position unavailable for reading-time report',1,true),"GET failure does not block time POST")
assert(not compat:find('position_override = normalize_cloud_anchor(job.cloud_anchor, book)',1,true),"cached canonical anchor trusted again")

print("beta17 progress failure lifecycle / epoch authority contract: PASS")
