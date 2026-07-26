local ButtonDialog=require("ui/widget/buttondialog")
local ConfirmBox=require("ui/widget/confirmbox")
local Event=require("ui/event")
local Dispatcher=require("dispatcher")
local InfoMessage=require("ui/widget/infomessage")
local InputDialog=require("ui/widget/inputdialog")
local Menu=require("ui/widget/menu")
local PathChooser=require("ui/widget/pathchooser")
local UIManager=require("ui/uimanager")
local WidgetContainer=require("ui/widget/container/widgetcontainer")
local logger=require("logger")
local lfs=require("libs/libkoreader-lfs")
local Config=require("miuthought.config")
local Text=require("miuthought.text")
local U=require("miuthought.util")
local Store=require("miuthought.store")
local Http=require("miuthought.http")
local Api=require("miuthought.api")
local Auth=require("miuthought.auth")
local Reader=require("miuthought.reader")
local Annotations=require("miuthought.annotations")
local Downloader=require("miuthought.downloader")
local DownloadProgress=require("miuthought.download_progress")
local DownloadTask=require("miuthought.download_task")
local CacheCleanupTask=require("miuthought.cache_cleanup_task")
local EpubStyleRepairTask=require("miuthought.epub_style_repair_task")
local Library=require("miuthought.library")
local ShelfView=require("miuthought.shelf_view")
local Async=require("miuthought.async")
local Sync=require("miuthought.sync")
local Updater=require("miuthought.updater")
local Cookies=require("miuthought.cookies")
local Thoughts=require("miuthought.thoughts")
local ThoughtPopup=require("miuthought.thought_popup")
local StatusToast=require("miuthought.status_toast")
local _=Text.tr
local unpack_args=unpack or table.unpack
local SHELF_CACHE_TTL=15*60
local SHELF_DIRECT_CACHE_TTL=6*60*60
local COVER_GUARD_WINDOW=6*60*60
local source=debug.getinfo(1,"S").source:gsub("^@",""); local ROOT=source:match("^(.*)/main%.lua$") or "."
local Plugin=WidgetContainer:extend{name="miuread",is_doc_only=false,version=Config.VERSION}
local function normalize(v) local b=v.bookInfo or v.book or v; return {bookId=tostring(b.bookId or v.bookId or ""),title=b.title or v.title or "未命名",author=b.author or v.author or "",cover=b.cover or v.cover,category=b.category or v.category,progress=tonumber(v.progress or b.progress or 0) or 0,updateTime=tonumber(v.updateTime or b.updateTime or 0) or 0} end
local function sanitize_saved_auth(store)
    local auth=store:auth()
    local cleaned,changed=Cookies.sanitize(auth.cookies or {})
    if changed then
        auth.cookies=cleaned
        store:save_auth(auth)
        logger.info("[MiuRead][Auth] startup cookie cleanup",
            "names=",table.concat(Cookies.names(cleaned),","))
    end
end
function Plugin:init()
    math.randomseed(os.time()+math.floor(collectgarbage("count")))
    self.store=Store:new()
    logger.info("[MiuRead] initialized", "version=", tostring(Config.VERSION),
        "schema=", tostring(Config.SCHEMA), "root=", tostring(ROOT))
    sanitize_saved_auth(self.store)
    self.http=Http:new(self.store)
    self.reader=Reader:new(self.http,self.store)
    self.api=Api:new(self.http,self.store,self.reader)
    self.annotations=Annotations:new(self.api)
    self.downloader=Downloader:new(self.reader,self.api,self.annotations,self.store,self.http)
    self.download_task=DownloadTask:new(self.store)
    self.cache_cleanup_task=CacheCleanupTask:new(self.store)
    self.epub_style_repair_task=EpubStyleRepairTask:new(self.store)
    self.library=Library:new(self.api,self.http,self.store)
    self.async=Async:new(self.store)
    self.search_async=Async:new(self.store,{poll_interval=.4})
    self.shelf_async=Async:new(self.store,{poll_interval=.4})
    self.cover_async=Async:new(self.store)
    self.auth_flow=Auth:new(self.http,self.store,self)
    self.sync=Sync:new(self.reader,self.api,self.store,self,self.async)
    self.updater=Updater:new(self.http,self.store,self.version,ROOT)
    self._suspended_at=nil
    self._cover_generation=0
    self._cover_refresh_task=nil
    self._cover_index_pending={}
    self._cover_index_flush_task=nil
    self._cover_safe_mode=false
    self._cover_safe_notice_shown=false
    self._shelf_view=nil
    self._last_shelf_mode=false
    self._last_shelf_section="account"
    self._shelf_refresh_generation=0
    self._shelf_main_busy=false
    self._downloads_menu=nil
    self._download_book_menu=nil
    self._cache_cleanup_dialog=nil
    self._epub_style_repair_dialog=nil
    self._download_runtime=nil
    self._download_state_last_write=0
    self._download_state_last_stage=nil

    local guard=self.store:cover_guard()
    local guard_age=os.time()-(tonumber(guard.started_at) or 0)
    if guard.active==true and guard_age>=0 and guard_age<COVER_GUARD_WINDOW then
        self._cover_safe_mode=true
        logger.warn("[MiuRead][Cover] previous render did not finish; safe shelf mode enabled",
            "stage=",tostring(guard.stage or ""),"age=",tostring(guard_age))
    end
    if guard.active==true then
        self.store:save_cover_guard({active=false,started_at=0,stage="",version=Config.VERSION})
    end

    local recovered=self:_recover_download_state()
    if not recovered then UIManager:scheduleIn(1.0,function() self:_start_next_queued_download() end) end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    local state=self.updater:startup()
    if state=="updated" then UIManager:scheduleIn(1,function() self:toast(_("Update installed"),3) end) end
    UIManager:scheduleIn(.8,function() if not self:_current_document_path() then self:_install_pending_downloads(false) end end)
end
function Plugin:onDispatcherRegisterActions() Dispatcher:registerAction("miuread_show",{category="none",event="ShowMiuRead",title=Config.NAME,filemanager=true,reader=true}) end
function Plugin:addToMainMenu(items) items.miuread={text=Config.NAME,sorting_hint="tools",sub_item_table_func=function() return self.ui.document and self:reader_menu() or self:home_menu() end} end
function Plugin:info(t) UIManager:show(InfoMessage:new{text=tostring(t or "")}) end
function Plugin:toast(t,s) UIManager:show(InfoMessage:new{text=tostring(t or ""),timeout=s or 2}) end
function Plugin:status_toast(title,text,timeout)
    local ok,err=pcall(StatusToast.show,{
        title=tostring(title or ""),
        text=tostring(text or ""),
        timeout=timeout or 3,
    })
    if not ok then
        logger.warn("[MiuRead] status toast failed",tostring(err))
        self:toast(tostring(title or "").." · "..tostring(text or ""):gsub("%s+"," "),timeout or 3)
    end
end
function Plugin:_legacy_weread_plugin_present()
    local plugins_root=ROOT:match("^(.*)/[^/]+$") or "."
    return lfs.attributes(plugins_root.."/weread.koplugin","mode")=="directory"
end
function Plugin:_begin_cover_guard(stage)
    self.store:save_cover_guard({
        active=true,
        started_at=os.time(),
        stage=tostring(stage or "shelf"),
        version=Config.VERSION,
    })
end
function Plugin:_clear_cover_guard()
    local guard=self.store:cover_guard()
    if guard.active==true then
        self.store:save_cover_guard({active=false,started_at=0,stage="",version=Config.VERSION})
    end
end
function Plugin:_shelf_covers_enabled(prefs)
    prefs=prefs or self.store:preferences()
    local enabled=prefs.shelf_covers~=false and not prefs.low_resource
    if enabled and self._cover_safe_mode then
        if not self._cover_safe_notice_shown then
            self._cover_safe_notice_shown=true
            self:toast("检测到上次封面加载异常，本次已使用安全书架模式。",4)
        end
        return false
    end
    return enabled
end
function Plugin:safe(label,fn) return function(...) local a={...}; local ok,e=xpcall(function() return fn(unpack_args(a)) end,debug.traceback); if not ok then logger.err("[MiuRead]",label,e); self:info(_("Operation failed")..":\n"..U.first_line(e)) end end end
function Plugin:safe_menu(label,fn)
    local ok,value=xpcall(fn,debug.traceback)
    if ok and type(value)=="table" then return value end
    local err=ok and "菜单函数没有返回有效项目" or tostring(value)
    logger.err("[MiuRead]",label,err)
    UIManager:scheduleIn(.05,function()
        self:info("菜单加载失败：\n"..U.first_line(err))
    end)
    return {{text="菜单加载失败",enabled=false}}
end
function Plugin:is_online() local ok,N=pcall(require,"ui/network/manager"); if not ok or not N or not N.isOnline then return true end; local g,v=pcall(N.isOnline,N); return not g or v==true end
function Plugin:online(label,fn) if not self:is_online() then self:info(_("Network unavailable")); return end; UIManager:scheduleIn(.05,self:safe(label,fn)) end
function Plugin:run_online(label,fn) return self:online(label,fn) end
function Plugin:list(title,items,empty) if not items or #items==0 then self:info(empty or _("No items")); return end; UIManager:show(Menu:new{title=title,item_table=items,is_borderless=true,title_bar_fm_style=true}) end
function Plugin:logged_in() local a=self.store:auth(); return a.api_key~="" and next(a.cookies or {})~=nil end
function Plugin:require_login() if not self:logged_in() then self:info(_("Not logged in")); return false end return true end
function Plugin:home_menu()
    local out={
        {text="我的书架",callback=self:safe("shelf",function() self:show_shelf(nil) end)},
        {text="搜索书籍",callback=self:safe("search",function() self:search_dialog() end)},
        {text="下载管理",callback=self:safe("downloads",function() self:show_downloads() end)},
        {text="阅读同步",sub_item_table_func=function() return self:sync_menu() end},
        {text="设置",sub_item_table_func=function() return self:settings_menu() end},
        {text="账户",sub_item_table_func=function() return self:account_menu() end},
        {text="更新与关于",sub_item_table_func=function() return self:safe_menu("update-about-menu",function() return self:update_about_menu() end) end},
    }
    if self:_has_download_status() then table.insert(out,1,{text=self:_download_status_label(),callback=function() self:show_download_status() end}) end
    return out
end
function Plugin:reader_menu()
    local out={
        {text="阅读同步",sub_item_table_func=function() return self:reader_sync_menu() end},
        {text="返回我的书架",callback=self:safe("shelf",function() self:show_shelf(nil) end)},
        {text="当前书籍信息",callback=function() self:show_current_book_info() end},
        {text="重新生成当前书籍",callback=self:safe("redownload",function() self:redownload_current() end)},
        {text="觅阅设置",sub_item_table_func=function() return self:settings_menu() end},
    }
    if self:_has_download_status() then table.insert(out,1,{text=self:_download_status_label(),callback=function() self:show_download_status() end}) end
    return out
