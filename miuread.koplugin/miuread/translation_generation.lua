-- Official WeRead generation, used only after an explicit reader mode change.
-- No local membership flag, free-trial activation or third-party translator.
local M={}
local function truth(value) return value==true or value==1 or value=="1" or value=="true" end
local function uid(chapter) return type(chapter)=="table" and tostring(chapter.chapterUid or chapter.uid or "") or "" end

-- Log schema and types only. A raw response may contain account/session data.
function M.describe_response(value,depth)
    depth=depth or 0
    if type(value)~="table" then return type(value) end
    if depth>=3 then return "table" end
    local parts,known={},{}
    for _,key in ipairs({"data","result","payload","curStatus","stopPoll","tips","errCode","errMsg","code","message"}) do
        if value[key]~=nil then
            known[key]=true
            parts[#parts+1]=key.."="..M.describe_response(value[key],depth+1)
        end
    end
    local other=0
    for key in pairs(value) do if not known[key] then other=other+1 end end
    if other>0 then parts[#parts+1]="other_fields="..other end
    return "table("..table.concat(parts,",")..")"
end

function M.parse_status(value)
    for _=1,5 do
        if type(value)~="table" then return nil end
        if value.curStatus~=nil or value.stopPoll~=nil or value.tips~=nil or next(value)==nil then return value end
        local nested
        for _,key in ipairs({"data","result","payload"}) do
            if type(value[key])=="table" then nested=value[key]; break end
        end
        if not nested then return nil end
        value=nested
    end
end

function M.friendly_error(error_value)
    local message=tostring(error_value or "")
    local lower=message:lower()
    if message:find("[MiuReadTranslationMemberRequired]",1,true)
        or message:find("仅限会员",1,true) or message:find("付费会员",1,true)
        or message:find("会员专属",1,true) or lower:find("membership required",1,true)
        or lower:find("paid member",1,true) then
        return "生成外文译文需要微信读书付费会员，请确认当前登录账号的会员状态。"
    end
    if message:find("[MiuReadTranslationTimeout]",1,true) then
        return "微信读书仍在生成当前章译文，原文可以继续阅读。稍后再次选择双语或仅译文即可重试。"
    end
    if message:find("[MiuReadTranslationContentPending]",1,true) then
        return "微信读书的译文章节尚未准备好，已停止本次更新并保留原文件。稍后再次切换即可重试。"
    end
    return nil
end

function M.prepare(api, book_id, chapters, current_uid, options)
    options=options or {}
    local now=options.now or os.time
    local wait=options.wait or function(seconds) require("socket").sleep(seconds) end
    local function check_cancel()
        if options.cancelled and options.cancelled() then error("download cancelled") end
    end
    check_cancel()
    local member=api:translation_member_summary(book_id)
    check_cancel()
    if type(member)~="table" or member.isPaying==nil then
        error("无法确认微信读书会员状态，请稍后重试。")
    end
    if not truth(member.isPaying) then error("[MiuReadTranslationMemberRequired]") end
    local index
    for i,chapter in ipairs(chapters or {}) do if uid(chapter)==tostring(current_uid) then index=i; break end end
    if not index then error("微信读书目录中没有找到当前章节，原文件已保留。") end
    -- The official reader sends the catalog version, then polls until
    -- stopPoll. A non-zero version alone does not mean the job has finished.
    local current=chapters[index]
    local baseline=math.max(0,tonumber(current.translateVersion) or 0)
    local was_translated=truth(current.hasTranslated) or (tonumber(current.transWordCount) or 0)>0
    local read={{uid=current.chapterUid or current.uid,translateVersion=baseline}}
    if chapters[index+1] and options.include_next~=false then
        read[#read+1]={uid=chapters[index+1].chapterUid or chapters[index+1].uid,
            translateVersion=math.max(0,tonumber(chapters[index+1].translateVersion) or 0)}
    end
    api:toggle_translate(book_id,true)
    local deadline=now()+math.max(2,math.min(120,tonumber(options.timeout) or 90))
    local logged_state
    while true do
        check_cancel()
        local raw_response=api:en_read(book_id,read[1].uid,read)
        check_cancel()
        local response=M.parse_status(raw_response)
        if not response then
            local summary=M.describe_response(raw_response)
            require("logger").warn("[MiuRead][Translation] unrecognized response schema",summary)
            error("微信读书未返回可识别的译文状态（返回摘要："..summary.."）。原文件已保留。")
        end
        local versions,current_seen={},false
        for _,status in ipairs(type(response.curStatus)=="table" and response.curStatus or {}) do
            local key=uid(status)
            if key==tostring(current_uid) then current_seen=true end
            if key~="" and (tonumber(status.translateVersion) or 0)>0 then versions[key]=tonumber(status.translateVersion) end
        end
        local version=versions[tostring(current_uid)]
        local stopped=truth(response.stopPoll)
        local tip=type(response.tips)=="string" and response.tips or ""
        if stopped and M.friendly_error(tip) then error(M.friendly_error(tip)) end
        local state=tostring(version)..":"..tostring(stopped)..":"..type(response.curStatus)
        if state~=logged_state then
            logged_state=state
            require("logger").info("[MiuRead][Translation] generation status","chapter=",tostring(current_uid),
                "catalog_version=",tostring(baseline),"server_version=",tostring(version),"previously_translated=",tostring(was_translated),
                "stop_poll=",tostring(stopped),"schema=",M.describe_response(raw_response))
        end
        -- curStatus is optional while work is in progress, and can contain
        -- interim versions. The official reader consumes it at stopPoll.
        -- An unchanged completed version still needs fetching when the local
        -- chapter has no translation; Reader checks the actual body before save.
        if stopped and not current_seen and baseline>0 then version=baseline end
        if stopped and version then
            local ready={[tostring(current_uid)]=version}
            for offset,item in ipairs(read) do
                local chapter=chapters[index+offset-1]
                local already=truth(chapter.hasTranslated) or (tonumber(chapter.transWordCount) or 0)>0
                local available=versions[tostring(item.uid)]
                if available and (available>item.translateVersion or (already and available>=item.translateVersion)) then
                    ready[tostring(item.uid)]=available
                end
            end
            return ready
        end
        if stopped then
            error(M.friendly_error(tip) or (tip~="" and tip or "微信读书已结束本次请求，但当前章译文尚未就绪。原文件已保留。"))
        end
        if now()>=deadline then error("[MiuReadTranslationTimeout]") end
        if options.progress then options.progress(tip~="" and tip or "正在等待微信读书生成当前章译文") end
        wait(2)
    end
end

function M.content_ready(fragment)
    local analyzed,err=require("miuread.translation").analyze("<html><body>"..tostring(fragment or "").."</body></html>")
    return analyzed~=nil and analyzed.blocks>0,err
end

function M.should_refresh(versions, chapter_uid)
    local target=type(versions)=="table" and tonumber(versions[tostring(chapter_uid)]) or nil
    -- The explicit request means the open local chapter has no usable
    -- translation. Fetch it even if metadata already reported the same
    -- version: generation status can precede the updated content shards.
    return target~=nil and target>0
end
return M
