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
local sync=read("miuread.koplugin/miuread/sync.lua")
local main=read("miuread.koplugin/main.lua")
local service=read("miuread.koplugin/miuread/read_report_service.lua")
local worker=read("miuread.koplugin/miuread/legacy/read_report_worker.lua")

assert(config:find('VERSION = "5.9.0-beta.16"',1,true),"beta.16 version")
assert(sync:find('local READ_REPORT_SERVICE_VERSION = 30',1,true),"read-report service version 30 missing")

-- One-shot clean-state migration must be schema-independent because beta.4-15
-- all used schema 136. It advances the transaction epoch and preserves UI/user data.
assert(store:find('progress_state_reset_beta16',1,true),"beta16 reset marker missing")
assert(store:find('beta16_one_shot_clean_state',1,true),"beta16 one-shot reset reason missing")
local reset=slice(store,'local PROGRESS_SYNC_RESET_KEYS={','local function emergency_compact_sessions')
for _,field in ipairs({
    '"cloud_anchor"','"remote_wire_anchor"','"remote"','"position_state"','"local_position_snapshot"',
    '"last_verified_exact_position"','"pending_progress"','"pending_progress_coordinate"',
    '"progress_latest_sequence"','"progress_verified_sequence"','"progress_submission_phase"',
    '"legacy_report_context"','"report_context"'
}) do assert(reset:find(field,1,true),"reset does not clear "..field) end
assert(reset:find('row.progress_epoch=previous_epoch+1',1,true),"reset does not advance progress_epoch")
assert(not reset:find('local_display_progress',1,true),"reset must preserve local display progress")
assert(not reset:find('last_read_at',1,true),"reset must preserve reading history")

-- Manual per-book reset must use the same comprehensive invalidation instead
-- of a smaller ad-hoc list.
local menu=slice(main,'{text="重置本书同步状态"','{text="重新检查本书批注同步"')
assert(menu:find('self.store:reset_progress_sync_state(id,"manual_book_progress_reset",true)',1,true),
    "manual reset does not use comprehensive store reset")

-- v30 time daemon may not serialize the old canonical/pending cloud anchor at all.
local control=slice(sync,'function Sync:_write_daemon_control','function Sync:_schedule_daemon_poll')
assert(control:find('local wire_anchor=book_id~="" and self:remote_wire_anchor(book_id) or nil',1,true),"wire anchor missing")
assert(not control:find('local cloud_anchor=book_id',1,true),"daemon still loads canonical cloud anchor")
assert(not control:find('cloud_anchor_chapter_uid=',1,true),"daemon still persists stale cloud uid")
assert(not control:find('cloud_anchor_chapter_offset=',1,true),"daemon still persists stale cloud co")
assert(control:find('remote_wire_chapter_uid=wire_anchor and wire_anchor.chapter_uid or nil',1,true),"wire uid missing")
assert(control:find('remote_wire_chapter_offset=wire_anchor and wire_anchor.chapter_offset or nil',1,true),"wire co missing")
local cloudsetter=slice(sync,'function Sync:set_cloud_anchor','function Sync:remote(')
assert(not cloudsetter:find('cloud_anchor_chapter_uid=',1,true),"set_cloud_anchor still leaks canonical uid to daemon")
assert(not cloudsetter:find('cloud_anchor_chapter_offset=',1,true),"set_cloud_anchor still leaks canonical co to daemon")
assert(not cloudsetter:find('self:_write_daemon_control',1,true),"set_cloud_anchor still writes daemon control")

-- Retain beta.15 hard safety: every compatibility time POST refreshes the
-- server position first; failure to GET current remote means no POST.
local compat=slice(worker,'if reading_time_compat then','local accepted, result')
assert(compat:find('local refreshed=refresh_remote_anchor(client, book_id, book)',1,true),"fresh GET before time POST lost")
assert(compat:find('fresh cloud reading position unavailable for reading-time report',1,true),"GET failure does not block POST")
assert(not compat:find('position_override = normalize_cloud_anchor(job.cloud_anchor, book)',1,true),"worker trusts cached anchor again")
local report=slice(service,'local report_job = {','local attempted_at = os.time()')
assert(report:find('control.remote_wire_chapter_uid',1,true),"service wire uid missing")
assert(not report:find('control.cloud_anchor_chapter_uid',1,true),"service reads old cloud uid")

-- Existing progress transaction epoch/sequence guard remains active.
assert(main:find('snapshot.progress_epoch=tonumber(snapshot.progress_epoch or position.progress_epoch) or current_epoch',1,true),"progress snapshot epoch missing")
assert(main:find('if snapshot_epoch~=current_epoch then return false end',1,true),"stale epoch guard missing")
assert(main:find('stale verification ignored',1,true),"stale verification guard missing")

print("beta16 clean sync state / ghost-write contract: PASS")