end
function Plugin:account_menu()
    local out={{text=_("QR login"),callback=self:safe("login",function() self.auth_flow:start() end)},{text=_("Manual credentials"),callback=self:safe("manual",function() self:manual_credentials() end)},{text=_("Account status"),callback=function() local a=self.store:auth(); self:info((self:logged_in() and _("Logged in") or _("Not logged in")).."\n"..tostring(a.account.name or "").."\nVID: "..tostring(a.account.vid or "")) end}}
    if self:logged_in() then out[#out+1]={text=_("Clear account data"),callback=function() UIManager:show(ConfirmBox:new{text="清除当前账户信息？\n\n将退出微信读书账户，但不会删除已下载书籍。",ok_callback=function() self.auth_flow:cancel(); self.store:clear_auth(); self:toast(_("Logout")) end}) end} end; return out
end
function Plugin:manual_credentials()
    local d; d=InputDialog:new{title=_("Enter API key"),input=self.store:auth().api_key or "",buttons={{{text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},{text=_("Confirm"),is_enter_default=true,callback=function() local key=U.trim(d:getInputText()); UIManager:close(d); self:manual_cookie(key) end}}}}; UIManager:show(d); d:onShowKeyboard()
end
function Plugin:manual_cookie(key)
    local d; d=InputDialog:new{title=_("Enter Cookie header"),input="",buttons={{{text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},{text=_("Confirm"),is_enter_default=true,callback=function() local jar=Cookies.parse_header(d:getInputText()); self.store:save_auth({api_key=key,cookies=jar,account={name="Manual",vid=jar.wr_vid or "",logged_at=os.time()}}); UIManager:close(d); self:toast(_("Logged in")) end}}}}; UIManager:show(d); d:onShowKeyboard()
end
local ACCOUNT_SORT_LABELS={read="最近阅读（默认）",update="最近更新",progress="阅读进度",title="书名",author="作者"}
local ACCOUNT_SCOPE_LABELS={all="全部",generated="已生成",ungenerated="未生成",top="置顶",archive="书单"}
local GENERATED_SORT_LABELS={opened="最近打开",generated="最近生成",title="书名",author="作者",size="文件大小"}
local GENERATED_SCOPE_LABELS={all="全部",in_account="账号书架中",removed="已从账号书架移除",clean="纯净版",notes="划线与想法版"}

function Plugin:_shelf_summary(section)
    local p=self.store:preferences()
    section=tostring(section or p.shelf_section or "account")
    if section=="generated" then
        return tostring(GENERATED_SCOPE_LABELS[p.generated_shelf_scope] or "全部").." · "
            ..tostring(GENERATED_SORT_LABELS[p.generated_shelf_sort] or "最近打开")
    end
    return tostring(ACCOUNT_SCOPE_LABELS[p.account_shelf_scope] or "全部").." · "
        ..tostring(ACCOUNT_SORT_LABELS[p.account_shelf_sort] or "最近阅读（默认）")
end

function Plugin:_save_shelf_context(section,mp_mode)
    section=section=="generated" and "generated" or "account"
    local p=self.store:preferences()
    local changed=p.shelf_section~=section
    p.shelf_section=section
    if section=="account" and mp_mode~=nil then
        local kind=mp_mode==true and "mp" or "books"
        if p.account_shelf_kind~=kind then changed=true end
        p.account_shelf_kind=kind
    end
    if changed then self.store:save_preferences(p) end
    self._last_shelf_section=section
    if section=="account" then self._last_shelf_mode=mp_mode==true end
end

function Plugin:show_shelf_tabs()
    local p=self.store:preferences()
    local section=tostring(p.shelf_section or "account")
    self:list("我的书架",{
        {text=(section=="account" and "✓ " or "").."账号书架",post_text=self:_shelf_summary("account"),callback=function() self:show_shelf(nil,false,"account") end},
        {text=(section=="generated" and "✓ " or "").."已生成书籍",post_text=self:_shelf_summary("generated"),callback=function() self:show_shelf(nil,false,"generated") end},
    })
end
function Plugin:_friendly_remote_error(err, context)
    local text=tostring(err or "未知错误")
    local lower=text:lower()
    if Http.is_auth_error(text) or lower:find("api key",1,true)
        or lower:find("authorization",1,true) then
        return "登录凭证已失效或被拒绝，请在账户设置中重新扫码登录。"
    end
    if lower:find("timeout",1,true) then return "网络请求超时，请检查 Wi-Fi 后重试。" end
    if lower:find("network request failed",1,true) then return "网络连接失败，请检查 Wi-Fi 后重试。" end
    return tostring(context or "请求").."失败：\n"..U.first_line(text,180)
end

function Plugin:_refresh_shelf_async(on_ready,silent)
    local function fail(err)
        local message=self:_friendly_remote_error(err,"书架加载")
        if on_ready then
            on_ready({}, {}, message)
        elseif not silent or message:find("重新扫码登录",1,true) then
            self:toast(message,4)
        end
        return false,err
    end
    if not self:is_online() then
        return fail("network request failed: offline")
    end

    local async_available=self.shelf_async and self.shelf_async:available()
    if async_available then
        if self.shelf_async:busy() then return fail("书架正在刷新，请稍后重试。") end
    elseif self._shelf_main_busy then
        return fail("书架正在刷新，请稍后重试。")
    end

    self._shelf_refresh_generation=(tonumber(self._shelf_refresh_generation) or 0)+1
    local generation=self._shelf_refresh_generation
    local function succeed(data,mode)
        if generation~=self._shelf_refresh_generation then return end
        local books,mp=self.library:normalize(data or {})
        self.store:save_shelf_cache({books=books,mp=mp,updated_at=os.time()})
        logger.info("[MiuRead][Shelf] refresh completed","mode=",tostring(mode),
            "books=",tostring(#books),"mp=",tostring(#mp))
        if on_ready then on_ready(books,mp,nil) end
    end

    if not async_available then
        self._shelf_main_busy=true
        local loading
        if on_ready and not silent then
            loading=InfoMessage:new{text="正在加载书架……"}
            UIManager:show(loading)
        end
        logger.info("[MiuRead][Shelf] refresh started","mode=direct")
        UIManager:scheduleIn(.05,function()
            local handled,unexpected=xpcall(function()
                if generation~=self._shelf_refresh_generation then return end
                local ok,data=pcall(self.api.shelf,self.api,{retries=0,timeout={7,12}})
                if not ok then error(tostring(data)) end
                if loading then pcall(function() UIManager:close(loading) end); loading=nil end
                succeed(data,"direct")
            end,debug.traceback)
            self._shelf_main_busy=false
            if loading then pcall(function() UIManager:close(loading) end) end
            if not handled and generation==self._shelf_refresh_generation then fail(unexpected) end
        end)
        return true
    end

    local auth=U.copy(self.store:auth())
    logger.info("[MiuRead][Shelf] refresh started","mode=subprocess")
    local started,err=self.shelf_async:run("shelf_refresh",function()
        local HttpChild=require("miuthought.http")
        local ApiChild=require("miuthought.api")
        local UtilChild=require("miuthought.util")
        local child_store={
            auth=function() return UtilChild.copy(auth) end,
            save_auth=function() end,
        }
        return ApiChild:new(HttpChild:new(child_store),child_store):shelf({retries=1,timeout={10,18}})
    end,function(result)
        if generation~=self._shelf_refresh_generation then return end
        if result and result.ok==true then
            succeed(result.value or {},"subprocess")
            return
        end
        fail(result and result.error or "未知错误")
    end,32)
    if not started then return fail(err or "无法启动异步任务") end
    return true
end

function Plugin:load_shelf(cb,force_remote,section)
    section=section=="generated" and "generated" or "account"
    local cached_books,cached_mp,cached_updated=self.library:cached()
    local library_snapshot=self.store:library()
    local local_books,local_mp=self.library:local_books(library_snapshot,self.store:get("sessions",{}))
    local cached_count=#cached_books+#cached_mp
    local local_count=#local_books+#local_mp
    local cache_age=math.max(0,os.time()-(tonumber(cached_updated) or 0))
    local background_available=self.shelf_async and self.shelf_async:available()

    if not force_remote then
        if cached_count>0 then
            cb(cached_books,cached_mp,nil)
            local refresh_after=background_available and SHELF_CACHE_TTL or SHELF_DIRECT_CACHE_TTL
            if self:logged_in() and cache_age>refresh_after then
                self:_refresh_shelf_async(function(_,_,err)
                    if not err and self._shelf_view and not self._shelf_view._miu_closed then
                        self:_reopen_shelf(self._last_shelf_mode,self._last_shelf_section)
                    end
                end,true)
            end
            return
        end
        if local_count>0 then
            if section=="account" and self:logged_in() then
                self:toast("正在加载账号书架…",2)
                self:_refresh_shelf_async(function(books,mp,err)
                    cb(books,mp,err)
                end,false)
                return
            end
            self:toast("账号书架暂未加载，可先查看“已生成书籍”。",3)
            cb({}, {}, "账号书架正在后台加载。")
            if self:logged_in() then
                self:_refresh_shelf_async(function(_,_,err)
                    if not err and self._shelf_view and not self._shelf_view._miu_closed then
                        self:_reopen_shelf(self._last_shelf_mode,self._last_shelf_section)
                    end
                end,true)
            end
            return
        end
    end
    if not self:logged_in() then
        cb(cached_books,cached_mp,"当前未登录，仅使用已缓存的账号书架和已生成书籍。")
        return
    end
    self:_refresh_shelf_async(function(books,mp,err)
        if err and cached_count>0 then cb(cached_books,cached_mp,err) else cb(books,mp,err) end
    end,false)
end

function Plugin:_shelf_rows(section,mp_mode,remote_books,remote_mp,remote_status_known)
    if remote_books==nil or remote_mp==nil then remote_books,remote_mp=self.library:cached() end
    local library_snapshot=self.store:library()
    local sessions=self.store:get("sessions",{})
    local local_books,local_mp=self.library:local_books(library_snapshot,sessions)
    section=section=="generated" and "generated" or "account"
    if section=="generated" then
        local rows=self.library:generated_rows(remote_books or {},remote_mp or {},local_books,local_mp,remote_status_known)
        for _,row in ipairs(rows) do row.shelf_section="generated" end
        return rows
    end
    local remote_rows=mp_mode and (remote_mp or {}) or (remote_books or {})
    local local_rows=mp_mode and local_mp or local_books
    local rows=self.library:account_rows(remote_rows,local_rows)
    for _,row in ipairs(rows) do row.shelf_section="account" end
    return rows
end

function Plugin:_prepare_shelf_rows(rows)
    local cover_index=self.store:get("cover_index",{})
    for id,path in pairs(self._cover_index_pending or {}) do cover_index[id]=path end
    local cover_index_changed=false
    local download_state=self:_download_state()
    for _,b in ipairs(rows or {}) do
        local removed
        b.cover_path,removed=self.library:cached_cover_path(b.bookId,cover_index)
        if removed then
            cover_index_changed=true
            if self._cover_index_pending then self._cover_index_pending[tostring(b.bookId)]=nil end
        end
        b.download_status=nil
        if tostring(download_state.book_id or "")~="" and tostring(download_state.book_id)==tostring(b.bookId or "") then
            if download_state.status=="active" then b.download_status="生成中 "..tostring(self:_download_percent(download_state)).."%"
            elseif download_state.status=="pending_install" then b.download_status="等待关闭后更新"
            elseif download_state.status=="failed" or download_state.status=="interrupted" then b.download_status="生成未完成"
            elseif download_state.status=="completed" and download_state.seen~=true then b.download_status="刚刚生成完成" end
        end
        b.status_text=self:_shelf_status_text(b)
    end
    if cover_index_changed then self.store:set("cover_index",cover_index) end
    return rows
end

function Plugin:_flush_cover_index()
    if self._cover_index_flush_task then
        UIManager:unschedule(self._cover_index_flush_task)
        self._cover_index_flush_task=nil
    end
    local pending=self._cover_index_pending or {}
    if not next(pending) then return end
    local index=self.store:get("cover_index",{})
    for id,path in pairs(pending) do index[id]=path end
    self.store:set("cover_index",index)
    self._cover_index_pending={}
end

function Plugin:_remember_cover_path(id,path)
    if not id or not path then return end
    self._cover_index_pending=self._cover_index_pending or {}
    self._cover_index_pending[tostring(id)]=path
    if self._cover_index_flush_task then return end
    local task
    task=function()
        if self._cover_index_flush_task~=task then return end
        self._cover_index_flush_task=nil
        self:_flush_cover_index()
    end
    self._cover_index_flush_task=task
    UIManager:scheduleIn(.75,task)
end

function Plugin:_shelf_status_text(b)
    if b.download_status and b.download_status~="" then return b.download_status end
    local state
    if b.shelf_section=="generated" then
        if b.remote_status_known~=true then state="云端状态暂不可用"
        elseif b.in_account_shelf==true then state="账号书架中"
        else state="已从账号书架移除" end
        if b.hasClean and b.hasNotes then state=state.." · 两个版本"
        elseif b.hasNotes then state=state.." · 划线与想法版"
        elseif b.hasClean then state=state.." · 纯净版" end
    else
        state=b.downloaded and "已生成" or "未生成"
        if b.isTop then state="置顶 · "..state end
    end
    local progress=tonumber(b.progress or 0) or 0
    if progress>=100 then return state.." · 已读完" end
    if progress>0 then return state.." · "..tostring(math.floor(progress+.5)).."%" end
    return state
end

function Plugin:_shelf_select(b)
    local available={}
    for _,kind in ipairs({"notes","clean"}) do
        local r=self.store:variant(b.bookId,kind)
        if r and r.file and U.file_exists(r.file) then available[#available+1]=r end
    end
    if #available==1 then self:open_file(available[1].file) else self:book_menu(b) end
end

function Plugin:show_shelf_search_dialog(mp_mode,source_rows,section)
    section=section=="generated" and "generated" or "account"
    if not source_rows then
        local remote_books,remote_mp=self.library:cached()
        source_rows=self:_shelf_rows(section,mp_mode,remote_books,remote_mp,#remote_books+#remote_mp>0)
    end
    local d
    d=InputDialog:new{
        title=section=="generated" and "搜索已生成书籍" or "搜索账号书架",input="",
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},
            {text=_("Search"),is_enter_default=true,callback=function()
                local q=U.trim(d:getInputText())
                UIManager:close(d)
                if q=="" then return end
                local results=self.library:search(source_rows,q)
                if #results==0 then self:info("没有找到相关书籍") return end
                self:_prepare_shelf_rows(results)
                local prefs=self.store:preferences()
                local show_covers=self:_shelf_covers_enabled(prefs)
                if show_covers then self:_begin_cover_guard("shelf_search_open") end
                local ok,view=pcall(ShelfView.show,{
                    title=(section=="generated" and "已生成书籍 · " or "账号书架 · ").."搜索 “"..q.."” · "..tostring(#results).."本",
                    books=results,
                    show_actions=false,
                    show_tabs=false,
                    show_covers=show_covers,
                    on_select=function(b) self:_shelf_select(b) end,
                    on_hold=function(b) self:book_menu(b) end,
                    on_page_changed=function(page,first,last,current)
                        if show_covers then self:_on_shelf_page(results,current,page,first,last) end
                    end,
                    on_rendered=function() self:_clear_cover_guard() end,
                    on_close=function()
                        self:_cancel_cover_loading()
                        collectgarbage("step",120)
                    end,
                })
                if ok and view then return end
                self:_clear_cover_guard()
                logger.warn("[MiuRead][ShelfSearch] custom view unavailable",tostring(view))
                local items={}
                for _,book in ipairs(results) do
                    local b=book
                    items[#items+1]={
                        text=(b.downloaded and "✓ " or "")..tostring(b.title or "未命名"),
                        post_text=(tostring(b.author or "")~="" and (tostring(b.author).." · ") or "")..self:_shelf_status_text(b),
                        callback=function() self:_shelf_select(b) end,
                        hold_callback=function() self:book_menu(b) end,
                    }
                end
                self:list("搜索书架 · "..q,items)
            end},
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
end
function Plugin:_cancel_cover_loading()
    self._cover_generation=(tonumber(self._cover_generation) or 0)+1
    if self.cover_async then self.cover_async:cancel("shelf page changed") end
    if self._cover_refresh_task then
        UIManager:unschedule(self._cover_refresh_task)
        self._cover_refresh_task=nil
    end
    self:_clear_cover_guard()
end
function Plugin:_schedule_shelf_cover_refresh(view,generation,delay)
    if self._cover_refresh_task then return end
    local task
    task=function()
        if self._cover_refresh_task~=task then return end
        self._cover_refresh_task=nil
        if generation~=self._cover_generation or not view or view._miu_closed then return end
        self:_begin_cover_guard("shelf_cover_refresh")
        view._suppress_page_callback=true
        local ok,err=pcall(view.updateItems,view,nil,true)
        view._suppress_page_callback=false
        if ok then
            self:_clear_cover_guard()
            collectgarbage("step",160)
        else
            self._cover_safe_mode=true
            logger.warn("[MiuRead][Cover] shelf refresh failed",tostring(err))
        end
    end
    self._cover_refresh_task=task
    UIManager:scheduleIn(delay or .18,task)
end
function Plugin:_schedule_cover_continue(rows,view,page,first,last,generation,index,delay)
    UIManager:scheduleIn(delay or .06,function()
        self:_cache_shelf_page_covers(rows,view,page,first,last,generation,index)
    end)
end
function Plugin:_cache_shelf_page_covers(rows,view,page,first,last,generation,index)
    index=index or first
    if generation~=self._cover_generation or not view or view._miu_closed or tonumber(view.page or 1)~=tonumber(page) then return end
    if index>last then return end
    local book=rows[index]
    if not book or not book.cover or book.cover=="" then
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index+1,.04)
        return
    end
    local cached=book.cover_path or self.library:cached_cover_path(book.bookId)
    if cached then
        book.cover_path=cached
        local changed=false
        for _,entry in ipairs(view.item_table or {}) do
            if tostring(entry.book_id)==tostring(book.bookId) then
                if entry.cover_path~=cached then entry.cover_path=cached; changed=true end
                break
            end
        end
        if changed then self:_schedule_shelf_cover_refresh(view,generation,.12) end
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index+1,.04)
        return
    end
    if not self.cover_async then return end
    if self.cover_async:busy() then
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index,.25)
        return
    end
    local background_available=self.cover_async:available()
    local download_options=background_available
        and {retries=1,timeout={8,15}}
        or {retries=0,timeout={4,7}}
    local book_copy={bookId=book.bookId,cover=book.cover}
    local worker
    if background_available then
        local covers_dir=self.store.covers_dir
        worker=function()
            local HttpChild=require("miuthought.http")
            local LibraryChild=require("miuthought.library")
            local store={
                covers_dir=covers_dir,
                auth=function() return {cookies={}} end,
                save_auth=function() end,
                get=function(_,_,default) return default end,
                set=function() end,
            }
            local http=HttpChild:new(store)
            local options={
                retries=download_options.retries,
                timeout=download_options.timeout,
                persist_index=false,
                skip_index_lookup=true,
            }
            return LibraryChild:new(nil,http,store):cache_cover(book_copy,options)
        end
    else
        worker=function() return self.library:cache_cover(book_copy,download_options) end
    end
    local started=self.cover_async:run("shelf_cover_page",worker,function(result)
        if generation~=self._cover_generation or not view or view._miu_closed or tonumber(view.page or 1)~=tonumber(page) then return end
        if result and result.ok and result.value then
            if background_available then self:_remember_cover_path(book.bookId,result.value) end
            book.cover_path=result.value
            for _,entry in ipairs(view.item_table or {}) do
                if tostring(entry.book_id)==tostring(book.bookId) then entry.cover_path=result.value; break end
            end
            self:_schedule_shelf_cover_refresh(view,generation,.18)
        elseif result and result.error then
            logger.warn("[MiuRead][Cover] download failed","book_id=",tostring(book.bookId),
                "error=",U.first_line(result.error,160))
        end
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index+1,background_available and .06 or .18)
    end,background_available and 35 or 14)
    if not started then
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index,.3)
    end
end
function Plugin:_on_shelf_page(rows,view,page,first,last)
    self:_cancel_cover_loading()
    local generation=self._cover_generation
    self:_cache_shelf_page_covers(rows,view,page,first,last,generation,first)
end
function Plugin:_close_current_shelf()
    local view=self._shelf_view
    self._shelf_view=nil
    self:_cancel_cover_loading()
    if view and not view._miu_closed then pcall(function() UIManager:close(view) end) end
end
function Plugin:_reopen_shelf(mp_mode,section,force_remote)
    section=section=="generated" and "generated" or "account"
    self:_save_shelf_context(section,mp_mode)
    UIManager:scheduleIn(0,function()
        self:_close_current_shelf()
        self:show_shelf(mp_mode,force_remote,section)
    end)
end

function Plugin:show_shelf(mp_mode,force_remote,section)
    local prefs=self.store:preferences()
    section=section or prefs.shelf_section or "account"
    section=section=="generated" and "generated" or "account"
    if mp_mode==nil then mp_mode=tostring(prefs.account_shelf_kind or "books")=="mp" end
    self:_save_shelf_context(section,mp_mode)
    self:load_shelf(function(remote_books,remote_mp,remote_error)
        local remote_known=remote_error==nil and (self:logged_in() or (#remote_books+#remote_mp)>0)
        local all_rows=self:_shelf_rows(section,mp_mode,remote_books,remote_mp,remote_known)
        local rows=self.library:sort_filter(all_rows,{section=section})
        self:_prepare_shelf_rows(rows)
        local current_prefs=self.store:preferences()
        local show_covers=self:_shelf_covers_enabled(current_prefs)
        local scope_label
        local title
        if section=="generated" then
            scope_label=GENERATED_SCOPE_LABELS[current_prefs.generated_shelf_scope] or "全部"
            title="已生成书籍 · "..scope_label
        else
            scope_label=ACCOUNT_SCOPE_LABELS[current_prefs.account_shelf_scope] or "全部"
            title=(mp_mode and "账号书架 · 公众号" or "账号书架").." · "..scope_label
        end
        if remote_error and #rows>0 then self:toast(remote_error,3) end

        local function open_account()
            if section=="account" then return end
            local p=self.store:preferences()
            self:_reopen_shelf(tostring(p.account_shelf_kind or "books")=="mp","account")
        end
        local function open_generated()
            if section=="generated" then return end
            self:_reopen_shelf(mp_mode,"generated")
        end

        if #rows==0 then
            local items={
                {text=(section=="account" and "✓ " or "").."账号书架",callback=open_account},
                {text=(section=="generated" and "✓ " or "").."已生成书籍",callback=open_generated},
                {text=section=="generated" and "搜索已生成书籍" or "搜索账号书架",callback=function() self:show_shelf_search_dialog(mp_mode,all_rows,section) end},
                {text="排序和筛选",post_text=self:_shelf_summary(section),callback=function() self:show_shelf_controls(mp_mode,section) end},
            }
            if self:logged_in() then
                items[#items+1]={text=section=="generated" and "刷新云端状态" or "刷新账号书架",callback=function() self:show_shelf(mp_mode,true,section) end}
            else
                items[#items+1]={text="扫码登录",callback=function() self.auth_flow:start() end}
            end
            if remote_error then table.insert(items,3,{text=remote_error,enabled=false}) end
            self:list(title,items,"书架为空")
            return
        end
        if show_covers then self:_begin_cover_guard("shelf_open") end
        local ok,view=pcall(ShelfView.show,{
            title=title.." · "..tostring(#rows).."本",
            books=rows,
            selected_tab=section,
            show_covers=show_covers,
            on_account_tab=open_account,
            on_generated_tab=open_generated,
            on_search=function() self:show_shelf_search_dialog(mp_mode,all_rows,section) end,
            on_sort=function() self:show_shelf_controls(mp_mode,section) end,
            on_select=function(b) self:_shelf_select(b) end,
            on_hold=function(b) self:book_menu(b) end,
            on_page_changed=function(page,first,last,current)
                if show_covers then self:_on_shelf_page(rows,current,page,first,last) end
            end,
            on_rendered=function() self:_clear_cover_guard() end,
            on_close=function(current)
                if self._shelf_view==current then self._shelf_view=nil end
                self:_cancel_cover_loading()
                collectgarbage("step",160)
            end,
        })
        if ok and view then self._shelf_view=view; return end
        self:_clear_cover_guard()
        logger.warn("[MiuRead][Shelf] custom view unavailable",tostring(view))
        local items={
            {text=(section=="account" and "✓ " or "").."账号书架",callback=open_account},
            {text=(section=="generated" and "✓ " or "").."已生成书籍",callback=open_generated},
            {text=section=="generated" and "搜索已生成书籍" or "搜索账号书架",callback=function() self:show_shelf_search_dialog(mp_mode,all_rows,section) end},
            {text="排序和筛选",post_text=self:_shelf_summary(section),callback=function() self:show_shelf_controls(mp_mode,section) end},
        }
        for _,b in ipairs(rows) do
            local book=b
            items[#items+1]={text=(book.downloaded and "✓ " or "")..book.title,post_text=self:_shelf_status_text(book),callback=function() self:_shelf_select(book) end,hold_callback=function() self:book_menu(book) end}
        end
        self:list(title,items)
    end,force_remote,section)
end

function Plugin:show_shelf_controls(mp_mode,section)
    local menu
    local prefs=self.store:preferences()
    section=section or prefs.shelf_section or "account"
    section=section=="generated" and "generated" or "account"
    if mp_mode==nil then mp_mode=tostring(prefs.account_shelf_kind or "books")=="mp" end
    local current_scope=section=="generated"
        and tostring(prefs.generated_shelf_scope or "all")
        or tostring(prefs.account_shelf_scope or "all")
    local current_sort=section=="generated"
        and tostring(prefs.generated_shelf_sort or "opened")
        or tostring(prefs.account_shelf_sort or "read")

    local function close_menu()
        if menu then pcall(function() UIManager:close(menu) end) end
    end
    local function apply(change,next_mp)
        change()
        close_menu()
        self:_reopen_shelf(next_mp==nil and mp_mode or next_mp,section)
    end

    local items={}
    if section=="account" then
        local kind_items={
            {
                text=(not mp_mode and "✓ " or "").."普通书籍",
                radio=true,
                checked_func=function() return tostring(self.store:preferences().account_shelf_kind or "books")=="books" end,
                callback=function()
                    if mp_mode then
                        local next_prefs=self.store:preferences()
                        next_prefs.account_shelf_kind="books"
                        self.store:save_preferences(next_prefs)
                        close_menu()
                        self:_reopen_shelf(false,"account")
                    end
                end,
            },
            {
                text=(mp_mode and "✓ " or "").."公众号",
                radio=true,
                checked_func=function() return tostring(self.store:preferences().account_shelf_kind or "books")=="mp" end,
                callback=function()
                    if not mp_mode then
                        local next_prefs=self.store:preferences()
                        next_prefs.account_shelf_kind="mp"
                        self.store:save_preferences(next_prefs)
                        close_menu()
                        self:_reopen_shelf(true,"account")
                    end
                end,
            },
        }
        items[#items+1]={text="账号内容",post_text=mp_mode and "公众号" or "普通书籍",sub_item_table=kind_items}
    end

    local scope_items={}
    local scope_rows=section=="generated"
        and {{"all","全部"},{"in_account","账号书架中"},{"removed","已从账号书架移除"},{"clean","纯净版"},{"notes","划线与想法版"}}
        or {{"all","全部"},{"generated","已生成"},{"ungenerated","未生成"},{"top","置顶"},{"archive","书单"}}
    for _,row in ipairs(scope_rows) do
        local key,label=row[1],row[2]
        local selected=current_scope==key
        scope_items[#scope_items+1]={
            text=(selected and "✓ " or "")..label,
            radio=true,
            checked_func=function()
                local p=self.store:preferences()
                return tostring(section=="generated" and p.generated_shelf_scope or p.account_shelf_scope)==key
            end,
            callback=function()
                apply(function()
                    local p=self.store:preferences()
                    if section=="generated" then p.generated_shelf_scope=key else p.account_shelf_scope=key end
                    self.store:save_preferences(p)
                end)
            end,
        }
    end

    local sort_items={}
    local sort_rows=section=="generated"
        and {{"opened","最近打开"},{"generated","最近生成"},{"title","书名"},{"author","作者"},{"size","文件大小"}}
        or {{"read","最近阅读（默认）"},{"update","最近更新"},{"progress","阅读进度（高到低）"},{"title","书名"},{"author","作者"}}
    for _,row in ipairs(sort_rows) do
        local key,label=row[1],row[2]
        local selected=current_sort==key
        sort_items[#sort_items+1]={
            text=(selected and "✓ " or "")..label,
            radio=true,
            checked_func=function()
                local p=self.store:preferences()
                return tostring(section=="generated" and p.generated_shelf_sort or p.account_shelf_sort)==key
            end,
            callback=function()
                apply(function()
                    local p=self.store:preferences()
                    if section=="generated" then p.generated_shelf_sort=key else p.account_shelf_sort=key end
                    self.store:save_preferences(p)
                end)
            end,
        }
    end

    local scope_labels=section=="generated" and GENERATED_SCOPE_LABELS or ACCOUNT_SCOPE_LABELS
    local sort_labels=section=="generated" and GENERATED_SORT_LABELS or ACCOUNT_SORT_LABELS
    items[#items+1]={text="筛选范围",post_text=scope_labels[current_scope] or "全部",sub_item_table=scope_items}
    items[#items+1]={text="排序方式",post_text=sort_labels[current_sort] or (section=="generated" and "最近打开" or "最近阅读（默认）"),sub_item_table=sort_items}
    items[#items+1]={
        text=section=="generated" and "刷新云端状态" or "刷新账号书架",
        enabled=self:logged_in(),
        callback=function()
            close_menu()
            UIManager:scheduleIn(0,function()
                self:_close_current_shelf()
                self:show_shelf(mp_mode,true,section)
            end)
        end,
    }
    menu=Menu:new{title=section=="generated" and "已生成书籍选项" or "账号书架选项",item_table=items,is_borderless=true,title_bar_fm_style=true}
    UIManager:show(menu)
end
function Plugin:sort_menu() return {{text="打开书架排序与筛选",callback=function() self:show_shelf_controls(self._last_shelf_mode,self._last_shelf_section) end}} end
function Plugin:filter_menu() return self:sort_menu() end
function Plugin:search_dialog()
    if not self:require_login() then return end
    local d
    d=InputDialog:new{
        title=_("Search books"), input="",
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},
            {text=_("Search"),is_enter_default=true,callback=function()
                local q=U.trim(d:getInputText())
                UIManager:close(d)
                if q~="" then self:search(q) end
            end},
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
end

function Plugin:_cancel_search(reason)
    self._search_generation=(tonumber(self._search_generation) or 0)+1
    if self.search_async then self.search_async:cancel(reason or "cancelled") end
    local dialog=self._search_dialog
    self._search_dialog=nil
    if dialog then pcall(UIManager.close,UIManager,dialog) end
end

function Plugin:search(q)
    if not self:require_login() then return end
    if not self:is_online() then self:info(_("Network unavailable")); return end
    if self.search_async and self.search_async:busy() then self:_cancel_search("new_search") end

    self._search_generation=(tonumber(self._search_generation) or 0)+1
    local generation=self._search_generation
    local closing=false
    local dialog
    dialog=ButtonDialog:new{
        title="正在搜索《"..tostring(q).."》……\n\n可按返回键或点击取消。",
        title_align="center",
        close_callback=function()
            if closing then return end
            closing=true
            if generation==self._search_generation and self.search_async then
                self.search_async:cancel("search_dialog_closed")
                self._search_generation=self._search_generation+1
            end
            self._search_dialog=nil
        end,
        buttons={
            {{text="取消搜索",callback=function()
                if closing then return end
                closing=true
                if generation==self._search_generation and self.search_async then
                    self.search_async:cancel("user_cancelled")
                end
                self._search_generation=self._search_generation+1
                self._search_dialog=nil
                UIManager:close(dialog)
            end}},
        },
    }
    self._search_dialog=dialog
    UIManager:show(dialog)

    local function finish(result)
        if generation~=self._search_generation then return end
        closing=true
        self._search_dialog=nil
        UIManager:close(dialog)
        if not result or result.ok~=true then
            self:info(self:_friendly_remote_error(result and result.error or "未知错误","搜索"))
            return
        end
        local data=result.value or {}
        local items={}
        local function add(r)
            local b=normalize(r)
            if b.bookId~="" then
                items[#items+1]={text=b.title,post_text=b.author,callback=function() self:book_menu(b) end}
            end
        end
        for _,g in ipairs(data.results or data.books or {}) do
            if g.books then for _,r in ipairs(g.books) do add(r) end else add(g) end
        end
        self:list(_("Search").." · "..q,items,"没有找到相关书籍")
    end

    local function run_on_main_thread()
        UIManager:scheduleIn(.10,function()
            if generation~=self._search_generation then return end
            local ok,value=xpcall(function() return self.api:search(q,0,40) end,debug.traceback)
            finish(ok and {ok=true,value=value} or {ok=false,error=tostring(value)})
        end)
    end

    if not self.search_async or not self.search_async:available() then
        run_on_main_thread()
        return
    end

    local auth=U.copy(self.store:auth())
    local started,err=self.search_async:run("book_search",function()
        local HttpChild=require("miuthought.http")
        local ApiChild=require("miuthought.api")
        local UtilChild=require("miuthought.util")
        local child_store={
            auth=function() return UtilChild.copy(auth) end,
            save_auth=function() end,
        }
        local api=ApiChild:new(HttpChild:new(child_store),child_store)
        return api:search(q,0,40)
    end,finish,32)
    if not started then
        logger.warn("[MiuRead][Search] async unavailable; falling back",tostring(err or "worker busy"))
        run_on_main_thread()
    end
end
function Plugin:_variant_exists(book_id,kind)
    local r=self.store:variant(book_id,kind)
    return r and r.file and U.file_exists(r.file) and r or nil
end
function Plugin:_book_has_cache(book_id)
    local stored=self.store:book(book_id)
    if not stored then return false end
    for _,r in pairs(stored.variants or {}) do if r.file and U.file_exists(r.file) then return true end end
    for _,row in pairs(stored.chapters or {}) do for _,r in pairs(row or {}) do if r.file and U.file_exists(r.file) then return true end end end
    return false
end
function Plugin:book_menu(b)
    local original=type(b)=="table" and b or {}
    b=U.merge(original,normalize(original))
    local clean=self:_variant_exists(b.bookId,"clean")
    local notes=self:_variant_exists(b.bookId,"notes")
    local items={}
    if clean and notes then
        items[#items+1]={text="打开纯净版",callback=function() self:open_file(clean.file) end}
        items[#items+1]={text="打开划线与想法版",callback=function() self:open_file(notes.file) end}
        items[#items+1]={text="重新生成",callback=function() self:choose_download(b,nil,false) end}
    elseif clean or notes then
        local current=clean or notes
        local current_label=clean and "纯净版" or "划线与想法版"
        items[#items+1]={text="打开 · "..current_label,callback=function() self:open_file(current.file) end}
        if clean then
            items[#items+1]={text="生成划线与想法版",callback=function() self:choose_download_mode(b,{annotations=true},false) end}
        else
            items[#items+1]={text="生成纯净版",callback=function() self:choose_download_mode(b,{annotations=false},false) end}
        end
        items[#items+1]={text="重新生成",callback=function() self:choose_download(b,nil,false) end}
    else
        items[#items+1]={text="生成书籍",callback=function() self:choose_download(b,nil,false) end}
        items[#items+1]={text=_("Read first chapter"),callback=function() self:choose_download(b,1,true) end}
    end
    items[#items+1]={text=_("Chapter list"),callback=function() self:chapters(b) end}
    items[#items+1]={text=_("Book details"),callback=function() self:book_details(b) end}
    if b.archiveNames and tostring(b.archiveNames)~="" then
        items[#items+1]={text="所属书单",post_text=tostring(b.archiveNames),callback=function() self:info("所属书单：\n"..tostring(b.archiveNames)) end}
    end
    items[#items+1]={text=_("View cover"),callback=function() self:view_cover(b) end}
    if self:_book_has_cache(b.bookId) or self.store:book_has_partial_cache(b.bookId) then
        items[#items+1]={text="管理已生成文件",callback=function() self:downloaded_book_menu(tostring(b.bookId)) end}
    end
    self:list(b.title,items)
end
function Plugin:book_details(b)
    self:online("details",function() local x=self.api:book(b.bookId); local z=normalize(x); self:info(z.title.."\n"..z.author.."\n\n"..tostring(x.intro or x.description or "")) end)
end
function Plugin:view_cover(b)
    self:online("cover",function() local path=self.library:cache_cover(b); if not path then self:info("没有可用封面") return end; local ok,Viewer=pcall(require,"ui/widget/imageviewer"); if ok then local good,obj=pcall(Viewer.new,Viewer,{file=path,title=b.title,with_title_bar=true}); if good then UIManager:show(obj); return end end; self:info(path) end)
end
function Plugin:open_variant(b,kind) local r=self.store:variant(b.bookId,kind); if r and r.file and U.file_exists(r.file) then self:open_file(r.file) else self:info(_("No cached file")) end end
function Plugin:choose_download_mode(b,opt,open_after)
    local dialog
    local function start(background)
        UIManager:close(dialog)
        if background then
            self:status_toast("觅阅",tostring(b and b.title or "未命名").."正在启动后台下载",2)
        end
        -- Close and repaint the menu before starting the child process. This
        -- avoids the Android screen looking frozen after the download button.
        UIManager:scheduleIn(.20,function()
            self:download(b,opt,open_after,nil,background)
        end)
    end
    dialog=ButtonDialog:new{title="下载方式",title_align="center",buttons={
        {{text="后台下载",callback=function() start(true) end}},
        {{text="留在当前页面下载",callback=function() start(false) end}},
        {{text="取消",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end
function Plugin:choose_download(b,limit,open_after,uid)
    local dialog
    local function choose_version(annotations)
        UIManager:close(dialog)
        self:choose_download_mode(b,{annotations=annotations,limit=limit,chapter_uid=uid},open_after)
    end
    dialog=ButtonDialog:new{
        title="下载《"..tostring(b.title or "未命名").."》",title_align="center",
        buttons={
            {{text="纯净版",callback=function() choose_version(false) end}},
            {{text="划线与想法版",callback=function() choose_version(true) end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        },
    }
    UIManager:show(dialog)
end
function Plugin:_download_summary(rec,opt)
    local lines={
        "下载完成",
        "保存位置："..tostring(rec.file or ""),
        "打开一次后会出现在 KOReader 最近阅读中",
    }
    if opt and opt.annotations then
        local a=rec.annotation_summary or {}
        lines[#lines+1]="划线："..tostring(a.underlines or 0)
        lines[#lines+1]="含想法的划线："..tostring(a.thoughts or 0)
    end
    return table.concat(lines,"\n")
end

function Plugin:_refresh_local_files()
    local ui=self.ui
    if not ui then return end
    local chooser=ui.file_chooser
    if chooser then
        if type(chooser.refreshPath)=="function" then pcall(chooser.refreshPath,chooser)
        elseif type(chooser.refresh)=="function" then pcall(chooser.refresh,chooser) end
    end
    if type(ui.onRefresh)=="function" then pcall(ui.onRefresh,ui) end
end
function Plugin:_update_open_shelf_download_status(book_id,status)
    local view=self._shelf_view
    if not view or view._miu_closed or type(view.item_table)~="table" then return false end
    local changed=false
    for _,entry in ipairs(view.item_table) do
        if tostring(entry.book_id or "")==tostring(book_id or "") then
            entry.status=tostring(status or "")
            changed=true
        end
    end
    if changed and type(view.updateItems)=="function" then pcall(view.updateItems,view,nil,true) end
    return changed
end
local DOWNLOAD_STAGE_LABELS={
    prepare="准备下载",catalog="读取目录",resume="恢复断点",content="下载正文",
    underlines="获取划线",thoughts="获取想法",footnotes="处理脚注",
    images="处理图片",package="生成 EPUB",done="下载完成",error="下载失败",
    cancelled="下载已取消",
}
function Plugin:_on_download_progress(runtime,state)
    if self._download_runtime~=runtime then return end
    runtime.last_state=U.copy(state or {})
    runtime.task=self.download_task and self.download_task:descriptor() or runtime.task
    if runtime.dialog then runtime.dialog:set_state(state) end
    self:_write_download_state("active",self:_active_download_payload(runtime,state),false)
    if state and state.waiting_network==true then
        self:_update_open_shelf_download_status(runtime.book.bookId,"等待网络")
    end
    if runtime.background and self.store:preferences().download_notice_enabled~=false then
        runtime.notified_milestones=runtime.notified_milestones or {}
        local percent=self:_download_percent(state)
        for _,mark in ipairs({25,50,75}) do
            if percent>=mark and not runtime.notified_milestones[mark] then
                runtime.notified_milestones[mark]=true
                self:_update_open_shelf_download_status(runtime.book.bookId,"生成中 "..tostring(mark).."%")
                self:status_toast("后台下载",tostring(runtime.book.title or "未命名").." · "..tostring(mark).."%",3)
            end
        end
    end
end
function Plugin:_finish_download_runtime(runtime,result)
    if self._download_runtime~=runtime then return end
    local b=runtime.book or {}
    local opt=runtime.options or {}
    local done=runtime.done
    local open_after=runtime.open_after==true
    local was_background=runtime.background==true
    self:_close_download_dialog()
    if self.download_task then self.download_task:set_backgrounded(false) end
    self._download_runtime=nil
    if not result or result.ok~=true then
        local err=result and result.error or "未知下载错误"
        logger.warn("[MiuRead][Download] failed",tostring(err))
        if tostring(err)=="下载已取消" then
            self.store:clear_download_state()
            self:_update_open_shelf_download_status(b.bookId,"生成已取消")
            if was_background then self:status_toast("觅阅","下载已取消",3) else self:toast("下载已取消",3) end
            self:_start_next_queued_download()
            return
        end
        self:_write_download_state("failed",{
            title=b.title,book_id=b.bookId,book=U.copy(b),options=U.copy(opt),
            error=tostring(err),stage=runtime.last_state and runtime.last_state.stage,
            current=runtime.last_state and runtime.last_state.current,total=runtime.last_state and runtime.last_state.total,
            percent=runtime.last_state and runtime.last_state.percent,seen=false,
        },true)
        self:_update_open_shelf_download_status(b.bookId,"生成未完成")
        if was_background then self:status_toast("觅阅",tostring(b.title or "未命名").."下载未完成，进度已保留",5)
        else self:info("下载失败：\n"..U.first_line(err)) end
        self:_start_next_queued_download()
        return
    end
    local rec=self:_merge_download_result(result,b,opt)
    if rec.pending_install and tostring(self:_current_document_path() or "")~=tostring(rec.file or "") then
        self:_install_pending_downloads(false)
        self.store:reload()
        local kind=rec.variant or (opt.annotations and "notes" or "clean")
        local refreshed=opt.chapter_uid and self.store:chapter_variant(b.bookId,opt.chapter_uid,kind)
            or self.store:variant(b.bookId,kind)
        if refreshed then rec=U.copy(refreshed) end
    end
    self:_refresh_local_files()
    local pending=rec.pending_install==true and rec.pending_file and U.file_exists(rec.pending_file)
    self:_update_open_shelf_download_status(b.bookId,pending and "等待关闭后更新" or "已生成")
    self:_write_download_state(pending and "pending_install" or "completed",{
        title=b.title,book_id=b.bookId,book=U.copy(b),options=U.copy(opt),file=rec.file,
        pending_file=rec.pending_file,pending_install=pending or nil,seen=false,percent=1,
        current=rec.chapter_count,total=rec.expected_chapter_count,completed_at=os.time(),
    },true)
    if done then done(rec,was_background); self:_start_next_queued_download(); return end
    if pending then
        local text=tostring(b.title or "未命名").."新版本已下载，关闭当前书籍后更新"
        if was_background then self:status_toast("觅阅",text,5) else self:info(text) end
    elseif was_background then
        if self.store:preferences().download_complete_notice~=false then
            self:status_toast("觅阅",tostring(b.title or "未命名").."下载完成",5)
        end
    elseif open_after and rec.file then
        self.store:clear_download_state(); self:open_file(rec.file)
    else
        self:_show_download_complete(rec,opt)
    end
    self:_start_next_queued_download()
end
function Plugin:_recover_download_state()
    local state=self.store:download_state()
    if state.status~="active" then return false end
    local runtime={
        book=U.copy(state.book or {bookId=state.book_id,title=state.title}),
        options=U.copy(state.options or {}),
        last_state={stage=state.stage,current=state.current,total=state.total,percent=state.percent,
            chapter=state.chapter,message=state.message},
        background=true,dialog=nil,started_at=state.started_at,task=U.copy(state.task),
        open_after=false,done=nil,recovered=true,
    }
    if type(runtime.task)=="table" then
        self._download_runtime=runtime
        local ok,err=self.download_task:attach(runtime.task,
            function(progress) self:_on_download_progress(runtime,progress) end,
            function(result) self:_finish_download_runtime(runtime,result) end)
        if ok then
            runtime.task=self.download_task:descriptor() or runtime.task
            self.download_task:set_backgrounded(true)
            self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
            logger.info("[MiuRead][Download] active task recovered","pid=",tostring(runtime.task.pid),
                "book=",tostring(runtime.book.bookId or ""))
            return true
        end
        self._download_runtime=nil
        logger.warn("[MiuRead][Download] active task recovery failed",tostring(err))
    end
    state.status="interrupted"
    state.error="上次下载已停止，已完成内容仍保存在断点缓存；再次下载时会继续。"
    state.updated_at=os.time()
    self.store:save_download_state(state)
    return false
end
function Plugin:_download_percent(state)
    state=state or {}
    local p=tonumber(state.percent)
    if not p then
        local current,total=tonumber(state.current) or 0,tonumber(state.total) or 0
        p=total>0 and current/total or 0
    elseif p>1 then p=p/100 end
    if p<0 then p=0 elseif p>1 then p=1 end
    return math.floor(p*100+0.5)
end
function Plugin:_download_state()
    local runtime=self._download_runtime
    if runtime and self.download_task and self.download_task:busy() then
        local state=U.copy(runtime.last_state or {})
        state.status="active"
        state.title=runtime.book and runtime.book.title or state.title
        state.book_id=runtime.book and runtime.book.bookId or state.book_id
        state.background=runtime.background==true
        return state
    end
    return self.store:download_state()
end
function Plugin:_has_download_status()
    if self.download_task and self.download_task:busy() then return true end
    local state=self.store:download_state()
    if state.status=="completed" then return state.seen~=true end
    return state.status=="failed" or state.status=="interrupted" or state.status=="pending_install"
end
function Plugin:_download_status_label()
    local state=self:_download_state()
    if state.status=="active" then
        local title=tostring(state.title or "未命名")
        if #title>16 then title=title:sub(1,16).."…" end
        return "后台下载：《"..title.."》 "..tostring(self:_download_percent(state)).."%"
    end
    if state.status=="pending_install" then return "后台下载 · 等待更新" end
    if state.status=="completed" then return "后台下载 · 已完成" end
    if state.status=="failed" then return "后台下载 · 未完成" end
    if state.status=="interrupted" then return "后台下载 · 可继续" end
    return "后台下载"
end
function Plugin:_write_download_state(status,patch,force)
    local now=os.time()
    local stage=patch and patch.stage
    if not force and status=="active" and now-(self._download_state_last_write or 0)<2 and stage==self._download_state_last_stage then return end
    local state
    if force or status~="active" then state=U.copy(patch or {})
    else state=U.merge(self.store:download_state(),patch or {}) end
    state.status=status
    state.updated_at=now
    self.store:save_download_state(state)
    self._download_state_last_write=now
    self._download_state_last_stage=stage
end
function Plugin:_active_download_payload(runtime,state)
    local task=runtime.task or (self.download_task and self.download_task:descriptor())
    return {
        title=runtime.book and runtime.book.title or "未命名",
        book_id=runtime.book and runtime.book.bookId or "",
        book=U.copy(runtime.book or {}),
        options=U.copy(runtime.options or {}),
        background=runtime.background==true,
        stage=state and state.stage or "prepare",
        current=state and state.current or 0,
        total=state and state.total or 0,
        percent=state and state.percent or 0,
        chapter=state and state.chapter or "",
        message=state and state.message or "",
        started_at=runtime.started_at,
        task=U.copy(task),
    }
end
function Plugin:_close_download_dialog()
    local runtime=self._download_runtime
    if not runtime or not runtime.dialog then return end
    local dialog=runtime.dialog
    runtime.dialog=nil
    pcall(function() dialog:close() end)
end
function Plugin:_send_download_to_background()
    local runtime=self._download_runtime
    if not runtime or not self.download_task or not self.download_task:busy() then return end
    runtime.background=true
    self:_close_download_dialog()
    self.download_task:set_backgrounded(true)
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
    self:status_toast("觅阅",tostring(runtime.book.title or "未命名").."已转入后台下载",3)
end
function Plugin:_show_active_download_dialog()
    local runtime=self._download_runtime
    if not runtime or not self.download_task or not self.download_task:busy() then self:show_download_status(); return end
    if runtime.dialog then return end
    runtime.background=false
    self.download_task:set_backgrounded(false)
    local dialog
    dialog=DownloadProgress:new{
        title="正在下载《"..tostring(runtime.book.title or "未命名").."》",
        on_cancel=function() if self.download_task then self.download_task:cancel() end end,
        on_background=function() self:_send_download_to_background() end,
    }
    runtime.dialog=dialog
    dialog:show()
    if runtime.last_state then dialog:set_state(runtime.last_state) end
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
end
function Plugin:_merge_download_result(result,book,opt)
    self.store:reload()
    if type(result.auth)=="table" then
        local current=self.store:auth()
        local merged_cookies=U.copy(current.cookies or {})
        for name,value in pairs(result.auth.cookies or {}) do merged_cookies[name]=value end
        merged_cookies=Cookies.sanitize(merged_cookies)
        current.cookies=merged_cookies
        if tostring(result.auth.api_key or "")~="" then current.api_key=result.auth.api_key end
        local child_account=result.auth.account or {}
        if tonumber(child_account.logged_at or 0)>tonumber((current.account or {}).logged_at or 0) then current.account=U.copy(child_account) end
        self.store:save_auth(current)
    end
    local rec=result.value or {}
    local kind=rec.variant or (opt.annotations and "notes" or "clean")
    if opt.chapter_uid then self.store:save_chapter_variant(book.bookId,opt.chapter_uid,kind,rec)
    else self.store:save_variant(book.bookId,kind,rec) end
    if rec.pending_install==true and rec.pending_file then
        self.store:add_pending_install(book.bookId,kind,opt.chapter_uid,rec)
    else
        self.store:remove_pending_install(book.bookId,kind,opt.chapter_uid)
    end
    self.store:save_book(book.bookId,{
        book_id=tostring(book.bookId),title=book.title,author=book.author,cover=book.cover,
        directory=rec.directory,updated_at=os.time(),catalog=rec.chapter_map,
    })
    if type(result.session)=="table" then
        local allowed={"psvts","pclts","token","reader_url","chapters","context_updated_at","app_id"}
        local patch={}
        for _,key in ipairs(allowed) do if result.session[key]~=nil then patch[key]=result.session[key] end end
        if next(patch) then self.store:save_session(book.bookId,patch) end
    end
    return rec
end
function Plugin:_show_download_complete(rec,opt)
    local dialog
    dialog=ButtonDialog:new{title=self:_download_summary(rec,opt),title_align="center",buttons={
        {{text="立即阅读",callback=function() UIManager:close(dialog); self.store:clear_download_state(); self:open_file(rec.file) end}},
        {{text="关闭",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end
function Plugin:show_download_status()
    if self.download_task and self.download_task:busy() then self:_show_active_download_dialog(); return end
    local state=self.store:download_state()
    if not state.status or state.status=="" then self:info("当前没有后台下载记录。") return end
    if state.status=="completed" then state.seen=true; self.store:save_download_state(state) end
    local title=tostring(state.title or "未命名")
    local lines={}
    if state.status=="completed" then lines[#lines+1]="下载完成"
    elseif state.status=="pending_install" then lines[#lines+1]="新版本已下载完成"
    elseif state.status=="failed" then lines[#lines+1]="下载未完成"
    elseif state.status=="interrupted" then lines[#lines+1]="上次下载已中断"
    else lines[#lines+1]=tostring(state.status) end
    lines[#lines+1]="《"..title.."》"
    if state.current and state.total and tonumber(state.total)>0 then lines[#lines+1]="章节 "..tostring(state.current).." / "..tostring(state.total) end
    if state.error and state.error~="" then lines[#lines+1]="\n"..U.first_line(state.error) end
    if state.status=="pending_install" then lines[#lines+1]="\n关闭当前书籍后会自动安装新版本。" end
    local buttons={}
    local dialog
    if state.status=="completed" and state.file and U.file_exists(state.file) then
        buttons[#buttons+1]={{text="立即阅读",callback=function() UIManager:close(dialog); self.store:clear_download_state(); self:open_file(state.file) end}}
    elseif (state.status=="failed" or state.status=="interrupted") and type(state.book)=="table" then
        buttons[#buttons+1]={{text="继续下载",callback=function() UIManager:close(dialog); self:download(state.book,state.options or {},false) end}}
    end
    buttons[#buttons+1]={{text="清除记录",callback=function() UIManager:close(dialog); self.store:clear_download_state() end}}
    buttons[#buttons+1]={{text="关闭",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title=table.concat(lines,"\n"),title_align="center",buttons=buttons}
    UIManager:show(dialog)
end
function Plugin:_install_pending_record(book_id,kind,chapter_uid,record)
    local pending=tostring(record and record.pending_file or "")
    local target=tostring(record and record.file or "")
    if pending=="" or target=="" or not U.file_exists(pending) then return false,"等待安装文件不存在" end
    local backup=target..".miuread-backup"
    os.remove(backup)
    local had_previous=U.file_exists(target)
    if had_previous then
        local ok,err=os.rename(target,backup)
        if not ok then return false,"无法保护原 EPUB："..tostring(err) end
    end
    local ok,err=os.rename(pending,target)
    if not ok then
        if had_previous then os.rename(backup,target) end
        return false,"无法安装新 EPUB："..tostring(err)
    end
    if had_previous then os.remove(backup) end
    local updated=U.copy(record)
    updated.pending_file=nil; updated.pending_install=nil; updated.installed_at=os.time()
    if chapter_uid then self.store:save_chapter_variant(book_id,chapter_uid,kind,updated)
    else self.store:save_variant(book_id,kind,updated) end
    self.store:remove_pending_install(book_id,kind,chapter_uid)
    return true,updated
end
function Plugin:_install_pending_downloads(notify)
    local current=tostring(self:_current_document_path() or "")
    self.store:reload()
    local pending=self.store:prune_pending_installs()
    if #pending==0 then return false end
    local installed,last_record=0,nil
    for _,item in ipairs(pending) do
        local book_id=tostring(item.book_id or "")
        local kind=tostring(item.kind or "")
        local chapter_uid=item.chapter_uid and tostring(item.chapter_uid) or nil
        local book=self.store:book(book_id)
        local record
        if chapter_uid then
            local row=book and book.chapters and book.chapters[chapter_uid]
            record=row and row[kind]
        else
            record=book and book.variants and book.variants[kind]
        end
        if not record or record.pending_install~=true or not U.file_exists(record.pending_file) then
            self.store:remove_pending_install(book_id,kind,chapter_uid)
        elseif tostring(record.file or "")~=current then
            local ok,value=self:_install_pending_record(book_id,kind,chapter_uid,record)
            if ok then installed=installed+1; last_record=value
            else logger.warn("[MiuRead][Download] pending install failed",tostring(value)) end
        end
    end
    if installed>0 then
        local remaining=self.store:prune_pending_installs()
        local state=self.store:download_state()
        if #remaining==0 then
            state.status="completed"; state.pending_install=nil; state.pending_file=nil; state.seen=false
        else
            state.status="pending_install"; state.pending_install=true
        end
        state.updated_at=os.time()
        if last_record then state.file=last_record.file end
        self.store:save_download_state(state)
        self:_refresh_local_files()
        if notify then
            self:status_toast("觅阅",installed>1 and (tostring(installed).." 个新版本已安装") or "新版本已安装",4)
        end
        return true
    end
    return false
end

function Plugin:_download_job_key(book,opt)
    opt=opt or {}
    return table.concat({tostring(book and book.bookId or ""),opt.annotations and "notes" or "clean",tostring(opt.chapter_uid or "full")},":")
end
function Plugin:_queue_download(book,opt,open_after)
    local key=self:_download_job_key(book,opt)
    local runtime=self._download_runtime
    if runtime and self:_download_job_key(runtime.book,runtime.options)==key then
        self:info("这项下载已经在进行中。") return false
    end
    for _,job in ipairs(self.store:download_queue()) do
        if tostring(job.key or "")==key then self:info("这项下载已经在等待队列中。") return false end
    end
    local position=self.store:enqueue_download({key=key,book=U.copy(book or {}),options=U.copy(opt or {}),open_after=open_after==true,queued_at=os.time()})
    self:status_toast("下载队列","已加入等待队列 · 第 "..tostring(position).." 项",3)
    return true
end
function Plugin:_start_next_queued_download()
    if self.download_task and self.download_task:busy() then return false end
    if self._download_runtime then return false end
    if not self:is_online() or not self:logged_in() then return false end
    local job=self.store:dequeue_download()
    if not job then return false end
    UIManager:scheduleIn(.15,function()
        self:download(job.book or {},job.options or {},job.open_after==true,nil,true,true)
    end)
    return true
end
function Plugin:show_waiting_downloads()
    local queue=self.store:download_queue()
    if #queue==0 then self:info("当前没有等待下载的任务。") return end
    local items={}
    for index,job in ipairs(queue) do
        local queue_index=index
        local title=tostring(job.book and job.book.title or "未命名")
        local variant=(job.options and job.options.annotations) and "划线与想法版" or "纯净版"
        items[#items+1]={text=title,post_text=tostring(queue_index).." · "..variant,callback=function()
            UIManager:show(ConfirmBox:new{text="从等待队列移除《"..title.."》？",ok_callback=function()
                self.store:remove_queued_download(queue_index); self:toast("已移出等待队列")
            end})
        end}
    end
    self:list("等待下载",items)
end

function Plugin:download(b,opt,open_after,done,start_in_background,from_queue)
    if not self:require_login() then return end
    if not self:is_online() then self:info(_("Network unavailable")); return end
    opt=U.copy(opt or {})
    if self.download_task and self.download_task:busy() then
        if from_queue then
            self.store:enqueue_download({key=self:_download_job_key(b,opt),book=U.copy(b),options=U.copy(opt),open_after=open_after==true,queued_at=os.time()})
            return false
        end
        return self:_queue_download(b,opt,open_after)
    end
    local stored=self.store:download_state()
    if stored.status=="active" and self:_recover_download_state() then
        if from_queue then
            self.store:enqueue_download({key=self:_download_job_key(b,opt),book=U.copy(b),options=U.copy(opt),open_after=open_after==true,queued_at=os.time()})
            return false
        end
        return self:_queue_download(b,opt,open_after)
    end
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存正在清理，完成后再开始下载。"); return end
    if self.epub_style_repair_task and self.epub_style_repair_task:busy() then self:info("已下载书籍正在修复，完成后再开始下载。"); return end
    if b and b.bookId and tostring(b.bookId)~="" then self.store:save_book(b.bookId,{book_id=tostring(b.bookId),title=b.title,author=b.author,updated_at=os.time()}) end
    local prefs=self.store:preferences()
    opt.images=tostring(b.bookId):sub(1,7)=="MP_WXS_" and prefs.mp_images or prefs.images
    opt.active_document_path=self:_current_document_path()
    local runtime={book=U.copy(b),options=U.copy(opt),last_state={stage="prepare",current=0,total=1,percent=0,chapter=b.title or ""},background=start_in_background==true,dialog=nil,started_at=os.time(),open_after=open_after==true,done=done,notified_milestones={}}
    self._download_runtime=runtime
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
    local ok,err=self.download_task:start(b,opt,
        function(state) self:_on_download_progress(runtime,state) end,
        function(result) self:_finish_download_runtime(runtime,result) end)
    if not ok then
        self._download_runtime=nil
        self.store:clear_download_state()
        if from_queue then self.store:enqueue_download({key=self:_download_job_key(b,opt),book=U.copy(b),options=U.copy(opt),open_after=open_after==true,queued_at=os.time()}) end
        self:info("无法启动下载任务：\n"..tostring(err))
        return false
    end
    runtime.task=self.download_task:descriptor()
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
    if runtime.background then
        self.download_task:set_backgrounded(true)
        self:_update_open_shelf_download_status(b.bookId,"生成中 0%")
        if self.store:preferences().download_notice_enabled~=false then
            self:status_toast("觅阅",tostring(b.title or "未命名").."已转入后台下载",3)
        end
    else
        self:_show_active_download_dialog()
    end
end

function Plugin:chapters(b)
    self:online("chapters",function()
        local _,rows=self.downloader:catalog(b.bookId)
        local items={}
        for _,ch in ipairs(rows) do
            local chapter=ch
            items[#items+1]={text=chapter.title or tostring(chapter.chapterUid),post_text=tostring(chapter.wordCount or ""),callback=function() self:chapter_menu(b,chapter) end}
        end
        self:list(b.title,items)
    end)
end
function Plugin:chapter_menu(b,ch)
    local uid=ch.chapterUid
    local clean=self.store:chapter_variant(b.bookId,uid,"clean")
    local notes=self.store:chapter_variant(b.bookId,uid,"notes")
    if not (clean and clean.file and U.file_exists(clean.file)) then clean=nil end
    if not (notes and notes.file and U.file_exists(notes.file)) then notes=nil end
    local items={}
    if clean and notes then
        items[#items+1]={text="阅读纯净版",callback=function() self:open_file(clean.file) end}
        items[#items+1]={text="阅读划线与想法版",callback=function() self:open_file(notes.file) end}
        items[#items+1]={text="重新下载本章",callback=function() self:choose_download(b,nil,false,uid) end}
    elseif clean or notes then
        local current=clean or notes
        local label=clean and "纯净版" or "划线与想法版"
        items[#items+1]={text="继续阅读 · "..label,callback=function() self:open_file(current.file) end}
        if clean then
            items[#items+1]={text="下载本章划线与想法版",callback=function() self:choose_download_mode(b,{annotations=true,chapter_uid=uid},true) end}
        else
            items[#items+1]={text="下载本章纯净版",callback=function() self:choose_download_mode(b,{annotations=false,chapter_uid=uid},true) end}
        end
    else
        items[#items+1]={text=_("Download chapter"),callback=function() self:choose_download(b,nil,true,uid) end}
    end
    if clean or notes then
        items[#items+1]={text=_("Delete chapter cache"),callback=function() self:_confirm_delete_chapter_cache(b.bookId,uid,ch.title or tostring(uid)) end}
    end
    self:list(ch.title or tostring(uid),items)
end
function Plugin:open_file(path)
    if not path or not U.file_exists(path) then self:info(_("No cached file")); return end
    -- Do not inspect the EPUB or flush settings before opening it. The reader
    -- ready callback identifies the book after input handling is restored.
    if self.ui.document then self.ui:switchDocument(path) else self.ui:openFile(path) end
end
function Plugin:_variant_label(kind)
    return kind=="notes" and "划线与想法版" or "纯净版"
end
function Plugin:_close_download_menus()
    local detail=self._download_book_menu; self._download_book_menu=nil
    local root=self._downloads_menu; self._downloads_menu=nil
    if detail then pcall(function() UIManager:close(detail) end) end
    if root and root~=detail then pcall(function() UIManager:close(root) end) end
end
function Plugin:_cache_action_blocked()
    if self.download_task and self.download_task:busy() then self:info("下载任务进行中，暂时不能修改下载文件。") return true end
    local state=self.store:download_state()
    if state.status=="active" then self:info("后台下载状态正在恢复，暂时不能清理文件。") return true end
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存任务正在运行，请勿重复操作。") return true end
    if self.epub_style_repair_task and self.epub_style_repair_task:busy() then self:info("已下载书籍正在修复，请稍候。") return true end
    return false
end
function Plugin:_notes_epub_paths(book_id)
    self.store:reload()
    local out,seen={},{}
    local function add(record)
        local path=record and tostring(record.file or "") or ""
        if path~="" and path:lower():match("%.epub$") and U.file_exists(path) and not seen[path] then
            seen[path]=true; out[#out+1]=path
        end
    end
    local function add_book(book)
        if not book then return end
        for _,kind in ipairs({"clean","notes"}) do add(book.variants and book.variants[kind]) end
        for _,row in pairs(book.chapters or {}) do
            for _,kind in ipairs({"clean","notes"}) do add(row and row[kind]) end
        end
    end
    if book_id then add_book(self.store:book(book_id))
    else for _,book in ipairs(self.store:all_books()) do add_book(book) end end
    table.sort(out)
    return out
end
function Plugin:_current_document_path()
    local doc=self.ui and self.ui.document
    return doc and (doc.file or (doc.getFilePath and doc:getFilePath())) or nil
end
function Plugin:_run_epub_style_repair(paths,options)
    options=options or {}
    if self:_cache_action_blocked() then return end
    local unique,seen={},{}
    for _,path in ipairs(paths or {}) do
        path=tostring(path or "")
        if path~="" and not seen[path] then seen[path]=true; unique[#unique+1]=path end
    end
    if #unique==0 then self:info("没有可修复的已下载 EPUB。") return end
    local current=tostring(self:_current_document_path() or "")
    if current~="" then
        for _,path in ipairs(unique) do
            if tostring(path)==current then
                self:info("当前书籍仍在阅读器中打开。\n\n请先返回文件管理器或书架，再执行书籍修复。修复失败时原文件会自动恢复。")
                return
            end
        end
    end
    self:_close_download_menus()
    local dialog=InfoMessage:new{text=tostring(options.progress_text or "正在检查并修复已下载书籍，请稍候……")}
    self._epub_style_repair_dialog=dialog
    UIManager:show(dialog)
    local function finish(result)
        if self._epub_style_repair_dialog then pcall(function() UIManager:close(self._epub_style_repair_dialog) end) end
        self._epub_style_repair_dialog=nil
        local repaired=tonumber(result and result.repaired or 0) or 0
        local skipped=tonumber(result and result.skipped or 0) or 0
        local errors=result and result.errors or {}
        local links_checked=tonumber(result and result.links_checked or 0) or 0
        local links_rewritten=tonumber(result and result.links_rewritten or 0) or 0
        if result and result.ok==true then
            local lines={"已下载书籍修复完成"}
            if repaired>0 then lines[#lines+1]="已修复："..tostring(repaired).." 个 EPUB" end
            if skipped>0 then lines[#lines+1]="无需修改："..tostring(skipped).." 个 EPUB" end
            if links_checked>0 then lines[#lines+1]="检查书内链接："..tostring(links_checked).." 个" end
            if links_rewritten>0 then lines[#lines+1]="修复失效链接："..tostring(links_rewritten).." 个" end
            lines[#lines+1]=""
            lines[#lines+1]="已修复可识别的尾注双向链接、失效旧路径和旧划线样式。重新打开书籍即可生效。"
            self:info(table.concat(lines,"\n"))
        else
            local lines={"已下载书籍修复未完全完成","","已修复："..tostring(repaired).." 个 EPUB"}
            if skipped>0 then lines[#lines+1]="无需修改："..tostring(skipped).." 个 EPUB" end
            if #errors>0 then lines[#lines+1]=""; lines[#lines+1]=U.first_line(table.concat(errors,"\n"),420) end
            lines[#lines+1]=""; lines[#lines+1]="失败文件已自动恢复原版。"
            self:info(table.concat(lines,"\n"))
        end
        if options.refresh~=false then UIManager:scheduleIn(.08,function() self:show_downloads() end) end
    end
    local ok,err=self.epub_style_repair_task:start(unique,finish)
    if not ok then
        pcall(function() UIManager:close(dialog) end); self._epub_style_repair_dialog=nil
        self:info("无法开始修复：\n"..tostring(err))
        if options.refresh~=false then UIManager:scheduleIn(.08,function() self:show_downloads() end) end
    end
end
function Plugin:_confirm_repair_book_style(book_id,title)
    local paths=self:_notes_epub_paths(book_id)
    if #paths==0 then self:info("《"..tostring(title or book_id).."》没有可修复的已下载 EPUB。") return end
    UIManager:show(ConfirmBox:new{
        text="修复《"..tostring(title or book_id).."》？\n\n会检查并修复正文到尾注、尾注返回正文、失效旧路径，以及旧划线样式。直接处理现有 EPUB，不重新下载；操作前会临时备份，失败会自动恢复。",
        ok_text="开始修复",
        ok_callback=function()
            self:_run_epub_style_repair(paths,{progress_text="正在修复本书……"})
        end,
    })
end
function Plugin:_confirm_repair_all_styles()
    local paths=self:_notes_epub_paths()
    if #paths==0 then self:info("没有可修复的已下载 EPUB。") return end
    UIManager:show(ConfirmBox:new{
        text="修复全部已下载书籍？\n\n共检测到 "..tostring(#paths).." 个 EPUB。会检查尾注双向链接、失效旧路径和旧划线样式；直接处理现有文件，失败文件会自动恢复。",
        ok_text="修复全部",
        ok_callback=function()
            self:_run_epub_style_repair(paths,{progress_text="正在修复全部已下载书籍……"})
        end,
    })
end
local function human_size(bytes)
    bytes=tonumber(bytes) or 0
    if bytes>=1024*1024*1024 then return string.format("%.2f GB",bytes/(1024*1024*1024)) end
    if bytes>=1024*1024 then return string.format("%.1f MB",bytes/(1024*1024)) end
    if bytes>=1024 then return string.format("%.1f KB",bytes/1024) end
    return tostring(bytes).." B"
end
local function path_name(path) return tostring(path or ""):match("([^/]+)$") or "" end
local function is_download_temp_name(name)
    name=tostring(name or "")
    return name=="download-task-owner.json"
        or name:match("^download%-settings%-.+%.lua$")
        or name:match("^download%-progress%-.+%.json$")
        or name:match("^download%-result%-.+%.json$")
        or name:match("^download%-cancel%-.+")
end
local function is_epub_residue_name(name)
    name=tostring(name or "")
    return name:match("%.miuread%-new%-%d+%-%d+$")
        or name:match("%.miuread%-backup$")
        or name:match("%.miuread%-linkfix$")
        or name:match("%.miuread%-linkbak$")
end
local function is_pending_epub_name(name)
    return tostring(name or ""):match("%.miuread%-pending$")~=nil
end
function Plugin:_all_partial_cache_paths()
    local paths={}
    for _,book_path in ipairs(U.list(self.store.cache_books_dir)) do
        if lfs.attributes(book_path,"mode")=="directory" then
            for _,path in ipairs(U.list(book_path)) do
                if path_name(path):match("^%.miuread%-partial%-") then paths[#paths+1]=path end
            end
        end
    end
    return paths
end
function Plugin:_download_residue_paths()
    local paths={}
    for _,path in ipairs(U.list(self.store.temp_dir)) do
        if is_download_temp_name(path_name(path)) then paths[#paths+1]=path end
    end
    for _,path in ipairs(U.list(self.store:books_root())) do
        if is_epub_residue_name(path_name(path)) then paths[#paths+1]=path end
    end
    for _,path in ipairs(self:_all_partial_cache_paths()) do paths[#paths+1]=path end
    return paths
end
function Plugin:_storage_categories()
    local categories={books={},partial={},protected={},covers={self.store.covers_dir},temp={}}
    for _,path in ipairs(U.list(self.store:books_root())) do
        local name=path_name(path)
        if name:lower():match("%.epub$") and not name:find(".miuread-",1,true) then
            categories.books[#categories.books+1]=path
        elseif is_epub_residue_name(name) or is_pending_epub_name(name) then
            categories.temp[#categories.temp+1]=path
        end
    end
    for _,book_path in ipairs(U.list(self.store.cache_books_dir)) do
        if lfs.attributes(book_path,"mode")=="directory" then
            for _,path in ipairs(U.list(book_path)) do
                if path_name(path):match("^%.miuread%-partial%-") then
                    categories.partial[#categories.partial+1]=path
                else
                    categories.protected[#categories.protected+1]=path
                end
            end
        end
    end
    for _,path in ipairs(U.list(self.store.temp_dir)) do
        if is_download_temp_name(path_name(path)) then categories.temp[#categories.temp+1]=path end
    end
    return categories
end
function Plugin:_run_cache_cleanup(paths,options)
    options=options or {}
    if self:_cache_action_blocked() then return end
    local unique,seen={},{}
    for _,path in ipairs(paths or {}) do
        path=tostring(path or "")
        if path~="" and not seen[path] then seen[path]=true; unique[#unique+1]=path end
    end
    self:_close_download_menus()
    local dialog=InfoMessage:new{text=tostring(options.progress_text or "正在清理，请稍候……")}
    self._cache_cleanup_dialog=dialog
    UIManager:show(dialog)

    local function close_progress()
        if self._cache_cleanup_dialog then pcall(function() UIManager:close(self._cache_cleanup_dialog) end) end
        self._cache_cleanup_dialog=nil
    end
    local function finish(result)
        local ok,unexpected=xpcall(function()
            close_progress()
            result=type(result)=="table" and result or {ok=false,error="未知错误"}
            result.finished_at=os.time()
            result.operation=tostring(options.operation or options.done_text or "缓存清理")
            self.store:reload()
            local commit_ok=true
            if result.ok==true and options.commit then
                local committed,err=xpcall(options.commit,debug.traceback)
                if not committed then
                    commit_ok=false
                    result.commit_error=tostring(err)
                    logger.err("[MiuRead][CacheCleanup] commit failed",tostring(err))
                    self.store:prune_missing_files()
                end
            elseif result.ok~=true then
                self.store:prune_missing_files()
            end
            U.mkdir(self.store.cache_books_dir); U.mkdir(self.store.covers_dir); U.mkdir(self.store.temp_dir)
            self.store:save_cleanup_result(result)
            self:_refresh_local_files()

            local freed=tonumber(result.freed_bytes or 0) or 0
            local removed=tonumber(result.removed or 0) or 0
            local message
            if result.ok==true and commit_ok then
                if freed>0 or removed>0 then
                    message=(options.done_text or _("Cache cleared"))
                        .."\n释放空间："..human_size(freed)
                        .."\n清理项目："..tostring(removed)
                else
                    message="没有可清理内容"
                end
            elseif result.ok==true then
                message="文件已清理，但记录刷新失败。重启 KOReader 后会自动重新检查。"
            else
                local err=result.error or table.concat(result.errors or {},"\n") or "未知错误"
                message="清理未完全完成"
                if freed>0 then message=message.."\n已释放："..human_size(freed) end
                message=message.."\n"..U.first_line(err,260)
            end
            self:toast(message,4)
            if options.refresh~=false then UIManager:scheduleIn(.30,function() self:show_downloads() end) end
        end,debug.traceback)
        if not ok then
            close_progress()
            logger.err("[MiuRead][CacheCleanup] result handling failed",tostring(unexpected))
            pcall(function() self:info("清理任务已经结束，但结果显示失败。请重启 KOReader 后检查存储占用。") end)
        end
    end
    if #unique==0 then finish({ok=true,removed=0,missing=0,freed_bytes=0,errors={}}); return end
    local ok,err=self.cache_cleanup_task:start(unique,finish,options.policy)
    if not ok then
        close_progress()
        self:info("无法开始清理：\n"..tostring(err))
        UIManager:scheduleIn(.15,function() self:show_downloads() end)
    end
end

function Plugin:_confirm_delete_variant(book_id,kind,title)
    if self:_cache_action_blocked() then return end
    local record=self.store:variant(book_id,kind)
    if not (record and record.file and U.file_exists(record.file)) then self.store:forget_variant(book_id,kind); self:toast("该版本已经不存在"); self:show_downloads(); return end
    local label=self:_variant_label(kind)
    UIManager:show(ConfirmBox:new{
        text="删除《"..tostring(title or book_id).."》的"..label.."？\n\n只删除这个 EPUB，其他版本和下载断点会保留。",
        ok_callback=function()
            local paths=self.store:variant_paths(book_id,kind)
            self:_run_cache_cleanup(paths,{
                progress_text="正在删除"..label.."……",
                done_text=label.."已删除",
                commit=function() self.store:forget_variant(book_id,kind) end,
                policy={mode="variant_delete"},operation="删除单个 EPUB",
            })
        end,
    })
end
function Plugin:_confirm_delete_chapter_cache(book_id,uid,title)
    if self:_cache_action_blocked() then return end
    local paths=self.store:chapter_paths(book_id,uid)
    if #paths==0 then self.store:forget_chapter_all(book_id,uid); self:toast("本章缓存已经不存在"); return end
    UIManager:show(ConfirmBox:new{
        text="删除“"..tostring(title or uid).."”的全部单章文件？",
        ok_callback=function()
            self:_run_cache_cleanup(self.store:chapter_paths(book_id,uid),{
                progress_text="正在删除本章文件……",
                done_text="本章文件已删除",
                commit=function() self.store:forget_chapter_all(book_id,uid) end,
                policy={mode="chapter_delete"},operation="删除单章 EPUB",
            })
        end,
    })
end
function Plugin:_confirm_clear_partial_cache(book_id,title)
    if self:_cache_action_blocked() then return end
    local paths=self.store:partial_cache_paths(book_id)
    if #paths==0 then self:toast("没有未完成下载缓存"); return end
    UIManager:show(ConfirmBox:new{
        text="清理《"..tostring(title or book_id).."》的未完成下载缓存？\n\n已生成的 EPUB 不会删除；下次下载将重新获取尚未完成的内容。",
        ok_callback=function()
            self:_run_cache_cleanup(self.store:partial_cache_paths(book_id),{
                progress_text="正在清理未完成下载缓存……",
                done_text="下载断点已清理",
                commit=function() self.store:prune_missing_files() end,
                policy={mode="download_residue"},operation="清理单本下载断点",
            })
        end,
    })
end
function Plugin:_confirm_delete_book_downloads(book_id,title)
    if self:_cache_action_blocked() then return end
    local paths=self.store:book_paths(book_id,true)
    if #paths==0 then self.store:forget_book(book_id); self:show_downloads(); return end
    UIManager:show(ConfirmBox:new{
        text="删除《"..tostring(title or book_id).."》的全部下载内容？\n\n将删除纯净版、划线与想法版、单章文件和下载断点，不会退出账户。",
        ok_callback=function()
            self:_run_cache_cleanup(self.store:book_paths(book_id,true),{
                progress_text="正在删除本书全部下载内容……",
                done_text="本书下载内容已删除",
                commit=function() self.store:forget_book(book_id) end,
                policy={mode="book_delete",allowed_book_cache={self.store:book_cache_path(book_id)}},operation="删除本书下载内容",
            })
        end,
    })
end
function Plugin:_download_book_labels(b)
    local labels={}
    for _,kind in ipairs({"clean","notes"}) do
        local r=b.variants and b.variants[kind]
        if r and r.file and U.file_exists(r.file) then labels[#labels+1]=self:_variant_label(kind) end
    end
    local chapter_count=0
    for _,row in pairs(b.chapters or {}) do for _,r in pairs(row or {}) do if r.file and U.file_exists(r.file) then chapter_count=chapter_count+1 end end end
    if chapter_count>0 then labels[#labels+1]="单章 "..tostring(chapter_count) end
    if self.store:book_has_partial_cache(b.book_id) then labels[#labels+1]="未完成缓存" end
    return labels,chapter_count
end
function Plugin:show_storage_usage()
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存任务正在运行，请稍候。") return end
    local categories=self:_storage_categories()
    local dialog=InfoMessage:new{text="正在统计存储占用……"}
    UIManager:show(dialog)
    local function done(result)
        local ok,unexpected=xpcall(function()
            pcall(function() UIManager:close(dialog) end)
            if not (result and result.ok==true and type(result.sizes)=="table") then
                self:info("存储统计失败：\n"..U.first_line(result and result.error or "未知错误",220))
                return
            end
            local size=result.sizes
            self:info("存储占用\n\n已下载书籍："..human_size(size.books)
                .."\n下载断点："..human_size(size.partial)
                .."\n想法与章节数据（受保护）："..human_size(size.protected)
                .."\n封面缓存："..human_size(size.covers)
                .."\n临时与待安装文件："..human_size(size.temp))
        end,debug.traceback)
        if not ok then
            pcall(function() UIManager:close(dialog) end)
            logger.err("[MiuRead][Storage] result handling failed",tostring(unexpected))
            pcall(function() self:info("存储统计结果显示失败。") end)
        end
    end
    local started,err=self.cache_cleanup_task:start_scan(categories,done)
    if not started then pcall(function() UIManager:close(dialog) end); self:info("无法开始统计：\n"..tostring(err)) end
end
function Plugin:_clear_download_residue()
    if self:_cache_action_blocked() then return end
    local paths=self:_download_residue_paths()
    UIManager:show(ConfirmBox:new{text="清理全部下载断点和失败任务留下的临时文件？\n\n不会删除已生成 EPUB、想法与章节数据、待安装文件和封面。",ok_callback=function()
        self:_run_cache_cleanup(paths,{progress_text="正在清理下载断点与临时文件……",done_text="下载断点与临时文件已清理",operation="清理下载断点与临时文件",policy={mode="download_residue"},commit=function()
            U.mkdir(self.store.temp_dir); self.store:prune_missing_files()
            local state=self.store:download_state()
            if state.status=="failed" or state.status=="interrupted" then self.store:clear_download_state() end
        end})
    end})
end
function Plugin:_clear_cover_cache()
    if self:_cache_action_blocked() then return end
    UIManager:show(ConfirmBox:new{text="清理全部封面缓存？\n\n不会删除书籍、想法、章节数据或阅读记录；下次进入书架时会按需重新下载封面。",ok_callback=function()
        self:_run_cache_cleanup({self.store.covers_dir},{progress_text="正在清理封面缓存……",done_text="封面缓存已清理",operation="清理封面缓存",policy={mode="cover_cache"},commit=function()
            U.mkdir(self.store.covers_dir); self.store:set("cover_index",{})
        end})
    end})
end
function Plugin:show_download_cleanup_dialog()
    if self:_cache_action_blocked() then return end
    local dialog
    dialog=ButtonDialog:new{title="清理下载与缓存",title_align="center",buttons={
        {{text="清理下载断点与临时文件",callback=function() UIManager:close(dialog); self:_clear_download_residue() end}},
        {{text="清理封面缓存",callback=function() UIManager:close(dialog); self:_clear_cover_cache() end}},
        {{text="清理无效书籍记录",callback=function()
            UIManager:close(dialog)
            local changed=self.store:prune_missing_files()
            self:toast(changed and "无效书籍记录已清理" or "没有无效书籍记录",3)
        end}},
        {{text="取消",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end

function Plugin:show_downloads()
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存正在清理，请稍候。") return end
    if self.epub_style_repair_task and self.epub_style_repair_task:busy() then self:info("已下载书籍正在修复，请稍候。") return end
    self.store:reload(); self.store:prune_missing_files()
    if self._download_book_menu then pcall(function() UIManager:close(self._download_book_menu) end); self._download_book_menu=nil end
    if self._downloads_menu then pcall(function() UIManager:close(self._downloads_menu) end); self._downloads_menu=nil end
    local items={}
    if self:_has_download_status() then items[#items+1]={text=self:_download_status_label(),callback=function() self:show_download_status() end} end
    local queue=self.store:download_queue()
    items[#items+1]={text="等待下载",post_text=tostring(#queue).." 项",callback=function() self:show_waiting_downloads() end}
    items[#items+1]={text="存储占用",callback=function() self:show_storage_usage() end}
    items[#items+1]={text="清理下载与缓存",callback=function() self:show_download_cleanup_dialog() end}
    local repair_paths=self:_notes_epub_paths()
    if #repair_paths>0 then
        items[#items+1]={text="修复已下载书籍",post_text=tostring(#repair_paths).." 个 EPUB · 含尾注链接",callback=function() self:_confirm_repair_all_styles() end}
    end
    items[#items+1]={text="已完成",enabled=false}
    for _,b in ipairs(self.store:all_books()) do
        local labels=self:_download_book_labels(b)
        if #labels>0 then
            local book_id=tostring(b.book_id)
            items[#items+1]={text=b.title or book_id,post_text=table.concat(labels," · "),callback=function() self:downloaded_book_menu(book_id) end}
        end
    end
    local menu=Menu:new{title="下载管理",item_table=items,is_borderless=true,title_bar_fm_style=true}
    self._downloads_menu=menu
    UIManager:show(menu)
end
function Plugin:downloaded_chapters_menu(book_id)
    self.store:reload()
    local b=self.store:book(book_id)
    if not b then self:toast("下载记录已不存在"); self:show_downloads(); return end
    local items={}
    for uid,row in pairs(b.chapters or {}) do
        for kind,r in pairs(row or {}) do
            if r.file and U.file_exists(r.file) then
                local file=r.file
                items[#items+1]={text=tostring(r.title or uid),post_text=self:_variant_label(kind),callback=function() self:open_file(file) end}
            end
        end
    end
    table.sort(items,function(a,c) return tostring(a.text)..tostring(a.post_text)<tostring(c.text)..tostring(c.post_text) end)
    self:list("单章文件 · "..tostring(b.title or book_id),items,"没有单章文件")
end
function Plugin:downloaded_book_menu(book_ref)
    local book_id=type(book_ref)=="table" and tostring(book_ref.book_id or book_ref.bookId) or tostring(book_ref)
    self.store:reload(); self.store:prune_missing_files()
    local b=self.store:book(book_id)
    if not b then self:toast("下载记录已不存在"); self:show_downloads(); return end
    local items={}
    local variants={}
    for _,kind in ipairs({"clean","notes"}) do
        local r=b.variants and b.variants[kind]
        if r and r.file and U.file_exists(r.file) then variants[#variants+1]={kind=kind,file=r.file,label=self:_variant_label(kind)} end
    end
    if #variants>0 then
        items[#items+1]={text="可阅读版本",enabled=false}
        for _,variant in ipairs(variants) do
            local kind_key=variant.kind; local file=variant.file; local label=variant.label
            items[#items+1]={text="阅读"..label,post_text="EPUB",callback=function() self:open_file(file) end}
            items[#items+1]={text="删除"..label,post_text="仅删除该版本",callback=function() self:_confirm_delete_variant(book_id,kind_key,b.title) end}
        end
    end
    local notes_paths=self:_notes_epub_paths(book_id)
    if #notes_paths>0 then
        items[#items+1]={text="书籍修复",enabled=false}
        items[#items+1]={text="修复本书",post_text=tostring(#notes_paths).." 个 EPUB · 含尾注链接",callback=function() self:_confirm_repair_book_style(book_id,b.title) end}
        items[#items+1]={text="重新下载本书",post_text="修复失败时使用",callback=function()
            self:choose_download({bookId=book_id,title=b.title,author=b.author,cover=b.cover},nil,false)
        end}
    end
    local _,chapter_count=self:_download_book_labels(U.merge(b,{book_id=book_id}))
    local has_partial=self.store:book_has_partial_cache(book_id)
    if chapter_count>0 or has_partial then
        items[#items+1]={text="缓存与断点",enabled=false}
        if chapter_count>0 then
            items[#items+1]={text="查看单章文件",post_text=tostring(chapter_count).." 个",callback=function() self:downloaded_chapters_menu(book_id) end}
        end
        if has_partial then
            items[#items+1]={text="清理未完成下载缓存",post_text="保留已生成 EPUB",callback=function() self:_confirm_clear_partial_cache(book_id,b.title) end}
        end
    end
    if #variants>0 or chapter_count>0 or has_partial then
        items[#items+1]={text="本书管理",enabled=false}
        items[#items+1]={text="删除本书全部下载内容",post_text="不可恢复",callback=function() self:_confirm_delete_book_downloads(book_id,b.title) end}
    end
    if #items==0 then self:toast("本书没有可管理的下载内容"); self:show_downloads(); return end
    if self._download_book_menu then pcall(function() UIManager:close(self._download_book_menu) end) end
    local menu=Menu:new{title=b.title or book_id,item_table=items,is_borderless=true,title_bar_fm_style=true}
    self._download_book_menu=menu
    UIManager:show(menu)
end
function Plugin:progress_sync_label()
    local prefs=self.store:preferences().sync or {}
    if prefs.progress_enabled==false then return "已关闭" end
    local r=self.sync:record()
    local session=r and self.store:session(r.book.book_id) or {}
    local state=session and session.progress_sync_state or nil
    local labels={checking="正在检查",retrying="正在重试",mapping_pending="等待章节换算",aligned="已同步",local_selected="使用本机位置",local_uploaded="已上传并确认",uploading="正在上传",verifying_upload="正在确认",upload_failed="上传失败",upload_unconfirmed="云端未确认",source_conflict="云端来源冲突",remote_selected="已采用云端位置",different="等待选择",deferred="本次暂不处理",remote_unavailable="等待重新检查",remote_jump_unconfirmed="跳转待确认"}
    return labels[state] or "已开启"
end
function Plugin:reader_sync_menu()
    return {
        {text="同步状态",callback=function() self:show_sync_status(false) end},
        {text="上传当前进度",callback=function() self:upload_local_progress(true) end},
        {text="读取云端进度",callback=function() self:manual_sync() end},
    }
end
function Plugin:time_sync_menu()
    return {
        {text="启用阅读时间同步",checked_func=function() return self.store:preferences().sync.time_enabled end,keep_menu_open=true,callback=function() self:toggle_time_sync() end},
        {text="上传结果提醒",checked_func=function() return self.store:preferences().sync.time_notice_enabled~=false end,keep_menu_open=true,callback=function() self:toggle_time_notice() end},
        {text="测试上传 30 秒",callback=function() self:test_read_report() end},
    }
end
function Plugin:progress_sync_settings_menu()
    return {
        {text="启用阅读进度同步",checked_func=function() return self.store:preferences().sync.progress_enabled~=false end,keep_menu_open=true,callback=function() self:toggle_progress_sync() end},
        {text="打开书籍时读取云端",checked_func=function() return self.store:preferences().sync.pull_on_open~=false end,keep_menu_open=true,callback=function()
            local p=self.store:preferences(); p.sync=p.sync or {}; p.sync.pull_on_open=not (p.sync.pull_on_open~=false); self.store:save_preferences(p)
        end},
        {text="同步成功提示 · "..self:progress_notice_label(),sub_item_table_func=function() return self:progress_notice_menu() end},
        {text="位置差异阈值 · "..tostring((self.store:preferences().sync or {}).threshold or 2).."%",enabled=false},
    }
end
function Plugin:sync_diagnostics_menu()
    return {
        {text="检查当前书籍识别",callback=function()
            local r=self.sync:record(); self:info(r and ("已识别：《"..tostring(r.book.title or "未命名").."》") or "当前书籍未被识别为觅阅文件")
        end},
        {text="检查登录状态",callback=function() local a=self.store:auth(); self:info(self:logged_in() and ("已登录\n"..tostring((a.account or {}).name or "")) or "尚未登录") end},
        {text="检查云端读取",callback=function() self:manual_sync() end},
        {text="检查进度上传",callback=function() self:upload_local_progress(true) end},
        {text="查看详细错误",callback=function() self:show_sync_status(true) end},
        {text="清除当前同步状态",callback=function()
            local r=self.sync:record()
            if r then self.store:clear_session(r.book.book_id); self.sync:clear_verified("manual_clear"); self:toast("同步状态已清除")
            else self:info("请先打开一本觅阅下载的书籍。") end
        end},
    }
end
function Plugin:sync_menu()
    return {
        {text="同步状态",callback=function() self:show_sync_status(false) end},
        {text="上传当前进度",callback=function() self:upload_local_progress(true) end},
        {text="读取云端进度",callback=function() self:manual_sync() end},
        {text="阅读时间同步",sub_item_table_func=function() return self:time_sync_menu() end},
        {text="阅读进度同步",sub_item_table_func=function() return self:progress_sync_settings_menu() end},
        {text="同步诊断",sub_item_table_func=function() return self:sync_diagnostics_menu() end},
    }
end
function Plugin:toggle_time_sync()
    local p=self.store:preferences(); p.sync.time_enabled=not p.sync.time_enabled; self.store:save_preferences(p)
    if p.sync.time_enabled then
        local record=self.sync:record()
        if record and p.sync.progress_enabled~=false and not self.sync:is_current_verified() then
            self:ensure_read_report_progress("time_sync_enabled",false)
        else
            self.sync:start("enabled")
        end
        if self:_legacy_weread_plugin_present() then
            self:info("阅读时间同步已开启。\n\n检测到旧版 weread.koplugin 仍然存在。两套插件会同时监听阅读状态，建议在 KOReader 插件管理中停用旧版 WeRead，只保留觅阅。")
        else
            self:status_toast("阅读时间同步","已开启",3)
        end
    else
        self.sync:stop("disabled")
        self:status_toast("阅读时间同步","已关闭",3)
    end
end
function Plugin:toggle_time_notice()
    local p=self.store:preferences()
    p.sync=p.sync or {}
    p.sync.time_notice_enabled=not (p.sync.time_notice_enabled~=false)
    self.store:save_preferences(p)
    self:status_toast("阅读时间同步弹窗提醒",p.sync.time_notice_enabled and "已开启" or "已关闭",3)
end
function Plugin:progress_notice_label()
    local mode=tostring((self.store:preferences().sync or {}).progress_notice_mode or "first")
    return ({first="仅首次",always="始终",off="不提示"})[mode] or "仅首次"
end
function Plugin:progress_notice_menu()
    local items={}
    for _,row in ipairs({{"first","仅首次提示"},{"always","始终提示"},{"off","不提示"}}) do
        local key,label=row[1],row[2]
        items[#items+1]={text=label,radio=true,checked_func=function()
            return tostring((self.store:preferences().sync or {}).progress_notice_mode or "first")==key
        end,callback=function()
            local p=self.store:preferences(); p.sync=p.sync or {}; p.sync.progress_notice_mode=key
            self.store:save_preferences(p)
            self:status_toast("阅读进度成功提示",label,3)
        end}
    end
    return items
end
function Plugin:_progress_notice_mode()
    return tostring((self.store:preferences().sync or {}).progress_notice_mode or "first")
end
function Plugin:_progress_notice_allowed()
    local mode=self:_progress_notice_mode()
    if mode=="off" then return false end
    if mode=="always" then return true end
    return self._progress_success_notified~=true
end
function Plugin:_show_progress_success(text)
    if not self:_progress_notice_allowed() then return end
    self._progress_success_notified=true
    self:status_toast("阅读进度同步",text or "已同步",3)
end

function Plugin:toggle_progress_sync()
    local p=self.store:preferences(); p.sync.progress_enabled=not (p.sync.progress_enabled~=false); p.sync.pull_on_open=p.sync.progress_enabled; self.store:save_preferences(p)
    local r=self.sync:record()
    if p.sync.progress_enabled then
        self.sync:clear_verified("progress_sync_enabled")
        self:toast("阅读进度同步已开启",3)
        if r then UIManager:scheduleIn(.1,function() self:ensure_read_report_progress("enabled",false) end) end
    else
        if r then self.store:save_session(r.book.book_id,{progress_sync_state="disabled",progress_sync_message="阅读进度同步已关闭"}) end
        self.sync.progress_hold=false
        self.sync:start("progress_disabled")
        self:toast("阅读进度同步已关闭",3)
    end
end
function Plugin:test_read_report()
    local r=self.sync:record(); if not r then self:info("请先打开一本觅阅下载的书籍再测试。"); return end
    self:status_toast("阅读时间测试","正在上传 30 秒……",3)
    local started=self.sync:test_upload(function(ok,result,position,detail)
        if ok then
            local progress=tostring(position and position.progress or "—")
            self:status_toast(
                "阅读时间测试成功",
                "已接收 30 秒 · 当前位置 "..progress.."%",
                4
            )
        else
            self:info("测试失败\n\n"..tostring(result or "未知错误").."\n\n可在‘同步状态’中查看当前阶段。")
        end
    end)
    if not started then self:info("无法启动测试：同步任务可能正在运行。") end
end
function Plugin:_save_progress_state(id,state,message,localp,remotep)
    self.store:save_session(id,{
        progress_sync_state=state,
        progress_sync_message=message,
        progress_local_percent=localp,
        progress_remote_percent=remotep,
        progress_decided_at=os.time(),
    })
end
function Plugin:ensure_read_report_progress(reason,automatic)
    local prefs=self.store:preferences().sync or {}
    if prefs.progress_enabled==false then
        if not automatic then self:info("阅读进度同步已关闭。") end
        self.sync:start("progress_disabled")
        return false
    end
    local r=self.sync:record()
    if not r then
        if not automatic then self:info(_("No matching MiuRead book is open.")) end
        return false
    end
    local id=tostring(r.book.book_id)
    if self._progress_check_running then
        if not automatic then self:toast("正在读取云端位置……",2) end
        return false
    end
    self._progress_check_running=true
    local local_position=self.sync:local_position()
    if not local_position or local_position.safe~=true or local_position.progress==nil then
        local chapter_percent=local_position and local_position.chapter_percent
            or math.floor((self.sync:local_ratio() or 0)*100+.5)
        self:_save_progress_state(id,"mapping_pending","正在取得完整目录以换算单章进度",chapter_percent,nil)
        self._progress_check_running=false
        self.sync:end_progress_sync("单章位置等待完整目录")
        if not automatic then
            self:info("当前打开的是单章文件。\n\n正在等待完整目录用于换算整书进度；在换算完成前，不会把本章百分比直接上传成整书百分比。")
        end
        return false
    end
    local localp=math.floor((tonumber(local_position.progress) or 0)+.5)
    self:_save_progress_state(id,"checking","正在读取云端位置",localp,nil)
    self.sync:begin_progress_sync(reason or "读取云端进度")
    self.sync:remote(id,function(remote,remote_err)
        self._progress_check_running=false
        self._progress_remote_retries=self._progress_remote_retries or {}
        if not remote then
            local retries=tonumber(self._progress_remote_retries[id] or 0) or 0
            if automatic and retries<1 and self.ui and self.ui.document then
                self._progress_remote_retries[id]=retries+1
                self:_save_progress_state(id,"retrying","云端位置读取失败，准备重试",localp,nil)
                self.sync:end_progress_sync("云端位置读取失败，等待重试")
                UIManager:scheduleIn(2.5,function()
                    if self.ui and self.ui.document then
                        self:ensure_read_report_progress("remote_progress_retry",true)
                    end
                end)
                return
            end
            self:_save_progress_state(id,"remote_unavailable","暂时无法读取云端位置",localp,nil)
            self.sync:end_progress_sync("云端位置暂时不可用，阅读时间等待确认")
            if not automatic then
                self:info("暂时无法读取云端位置。\n\n为了避免覆盖其他设备上的位置，本次阅读时间会等待位置确认后再上传。")
            end
            logger.warn("[MiuRead][Sync] remote position unavailable", tostring(remote_err or "unknown"))
            return
        end
        self._progress_remote_retries[id]=0
        if remote.conflict then
            local webp=remote.web and math.floor((tonumber(remote.web.percent) or 0)+.5) or nil
            local agentp=remote.agent and math.floor((tonumber(remote.agent.percent) or 0)+.5) or nil
            self:_save_progress_state(id,"source_conflict","云端两个来源的位置不一致",localp,webp or agentp)
            self.sync.state="verification_required"
            self.sync.last_stage="等待选择云端位置来源"
            self:on_remote_source_conflict(id,localp,remote,automatic==true)
            return
        end
        local remotep=math.floor((tonumber(remote.percent) or 0)+.5)
        local cmp=self.sync:compare(localp,remote)
        if cmp=="same" then
            self.sync:mark_verified(id,"positions_aligned",localp,remotep)
            self:_save_progress_state(id,"aligned","本机与云端位置接近",localp,remotep)
            self.sync:end_progress_sync("位置接近，阅读时间开始同步")
            if not automatic then self:info("本机位置："..localp.."%\n云端位置："..remotep.."%\n\n位置接近，无需处理。") end
            return
        end
        self:_save_progress_state(id,"different","检测到本机与云端位置不同",localp,remotep)
        self.sync.state="verification_required"
        self.sync.last_stage="等待选择本机或云端位置"
        self:on_remote_progress(id,localp,remote,automatic==true)
    end)
    return true
end

function Plugin:_legacy_ensure_read_report_progress(reason,automatic)
    return self:ensure_read_report_progress(reason,automatic)
end
function Plugin:manual_sync()
    return self:ensure_read_report_progress("manual_progress_sync",false)
end

function Plugin:_remote_matches(remote,target)
    local threshold=tonumber(self.store:preferences().sync.threshold) or 2
    target=tonumber(target)
    if not target or not remote then return false,nil,nil end
    local function match(candidate)
        local percent=candidate and tonumber(candidate.percent)
        return percent and math.abs(percent-target)<=threshold,percent,candidate and candidate.source
    end
    if remote.conflict then
        local ok,p,source=match(remote.web); if ok then return true,p,source end
        ok,p,source=match(remote.agent); if ok then return true,p,source end
        return false,nil,nil
    end
    return match(remote)
end

function Plugin:upload_local_progress(manual,callback)
    local r=self.sync:record()
    if not r then
        if manual then self:info("请先打开一本觅阅下载的书籍。") end
        if callback then callback(false,"未识别当前书籍") end
        return false
    end
    local position=self.sync:local_position()
    if not position or position.safe~=true or position.progress==nil then
        local err="当前文件暂时无法安全换算整书进度。"
        if manual then self:info(err) end
        if callback then callback(false,err) end
        return false
    end
    local id=tostring(r.book.book_id)
    local target=math.floor((tonumber(position.progress) or 0)+.5)
    self.sync:begin_progress_sync("主动上传本机阅读进度")
    self:_save_progress_state(id,"uploading","正在上传本机阅读进度",target,nil)
    if manual then self:status_toast("阅读进度同步","正在上传 "..target.."%……",3) end
    local started=self.sync:upload_progress(function(ok,result,submitted)
        if not ok then
            self:_save_progress_state(id,"upload_failed","阅读进度上传失败",target,nil)
            self.sync:end_progress_sync("阅读进度上传失败")
            if manual then self:info("阅读进度上传失败\n\n"..tostring(result or "未知错误")) end
            if callback then callback(false,result) end
            return
        end
        target=math.floor((tonumber(submitted and submitted.progress) or target)+.5)
        self:_save_progress_state(id,"verifying_upload","请求已接收，正在确认云端位置",target,nil)
        local function verify(attempt)
            UIManager:scheduleIn(attempt==1 and 1.5 or 2.5,function()
                if not self.ui or not self.ui.document then return end
                self.sync:remote(id,function(remote,remote_err)
                    local matched,actual,source=self:_remote_matches(remote,target)
                    if matched then
                        actual=math.floor((tonumber(actual) or target)+.5)
                        self.sync:mark_verified(id,"local_progress_uploaded",target,actual)
                        self:_save_progress_state(id,"local_uploaded","本机进度已上传并确认",target,actual)
                        self.store:save_session(id,{progress_upload_state="verified",progress_upload_verified_at=os.time(),progress_upload_source=source})
                        self.sync:end_progress_sync("本机阅读进度已上传并确认")
                        if manual then
                            self:status_toast("阅读进度同步","已上传并确认："..target.."%",4)
                        else
                            self:_show_progress_success("已同步："..target.."%")
                        end
                        if callback then callback(true,remote) end
                    elseif attempt<2 then
                        verify(attempt+1)
                    else
                        self:_save_progress_state(id,"upload_unconfirmed","请求已发送，但云端位置尚未更新",target,remote and remote.percent)
                        self.store:save_session(id,{progress_upload_state="unconfirmed",progress_upload_error=remote_err})
                        self.sync:end_progress_sync("进度请求已发送，云端尚未确认")
                        if manual then self:info("上传请求已发送，但云端位置尚未更新。\n\n本机位置："..target.."%") end
                        if callback then callback(false,remote_err or "云端位置尚未更新") end
                    end
                end,{force=true})
            end)
        end
        verify(1)
    end)
    if not started then
        self.sync:end_progress_sync("无法启动阅读进度上传")
        if manual then self:info("无法启动阅读进度上传：同步任务正在运行。") end
        if callback then callback(false,"同步任务正在运行") end
        return false
    end
    return true
end

function Plugin:_use_remote_position(id,localp,remote)
    local remotep=math.floor((tonumber(remote and remote.percent) or 0)+.5)
    local jumped,jump_error=self.sync:jump_remote(remote)
    if not jumped then
        self:_save_progress_state(id,"remote_jump_unconfirmed","无法跳转到云端位置",localp,remotep)
        self.sync:end_progress_sync("云端位置跳转失败，阅读时间暂缓上传")
        self:info(tostring(jump_error or "无法跳转到云端位置。").."\n\n当前位置未确认，因此暂不上传阅读时间。")
        return false
    end
    UIManager:scheduleIn(1.2,function()
        local actual_position=self.sync:local_position()
        local actual=actual_position and actual_position.progress and math.floor(actual_position.progress+.5) or localp
        local threshold=tonumber(self.store:preferences().sync.threshold) or 2
        if math.abs(actual-remotep)<=threshold then
            self.sync:mark_verified(id,"remote_position_selected",actual,remotep)
            self:_save_progress_state(id,"remote_selected","已采用云端位置",actual,remotep)
            self.sync:end_progress_sync("已采用云端位置，阅读时间开始同步")
            self:status_toast("阅读进度同步","已切换到云端进度："..remotep.."%",4)
        else
            self:_save_progress_state(id,"remote_jump_unconfirmed","已请求跳转，位置仍待确认",actual,remotep)
            self.sync:end_progress_sync("云端位置仍待确认，阅读时间暂缓上传")
            self:info("已请求跳到云端位置，但当前显示位置为 "..actual.."%。\n\n为避免覆盖云端位置，暂不上传阅读时间。")
        end
    end)
    return true
end

function Plugin:on_remote_source_conflict(id,localp,remote,automatic)
    if automatic and self._progress_prompted_book_id==tostring(id) then
        self.sync:end_progress_sync("云端来源冲突等待用户处理")
        return
    end
    self._progress_prompted_book_id=tostring(id)
    local webp=remote.web and math.floor((tonumber(remote.web.percent) or 0)+.5) or nil
    local agentp=remote.agent and math.floor((tonumber(remote.agent.percent) or 0)+.5) or nil
    local title="云端阅读位置来源不一致\n\n本机："..localp.."%"
        .."\n微信读书网页："..tostring(webp or "未获取").."%"
        .."\n官方接口："..tostring(agentp or "未获取").."%"
    local dialog,closing_for_action
    local function defer()
        self:_save_progress_state(id,"deferred","云端来源不一致，本次暂不处理",localp,webp or agentp)
        self.sync:end_progress_sync("云端来源冲突尚未确认")
    end
    local buttons={}
    if remote.web then buttons[#buttons+1]={{text="使用网页云端 "..webp.."%",callback=function()
        closing_for_action=true; UIManager:close(dialog); self:_use_remote_position(id,localp,remote.web)
    end}} end
    if remote.agent then buttons[#buttons+1]={{text="使用官方云端 "..agentp.."%",callback=function()
        closing_for_action=true; UIManager:close(dialog); self:_use_remote_position(id,localp,remote.agent)
    end}} end
    buttons[#buttons+1]={{text="使用本机并上传 "..localp.."%",callback=function()
        closing_for_action=true; UIManager:close(dialog); self:upload_local_progress(true)
    end}}
    buttons[#buttons+1]={{text="本次暂不处理",callback=function()
        closing_for_action=true; UIManager:close(dialog); defer()
    end}}
    dialog=ButtonDialog:new{title=title,title_align="center",close_callback=function()
        if not closing_for_action then defer() end
    end,buttons=buttons}
    UIManager:show(dialog)
end

function Plugin:on_remote_progress(id,localp,remote,automatic)
    local remotep=math.floor((tonumber(remote.percent) or 0)+.5)
    if automatic and self._progress_prompted_book_id==tostring(id) then
        self.sync:end_progress_sync("已提示位置差异，等待用户选择")
        return
    end
    self._progress_prompted_book_id=tostring(id)
    local source=remote.source=="web_cookie" and "网页云端" or (remote.source=="agent_gateway" and "官方云端" or "云端")
    local text="检测到阅读位置不同\n\n本机位置："..localp.."%\n"..source.."位置："..remotep.."%"
    local dialog,closing_for_action
    local function defer()
        self:_save_progress_state(id,"deferred","本次暂不处理位置差异",localp,remotep)
        self.sync:end_progress_sync("位置差异尚未确认，阅读时间暂缓上传")
    end
    dialog=ButtonDialog:new{title=text,title_align="center",close_callback=function()
        if not closing_for_action then defer() end
    end,buttons={
        {{text="使用云端位置",callback=function()
            closing_for_action=true; UIManager:close(dialog); self:_use_remote_position(id,localp,remote)
        end}},
        {{text="使用本机位置并上传",callback=function()
            closing_for_action=true; UIManager:close(dialog); self:upload_local_progress(true)
        end}},
        {{text="本次暂不同步位置",callback=function()
            closing_for_action=true; UIManager:close(dialog); defer()
        end}},
    }}
    UIManager:show(dialog)
end

function Plugin:_relative_time(ts)
    ts=tonumber(ts or 0) or 0
    if ts<=0 then return "尚未同步" end
    local delta=math.max(0,os.time()-ts)
    if delta<10 then return "刚刚" end
    if delta<60 then return tostring(delta).."秒前" end
    if delta<3600 then return tostring(math.floor(delta/60)).."分钟前" end
    if delta<86400 then return tostring(math.floor(delta/3600)).."小时前" end
    return U.now_text(ts)
end
function Plugin:show_sync_status(detail)
    local s=self.sync:status()
    local prefs=self.store:preferences().sync or {}
    local remote=s.remote and math.floor((s.remote.percent or 0)+.5) or nil
    local session=s.record and self.store:session(s.record.book.book_id) or {}
    local local_text=s.local_percent~=nil and (tostring(s.local_percent).."%")
        or (s.local_chapter_percent~=nil and ("本章 "..tostring(s.local_chapter_percent).."% · 等待整书换算") or "—")
    if detail then
        local next_text=(tonumber(s.next_due or 0)>os.time()) and (tostring(math.max(0,s.next_due-os.time())).." 秒后") or "—"
        local t="阅读同步诊断\n\n"
            .."阅读时间开关："..(s.time_enabled and "已开启" or "已关闭").."\n"
            .."同步弹窗提醒："..(prefs.time_notice_enabled~=false and "已开启" or "已关闭").."\n"
            .."阅读进度开关："..(prefs.progress_enabled~=false and "已开启" or "已关闭").."\n"
            .."进度成功提示："..self:progress_notice_label().."\n"
            .."当前状态："..tostring(s.state_label or s.state).."\n"
            .."当前书籍："..tostring(s.record and s.record.book and s.record.book.title or "未识别").."\n"
            .."本机位置："..local_text.."\n"
            .."云端位置："..tostring(remote and (remote.."%") or "未获取").."\n"
            .."云端原始百分比："..tostring(s.remote and s.remote.raw_percent and (math.floor(tonumber(s.remote.raw_percent)+.5).."%") or "—").."\n"
            .."位置判定依据："..tostring(s.remote and s.remote.position_basis or "原始百分比").."\n"
            .."进度状态："..tostring(session.progress_sync_state or "—").."\n"
            .."本次成功上传："..tostring(s.session_uploads).." 次\n"
            .."上次尝试："..U.now_text(s.last_attempt).."\n"
            .."上次成功："..U.now_text(s.last_upload).."\n"
            .."下次计划："..next_text.."\n"
            .."当前阶段："..tostring(s.last_stage or "—").."\n"
            .."连续失败："..tostring(s.consecutive_failures or 0)
            .."\n\n最近成功路径："..tostring(s.last_path or "—")
            .."\n最近响应："..tostring(s.last_response_summary or "—")
            .."\nHTTP 状态："..tostring(s.last_http_code or "—")
            .."\n响应长度："..tostring(s.last_http_length or "—")
            .."\n服务 PID："..tostring(s.service_pid or "—")
            .."\n服务版本："..tostring(s.service_version or "—")
            .."\n关闭前补传："..(s.final_flush_pending and "等待完成" or "无")
            .."\n旧版 WeRead 插件："..(self:_legacy_weread_plugin_present() and "已检测到，建议停用" or "未检测到")
            .."\n最近错误："..tostring(type(s.last_error)=="string" and s.last_error or "—")
        self:info(t)
        return
    end
    local time_text
    if not s.time_enabled then time_text="已关闭"
    elseif not s.record or s.state=="stopped" then time_text="未运行"
    elseif s.state=="verification_required" or s.state=="fetching_remote" or s.state=="progress_sync" then time_text="等待位置确认"
    elseif type(s.last_error)=="string" and (tonumber(s.consecutive_failures) or 0)>=2 then time_text="暂时同步失败"
    elseif s.state=="uploading" then time_text="正在同步"
    else time_text="运行中" end
    local progress_text=self:progress_sync_label()
    local lines={"阅读同步","","阅读时间："..time_text,"阅读进度："..progress_text,"当前位置："..local_text}
    if remote then lines[#lines+1]="云端位置："..remote.."%" end
    lines[#lines+1]="上次同步："..self:_relative_time(s.last_upload)
    if time_text=="暂时同步失败" then lines[#lines+1]="将在稍后自动重试" end
    self:info(table.concat(lines,"\n"))
end
function Plugin:_time_notice_enabled()
    return self.store:preferences().sync.time_notice_enabled~=false
end
function Plugin:on_read_report_ready()
    if self:_time_notice_enabled() then
        self:status_toast("阅读时间同步","后台运行已开始",3)
    end
end
function Plugin:_verify_automatic_progress_once()
    if self._progress_auto_verify_started then return end
    self._progress_auto_verify_started=true
    local r=self.sync:record()
    local position=self.sync:local_position()
    if not r or not position or position.safe~=true or position.progress==nil then return end
    local id=tostring(r.book.book_id)
    local target=math.floor((tonumber(position.progress) or 0)+.5)
    self.sync:remote(id,function(remote)
        local matched,actual,source=self:_remote_matches(remote,target)
        if matched then
            actual=math.floor((tonumber(actual) or target)+.5)
            self.sync:mark_verified(id,"automatic_progress_confirmed",target,actual)
            self:_save_progress_state(id,"aligned","阅读进度已上传并确认",target,actual)
            self.store:save_session(id,{progress_upload_state="verified",progress_upload_verified_at=os.time(),progress_upload_source=source})
            self:_show_progress_success("已同步："..target.."%")
        else
            self.store:save_session(id,{progress_upload_state="unconfirmed",progress_upload_checked_at=os.time()})
            logger.warn("[MiuRead][Progress] automatic upload not confirmed","book=",id,"target=",tostring(target))
        end
    end,{force=true})
end
function Plugin:on_read_report_success(path)
    if self:_time_notice_enabled() then
        self:status_toast("阅读时间同步","首次上传成功",3)
    end
    local r=self.sync:record()
    local session=r and self.store:session(r.book.book_id) or {}
    if r and session.progress_sync_state=="mapping_pending"
        and self.store:preferences().sync.progress_enabled~=false then
        UIManager:scheduleIn(.5,function()
            if self.ui and self.ui.document then self:ensure_read_report_progress("catalog_ready",true) end
        end)
    elseif r and self.store:preferences().sync.progress_enabled~=false then
        UIManager:scheduleIn(1.5,function()
            if self.ui and self.ui.document then self:_verify_automatic_progress_once() end
        end)
    end
end
function Plugin:on_read_report_interval_success(status)
    if self:_progress_notice_mode()~="always" or self._progress_success_notified~=true then return end
    local percent=status and status.position and tonumber(status.position.progress)
    if not percent then return end
    percent=math.floor(percent+.5)
    if tonumber(self._last_progress_submit_notice)==percent then return end
    self._last_progress_submit_notice=percent
    self:status_toast("阅读进度同步","已提交："..percent.."%",3)
end

function Plugin:on_read_report_failure(err)
    if self:_time_notice_enabled() then
        self:status_toast("阅读时间同步","连续上传失败，请查看同步状态",5)
    end
end
function Plugin:jump_dialog() local d; d=InputDialog:new{title=_("Enter percentage"),input="",buttons={{{text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},{text=_("Confirm"),is_enter_default=true,callback=function() local p=tonumber(d:getInputText()); UIManager:close(d); if p then self.sync:jump(p) end end}}}}; UIManager:show(d); d:onShowKeyboard() end
function Plugin:_annotation_mode() return "epub_inline_dashed" end
function Plugin:annotation_mode_label() return "EPUB 内置虚线" end
function Plugin:_set_annotation_visibility(_show_lines,_show_stars) return true end
function Plugin:annotation_mode_menu()
    return {{text="EPUB 内置虚线",radio=true,checked_func=function() return true end,
        callback=function() self:info("新下载的划线与想法版会把评论正文写成普通 inline span + 2px 虚线底边。旧书可在‘下载管理’中直接修复，无需重新下载正文。") end}}
end
function Plugin:toggle_annotations()
    self:toast("评论正文使用 EPUB 内置虚线",3)
end
function Plugin:_current_book_record()
    self.store:reload()
    local r=self.sync:record()
    if r then return r end
    local doc=self.ui and self.ui.document
    local path=doc and (doc.file or (doc.getFilePath and doc:getFilePath()))
    local b,rec,variant=self.store:file_record(path)
    if b then return {book=b,record=rec,variant=variant,path=path} end
    local raw=path and U.read_file(path,true)
    local id=raw and (raw:match('"book_id"%s*:%s*"([^"]+)"') or raw:match('miuread://book/([^<"]+)'))
    local fallback=id and self.store:book(id)
    if fallback then return {book=fallback,record=fallback.variants and (fallback.variants.notes or fallback.variants.clean),variant=nil,path=path} end
end
function Plugin:show_current_book_info()
    local r=self:_current_book_record()
    if not r or not r.book then self:info("当前书籍不是觅阅生成的文件。") return end
    local position=self.sync:local_position()
    local lines={
        tostring(r.book.title or "未命名"),
        tostring(r.book.author or ""),
        "版本："..self:_variant_label(r.variant or (r.record and r.record.variant) or "clean"),
        "本机进度："..(position and position.progress and (tostring(math.floor(position.progress+.5)).."%") or "—"),
        "文件："..tostring(r.path or ""),
    }
    self:info(table.concat(lines,"\n"))
end

function Plugin:redownload_current()
    local r=self:_current_book_record()
    if not r or not r.book then self:info(_("No matching MiuRead book is open.")); return end
    local b={bookId=r.book.book_id,title=r.book.title,author=r.book.author,cover=r.book.cover}
    local current=(r.variant=="notes" or r.variant=="clean") and r.variant or (r.record and r.record.variant)
    local dialog
    local buttons={}
    if current=="notes" then buttons[#buttons+1]={{text="重新生成当前划线与想法版",callback=function() UIManager:close(dialog); self:choose_download_mode(b,{annotations=true},false) end}}
    elseif current=="clean" then buttons[#buttons+1]={{text="重新生成当前纯净版",callback=function() UIManager:close(dialog); self:choose_download_mode(b,{annotations=false},false) end}} end
    buttons[#buttons+1]={{text="重新生成纯净版",callback=function() UIManager:close(dialog); self:choose_download_mode(b,{annotations=false},false) end}}
    buttons[#buttons+1]={{text="重新生成划线与想法版",callback=function() UIManager:close(dialog); self:choose_download_mode(b,{annotations=true},false) end}}
    buttons[#buttons+1]={{text="关闭",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title="重新生成《"..tostring(b.title or "本书").."》",title_align="center",buttons=buttons}
    UIManager:show(dialog)
end
function Plugin:_toggle_preference(key)
    local p=self.store:preferences(); p[key]=not p[key]; self.store:save_preferences(p)
end
function Plugin:reading_settings_menu()
    return {
        {text="划线显示 · "..self:annotation_mode_label(),sub_item_table_func=function() return self:annotation_mode_menu() end},
        {text="想法字体大小",sub_item_table_func=function() return self:thought_font_menu() end},
    }
end
function Plugin:shelf_settings_menu()
    return {
        {text="显示封面",checked_func=function() return self.store:preferences().shelf_covers~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("shelf_covers") end},
    }
end
function Plugin:performance_settings_menu()
    return {
        {text="低资源模式",checked_func=function() return self.store:preferences().low_resource end,keep_menu_open=true,callback=function() self:_toggle_preference("low_resource") end},
    }
end
function Plugin:notification_settings_menu()
    return {
        {text="下载关键进度提示",checked_func=function() return self.store:preferences().download_notice_enabled~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("download_notice_enabled") end},
        {text="下载完成提示",checked_func=function() return self.store:preferences().download_complete_notice~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("download_complete_notice") end},
        {text="阅读时间上传提醒",checked_func=function() return self.store:preferences().sync.time_notice_enabled~=false end,keep_menu_open=true,callback=function() self:toggle_time_notice() end},
        {text="进度成功提示 · "..self:progress_notice_label(),sub_item_table_func=function() return self:progress_notice_menu() end},
    }
end
function Plugin:advanced_maintenance_menu()
    return {
        {text="修复全部已下载书籍",post_text="尾注、链接与划线",callback=function() self:_confirm_repair_all_styles() end},
        {text="下载目录",post_text=self:_download_dir_label(),callback=function() self:directory_dialog() end},
        {text="查看详细同步日志",callback=function() self:show_sync_status(true) end},
    }
end
function Plugin:settings_menu()
    return {
        {text="阅读显示",sub_item_table_func=function() return self:reading_settings_menu() end},
        {text="书架显示",sub_item_table_func=function() return self:shelf_settings_menu() end},
        {text="性能与后台",sub_item_table_func=function() return self:performance_settings_menu() end},
        {text="通知",sub_item_table_func=function() return self:notification_settings_menu() end},
        {text="高级维护",sub_item_table_func=function() return self:advanced_maintenance_menu() end},
    }
end
function Plugin:thought_font_menu()
    local choices={{"standard","较小（默认）"},{"large","适中"},{"xlarge","接近正文"}}
    local rows={}
    for _,choice in ipairs(choices) do
        local key,label=choice[1],choice[2]
        rows[#rows+1]={text=label,radio=true,checked_func=function() return (self.store:preferences().thoughts or {}).font==key end,callback=function()
            local p=self.store:preferences(); p.thoughts=p.thoughts or {}; p.thoughts.font=key; self.store:save_preferences(p); self:toast("想法字体已设为："..label)
        end}
    end
    return rows
end
function Plugin:_download_dir_path()
    local custom=U.trim((self.store:preferences() or {}).download_dir or "")
    if custom~="" then return custom end
    return self.store.default_books_dir
end
function Plugin:_download_dir_label()
    local path=self:_download_dir_path()
    if path==self.store.default_books_dir then return "默认 · "..tostring(path) end
    return tostring(path)
end
function Plugin:_validate_download_dir(path)
    path=U.trim(path)
    if path=="" or path:sub(1,1)~="/" then return nil,"路径无效" end
    local attr=lfs.attributes(path)
    if not attr or attr.mode~="directory" then return nil,"文件夹不存在" end
    local probe=path.."/.miuread-write-test-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))
    local f=io.open(probe,"wb")
    if not f then return nil,"该文件夹不可写" end
    f:write("ok"); f:close(); os.remove(probe)
    return true
end
function Plugin:directory_dialog()
    local current=self:_download_dir_path()
    if lfs.attributes(current,"mode")~="directory" then
        if lfs.attributes("/mnt/us/documents","mode")=="directory" then current="/mnt/us/documents"
        elseif lfs.attributes("/mnt/us","mode")=="directory" then current="/mnt/us"
        else current="/" end
    end
    local chooser=PathChooser:new{
        title="选择下载文件夹（长按文件夹名称确认）",
        select_directory=true,
        select_file=false,
        show_files=false,
        path=current,
        onConfirm=function(path)
            local ok,err=self:_validate_download_dir(path)
            if not ok then self:info("无法使用此文件夹：\n"..tostring(err)); return end
            local old=self:_download_dir_path()
            local p=self.store:preferences(); p.download_dir=path; self.store:save_preferences(p)
            local note="下载目录已设置为：\n"..tostring(path)
            if old~=path then note=note.."\n\n只影响以后下载的书籍；已下载内容保留在原位置。" end
            self:info(note)
        end,
    }
    UIManager:show(chooser)
end
function Plugin:update_about_menu()
    return {
        {text="检查更新",callback=self:safe("update",function() self:check_update() end)},
        {text="当前版本 · "..tostring(self.version),enabled=false},
        {text="关于",callback=self:safe("about",function() self:show_about() end)},
    }
end
function Plugin:check_update()
    self:online("update",function()
        local m,e=self.updater:check()
        if not m then self:info("检查更新失败：\n"..tostring(e)); return end
        if m.current then self:info("当前已是最新版本\n\n当前版本："..tostring(self.version)); return end
        local text="发现新版本："..tostring(m.version)
        if m.name and tostring(m.name)~="" then text=text.."\n"..tostring(m.name) end
        if m.notes and tostring(m.notes)~="" then text=text.."\n\n更新说明：\n"..tostring(m.notes) end
        text=text.."\n\n是否下载并安装？"
        UIManager:show(ConfirmBox:new{text=text,ok_text="下载并安装",ok_callback=function()
            self:online("install",function()
                local path=self.updater:download(m)
                local ok,er=self.updater:install(path,m)
                if ok then self:info("更新已安装\n\n请完全退出并重新启动 KOReader。") else self:info("更新失败：\n"..tostring(er)) end
            end)
        end})
    end)
end
function Plugin:show_about() self:info(Config.NAME.." "..self.version.."\n\n".."想法弹窗性能优化版".."\n".."单次渲染 · 章节索引缓存 · Release 全量更新".."\n".._("Unofficial client").."\n\n".._("This build has not been verified with every Kindle model or every WeRead book.")) end
function Plugin:onShowMiuRead() self:show_shelf(false) end
local function extract_thought_href(value,seen,depth)
    if depth>4 or value==nil then return nil end
    if type(value)=="string" then return value:match("(#?miuthought%-[%x%.]+)") end
    if type(value)~="table" then return nil end
    seen=seen or {}; if seen[value] then return nil end; seen[value]=true
    for _,key in ipairs({"href","url","target","link","uri","dest","destination"}) do local found=extract_thought_href(value[key],seen,depth+1); if found then return found end end
    for _,child in pairs(value) do local found=extract_thought_href(child,seen,depth+1); if found then return found end end
end
function Plugin:_teardown_thought_tap()
    if self._thought_tap_setup and self.ui and self.ui.unRegisterTouchZones then pcall(function() self.ui:unRegisterTouchZones({{id="miuread_thought_popup",overrides={"tap_link"}}}) end) end
    self._thought_tap_setup=nil
end
function Plugin:_thought_font_size(level)
    local Device=require("device")
    local doc=self.ui and self.ui.document
    local configurable=doc and doc.configurable or {}
    local candidates={
        configurable.font_size,
        configurable.fontsize,
        self.ui and self.ui.rolling and self.ui.rolling.font_size,
    }
    local base
    for _,value in ipairs(candidates) do
        value=tonumber(value)
        if value and value>=10 and value<=80 then base=value; break end
    end
    if not base and _G.G_reader_settings and _G.G_reader_settings.readSetting then
        local ok,value=pcall(_G.G_reader_settings.readSetting,_G.G_reader_settings,"cre_font_size",22)
        if ok then base=tonumber(value) end
    end
    base=math.max(14,math.min(48,base or 22))
    local factors={standard=0.86,large=1.00,xlarge=1.15}
    local factor=factors[tostring(level or "standard")] or 1
    return Device.screen:scaleBySize(math.floor(base*factor+.5))
end
local function usable_font_name(value)
    if type(value)~="string" then return nil end
    value=value:match("^%s*(.-)%s*$")
    if value=="" then return nil end
    return value
end
function Plugin:_thought_font_name()
    local name=usable_font_name(self.ui and self.ui.font and self.ui.font.font_face)
    if name then return name end

    local doc=self.ui and self.ui.document
    if doc and type(doc.getFontFace)=="function" then
        local ok,value=pcall(doc.getFontFace,doc)
        if ok then
            name=usable_font_name(value)
            if name then return name end
        end
    end

    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting)=="function" then
        local ok,value=pcall(_G.G_reader_settings.readSetting,_G.G_reader_settings,"cre_font")
        if ok then return usable_font_name(value) end
    end
    return nil
end
function Plugin:_show_thought_href(href)
    local info=Thoughts.parse_href(href); if not info then return false end
    if self._thought_popup_busy then return true end
    self._thought_popup_busy=true
    local started=os.clock()
    local ok,unexpected=xpcall(function()
        local group,err,token=Thoughts.find(self.store,info.book_id,info.chapter_uid,info.range)
        if not group then self:info(tostring(err or "没有想法内容")); return end
        local prefs=self.store:preferences().thoughts or {}
        local source_html,html,metrics,html_cache_hit=Thoughts.popup_parts_cached(
            self.store,info.book_id,info.chapter_uid,info.range,group,token
        )
        if html=="" then self:info("没有想法内容"); return end
        ThoughtPopup.show{
            source_html=source_html,
            html=html,
            font_size=self:_thought_font_size(prefs.font),
            font_name=self:_thought_font_name(),
            width_ratio=tonumber(prefs.width_ratio) or 0.91,
            height_ratio=tonumber(prefs.height_ratio) or 0.60,
            css=Thoughts.popup_css(),
            metrics=metrics,
        }
        logger.info("[MiuRead][ThoughtPopup] opened",
            "book=",tostring(info.book_id),"chapter=",tostring(info.chapter_uid),
            "comments=",tostring(metrics and metrics.comment_count or 0),
            "chapter_cache=",token and token.cache_hit and "hit" or "miss",
            "html_cache=",html_cache_hit and "hit" or "miss",
            "elapsed_ms=",tostring(math.floor((os.clock()-started)*1000+.5)))
    end,debug.traceback)
    self._thought_popup_busy=false
    if not ok then
        logger.err("[MiuRead][ThoughtPopup] open failed",tostring(unexpected))
        self:info("想法弹窗打开失败：\n"..U.first_line(unexpected,220))
    end
    return true
end
function Plugin:_on_thought_tap(ges)
    if not self.ui or not self.ui.link or not self.ui.link.getLinkFromGes then return false end
    local ok,link=pcall(self.ui.link.getLinkFromGes,self.ui.link,ges); if not ok or not link then return false end
    local href=extract_thought_href(link,{},0); if not href then return false end
    return self:_show_thought_href(href)
end
function Plugin:_setup_thought_tap()
    if self._thought_tap_setup or not self.ui or not self.ui.registerTouchZones then return end
    local ok,Device=pcall(require,"device"); if ok and Device.isTouchDevice and not Device:isTouchDevice() then return end
    self.ui:registerTouchZones({{id="miuread_thought_popup",ges="tap",screen_zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=1},overrides={"tap_link"},handler=function(ges) return self:_on_thought_tap(ges) end}})
    self._thought_tap_setup=true
end
function Plugin:onReadSettings() end
function Plugin:on_sync_record_ready(current)
    if current and current.book then
        local book_id,path=tostring(current.book.book_id),current.path
        UIManager:scheduleIn(1.0,function()
            local active=self.sync and self.sync.current
            if self.ui and self.ui.document and active and tostring(active.book.book_id)==book_id then
                self.store:mark_last_read(book_id,path)
            end
        end)
    end
    if self.store:preferences().sync.progress_enabled~=false then
        UIManager:scheduleIn(1.2,function()
            if self.ui and self.ui.document then self:ensure_read_report_progress("reader_ready",true) end
        end)
    end
end
function Plugin:on_sync_record_missing()
    logger.warn("[MiuRead][Sync] current EPUB could not be identified after retries")
end
function Plugin:onReaderReady()
    logger.info("[MiuRead][Sync] reader ready")
    self:_teardown_thought_tap(); self:_setup_thought_tap()
    self._progress_prompted_book_id=nil
    self._progress_check_running=false
    self._progress_remote_retries={}
    self._progress_success_notified=false
    self._progress_auto_verify_started=false
    self._last_progress_submit_notice=nil
    self.sync:on_reader_ready()
end
function Plugin:onPageUpdate(page)
    self.sync:on_page(page)
end
function Plugin:onSuspend() self._suspended_at=os.time(); self.sync:on_suspend() end
function Plugin:onResume()
    local slept=self._suspended_at and os.time()-self._suspended_at or 0
    self._suspended_at=nil
    local prefs=self.store:preferences().sync or {}
    local recheck=prefs.progress_enabled~=false and slept>=math.max(60,tonumber(prefs.resume_after) or 300)
    if recheck then
        self._progress_prompted_book_id=nil
        self.sync:clear_verified("resume_recheck")
    end
    self.sync:on_resume(slept)
    if recheck then
        UIManager:scheduleIn(.5,function()
            if self.ui and self.ui.document then self:ensure_read_report_progress("resume_recheck",true) end
        end)
    end
end
function Plugin:onCloseDocument()
    self:_teardown_thought_tap(); self._progress_prompted_book_id=nil; self._progress_check_running=false; self.sync:on_close()
    UIManager:scheduleIn(.2,function() self:_install_pending_downloads(true) end)
end
function Plugin:onFlushSettings() self:_flush_cover_index(); self.store:flush() end
return Plugin
