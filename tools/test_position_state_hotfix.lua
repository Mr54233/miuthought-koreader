local TOOL_DIR=tostring(arg and arg[0] or ''):match('^(.*)/[^/]+$') or '.'
local ROOT=TOOL_DIR..'/../miuread.koplugin/'
package.path=ROOT..'?.lua;'..package.path

local R=require('miuread.position_resolution')

local remote={progress=100,percent=100,chapter_uid='40',offset=747,updated_at=1785082111,source='web_cookie'}
remote.sources={web=remote,agent={progress=99,chapter_uid='39',offset=500}}
local snap=assert(R.snapshot(remote))
assert(snap.sources==nil,'runtime sources graph crossed persistence boundary')
assert(snap.chapter_uid=='40' and snap.offset==747 and snap.percent==100,'scalar remote coordinate was damaged')
for _,v in pairs(snap) do assert(type(v)~='table','snapshot retained nested table') end

local state=R.state_snapshot{
    version=1,
    local_position={progress=1,chapter_uid='2',offset=570,safe=true},
    remote_position=remote,
    verified_anchor={chapter_uid='38',chapter_offset=5879,progress=87,sources={web={}}},
    resolved={source='remote',reason='test',resolved_at=100,extra={bad=true}},
    finished={local_finished=false,remote_finished=true,resolved_finished=true,source='remote',resolved_at=100,extra={bad=true}},
}
assert(state.remote_position.sources==nil,'state snapshot retained remote sources')
assert(state.verified_anchor.sources==nil,'state snapshot retained anchor sources')
assert(state.resolved.extra==nil and state.finished.extra==nil,'state snapshot retained nested diagnostics')

-- A merely observed cloud position is not a historical verified anchor.
local unverified=R.trusted_verified_anchor({remote_verified=false,verified_at=0},{verified_anchor={chapter_uid='40',chapter_offset=747,progress=100}})
assert(unverified==nil,'unverified cloud observation became a trusted anchor')

-- Explicit durable verified coordinates are authoritative even if the old
-- anchor object has a stale state label.
local trusted=assert(R.trusted_verified_anchor({
    remote_verified=true,verified_at=200,verified_chapter_uid='38',verified_chapter_offset=5879,
    verified_local_percent=87,verified_remote_percent=87,
},{verified_anchor={chapter_uid='38',chapter_offset=5879,progress=87,state='remote_observed'}}))
assert(tostring(trusted.chapter_uid)=='38' and tonumber(trusted.chapter_offset)==5879,'verified coordinate was not preserved')

-- First reconciliation: local has no durable event, remote has a timestamp.
local decision=R.decide{
    local_position={chapter_uid='2',offset=570,progress=0.2},
    remote_position={chapter_uid='40',offset=747,progress=100},
    verified_anchor=nil,local_seq=0,verified_seq=0,local_updated_at=0,remote_updated_at=1785082111,
}
assert(decision.winner=='remote','first reconciliation did not prefer the dated cloud position')

print('position state hotfix tests passed')
