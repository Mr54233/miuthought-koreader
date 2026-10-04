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
local main=read("miuread.koplugin/main.lua")
local sync=read("miuread.koplugin/miuread/sync.lua")
local service=read("miuread.koplugin/miuread/read_report_service.lua")
local worker=read("miuread.koplugin/miuread/legacy/read_report_worker.lua")
local source=read("miuread.koplugin/miuread/source_position.lua")
local config=read("miuread.koplugin/miuread/config.lua")

assert(config:find('VERSION = "5.9.0-beta.15"',1,true),"beta.15 version")
assert(sync:find('local READ_REPORT_SERVICE_VERSION = 29',1,true),"read-report service version not bumped")

-- A server observation must create/update a raw wire anchor independently of
-- canonical CloudAnchor and independently of local pending progress.
assert(sync:find('local function remote_wire_anchor_from',1,true),"remote wire parser missing")
assert(sync:find('function Sync:remote_wire_anchor',1,true),"remote wire getter missing")
assert(sync:find('function Sync:set_remote_wire_anchor',1,true),"remote wire setter missing")
assert(sync:find('self:set_remote_wire_anchor(book_id,remote,"remote_observed_wire",true)',1,true),"remote GET does not refresh wire anchor")
local remote_block=slice(sync,'-- beta.15: every authoritative server observation refreshes the wire','if remote.conflict then')
assert(remote_block:find('set_remote_wire_anchor',1,true),"wire anchor update missing from remote block")
assert(remote_block:find('options.update_cloud_anchor~=false',1,true),"canonical CloudAnchor gate unexpectedly removed")
assert(remote_block:find('set_remote_wire_anchor',1,true) < remote_block:find('options.update_cloud_anchor~=false',1,true),"wire anchor still depends on CloudAnchor gate")

-- The periodic reading-time control uses a dedicated server-wire channel.
local control=slice(sync,'function Sync:_write_daemon_control','function Sync:_schedule_daemon_poll')
assert(control:find('local wire_anchor=book_id~="" and self:remote_wire_anchor(book_id) or nil',1,true),"daemon does not load wire anchor")
assert(control:find('remote_wire_chapter_uid=wire_anchor and wire_anchor.chapter_uid or nil',1,true),"daemon wire uid field missing")
assert(control:find('remote_wire_chapter_offset=wire_anchor and wire_anchor.chapter_offset or nil',1,true),"daemon wire co field missing")
assert(control:find('remote_wire_protocol_progress=wire_anchor and wire_anchor.protocol_progress or nil',1,true),"daemon wire protocol progress missing")

-- read_report_service must never route time-only compatibility writes through
-- the old canonical/pending cloud_anchor fields.
local report=slice(service,'local report_job = {','local attempted_at = os.time()')
assert(report:find('control.remote_wire_chapter_uid',1,true),"service does not use remote wire uid")
assert(report:find('control.remote_wire_chapter_offset',1,true),"service does not use remote wire co")
assert(report:find('control.remote_wire_protocol_progress',1,true),"service does not use remote wire progress")
assert(not report:find('control.cloud_anchor_chapter_uid',1,true),"time writer still uses old cloud anchor uid")
assert(not report:find('control.cloud_anchor_chapter_offset',1,true),"time writer still uses old cloud anchor co")

-- Missing wire anchor is safe: worker refreshes the server position and uses
-- the protocol/raw progress instead of requiring locally-derived canonical pr.
local norm=slice(worker,'local function normalize_cloud_anchor','local function refresh_remote_anchor')
assert(norm:find('anchor.protocol_progress or anchor.raw_progress or anchor.raw_percent',1,true),"wire protocol progress not accepted")
assert(norm:find('book.remote_raw_progress',1,true),"fresh server fallback cannot normalize raw progress")
local compat=slice(worker,'if reading_time_compat then','local accepted, result')
assert(compat:find('local refreshed=refresh_remote_anchor(client, book_id, book)',1,true),"reading-time write does not require fresh server GET")
assert(compat:find('fresh cloud reading position unavailable for reading-time report',1,true),"failed GET can still fall through to a position write")
assert(not compat:find('position_override = normalize_cloud_anchor(job.cloud_anchor, book)',1,true),"reading-time write still trusts cached parent anchor")

-- Manual safe reading-time retry follows the same remote-wire rule.
local retry=slice(sync,'function Sync:retry_safe_reading_time','function Sync:begin_progress_write')
assert(retry:find('local anchor=self:remote_wire_anchor(book_id)',1,true),"safe retry still uses canonical CloudAnchor")
assert(not retry:find('local anchor=self:cloud_anchor(book_id)',1,true),"safe retry stale cloud anchor path remains")

-- Exact jump diagnostics now distinguish call failures from zero/multiple hits
-- and use the same full CREngine invocation with a compatibility fallback.
local rescue=slice(sync,'function Sync:text_anchor_rescue','function Sync:chapter_anchor_rescue')
assert(rescue:find('document.findAllText,document,query,true,3,40,false,flags',1,true),"standard CREngine search call missing")
assert(rescue:find('document.findAllText,document,query,true,3,40)',1,true),"compat CREngine fallback missing")
for _,state in ipairs({'state=call_failed','state=invalid_return','state=zero_hits','state=hits_outside_chapter','state=multiple_hits','state=unique_hit'}) do
    assert(rescue:find(state,1,true),"missing diagnostic "..state)
end
assert(rescue:find('query_hash=',1,true),"query hash diagnostic missing")
assert(rescue:find('utf8_valid=',1,true),"UTF-8 diagnostic missing")
assert(not rescue:find('return false,"text_anchor_search_failed"',1,true),"generic swallowed search error remains")

-- beta.14/beta.12 safety remains unchanged.
assert(main:find('remote_chapter_resolved',1,true),"beta.14 soft mismatch behavior lost")
assert(main:find('_restore_position_rollback("remote exact verification failed"',1,true),"hard mismatch rollback lost")
assert(source:find('options.force_refresh == true and (refresh_uid == "" or refresh_uid == uid)',1,true),"beta.12 source refresh lost")
assert(sync:find('FFIUtil.isSubProcessDone,pid,false',1,true),"beta.12 subprocess completion fix lost")

print("beta15 cloud position integrity contract: PASS")
