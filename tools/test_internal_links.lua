-- Link repair must reach a stable result before replacing chapter files.
-- No account/network access; disk fixtures are removed even after a failure.
local TOOL_DIR=tostring(arg and arg[0] or ''):gsub('\\','/'):match('^(.*)/[^/]+$') or '.'
package.path=TOOL_DIR..'/../miuread.koplugin/?.lua;'..package.path
local Links=require('miuread.internal_links')
local p1='OEBPS/text/chapter-0001.xhtml'
local p2='OEBPS/text/chapter-0002.xhtml'
local legacy='../Text/legacy.html#fn1'
local canonical='chapter-0002.xhtml#fn1'
local source='<p>Body '
    ..'<a href="https://example.com/?a=1&amp;b=2">External</a> '
    .."<a href='//example.com/?a=1&amp;b=2&amp;label=&apos;text&apos;'>Quoted</a> "
    ..'<a href="#miuthought-1?a=1&amp;b=2">Thought</a> '
    ..'<a data-href="'..legacy..'" href="'..legacy..'">Note</a> '
    .."<a title='href=\""..legacy.."\"' HREF = '"..legacy.."'>Second note</a> "
    ..'<a href="../Text/legacy.html?a=1&amp;b=2#fn1">Query note</a></p>'
local target='<p id="fn1">The actual note</p>'
local function documents()
    return {{path=p1,html=source},{path=p2,html=target}}
end
for _,rewrite in ipairs({Links.rewrite_documents,Links.rewrite_documents_strict}) do
    local docs=documents()
    local stats=rewrite(docs,{neutralize_unresolved=true})
    assert(stats.unresolved==0 and stats.rewritten==3,'known notes were not repaired')
    assert(docs[1].html:find('href="https://example.com/?a=1&amp;b=2"',1,true),'external URL was escaped again')
    assert(docs[1].html:find("href='//example.com/?a=1&amp;b=2&amp;label=&apos;text&apos;'",1,true),'quoted URL changed')
    assert(docs[1].html:find('href="#miuthought-1?a=1&amp;b=2"',1,true),'custom thought link changed')
    assert(docs[1].html:find('data-href="'..legacy..'" href="'..canonical..'"',1,true),'repair changed data-href instead of href')
    assert(docs[1].html:find("title='href=\""..legacy.."\"' HREF = '"..canonical.."'",1,true),'quoted title was mistaken for href')
    assert(docs[1].html:find('href="chapter-0002.xhtml?a=1&amp;b=2#fn1"',1,true),'query escaping was lost')
    local repaired=docs[1].html
    assert(Links.validate_documents(docs),'repaired notes did not validate')
    local second=rewrite(docs,{neutralize_unresolved=true})
    assert(second.rewritten==0 and docs[1].html==repaired and not docs[1].changed,'repair was not stable on the next pass')
end

-- The reported log lists only the first-pass missing TOC filenames. An
-- external URL elsewhere on that page used to fail the second pass while
-- these unrelated first-pass samples were shown as the failure details.
local toc='<nav>'
for _,name in ipairs({'titlepage','contents','front01','front02','c01','c02','c03','c04','c05','c06','c07','c08'}) do
    toc=toc..'<a href="'..name..'.xhtml">'..name..'</a>'
end
toc=toc..'<a href="https://publisher.example/?ref=1&amp;page=2">Publisher</a></nav>'
local toc_docs={{path=p1,html=target},{path=p2,html=toc}}
local toc_stats=Links.rewrite_documents_strict(toc_docs,{neutralize_unresolved=true,sample_limit=12})
assert(toc_stats.unresolved==12 and toc_stats.dropped==12 and #toc_stats.samples==12)
assert(toc_stats.samples[1]:find(p2..' -> titlepage.xhtml',1,true))
assert(toc_docs[2].html:find('<a>c08</a>',1,true),'missing TOC target removed visible text')
assert(Links.validate_documents(toc_docs),'reported TOC links prevented stable validation')

local base=arg and arg[1] and (arg[1]..'/internal-links') or os.tmpname()
local entries={{path=p1,full=base..'-1.xhtml'},{path=p2,full=base..'-2.xhtml'}}
local function write(path,value)
    local f=assert(io.open(path,'wb')); assert(f:write(value)); assert(f:close()); return true
end
local function read(path)
    local f=assert(io.open(path,'rb')); local value=f:read('*a'); f:close(); return value
end
local ok,err=xpcall(function()
    write(entries[1].full,source); write(entries[2].full,target)
    local stats,reason,verified=Links.rewrite_files_strict(entries,{neutralize_unresolved=true})
    assert(stats and not reason and stats.rewritten==3 and verified.rewritten==0,reason)
    local installed=read(entries[1].full)
    local again,again_error=Links.rewrite_files_strict(entries,{neutralize_unresolved=true})
    assert(again and not again_error and again.files_changed==0 and read(entries[1].full)==installed,again_error)
    local temp=io.open(entries[1].full..'.miuread-linkfix','rb')
    if temp then temp:close() end
    assert(not temp,'temporary link repair file remains')

    local missing='<p><a class="footnote" href="#missing">[1]</a></p>'
    write(entries[1].full,missing)
    local failed,failure=Links.rewrite_files_strict(entries)
    assert(failed and failure and read(entries[1].full)==missing,'unresolved critical note replaced its source')
    local dropped,drop_error=Links.rewrite_files_strict(entries,{neutralize_unresolved=true})
    assert(dropped and not drop_error and dropped.dropped==1,drop_error)
    assert(read(entries[1].full)=='<p><a class="footnote">[1]</a></p>','neutralizing a missing note lost its text')

    -- A staged write that reintroduces an old link must still block install.
    write(entries[1].full,source)
    local unstable,unstable_error,verification=Links.rewrite_files_strict(entries,{neutralize_unresolved=true,
        write_file=function(path,value)
            local changed=value:gsub('href="chapter%-0002%.xhtml#fn1"','href="'..legacy..'"',1)
            return write(path,changed)
        end})
    assert(unstable and unstable_error and read(entries[1].full)==source,'unstable staged links replaced the original')
    assert(unstable_error:find(p1,1,true) and verification.repair_samples[1]:find(canonical,1,true),
        'failed validation lost the chapter or link needing another repair')

    write(entries[1].full,target); write(entries[2].full,toc)
    local toc_result,toc_error=Links.rewrite_files_strict(entries,{neutralize_unresolved=true,sample_limit=12})
    assert(toc_result and not toc_error and toc_result.dropped==12,toc_error)
    assert(read(entries[2].full)==toc_docs[2].html,'disk repair differs from verified TOC repair')
end,debug.traceback)
for _,entry in ipairs(entries) do
    os.remove(entry.full); os.remove(entry.full..'.miuread-linkfix'); os.remove(entry.full..'.miuread-linkbak')
end
if not (arg and arg[1]) then os.remove(base) end
assert(ok,err)
print('Internal links: escaped external/custom URLs, exact href replacement, stable repair, disk install and failure protection passed')
