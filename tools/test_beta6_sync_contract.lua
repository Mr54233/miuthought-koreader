package.path = "./miuread.koplugin/?.lua;./miuread.koplugin/?/init.lua;" .. package.path
local R=require("miuread.position_resolution")

local function p(ch,co,updated)
    return {chapter_uid=tostring(ch),chapter_offset=co,canonical_offset=co,offset=co,offset_basis="wr_data_co",updated_at=updated}
end

-- A runtime remote graph may be cyclic; the persisted/IPC snapshot must be scalar-only.
local remote=p(127,4885,2000)
remote.sources={}
remote.sources.web=remote
remote.sources.agent={selected=remote}
local snap=R.snapshot(remote)
assert(type(snap)=="table","snapshot missing")
assert(snap.chapter_uid=="127" and snap.chapter_offset==4885,"coordinate lost during scalarization")
assert(snap.sources==nil,"cyclic runtime sources leaked into scalar snapshot")
for k,v in pairs(snap) do
    assert(type(v)~="table", "snapshot field is not scalar: "..tostring(k))
end

-- A newer local reading event may resolve a later recovery even if exact mapping had failed earlier.
local anchor={chapter_uid="127",chapter_offset=4885,offset_basis="wr_data_co"}
local r=R.decide{
    local_position=p(131,8748,3000),
    remote_position=p(127,4885,2000),
    verified_anchor=anchor,
    local_seq=8,verified_seq=7,
    local_updated_at=3000,remote_updated_at=2000,
    clock_skew_grace=120,
}
assert(r.winner=="local","new local event after shared anchor must remain recoverable")

-- If both sides changed inside the clock-skew grace window, recovery must defer rather than overwrite.
r=R.decide{
    local_position=p(131,8748,3000),
    remote_position=p(129,6000,3050),
    verified_anchor=anchor,
    local_seq=8,verified_seq=7,
    local_updated_at=3000,remote_updated_at=3050,
    clock_skew_grace=120,
}
assert(r.winner=="conflict","ambiguous dual-device change must remain deferred")

print("beta6 sync contract: PASS")
