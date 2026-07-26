local ConfirmBox=require("ui/widget/confirmbox")
local Dispatcher=require("dispatcher")
local InfoMessage=require("ui/widget/infomessage")
local InputDialog=require("ui/widget/inputdialog")
local Menu=require("ui/widget/menu")
local UIManager=require("ui/uimanager")
local WidgetContainer=require("ui/widget/container/widgetcontainer")
local logger=require("logger")
local Config=require("miuthought.config")
local Text=require("miuthought.text")
local U=require("miuthought.util")
local Store=require("miuthought.store")
local Http=require("miuthought.http")
local Api=require("miuthought.api")
local Auth=require("miuthought.auth")
local Annotations=require("miuthought.annotations")
local Updater=require("miuthought.updater")
local Cookies=require("miuthought.cookies")
local Thoughts=require("miuthought.thoughts")
local ThoughtPopup=require("miuthought.thought_popup")
local Binding=require("miuthought.binding")
local _=Text.tr
local unpack_args=unpack or table.unpack
local source=debug.getinfo(1,"S").source:gsub("^@",""); local ROOT=source:match("^(.*)/main%.lua$") or "."
local Plugin=WidgetContainer:extend{name="miuthought",is_doc_only=false,version=Config.VERSION}

local function sanitize_saved_auth(store)
    local auth=store:auth()
    local cleaned,changed=Cookies.sanitize(auth.cookies or {})
    if changed then
        auth.cookies=cleaned
        store:save_auth(auth)
        logger.info("[MiuThought][Auth] startup cookie cleanup",
            "names=",table.concat(Cookies.names(cleaned),","))
    end
end

function Plugin:init()
    math.randomseed(os.time()+math.floor(collectgarbage("count")))
    self.store=Store:new()
    logger.info("[MiuThought] initialized", "version=", tostring(Config.VERSION),
        "schema=", tostring(Config.SCHEMA), "root=", tostring(ROOT))
    sanitize_saved_auth(self.store)
    self.http=Http:new(self.store)
    self.api=Api:new(self.http,self.store)
    self.annotations=Annotations:new(self.api)
    self.auth_flow=Auth:new(self.http,self.store,self)
    self.updater=Updater:new(self.http,self.store,self.version,ROOT)
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    local state=self.updater:startup()
    if state=="updated" then UIManager:scheduleIn(1,function() self:toast(_("Update installed"),3) end) end
end

function Plugin:onDispatcherRegisterActions() Dispatcher:registerAction("miuthought_show",{category="none",event="ShowMiuThought",title=Config.NAME,filemanager=true,reader=true}) end
function Plugin:addToMainMenu(items) items.miuthought={text=Config.NAME,sorting_hint="tools",sub_item_table_func=function() return self.ui.document and self:reader_menu() or self:home_menu() end} end

function Plugin:info(t) UIManager:show(InfoMessage:new{text=tostring(t or "")}) end
function Plugin:toast(t,s) UIManager:show(InfoMessage:new{text=tostring(t or ""),timeout=s or 2}) end
function Plugin:safe(label,fn) return function(...) local a={...}; local ok,e=xpcall(function() return fn(unpack_args(a)) end,debug.traceback); if not ok then logger.err("[MiuThought]",label,e); self:info(_("Operation failed")..":\n"..U.first_line(e)) end end end
function Plugin:is_online() local ok,N=pcall(require,"ui/network/manager"); if not ok or not N or not N.isOnline then return true end; local g,v=pcall(N.isOnline,N); return not g or v==true end
function Plugin:online(label,fn) if not self:is_online() then self:info(_("Network unavailable")); return end; UIManager:scheduleIn(.05,self:safe(label,fn)) end
function Plugin:list(title,items,empty) if not items or #items==0 then self:info(empty or _("No items")); return end; UIManager:show(Menu:new{title=title,item_table=items,is_borderless=true,title_bar_fm_style=true}) end
function Plugin:logged_in() local a=self.store:auth(); return a.api_key~="" and next(a.cookies or {})~=nil end
function Plugin:require_login() if not self:logged_in() then self:info(_("Not logged in")); return false end return true end

