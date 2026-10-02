-- Display and native-position migration for official WeRead XHTML. Display
-- changes use CSS only; generated refreshes verify unchanged original blocks
-- before migrating highlights. Only paired blocks may hide their source text.
local M = {}

local INLINE = {span=true, a=true, em=true, strong=true, b=true, i=true, small=true}
local DISPLAY = {li="list-item", table="table", tr="table-row", td="table-cell", th="table-cell"}
local VOID = {area=true, base=true, br=true, col=true, embed=true, hr=true, img=true,
    input=true, link=true, meta=true, param=true, source=true, track=true, wbr=true}
local POSITION_BLOCK = {body=true,section=true,div=true,p=true,li=true,dt=true,dd=true,
    td=true,th=true,blockquote=true,pre=true,h1=true,h2=true,h3=true,h4=true,h5=true,h6=true}

local function utf8_char(n)
    if n < 0 or n > 0x10ffff or (n >= 0xd800 and n <= 0xdfff) then return "" end
    if n < 128 then return string.char(n) end
    if n < 2048 then return string.char(192+math.floor(n/64), 128+n%64) end
    if n < 65536 then return string.char(224+math.floor(n/4096), 128+math.floor(n/64)%64, 128+n%64) end
    return string.char(240+math.floor(n/262144), 128+math.floor(n/4096)%64, 128+math.floor(n/64)%64, 128+n%64)
end

local function unescape(s)
    local named = {amp="&", lt="<", gt=">", quot='"', apos="'"}
    return tostring(s or ""):gsub("&([^;]+);", function(entity)
        if named[entity] then return named[entity] end
        local n = entity:match("^#(%d+)$")
        n = n and tonumber(n) or tonumber(entity:match("^#[xX](%x+)$") or "", 16)
        return n and utf8_char(n) or ("&"..entity..";")
    end)
end

local function attribute(tag, name)
    for key, quote, value in tag:gmatch("([%w:_-]+)%s*=%s*(['\"])(.-)%2") do
        if key == name then return unescape(value) end
    end
end

local function has_class(value, class)
    for word in tostring(value or ""):gmatch("%S+") do if word == class then return true end end
    return false
end

local function inline_font_rem(style, inherited)
    local value, important
    for declaration in tostring(style or ""):lower():gmatch("[^;]+") do
        local property,candidate=declaration:match("^%s*([%w-]+)%s*:%s*(.-)%s*$")
        if property=="font-size" or property=="font" then
            local is_important=candidate:match("!%s*important%s*$")~=nil
            if not important or is_important then
                value=candidate:gsub("%s*!%s*important%s*$","")
                if property=="font" and value~="inherit" then value="unsupported" end
                important=is_important
            end
        end
    end
    if not value or value=="inherit" then return inherited end
    local size=tonumber(value:match("^([%d.]+)rem$"))
    -- Other units cannot be inferred from a sibling's nested inline style.
    return size and size>0 and size<=10 and size or false
end

local function tag_end(html, start_at)
    local quote
    for i = start_at + 1, #html do
        local c = html:sub(i, i)
        if quote then
            if c == quote then quote = nil end
        elseif c == '"' or c == "'" then quote = c
        elseif c == ">" then return i end
    end
end

