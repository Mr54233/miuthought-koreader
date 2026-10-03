local function read(path)
    local f=assert(io.open(path,"rb")); local s=f:read("*a"); f:close(); return s
end
local main=read("miuread.koplugin/main.lua")
local sync=read("miuread.koplugin/miuread/sync.lua")
local worker=read("miuread.koplugin/miuread/legacy/read_report_worker.lua")
local service=read("miuread.koplugin/miuread/read_report_service.lua")
local store=read("miuread.koplugin/miuread/store.lua")

for _,needle in ipairs{
    "progress_write_blocked=true", "progress_write_fenced", "remote_fetch_pending",
    "remote_newer_pending", "remote_exact_unresolved", "open_local_position=",
    "jump_cached_remote_position", "text_anchor_rescue", "bounded percent fallback",
} do assert(main:find(needle,1,true),needle) end
assert(not main:find("automatic_check_after_user_interaction",1,true),"interaction cannot force local winner")
assert(not main:find("late_remote_after_user_interaction",1,true),"late interaction cannot force local winner")

assert(sync:find("First PageUpdate after opening only establishes the baseline",1,true),"first restored page must not become a local event")
assert(sync:find("local freshness belongs to progress reconciliation",1,true),"local event tracking must be independent of time sync")
assert(sync:find("remote_xpointer_cache",1,true),"verified remote XPointer cache exists")
assert(sync:find("best_effort_runtime_only",1,true),"reading time has no durable retry debt")

assert(worker:find("anchor.canonical_progress or anchor.calculated_percent or anchor.progress",1,true),"read report consumes canonical progress")
assert(not worker:find("anchor.raw_percent or anchor.raw_progress",1,true),"raw percent cannot lead canonical anchor")
assert(service:find('state = drop_time and "dropped"',1,true),"time retry budget drops exhausted task")
assert(store:find("reading-time retry state cleared at startup",1,true),"old beta.4 time failures are cleaned")

print("beta.5 sync contract: PASS")