function Plugin:home_menu()
    return {
        {text="账户",sub_item_table_func=function() return self:account_menu() end},
        {text="更新与关于",sub_item_table_func=function() return self:update_about_menu() end},
    }
end

function Plugin:reader_menu()
    return {
        {text="绑定微信读书",callback=self:safe("bind",function() self:bind_book() end)},
        {text="同步划线与想法",callback=self:safe("sync_thoughts",function() self:sync_thoughts() end)},
        {text="账户",sub_item_table_func=function() return self:account_menu() end},
        {text="设置",sub_item_table_func=function() return self:settings_menu() end},
        {text="更新与关于",sub_item_table_func=function() return self:update_about_menu() end},
    }
end

-- ===== 绑定微信读书 =====
function Plugin:current_doc_path()
    local doc=self.ui and self.ui.document
    return doc and doc.file or nil
end

function Plugin:doc_title_guess()
    local props=(self.ui and self.ui.doc_props) or {}
    local title=U.trim(tostring(props.display_title or props.title or ""))
    if title~="" then return title end
    local name=tostring(self:current_doc_path() or ""):match("([^/\\]+)$") or ""
    return (name:gsub("%.[eE][pP][uU][bB]$",""))
end

function Plugin:bind_book()
    local path=self:current_doc_path()
    if not path then self:info("请先打开一本本地书") return end
    local current=Binding.get(self.store,path)
    if not current then self:bind_search(path) return end
    local ButtonDialog=require("ui/widget/buttondialog")
    local display=tostring(current.title or current.book_id or "")
    if tostring(current.author or "")~="" then display=display.." · "..tostring(current.author) end
    local dialog
    dialog=ButtonDialog:new{
        title="当前绑定:\n"..display,
        buttons={
            {{text="重新绑定",callback=function() UIManager:close(dialog); self:bind_search(path) end}},
            {{text="解除绑定",callback=function() UIManager:close(dialog); Binding.clear(self.store,path); self:toast("已解除绑定") end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        },
    }
    UIManager:show(dialog)
end

function Plugin:bind_search(path)
    if not self:require_login() then return end
    local d
    d=InputDialog:new{title="搜索微信读书",input=self:doc_title_guess(),buttons={{
        {text="取消",id="close",callback=function() UIManager:close(d) end},
        {text="搜索",is_enter_default=true,callback=function()
            local q=U.trim(d:getInputText()); UIManager:close(d)
            if q=="" then self:info("请输入书名") return end
            self:online("bind_search",function()
                local ok,data=pcall(function() return self.api:search(q) end)
                if not ok then self:info("搜索失败:\n"..U.first_line(data)) return end
                local rows=Binding.normalize_search(data)
                if #rows==0 then self:info("没有搜到「"..q.."」,换个关键词试试") return end
                local menu
                local items={}
                for _,row in ipairs(rows) do
                    local label=row.title~="" and row.title or row.book_id
                    if row.author~="" then label=label.." · "..row.author end
                    items[#items+1]={text=label,callback=function()
                        if menu then UIManager:close(menu) end
                        Binding.save(self.store,path,{book_id=row.book_id,title=row.title,author=row.author})
                        self:toast("已绑定:"..(row.title~="" and row.title or row.book_id))
                    end}
                end
                menu=Menu:new{title="选择要绑定的书",item_table=items,is_borderless=true,title_bar_fm_style=true}
                UIManager:show(menu)
            end)
        end},
    }}}
    UIManager:show(d); d:onShowKeyboard()
end

function Plugin:account_menu()
    local out={
        {text=_("QR login"),callback=self:safe("login",function() self.auth_flow:start() end)},
        {text=_("Manual credentials"),callback=self:safe("manual",function() self:manual_credentials() end)},
        {text=_("Account status"),callback=function() local a=self.store:auth(); self:info((self:logged_in() and _("Logged in") or _("Not logged in")).."\n"..tostring(a.account.name or "").."\nVID: "..tostring(a.account.vid or "")) end},
    }
    if self:logged_in() then out[#out+1]={text=_("Clear account data"),callback=function() UIManager:show(ConfirmBox:new{text="清除当前账户信息？\n\n将退出微信读书账户。",ok_callback=function() self.auth_flow:cancel(); self.store:clear_auth(); self:toast(_("Logout")) end}) end} end
    return out
end

function Plugin:manual_credentials()
    local d; d=InputDialog:new{title=_("Enter API key"),input=self.store:auth().api_key or "",buttons={{{text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},{text=_("Confirm"),is_enter_default=true,callback=function() local key=U.trim(d:getInputText()); UIManager:close(d); self:manual_cookie(key) end}}}}; UIManager:show(d); d:onShowKeyboard()
end

function Plugin:manual_cookie(key)
    local d; d=InputDialog:new{title=_("Enter Cookie header"),input="",buttons={{{text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},{text=_("Confirm"),is_enter_default=true,callback=function() local jar=Cookies.parse_header(d:getInputText()); self.store:save_auth({api_key=key,cookies=jar,account={name="Manual",vid=jar.wr_vid or "",logged_at=os.time()}}); UIManager:close(d); self:toast(_("Logged in")) end}}}}; UIManager:show(d); d:onShowKeyboard()
end

function Plugin:settings_menu()
    return {
        {text="想法弹窗字体",sub_item_table_func=function() return self:thought_font_menu() end},
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

function Plugin:show_about()
    self:info(Config.NAME.." "..self.version.."\n\n觅想 MiuThought\n只同步微信读书划线与想法到本地 EPUB 副本\n\n".._("Unofficial client").."\n\n".._("This build has not been verified with every Kindle model or every WeRead book."))
end

function Plugin:onShowMiuThought()
    local items=self.ui.document and self:reader_menu() or self:home_menu()
    self:list(Config.NAME,items)
end

-- ===== 同步划线与想法 =====
function Plugin:sync_thoughts()
    local path=self:current_doc_path()
    if not path then self:info("请先打开一本本地书") return end
    if not tostring(path):lower():match("%.epub$") then self:info("只支持 EPUB 格式的本地书") return end
    if not self:require_login() then return end
    local EpubReader=require("miuthought.epub_reader")
    local available,gate_err=EpubReader.available()
    if not available then self:info(tostring(gate_err)) return end
    local EpubInject=require("miuthought.epub_inject")
    if EpubInject.is_copy(path) then self:info("当前打开的是觅想版副本,请打开原书执行同步") return end
    local bound=Binding.get(self.store,path)
    if not bound then self:info("尚未绑定微信读书书目,请先在菜单里完成「绑定微信读书」") return end
    if not self:is_online() then self:info(_("Network unavailable")) return end
    local Trapper=require("ui/trapper")
    Trapper:wrap(function() self:_sync_run(path,bound) end)
end

function Plugin:_sync_run(path,bound)
    local Trapper=require("ui/trapper")
    local Sync=require("miuthought.sync")
    local EpubReader=require("miuthought.epub_reader")
    local EpubInject=require("miuthought.epub_inject")
    local report,err=Sync.run{
        doc_path=path,
        book_id=bound.book_id,
        api=self.api,
        annotations=self.annotations,
        load_meta=function(p) return EpubReader.load(p) end,
        read_text=function(meta,href) return (EpubReader.read(meta,href)) end,
        save_thoughts=function(book_id,uid,groups) Thoughts.save(self.store,book_id,uid,groups) end,
        inject=function(src,book_id,mapped) return EpubInject.inject_copy(src,book_id,mapped) end,
        progress=function(phase,i,n,text)
            local msg
            if phase=="chapters" then msg="正在获取章节列表…"
            elseif phase=="fetch" then msg=string.format("正在拉取划线与想法 %d/%d\n%s",i,n,tostring(text or ""))
            elseif phase=="map" then msg="正在匹配本地章节…"
            else msg="正在生成觅想版副本…\n(书较大时需要一点时间)" end
            return Trapper:info(msg)
        end,
    }
    Trapper:clear()
    if not report then
        if tostring(err)~="已取消" then self:info("同步失败:\n"..U.first_line(err,220)) end
        return
    end
    self:_sync_report(report)
end

function Plugin:_sync_report(report)
    local lines={
        "同步完成",
        "",
        string.format("章节:%d/%d 有划线,注入 %d 章",
            report.chapters_with_data,report.chapters_total,report.injected),
        string.format("锚点:%d 处(引文对齐 %d,定位失败 %d)",
            report.marks or 0,report.quote_aligned or 0,report.dropped or 0),
        string.format("想法缓存:%d 章",report.thoughts_saved or 0),
    }
    local misses={}
    for _,row in ipairs(report.unmatched or {}) do
        misses[#misses+1]=tostring(row.title~="" and row.title or row.uid)
    end
    if #misses>0 then
        local shown=table.concat(misses,"、",1,math.min(#misses,5))
        lines[#lines+1]="未匹配章节:"..shown..(#misses>5 and("等 "..#misses.." 章") or "")
    end
    if (report.fetch_errors or 0)>0 then
        lines[#lines+1]=string.format("有 %d 章拉取失败,可稍后重新同步",report.fetch_errors)
    end
    lines[#lines+1]=""
    lines[#lines+1]="副本:"..tostring(report.dest)
    UIManager:show(ConfirmBox:new{
        text=table.concat(lines,"\n"),
        ok_text="打开副本",
        ok_callback=function()
            local ReaderUI=require("apps/reader/readerui")
            ReaderUI:showReader(report.dest)
        end,
        cancel_text="稍后",
    })
end

-- ===== 想法弹窗体系（点击 EPUB 锚点 → 弹窗）=====
local function extract_thought_href(value,seen,depth)
    if depth>4 or value==nil then return nil end
    if type(value)=="string" then return value:match("(#?miuthought%-[%x%.]+)") end
    if type(value)~="table" then return nil end
    seen=seen or {}; if seen[value] then return nil end; seen[value]=true
    for _,key in ipairs({"href","url","target","link","uri","dest","destination"}) do local found=extract_thought_href(value[key],seen,depth+1); if found then return found end end
    for _,child in pairs(value) do local found=extract_thought_href(child,seen,depth+1); if found then return found end end
end

function Plugin:_teardown_thought_tap()
    if self._thought_tap_setup and self.ui and self.ui.unRegisterTouchZones then pcall(function() self.ui:unRegisterTouchZones({{id="miuthought_thought_popup",overrides={"tap_link"}}}) end) end
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
        logger.info("[MiuThought][ThoughtPopup] opened",
            "book=",tostring(info.book_id),"chapter=",tostring(info.chapter_uid),
            "comments=",tostring(metrics and metrics.comment_count or 0),
            "chapter_cache=",token and token.cache_hit and "hit" or "miss",
            "html_cache=",html_cache_hit and "hit" or "miss",
            "elapsed_ms=",tostring(math.floor((os.clock()-started)*1000+.5)))
    end,debug.traceback)
    self._thought_popup_busy=false
    if not ok then
        logger.err("[MiuThought][ThoughtPopup] open failed",tostring(unexpected))
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
    self.ui:registerTouchZones({{id="miuthought_thought_popup",ges="tap",screen_zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=1},overrides={"tap_link"},handler=function(ges) return self:_on_thought_tap(ges) end}})
    self._thought_tap_setup=true
end

-- ===== 事件 =====
function Plugin:onReadSettings() end

function Plugin:onReaderReady()
    self:_teardown_thought_tap(); self:_setup_thought_tap()
end

function Plugin:onCloseDocument()
    self:_teardown_thought_tap()
end

function Plugin:onFlushSettings() self.store:flush() end

return Plugin
