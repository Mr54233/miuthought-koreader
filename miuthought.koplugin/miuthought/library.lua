local Protocol=require("miuthought.protocol")
local Codec=require("miuthought.codec")
local U=require("miuthought.util")
local logger=require("logger")
local Library={}; Library.__index=Library
function Library:new(api,http,store) return setmetatable({api=api,http=http,store=store},self) end

local COVER_MAX_BYTES=12*1024*1024
local COVER_EXTENSIONS={
    [".png"]=true,[".jpg"]=true,[".gif"]=true,[".webp"]=true,
    [".svg"]=true,
}

local function truthy(value)
    if value==true then return true end
    if tonumber(value)==1 then return true end
    local text=tostring(value or ""):lower()
    return text=="true" or text=="yes"
end

local function first_number(...)
    for i=1,select("#",...) do
        local value=tonumber(select(i,...))
        if value~=nil then return value end
    end
    return nil
end

local function archive_entries(data)
    local source=data.archive or data.archives or data.bookArchives or data.archiveList or {}
    if type(source)~="table" then return {} end
    if source[1] then return source end
    if source.bookIds or source.bookIdList or source.books or source.items then return {source} end
    local out={}
    for _,row in pairs(source) do
        if type(row)=="table" then out[#out+1]=row end
    end
    table.sort(out,function(a,b)
        local ao=first_number(a.order,a.sort,a.index,a.archiveIndex) or 1000000000
        local bo=first_number(b.order,b.sort,b.index,b.archiveIndex) or 1000000000
        if ao~=bo then return ao<bo end
        return tostring(a.name or a.title or "")<tostring(b.name or b.title or "")
    end)
    return out
end

local function build_archive_map(data)
    local map={}
    for archive_index,archive in ipairs(archive_entries(data or {})) do
        local ids=archive.bookIds or archive.bookIdList or archive.books or archive.items or {}
        if type(ids)=="string" then
            local parsed={}
            for id in ids:gmatch("[^,%s]+") do parsed[#parsed+1]=id end
            ids=parsed
        end
        if type(ids)=="table" then
            local archive_name=tostring(archive.name or archive.title or archive.archiveName or "书单")
            for item_index,item in ipairs(ids) do
                local id
                if type(item)=="table" then
                    id=item.bookId or item.book_id or item.id
                else
                    id=item
                end
                id=tostring(id or "")
                if id~="" then
                    local current=map[id]
                    if not current then
                        current={
                            archiveIndex=archive_index,
                            archiveItemOrder=item_index,
                            archiveName=archive_name,
                            archiveNames={},
                        }
                        map[id]=current
                    end
                    current.archiveNames[#current.archiveNames+1]=archive_name
                end
            end
        end
    end
    for _,row in pairs(map) do row.archiveNamesText=table.concat(row.archiveNames,"、") end
    return map
end

local function book(row,raw_index,archive_map)
    row=type(row)=="table" and row or {}
    local b=type(row.bookInfo)=="table" and row.bookInfo or (type(row.book)=="table" and row.book or row)
    local id=tostring(b.bookId or row.bookId or b.book_id or row.book_id or "")
    local archive=archive_map and archive_map[id] or nil
    local top_value=row.isTop
    if top_value==nil then top_value=b.isTop end
    local explicit_order=first_number(
        row.shelfOrder,row.shelfIndex,row.bookOrder,row.sortOrder,row.displayOrder,
        b.shelfOrder,b.shelfIndex,b.bookOrder,b.sortOrder,b.displayOrder
    )
    return {
        bookId=id,
        title=b.title or row.title or "未命名",
        author=b.author or row.author or "",
        cover=b.cover or b.coverUrl or row.cover,
        category=b.category or row.category,
        updateTime=tonumber(row.updateTime or b.updateTime or row.bookUpdateTime or 0) or 0,
        progress=tonumber(row.progress or row.readingProgress or b.progress or 0) or 0,
        finished=(row.finished==true or tonumber(row.progress or row.readingProgress or 0)>=100),
        isTop=truthy(top_value),
        rawIndex=tonumber(raw_index) or 0,
        explicitOrder=explicit_order,
        cloudOrder=tonumber(row.cloudOrder or row.cloud_order),
        -- Keep the cloud reading timestamp independent from the book-content
        -- update timestamp. The old, proven shelf order uses readUpdateTime;
        -- updateTime must never be used as its fallback.
        readUpdateTime=tonumber(row.readUpdateTime or b.readUpdateTime or 0) or 0,
        cloudUpdatedAt=tonumber(row.readUpdateTime or b.readUpdateTime or 0) or 0,
        archiveIndex=archive and archive.archiveIndex or nil,
        archiveItemOrder=archive and archive.archiveItemOrder or nil,
        archiveName=archive and archive.archiveName or nil,
        archiveNames=archive and archive.archiveNamesText or nil,
        inArchive=archive~=nil,
        raw=row,
    }
end

local function order_cloud_rows(rows)
    table.sort(rows,function(a,b)
        if a.isTop~=b.isTop then return a.isTop==true end
        local ao,bo=tonumber(a.explicitOrder),tonumber(b.explicitOrder)
        if ao~=nil and bo~=nil and ao~=bo then return ao<bo end
        local ar,br=tonumber(a.rawIndex) or 1000000000,tonumber(b.rawIndex) or 1000000000
        if ar~=br then return ar<br end
        return tostring(a.bookId)<tostring(b.bookId)
    end)
    for index,row in ipairs(rows) do row.cloudOrder=index end
    logger.info("[MiuRead][ShelfOrder] normalized","count=",tostring(#rows))
    return rows
end

function Library:normalize(data)
    data=type(data)=="table" and data or {}
    local books,mp={},{}
    local seen_books,seen_mp={},{}
    local archive_map=build_archive_map(data)
    local src=data.books or data.bookList or data.updated or {}
    if type(src)~="table" then src={} end
    local raw_index=0
    for _,r in ipairs(src) do
        raw_index=raw_index+1
        local b=book(r,raw_index,archive_map)
        if b.bookId~="" then
            if Protocol.is_mp(b.bookId) then
                if not seen_mp[b.bookId] then mp[#mp+1]=b; seen_mp[b.bookId]=true end
            elseif not seen_books[b.bookId] then
                books[#books+1]=b; seen_books[b.bookId]=true
            end
        end
    end
    local extras={data.mp,data.mpBook,data.officialAccounts}
    for _,x in ipairs(extras) do
        if type(x)=="table" then
            if x[1] then
                for _,r in ipairs(x) do
                    raw_index=raw_index+1
                    local b=book(r,raw_index,archive_map)
                    if b.bookId~="" and not seen_mp[b.bookId] then mp[#mp+1]=b; seen_mp[b.bookId]=true end
                end
            else
                raw_index=raw_index+1
                local b=book(x,raw_index,archive_map)
                if b.bookId~="" and not seen_mp[b.bookId] then mp[#mp+1]=b; seen_mp[b.bookId]=true end
            end
        end
    end
    order_cloud_rows(books)
    order_cloud_rows(mp)
    return books,mp
end

function Library:refresh(options)
    local data=self.api:shelf(options)
    local books,mp=self:normalize(data)
    self.store:save_shelf_cache({books=books,mp=mp,updated_at=os.time()})
    return books,mp
end
function Library:cached() local c=self.store:shelf_cache(); return c.books or {},c.mp or {},c.updated_at end

local function record_state(row)
    local downloaded=false
    local partial_downloaded=false
    local has_record=false
    local latest_download=0
    local filenames={}
    local total_size=0
    local has_clean=false
    local has_notes=false
    local function scan(record,kind,is_final)
        if type(record)~="table" then return end
        local file=tostring(record.file or "")
        if file~="" then
            has_record=true
            latest_download=math.max(latest_download,tonumber(record.downloaded_at or 0) or 0)
            filenames[#filenames+1]=file:match("([^/]+)$") or file
            if U.file_exists(file) then
                if is_final then
                    downloaded=true
                    total_size=total_size+(tonumber(U.file_size(file)) or 0)
                    if kind=="clean" then has_clean=true end
                    if kind=="notes" then has_notes=true end
                else
                    partial_downloaded=true
                end
            end
        end
    end
    for kind,record in pairs((row and row.variants) or {}) do scan(record,tostring(kind),true) end
    for _,chapter in pairs((row and row.chapters) or {}) do
        for kind,record in pairs(chapter or {}) do scan(record,tostring(kind),false) end
    end
    return {
        has_record=has_record,
        downloaded=downloaded,
        partial_downloaded=partial_downloaded,
        file_missing=has_record and not downloaded and not partial_downloaded,
        downloaded_at=latest_download,
        filenames=table.concat(filenames," "),
        file_size=total_size,
        has_clean=has_clean,
        has_notes=has_notes,
    }
end

local function local_progress(session,row)
    session=type(session)=="table" and session or {}
    local pending=type(session.pending)=="table" and session.pending or {}
    return tonumber(pending.percent or session.progress_local_percent or session.verified_local_percent or row.progress or 0) or 0
end

function Library:is_downloaded(id, library_snapshot)
    local source=library_snapshot or self.store:library()
    local b=source and source[tostring(id)]
    return b and record_state(b).downloaded or false
end

function Library:local_books(library_snapshot,sessions_snapshot)
    local source=library_snapshot or self.store:library()
    local sessions=sessions_snapshot or self.store:get("sessions",{})
    local books,mp={},{}
    for id,row in pairs(source or {}) do
        local state=record_state(row)
        if state.downloaded then
            local session=sessions[tostring(id)] or {}
            local b={
                bookId=tostring(row.book_id or id or ""),
                title=row.title or "未命名",
                author=row.author or "",
                cover=row.cover,
                category=row.category,
                updateTime=tonumber(row.updated_at or row.downloaded_at or 0) or 0,
                progress=local_progress(session,row),
                local_only=true,
                downloaded=true,
                file_missing=false,
                downloadedAt=state.downloaded_at,
                lastReadTime=tonumber(session.last_read_at or 0) or 0,
                filename_search=state.filenames,
                fileSize=state.file_size,
                hasClean=state.has_clean,
                hasNotes=state.has_notes,
                local_record=row,
            }
            if b.bookId~="" then
                if Protocol.is_mp(b.bookId) then mp[#mp+1]=b else books[#books+1]=b end
            end
        end
    end
    return books,mp
end

local function local_index(local_rows)
    local index={}
    for _,row in ipairs(local_rows or {}) do
        local id=tostring(row.bookId or row.book_id or "")
        if id~="" then index[id]=row end
    end
    return index
end

local function merge_local_metadata(remote,local_book)
    remote.title=remote.title or local_book.title
    remote.author=remote.author or local_book.author
    remote.cover=remote.cover or local_book.cover
    remote.downloaded=local_book.downloaded==true
    remote.file_missing=local_book.file_missing==true
    remote.downloadedAt=tonumber(local_book.downloadedAt or 0) or 0
    remote.lastReadTime=tonumber(local_book.lastReadTime or 0) or 0
    remote.filename_search=local_book.filename_search
    remote.fileSize=tonumber(local_book.fileSize or 0) or 0
    remote.hasClean=local_book.hasClean==true
    remote.hasNotes=local_book.hasNotes==true
    remote.local_record=local_book.local_record
    if (tonumber(remote.progress or 0) or 0)<=0 then remote.progress=local_book.progress end
    return remote
end

function Library:account_rows(remote_rows,local_rows)
    local local_by_id=local_index(local_rows)
    local out={}
    for _,remote in ipairs(remote_rows or {}) do
        local b=U.copy(remote)
        local id=tostring(b.bookId or b.book_id or "")
        if id~="" then
            b.bookId=id
            b.local_only=false
            b.in_account_shelf=true
            b.remote_status_known=true
            local local_book=local_by_id[id]
            if local_book then merge_local_metadata(b,local_book) else b.downloaded=false end
            out[#out+1]=b
        end
    end
    return out
end

function Library:generated_rows(remote_books,remote_mp,local_books,local_mp,remote_status_known)
    local remote_index={}
    for _,row in ipairs(remote_books or {}) do remote_index[tostring(row.bookId or "")]=row end
    for _,row in ipairs(remote_mp or {}) do remote_index[tostring(row.bookId or "")]=row end
    local out={}
    local function append(local_rows)
        for _,local_book in ipairs(local_rows or {}) do
            local b=U.copy(local_book)
            local id=tostring(b.bookId or "")
            local remote=remote_index[id]
            b.remote_status_known=remote_status_known==true
            b.in_account_shelf=remote~=nil
            b.local_only=remote==nil
            if remote then
                b.isTop=remote.isTop==true
                b.archiveName=remote.archiveName
                b.archiveNames=remote.archiveNames
                b.inArchive=remote.inArchive==true
                b.cloudOrder=remote.cloudOrder
                if (tonumber(b.progress or 0) or 0)<=0 then b.progress=remote.progress end
            end
            out[#out+1]=b
        end
    end
    append(local_books)
    append(local_mp)
    return out
end

-- Kept for older call sites and saved data. New shelf pages use account_rows and
-- generated_rows so cloud-only and generated files are never silently mixed.
function Library:merge_books(remote_rows,local_rows)
    local out=self:account_rows(remote_rows,local_rows)
    local seen={}
    for _,row in ipairs(out) do seen[tostring(row.bookId)]=true end
    for _,local_book in ipairs(local_rows or {}) do
        local id=tostring(local_book.bookId or "")
        if id~="" and not seen[id] then
            local copy=U.copy(local_book)
            copy.cloudOrder=copy.cloudOrder or (1000000+#out+1)
            out[#out+1]=copy
        end
    end
    return out
end

function Library:combined(remote_books,remote_mp,library_snapshot,sessions_snapshot)
    local local_books,local_mp=self:local_books(library_snapshot,sessions_snapshot)
    return self:merge_books(remote_books,local_books),self:merge_books(remote_mp,local_mp)
end

local function less_text(a,b,field)
    local av=tostring(a[field] or "")
    local bv=tostring(b[field] or "")
    if av~=bv then return av<bv end
    return tostring(a.bookId or "")<tostring(b.bookId or "")
end

function Library:sort_filter(rows,options)
    options=options or {}
    local p=self.store:preferences()
    local section=tostring(options.section or p.shelf_section or "account")
    local scope
    local key
    if section=="generated" then
        scope=tostring(p.generated_shelf_scope or "all")
        key=tostring(p.generated_shelf_sort or "opened")
    else
        scope=tostring(p.account_shelf_scope or "all")
        key=tostring(p.account_shelf_sort or "read")
        -- Migrate stale in-memory values defensively. Persistent migration is
        -- handled by Store, but cached preferences can still survive briefly
        -- during an OTA restart.
        if key=="default" or key=="cloud" or key=="cloud_order" then key="read" end
    end
    local out={}
    for _,b in ipairs(rows or {}) do
        local pass=true
        local prog=tonumber(b.progress or 0) or 0
        if section=="generated" then
            if scope=="in_account" and b.in_account_shelf~=true then pass=false end
            if scope=="removed" and not (b.remote_status_known==true and b.in_account_shelf~=true) then pass=false end
            if scope=="clean" and b.hasClean~=true then pass=false end
            if scope=="notes" and b.hasNotes~=true then pass=false end
        else
            if scope=="generated" and b.downloaded~=true then pass=false end
            if scope=="ungenerated" and b.downloaded==true then pass=false end
            if scope=="top" and b.isTop~=true then pass=false end
            if scope=="archive" and b.inArchive~=true then pass=false end
        end
        if pass then out[#out+1]=b end
    end
    table.sort(out,function(a,b)
        if section=="generated" then
            if key=="title" then return less_text(a,b,"title") end
            if key=="author" then return less_text(a,b,"author") end
            if key=="size" then
                local av,bv=tonumber(a.fileSize or 0) or 0,tonumber(b.fileSize or 0) or 0
                if av~=bv then return av>bv end
            elseif key=="generated" then
                local av,bv=tonumber(a.downloadedAt or 0) or 0,tonumber(b.downloadedAt or 0) or 0
                if av~=bv then return av>bv end
            else
                local av,bv=tonumber(a.lastReadTime or 0) or 0,tonumber(b.lastReadTime or 0) or 0
                if av~=bv then return av>bv end
            end
            local ad,bd=tonumber(a.downloadedAt or 0) or 0,tonumber(b.downloadedAt or 0) or 0
            if ad~=bd then return ad>bd end
            return less_text(a,b,"title")
        end

        if key=="title" then return less_text(a,b,"title") end
        if key=="author" then return less_text(a,b,"author") end
        if key=="progress" then
            local av,bv=tonumber(a.progress or 0) or 0,tonumber(b.progress or 0) or 0
            if av~=bv then return av>bv end
        elseif key=="read" then
            -- Match the long-proven mobile-like shelf order: explicit pinned
            -- books first, then cloud readUpdateTime from newest to oldest.
            -- Unread books have timestamp 0 and naturally stay behind read
            -- books. rawIndex is the stable tie-breaker below.
            if a.isTop~=b.isTop then return a.isTop==true end
            local av,bv=tonumber(a.readUpdateTime or 0) or 0,tonumber(b.readUpdateTime or 0) or 0
            if av~=bv then return av>bv end
        elseif key=="update" then
            local av,bv=tonumber(a.updateTime or 0) or 0,tonumber(b.updateTime or 0) or 0
            if av~=bv then return av>bv end
        end
        local ar,br=tonumber(a.rawIndex or 0) or 0,tonumber(b.rawIndex or 0) or 0
        if ar~=br then return ar<br end
        return tostring(a.bookId or "")<tostring(b.bookId or "")
    end)
    logger.info("[MiuRead][ShelfSort] complete",
        "count=",tostring(#out),"section=",tostring(section),"sort=",tostring(key))
    return out
end

local function searchable(value)
    return U.trim(tostring(value or "")):lower():gsub("%s+"," ")
end

function Library:search(rows,query)
    local q=searchable(query)
    if q=="" then return U.copy(rows or {}) end
    local terms={}
    for term in q:gmatch("%S+") do terms[#terms+1]=term end
    local out={}
    for _,b in ipairs(rows or {}) do
        local hay=searchable(table.concat({b.title or "",b.author or "",b.filename_search or ""}," "))
        local pass=true
        for _,term in ipairs(terms) do
            if not hay:find(term,1,true) then pass=false; break end
        end
        if pass then out[#out+1]=b end
    end
    return out
end

local function cover_header(path)
    local f=io.open(path,"rb")
    if not f then return nil end
    local data=f:read(1024) or ""
    f:close()
    return data
end

function Library:_valid_cover_path(path)
    path=tostring(path or "")
    if path=="" or not U.file_exists(path) then return false,"missing" end
    local size=tonumber(U.file_size(path) or 0) or 0
    if size<=0 then return false,"empty" end
    if size>COVER_MAX_BYTES then return false,"too_large" end
    local ext=select(1,Codec.media(cover_header(path) or ""))
    if not COVER_EXTENSIONS[ext] then return false,"unsupported" end
    return true,nil,size,ext
end

function Library:cached_cover_path(id,cover_index)
    local own_index=cover_index==nil
    local index=cover_index or self.store:get("cover_index",{})
    local key=tostring(id)
    local path=index[key]
    if not path then return nil,false end
    local valid,reason=self:_valid_cover_path(path)
    if valid then return path,false end
    logger.warn("[MiuRead][Cover] removed invalid cache","book_id=",key,"reason=",tostring(reason),"path=",tostring(path))
    os.remove(path)
    index[key]=nil
    if own_index then self.store:set("cover_index",index) end
    return nil,true
end

function Library:cache_cover(b,options)
    if not b or not b.cover or b.cover=="" then return nil end
    options=options or {}
    local persist_index=options.persist_index~=false
    local index={}
    if options.skip_index_lookup~=true then
        index=self.store:get("cover_index",{})
        local cached,removed=self:cached_cover_path(b.bookId,index)
        if cached then return cached end
        if removed and persist_index then self.store:set("cover_index",index) end
    end
    local data=self.http:download(b.cover,{
        auth=false,
        retries=options.retries==nil and 1 or options.retries,
        timeout=options.timeout or {8,15},
    })
    if not data or #data==0 then return nil end
    if #data>COVER_MAX_BYTES then
        logger.warn("[MiuRead][Cover] skipped oversized image","book_id=",tostring(b.bookId),"bytes=",tostring(#data))
        return nil
    end
    local ext,mime=Codec.media(data)
    if not COVER_EXTENSIONS[ext] then
        logger.warn("[MiuRead][Cover] skipped unsupported response","book_id=",tostring(b.bookId),"type=",tostring(mime),"bytes=",tostring(#data))
        return nil
    end

    local base=self.store.covers_dir.."/"..U.id_name(b.bookId)
    local path=base..ext
    local written,write_error=U.atomic_write(path,data,true)
    if not written then error("cover write failed: "..tostring(write_error or "unknown")) end
    local valid,reason=self:_valid_cover_path(path)
    if not valid then
        os.remove(path)
        logger.warn("[MiuRead][Cover] downloaded image failed validation","book_id=",tostring(b.bookId),"reason=",tostring(reason))
        return nil
    end
    for old_ext in pairs(COVER_EXTENSIONS) do
        local old=base..old_ext
        if old~=path then os.remove(old) end
    end
    index[tostring(b.bookId)]=path
    if persist_index then self.store:set("cover_index",index) end
    logger.info("[MiuRead][Cover] cached","book_id=",tostring(b.bookId),"bytes=",tostring(#data),"type=",tostring(mime))
    return path
end
function Library:clear_covers() U.remove_tree(self.store.covers_dir); U.mkdir(self.store.covers_dir); self.store:set("cover_index",{}) end
function Library:reader_link(url)
    local id=tostring(url or ""):match("/web/reader/([^/?#]+)") or tostring(url or ""):match("bookId=([^&#]+)")
    if not id then return nil end
    if id:match("^%d+$") or id:match("^MP_WXS_") then return id end
    return nil
end
return Library
