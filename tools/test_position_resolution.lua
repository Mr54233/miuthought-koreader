package.path = "./miuread.koplugin/?.lua;./miuread.koplugin/?/init.lua;" .. package.path
local R=require("miuread.position_resolution")
local function p(ch,co,percent,updated) return {chapter_uid=tostring(ch),chapter_offset=co,progress=percent,updated_at=updated} end
local anchor={chapter_uid="10",chapter_offset=100,server_updated=1000}
assert(R.same_position(p(10,100),p(10,108))==true,"strict co tolerance")
assert(R.same_position(p(10,100),p(11,100))==false,"chapter mismatch")
local r=R.decide{local_position=p(10,100,80),remote_position=p(10,100,80),verified_anchor=anchor,local_seq=1,verified_seq=1}
assert(r.winner=="aligned","same exact position")
r=R.decide{local_position=p(11,20,40),remote_position=p(10,100,90),verified_anchor=anchor,local_seq=2,verified_seq=1,local_updated_at=2000,remote_updated_at=1000}
assert(r.winner=="local","local seq wins even when percent smaller")
r=R.decide{local_position=p(10,100,100),remote_position=p(12,20,8,3000),verified_anchor=anchor,local_seq=1,verified_seq=1,local_updated_at=1000,remote_updated_at=3000}
assert(r.winner=="remote","new 8 percent beats old 100 percent")
r=R.decide{local_position=p(11,20,70),remote_position=p(12,20,60),verified_anchor=anchor,local_seq=2,verified_seq=1,local_updated_at=5000,remote_updated_at=5200,clock_skew_grace=120}
assert(r.winner=="remote","clear newer remote timestamp")
r=R.decide{local_position=p(11,20,70),remote_position=p(12,20,60),verified_anchor=anchor,local_seq=2,verified_seq=1,local_updated_at=5000,remote_updated_at=5050,clock_skew_grace=120}
assert(r.winner=="conflict" and r.reason=="ambiguous_clock_conflict","ambiguous clocks must not overwrite either side")
print("position resolution: PASS")

-- Fetch time must not masquerade as server modification time; zero timestamps fall back safely.
r=R.decide{local_position=p(11,20,40),remote_position=p(12,20,90),verified_anchor=anchor,local_seq=1,verified_seq=1,local_updated_at=0,remote_updated_at=0}
assert(r.winner=="conflict","unknown freshness with divergent shared anchor must conflict")
r=R.decide{local_position=p(1,0,0),remote_position=p(9,90,65),verified_anchor=nil,local_seq=0,verified_seq=0,local_updated_at=0,remote_updated_at=0}
assert(r.winner=="remote" and r.reason=="initial_cloud_authority","first reconciliation prefers account cloud")
r=R.decide{local_position=p(2,20,8),remote_position=p(9,90,100),verified_anchor=nil,local_seq=3,verified_seq=2,local_updated_at=0,remote_updated_at=0}
assert(r.winner=="local","durable unsent local generation beats initial cloud authority")

-- Out-of-order cloud observations must not replace a known newer server state.
local chosen,why=R.prefer_nonstale_remote(p(12,20,60,1000),p(13,30,65,1400),120)
assert(chosen.chapter_uid=="13" and why=="stored_remote_newer","provably stale cloud response rejected")
chosen,why=R.prefer_nonstale_remote(p(12,20,60,0),p(13,30,65,1400),120)
assert(chosen.chapter_uid=="12","timestamp-less response is not guessed stale")
chosen,why=R.prefer_nonstale_remote(p(13,35,65,1410),p(13,30,65,1400),120)
assert(chosen.chapter_offset==35,"near-clock observation remains eligible")
