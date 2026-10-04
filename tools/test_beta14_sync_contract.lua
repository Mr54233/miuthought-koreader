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
local source=read("miuread.koplugin/miuread/source_position.lua")
local store=read("miuread.koplugin/miuread/store.lua")
local library=read("miuread.koplugin/miuread/library.lua")
local home=read("miuread.koplugin/miuread/home_view.lua")
local config=read("miuread.koplugin/miuread/config.lua")

assert(config:find('VERSION = "5.9.0-beta.14"',1,true),"beta.14 version")
assert(config:find('POSITION_CLOCK_SKEW_GRACE_SECONDS = 30',1,true),"30s resolver guard retained")

-- beta.12 safeguards remain: failed source cache is really bypassed once and
-- completed KOReader subprocesses are not mistaken for live time writers.
assert(source:find('local refresh_uid = tostring(options.force_refresh_uid or "")',1,true),"force refresh option missing")
assert(source:find('options.force_refresh == true and (refresh_uid == "" or refresh_uid == uid)',1,true),"targeted force refresh missing")
assert(sync:find('SourcePosition.locate(reader, record_snapshot, anchor,{cache_only=false,force_refresh=true,force_refresh_uid=tostring(anchor.chapter_uid or "")})',1,true),"fresh source recovery missing")
assert(sync:find('local function subprocess_done(pid)',1,true),"subprocess completion helper missing")
assert(sync:find('FFIUtil.isSubProcessDone,pid,false',1,true),"subprocess completion API missing")

-- beta.14 deliberately keeps the proven post-jump verification/rescue chain.
local use_remote=slice(main,'function Plugin:_use_remote_position','function Plugin:on_remote_source_conflict')
assert(use_remote:find('text anchor rescue started',1,true),"text-anchor rescue removed")
assert(use_remote:find('bounded percent fallback',1,true),"bounded fallback removed")
assert(use_remote:find('remote_chapter_resolved',1,true),"soft mismatch state missing")
assert(use_remote:find('kind=failure_kind',1,true),"failure classification missing")
assert(not main:find('[MiuRead][ProgressPreflight]',1,true),"beta.13 preflight returned")
assert(not main:find('remote_preflight_unverified',1,true),"beta.13 preflight state returned")
assert(not main:find('idle refresh book=',1,true),"active exact-cache refresh returned")

-- Same-chapter mismatch stays put; hard/unresolved failures still use rollback.
local remote_handler=slice(main,'function Plugin:on_remote_progress','function Plugin:sync_progress')
assert(remote_handler:find('failure_kind=="soft"',1,true),"soft mismatch handling missing")
assert(remote_handler:find('remote chapter resolved; exact co unverified',1,true),"soft mismatch close state missing")
assert(remote_handler:find('_restore_position_rollback("remote exact verification failed"',1,true),"hard mismatch rollback removed")
assert(remote_handler:find('_open_sync_user_interacted==true',1,true),"late user movement guard missing")
assert(remote_handler:find('_auto_position_check_user_interacted==true',1,true),"auto-check user movement guard missing")

-- Local UI progress is independent from cloud exact coordinates.
assert(main:find('function Plugin:_save_local_display_progress',1,true),"local display progress helper missing")
assert(main:find('function Plugin:_remember_passive_exact_position',1,true),"passive exact cache helper missing")
assert(main:find('function Plugin:_save_unresolved_position_snapshot',1,true),"unresolved snapshot helper missing")
local reading_end=slice(main,'function Plugin:_reading_end_sync','function Plugin:_reading_end_before_action')
assert(reading_end:find('_save_local_display_progress(book_id,display_progress,xpointer_snapshot',1,true),"reading-end local progress not saved first")
assert(reading_end:find('_passive_exact_position_for_xpointer(book_id,xpointer_snapshot)',1,true),"passive exact reuse missing")
assert(reading_end:find('local_coordinate_unresolved',1,true),"unresolved exact state missing")
assert(reading_end:find('handle_final_position(passive_exact',1,true),"passive exact cache not reused")

-- Unknown progress is no longer silently rewritten to 0 in the library model / hero label.
assert(library:find('progress_known=remote_progress_known',1,true),"library progress-known marker missing")
assert(library:find('progress=remote_progress_known and tonumber(remote_progress_value) or nil',1,true),"unknown library progress still coerced")
assert(home:find('local progress_known = book.progress_known~=false and progress_number_value~=nil',1,true),"hero progress-known handling missing")
assert(home:find('local progress_label = progress_known and ("阅读进度 " .. progress_number .. "%") or "阅读进度 —"',1,true),"unknown hero progress does not render dash")
assert(store:find('"local_display_progress","local_display_progress_at"',1,true),"local display progress not persisted")
assert(store:find('"last_verified_exact_position","pending_unresolved_position"',1,true),"passive/unresolved state not persisted")

print("beta14 sync stabilization contract: PASS")