local function notice_text(stack, value)
    value=unescape(value):gsub("\r\n","\n"):gsub("\r","\n")
    local node=stack[#stack]
    if node and node.dom_parts and value~="" then
        local last=node.dom_parts[#node.dom_parts]
        if type(last)=="table" then last.text=last.text..value
        else node.dom_parts[#node.dom_parts+1]={text=value} end
    end
    local text=value:gsub(utf8_char(160), " "):gsub("%s+", "")
    if text=="" then return end
    local font=node and node.font_rem or false
    for _, ancestor in ipairs(stack) do
        if ancestor.translation then ancestor.readable = true end
        if ancestor.font_counts then
            ancestor.font_counts[font]=(ancestor.font_counts[font] or 0)+#text
            ancestor.font_text_bytes=ancestor.font_text_bytes+#text
        end
    end
end

local function finish_node(node)
    if not node.dom_parts then return end
    local parts={node.name,":"..tostring(node.image_source or "")}
    for _,part in ipairs(node.dom_parts) do
        parts[#parts+1]=type(part)=="table" and ("t"..#part.text..":"..part.text) or ("e"..part)
    end
    node.signature=require("miuread.digests").sha256(table.concat(parts,"\0"))
    node.dom_parts=nil
    if node.parent and node.parent.dom_parts then
        node.parent.dom_parts[#node.parent.dom_parts+1]=node.signature
    end
end

function M.normalize_mode(mode)
    return (mode == "bilingual" or mode == "translation") and mode or "original"
end

function M.normalize_font_scale(value)
    value=tonumber(value) or 100
    if value~=value then value=100 end
    return math.max(80,math.min(180,math.floor(value/10+.5)*10))
end

function M.label(mode)
    return ({original="原文", bilingual="双语", translation="仅译文"})[M.normalize_mode(mode)]
end

-- WeRead currently duplicates the original id on an adjacent translation.
-- Require both the sibling relationship and a unique original/translation id
-- pair. An inline span, an enclosing container or an ambiguous id must never
-- cause a whole original paragraph (and its translation) to disappear.
-- Native migration collects DOM signatures instead of font statistics; it
-- never retains copies of the source markup for nested original nodes.
function M.analyze(html, chapter_uid, fragment_index, collect_positions)
    html = tostring(html or "")
    local out = {blocks=0, pairs={}, typography={}, tags={}, recoveries=0,
        chapter_uid=tostring(chapter_uid or ""), fragment_index=fragment_index or 1}
    if collect_positions then out.original_nodes={} end
    local stack, ids, pending, translated_nodes, font_pending = {}, {}, {}, {}, {}
    local cursor, body = 1, nil
    while true do
        local start_at = html:find("<", cursor, true)
        if not start_at then break end
        notice_text(stack, html:sub(cursor, start_at-1))
        local finish
        if html:sub(start_at, start_at+3) == "<!--" then
            finish = html:find("-->", start_at+4, true)
            if not finish then return nil, "unterminated_comment" end
            cursor = finish + 3
        elseif html:sub(start_at, start_at+8) == "<![CDATA[" then
            finish = html:find("]]>", start_at+9, true)
            if not finish then return nil, "unterminated_cdata" end
            notice_text(stack, html:sub(start_at+9, finish-1))
            cursor = finish + 3
        else
            finish = tag_end(html, start_at)
            if not finish then return nil, "unterminated_tag" end
            local raw = html:sub(start_at, finish)
            local closing, full_name = raw:match("^<%s*(/?)%s*([%w:_-]+)")
            if full_name then
                local name = full_name:match("([^:]+)$"):lower()
                if closing == "/" then
                    -- Imported HTML sometimes spells a void tag as <br></br>.
                    -- It has no children and must not pop its enclosing block.
                    if not VOID[name] then
                        local match
                        for index=#stack,1,-1 do
                            if stack[index].name==name then match=index; break end
                        end
                        -- Match CRE's XHTML DOM writer (ldomDocumentWriter::pop):
                        -- an unmatched end tag closes nothing; an ancestor end
                        -- tag closes intervening children first. Imported text
                        -- can contain <English>...</Chinese>; no source bytes
                        -- are rewritten, and pairing still requires verified
                        -- adjacent siblings with a unique original/translated id.
                        -- https://github.com/koreader/crengine/blob/60a5fbc1531f76a47c54699d487390e2e2cb1c14/crengine/src/lvtinydom.cpp
                        if not match then out.recoveries=out.recoveries+1
                        else
                            while #stack>match do
                                local node=table.remove(stack)
                                finish_node(node)
                                out.recoveries=out.recoveries+1
                            end
                            local node=table.remove(stack)
                            finish_node(node)
                        end
                    end
                else
                    local parent = stack[#stack]
                    local is_body = name == "body"
                    local in_body = is_body or (parent and parent.in_body) or false
                    local node = {name=name, parent=parent, in_body=in_body, counts={}}
                    if collect_positions and in_body then
                        node.dom_parts={}
                        if name=="img" then node.image_source=attribute(raw,"src") end
                    end
                    if is_body then
                        if body then return nil, "multiple_bodies" end
                        body = node
                        node.path = "/body"
                        out.scope_uid = attribute(raw, "data-miuread-chapter")
                        out.chapter_uid = out.scope_uid or out.chapter_uid
                    elseif parent and parent.path then
                        parent.counts[name] = (parent.counts[name] or 0) + 1
                        node.path = parent.path.."/"..name.."["..parent.counts[name].."]"
                    end
                    if in_body then
                        node.id = attribute(raw, "id")
                        node.translation = has_class(attribute(raw, "class"), "wr-translation")
                        node.in_translation = node.translation or (parent and parent.in_translation) or false
                        if not collect_positions then
                            node.font_rem=inline_font_rem(attribute(raw,"style"),parent and parent.font_rem)
                            if not node.in_translation then node.font_counts={}; node.font_text_bytes=0 end
                        end
                        if collect_positions and node.path and not node.in_translation then
                            out.original_nodes[#out.original_nodes+1]=node
                        end
                        if node.id then ids[node.id] = (ids[node.id] or 0) + 1 end
                        if node.translation and not (parent and parent.in_translation) then
                            translated_nodes[#translated_nodes+1] = node
                            out.tags[name] = true
                            local previous = parent and parent.last_child
                            if not collect_positions and previous and not previous.in_translation and not previous.has_translation
                                and previous.name==name then
                                font_pending[#font_pending+1]={source=previous,node=node,tag=name,
                                    original_path=previous.path,translation_path=node.path}
                            end
                            if previous and not previous.in_translation and not previous.has_translation
                                and previous.name == name and previous.id and previous.id == node.id then
                                pending[#pending+1] = {id=node.id, tag=name, original_path=previous.path, translation_path=node.path, node=node}
                            end
                            for _, ancestor in ipairs(stack) do ancestor.has_translation = true end
                        end
                    end
                    if parent then parent.last_child = node end
                    local self_closing=VOID[name] or raw:match("/%s*>$")
                    if not self_closing and (name=="style" or name=="script" or (name=="title" and not in_body)) then
                        -- CSS, scripts and head titles are raw text, not nested
                        -- chapter tags. A '<' in them cannot break the body scan.
                        local raw_start,raw_finish=html:lower():find("</"..name.."%s*>",finish+1)
                        if not raw_finish then return nil,"unterminated_raw_text tag="..name end
                        notice_text({node},html:sub(finish+1,raw_start-1))
                        finish=raw_finish
                        finish_node(node)
                    elseif not self_closing then stack[#stack+1] = node
                    else finish_node(node) end
                end
            end
            cursor = finish + 1
        end
    end
    if #stack > 0 or not body then return nil, "incomplete_document" end
    for _, node in ipairs(translated_nodes) do if node.readable then out.blocks = out.blocks + 1 end end
    for _, pair in ipairs(pending) do
        if ids[pair.id] == 2 and pair.node.readable then
            pair.node = nil
            out.pairs[#out.pairs+1] = pair
        end
    end
    for _, pair in ipairs(font_pending) do
        local source,node=pair.source,pair.node
        local font,weight,smallest,largest
        for size,count in pairs(source.font_counts or {}) do
            if size then
                if not weight or count>weight or (count==weight and size>font) then font,weight=size,count end
                smallest=math.min(smallest or size,size)
                largest=math.max(largest or size,size)
            end
        end
        -- Converted PDFs put reader-relative sizes on English spans but leave
        -- Chinese paragraphs unstyled. CRE resolves rem against its default
        -- reader font, while percentages inherit the book's fixed html size.
        -- Copy the dominant source size using CSS only, including id-less
        -- paragraphs. This never makes an unverified source block hideable.
        local uniform_rem=smallest and (source.font_counts[false] or 0)==0 and largest/smallest<=1.1
        if node.readable and font and (weight>=(source.font_text_bytes or 0)*.8 or uniform_rem) then
            pair.font_rem=font
            pair.id=node.id and (ids[node.id]==1 or (ids[node.id]==2 and source.id==node.id)) and node.id or nil
            pair.source=nil; pair.node=nil
            out.typography[#out.typography+1]=pair
        end
    end
    out.separable = out.blocks > 0 and #out.pairs == out.blocks and out.chapter_uid ~= ""
    if collect_positions then
        for index,node in ipairs(out.original_nodes) do
            out.original_nodes[index]={id=node.id,tag=node.name,path=node.path,signature=node.signature}
        end
    end
    return out
end

local function normalize_path(path)
    return path:gsub("/([^/]+)",function(segment)
        return "/"..(segment:match("^[%w_-]+$") and segment.."[1]" or segment)
    end):gsub("^/body%[1%]", "/body")
end

local function content_token(meta)
    return tostring(meta.task_id or meta.generated_at or "")..":"..tostring(meta._file_size or "")
end

function M.recover_settings(path, settings)
    local marker=settings and settings.miuread_translation_pending_rebase
    if type(marker)~="table" then return settings end
    local meta,err=require("miuread.epub_installer").inspect(path)
    if not meta then return nil,err end
    if tostring(meta.book_id or "")~=tostring(marker.book_id or "") then return nil,"translation_recovery_identity_changed" end
    local data
    if content_token(meta)==marker.new_token then
        data=require("miuread.util").copy(settings)
    elseif content_token(meta)==marker.old_token and type(marker.previous)=="table" then
        data=require("miuread.util").copy(marker.previous)
    else return nil,"translation_recovery_version_changed" end
    data.miuread_translation_pending_rebase=nil
    return data
end

local function css_quote(value)
    return '"'..tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
        :gsub("[%z\1-\31\127]", function(c) return string.format("\\%x ", c:byte()) end)..'"'
end

local function display(tag)
    return INLINE[tag] and "inline" or DISPLAY[tag] or "block"
end

local function block_selector(scope, pair, translated)
    local id = tostring(pair.id or "")
    -- CRE prefixes EPUB ids with "_doc_fragment_N_ ". Its #id selector
    -- understands that prefix, whereas [id="source-id"] in older versions
    -- compares the rewritten attribute verbatim and never matches.
    -- CRE also lacks identifier escapes: address unusual/long ids by the
    -- already verified block path instead of emitting an unsupported #id.
    if #id < 512 and (id:match("^[A-Za-z_][A-Za-z0-9_-]*$")
        or id:match("^%-[A-Za-z_-][A-Za-z0-9_-]*$")) then
        return scope.."#"..id
    end
    local path = translated and pair.translation_path or pair.original_path
    return scope:gsub(" $", "")..path:gsub("^/body", "")
        :gsub("/([%w_-]+)%[(%d+)%]", " > %1:nth-of-type(%2)")
end

function M.css(profile, mode, font_scale)
    mode = M.normalize_mode(mode)
    font_scale=M.normalize_font_scale(font_scale)
    if not profile or (profile.blocks or 0) == 0 then return nil end
    if mode == "translation" and not profile.separable then return nil end
    local lines = {"/* MiuRead: WeRead translation display */"}
    for _, chapter in ipairs(profile.chapters or {}) do
        if chapter.blocks > 0 and chapter.chapter_uid ~= "" then
            local scope = "body[data-miuread-chapter="..css_quote(chapter.chapter_uid).."] "
            if mode == "original" then
                lines[#lines+1] = scope..".wr-translation { display: none !important; }"
            else
                if mode == "translation" then
                    for _, pair in ipairs(chapter.pairs) do
                        lines[#lines+1] = block_selector(scope, pair, false).." { display: none !important; }"
                        lines[#lines+1] = block_selector(scope, pair, true)..".wr-translation { display: "..display(pair.tag).." !important; }"
                    end
                end
                local tags = {}
                for tag in pairs(chapter.tags) do tags[#tags+1] = tag end
                table.sort(tags) -- Stable stylesheet text keeps CRE caches reusable.
                for _, tag in ipairs(tags) do
                    lines[#lines+1] = scope..tag..".wr-translation { display: "..display(tag).." !important; }"
                    -- Imported translation styles may shrink body text. Use
                    -- a reader-controlled percentage of the surrounding body
                    -- size; keep the book's heading hierarchy intact.
                    if not tag:match("^h[1-6]$") then
                        lines[#lines+1]=scope..tag..".wr-translation { font-size: "..font_scale.."% !important; }"
                    end
                end
                for _,pair in ipairs(chapter.pairs) do
                    if not pair.tag:match("^h[1-6]$") then
                        lines[#lines+1]=block_selector(scope,pair,true)..".wr-translation { font-size: "..font_scale.."% !important; }"
                    end
                end
                for _,pair in ipairs(chapter.typography or {}) do
                    local size=pair.font_rem*(pair.tag:match("^h[1-6]$") and 1 or font_scale/100)
                    local value=string.format("%.4f",size):gsub("0+$",""):gsub("%.$","")
                    lines[#lines+1]=block_selector(scope,pair,true)..".wr-translation { font-size: "..value.."rem !important; }"
                end
            end
        end
    end
    return table.concat(lines, "\n")
end

-- Restore the corresponding paragraph, rather than a page percentage that
-- changes when bilingual text doubles the number of pages. Text offsets in
-- two different languages cannot be copied; use the paired block's start.
function M.remap_xpointer(profile, xp, mode)
    if type(xp) ~= "string" or mode == "bilingual" then return nil end
    local fragment, tail = xp:match("/DocFragment%[(%d+)%](/body.*)")
    if not fragment then return nil end
    local normalized = normalize_path(tail)
    for _, chapter in ipairs(profile.chapters or {}) do
        if chapter.fragment_index == tonumber(fragment) then
            for _, pair in ipairs(chapter.pairs) do
                local from = mode == "translation" and pair.original_path or pair.translation_path
                local to = mode == "translation" and pair.translation_path or pair.original_path
                if normalized:sub(1, #from) == from and (normalized:sub(#from+1, #from+1) == "/" or normalized == from) then
                    return "/body/DocFragment["..fragment.."]"..to
                end
            end
        end
    end
end

-- Rebase only native position fields. Notes, dates, text offsets and the
-- original EPUB remain untouched. Match a unique source id plus identical DOM
-- text/structure, or a unique identical subtree when ids are absent/changed.
-- Attribute order, quoting and generated ids do not change native text offsets.
-- Changed text, inserted children and ambiguous matches still stop installation.
function M.rebase_settings(old_path, new_path, settings, mode)
    local U=require("miuread.util")
    local installer=require("miuread.epub_installer")
    local data=U.copy(settings or {})
    local fields={pos0=true,pos1=true,page=true,last_xpointer=true,xpointer=true}
    local wanted,replacements,seen,fingerprints,parse_errors={},{},{},{},{}
    local function visit(value, callback)
        if type(value)~="table" then return end
        for key,item in pairs(value) do
            if type(item)=="table" then visit(item,callback)
            elseif fields[key] and type(item)=="string" and item:match("^/body/DocFragment%[%d+%]/body") then callback(value,key,item) end
        end
    end
    visit(data,function(_,_,xp)
        local fragment,tail=xp:match("^/body/DocFragment%[(%d+)%](/body.*)")
        fragment=tonumber(fragment)
        wanted[fragment]=wanted[fragment] or {}
        wanted[fragment][xp]={tail=normalize_path(tail)}
    end)
    local old_ok,old_meta=installer.visit_chapter_text(old_path,function(html,index,chapter)
        if not wanted[index] then return true end
        fingerprints[index]=require("miuread.digests").sha256(html)
        for _,position in pairs(wanted[index]) do position.chapter_uid=tostring(chapter.uid or "") end
        local analyzed,err=M.analyze(html,chapter.uid,index,true)
        if not analyzed then
            -- Exact byte equality can preserve paths in an unchanged legacy
            -- chapter even when its HTML is not strictly balanced. Defer the
            -- parser error until the new chapter is known to have changed.
            parse_errors[index]=err
            return true
        end
        local counts,signatures={},{}
        for _,node in ipairs(analyzed.original_nodes) do
            if node.id then counts[node.id]=(counts[node.id] or 0)+1 end
            signatures[node.signature]=(signatures[node.signature] or 0)+1
        end
        for _,position in pairs(wanted[index]) do
            position.nodes={}
            for _,node in ipairs(analyzed.original_nodes) do
                local path=node.path
                if position.tail==path or position.tail:sub(1,#path+1)==path.."/" then
                    node.unique_id=node.id and counts[node.id]==1
                    node.unique_signature=signatures[node.signature]==1
                    position.nodes[#position.nodes+1]=node
                end
            end
            table.sort(position.nodes,function(a,b) return #a.path>#b.path end)
        end
        return true
    end)
    if not old_ok then return nil,old_meta end
    local new_ok,new_meta=installer.visit_chapter_text(new_path,function(html,index,chapter)
        if not wanted[index] then return true end
        local unchanged=fingerprints[index]==require("miuread.digests").sha256(html)
        for xp,position in pairs(wanted[index]) do
            if position.chapter_uid~=tostring(chapter.uid or "") then return nil,"translation_chapter_order_changed" end
            if unchanged then replacements[xp]=xp end
        end
        if unchanged then
            seen[index]=M.analyze(html,chapter.uid,index) or {fragment_index=index,pairs={}}
            return true
        end
        if parse_errors[index] then return nil,"chapter="..tostring(chapter.uid).." "..parse_errors[index] end
        local analyzed,err=M.analyze(html,chapter.uid,index,true)
        if not analyzed then return nil,err end
        local by_id,by_signature={},{}
        for _,node in ipairs(analyzed.original_nodes) do
            if node.id then
                if by_id[node.id]~=nil then by_id[node.id]=false else by_id[node.id]=node end
            end
            if by_signature[node.signature]~=nil then by_signature[node.signature]=false
            else by_signature[node.signature]=node end
        end
        for xp,position in pairs(wanted[index]) do
            for _,before in ipairs(position.nodes or {}) do
                local after=before.unique_id and by_id[before.id]
                if not after and POSITION_BLOCK[before.tag] and (not before.id or by_id[before.id]==nil)
                    and before.unique_signature then
                    after=by_signature[before.signature]
                end
                if after and before.signature==after.signature then
                    replacements[xp]="/body/DocFragment["..index.."]"..after.path..position.tail:sub(#before.path+1)
                    break
                end
            end
            if not replacements[xp] and (position.tail=="/body" or position.tail=="/body/section[1]") then
                replacements[xp]=xp -- container start has no text offset to migrate
            elseif not replacements[xp] then
                return nil,"translation_position_unverified chapter="..tostring(chapter.uid).." path="..position.tail
            end
        end
        seen[index]=analyzed
        return true
    end)
    if not new_ok then return nil,new_meta end
    if tostring(old_meta.book_id or "")~=tostring(new_meta.book_id or "")
        or old_meta._chapter_count~=new_meta._chapter_count then return nil,"translation_book_identity_changed" end
    visit(data,function(table_value,key,xp)
        if not replacements[xp] then error("translation_position_missing") end
        table_value[key]=replacements[xp]
        if key=="last_xpointer" then
            local fragment=tonumber(xp:match("/DocFragment%[(%d+)%]"))
            local chapter=seen[fragment]
            table_value[key]=M.remap_xpointer({chapters={chapter}},table_value[key],mode) or table_value[key]
        end
    end)
    if type(data.annotations)=="table" then data.annotations_externally_modified=true end
    data.miuread_translation_mode=M.normalize_mode(mode)
    -- The sidecar and EPUB are separate files. A journal lets the next open
    -- recover the correct positions after power loss between their writes.
    data.miuread_translation_pending_rebase={book_id=old_meta.book_id,
        old_token=content_token(old_meta),new_token=content_token(new_meta),previous=U.copy(settings or {})}
    return data
end

function M.inspect(path)
    local profile = {blocks=0, pairs=0, chapters={}, separable=true,recoveries=0}
    local ok, meta = require("miuread.epub_installer").visit_chapter_text(path, function(html, index, chapter)
        local uid=chapter.uid or chapter.chapterUid or index
        local result,err
        local body_start=html:find("<[bB][oO][dD][yY][%s>]")
        if body_start and not html:find("wr-translation",body_start,true) then
            -- Original-only chapters need no pairing or CSS changes. Older
            -- imported HTML may be readable by CRE without balanced XML tags;
            -- it must not prevent inspecting translations in another chapter.
            local body_end=body_start and tag_end(html,body_start)
            local scope=body_end and attribute(html:sub(body_start,body_end),"data-miuread-chapter")
            result={blocks=0,pairs={},tags={},chapter_uid=tostring(scope or uid),scope_uid=scope,fragment_index=index}
        else result,err=M.analyze(html,uid,index) end
        if not result then return nil,"chapter="..tostring(uid).." "..tostring(err) end
        if not result.scope_uid or result.scope_uid == "" then return nil, "chapter_scope_missing" end
        profile.chapters[#profile.chapters+1] = result
        profile.blocks = profile.blocks + result.blocks
        profile.pairs = profile.pairs + #result.pairs
        profile.recoveries=profile.recoveries+(result.recoveries or 0)
        if profile.pairs > 20000 then return nil, "too_many_translation_blocks" end
        if result.blocks > 0 and not result.separable then profile.separable = false end
        return true
    end)
    if not ok then return nil, meta end
    if not tostring(meta.book_id or ""):match("^CB_") then return nil, "not_imported_book" end
    profile.book_id = meta.book_id
    profile.separable = profile.separable and profile.blocks > 0
    return profile
end

return M
