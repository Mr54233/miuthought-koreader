local script = arg and arg[0] or ""
local root = script:match("^(.*)/tools/[^/]+$") or "."
package.path = root.."/miuread.koplugin/?.lua;"..root.."/miuread.koplugin/?/init.lua;"..package.path

local R = require("miuread.position_resolution")

local function pos(ch, co)
    return {chapter_uid=tostring(ch), canonical_offset=co, offset_basis="wr_data_co"}
end

local anchor = {chapter_uid="131", chapter_offset=8748, offset_basis="wr_data_co"}

-- Real-device beta.6 case: the cloud was on a clearly different chapter and
-- 76 seconds newer. beta.7's 30s skew guard must allow timestamp resolution.
local d1 = R.decide{
    local_position=pos(131,8748), remote_position=pos(169,19588),
    verified_anchor=anchor, local_seq=2, verified_seq=1,
    local_updated_at=1791014788, remote_updated_at=1791014864,
    clock_skew_grace=30,
}
assert(d1.winner=="remote", "76s newer cloud should win outside 30s grace")
assert(d1.reason=="remote_newer_timestamp", "expected timestamp winner")

-- The original dangerous close-clock class remains protected.
local d2 = R.decide{
    local_position=pos(132,4992), remote_position=pos(169,19588),
    verified_anchor=anchor, local_seq=3, verified_seq=1,
    local_updated_at=1791014909, remote_updated_at=1791014930,
    clock_skew_grace=30,
}
assert(d2.winner=="conflict", "21s difference must remain conflict")
assert(d2.reason=="ambiguous_clock_conflict", "expected close-clock conflict")

-- Exact equality stays aligned regardless of timestamps.
local d3 = R.decide{
    local_position=pos(132,4992), remote_position=pos(132,4992),
    verified_anchor=anchor, local_seq=4, verified_seq=4,
    local_updated_at=1791015039, remote_updated_at=1791015059,
    clock_skew_grace=30,
}
assert(d3.winner=="aligned", "same exact position must be aligned")

print("beta7 sync contract: PASS")
