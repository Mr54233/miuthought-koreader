-- A fake WeRead transport drives the real reader, signing and body parser.
-- It serves original text to the old request, and delays translated content
-- on the browser request. No account or network access is used by this test.
local TOOL_DIR=tostring(arg and arg[0] or ''):gsub('\\','/'):match('^(.*)/[^/]+$') or '.'
local ROOT=TOOL_DIR..'/../miuread.koplugin/'
package.path=ROOT..'?.lua;'..package.path
local sleeps={}
package.preload['socket']=function() return {sleep=function(seconds) sleeps[#sleeps+1]=seconds end} end
package.preload['logger']=function() return {info=function() end,warn=function() end,err=function() end} end
package.preload['miuread.json']=function() return {encode=function(value) return value end,decode=function() error('unexpected JSON') end} end
package.preload['miuread.util']=function() return {extract_balanced_json=function() return nil end,file_exists=function() return false end,
    xml=function(value) return value end} end -- fixture titles contain no XML metacharacters
package.preload['miuread.annotation_coord']=function() return {fromDownloadedXhtml=function(value) return value end} end
package.preload['miuread.http']=function()
    return {is_auth_error=function(value) return tostring(value):find('test-auth-error',1,true)~=nil end,
        is_rate_limit_error=function() return false end,is_network_error=function() return false end}
end
local Codec=require('miuread.codec')
Codec.decode_parts=function(parts) return table.concat(parts) end -- fixture shards are already decrypted
local Protocol=require('miuread.protocol')
local Reader=require('miuread.reader')
local Generation=require('miuread.translation_generation')
local original='<section><p id="p">Original text.</p></section>'
local translated='<section><p id="p">Original text.</p><p id="p" class="wr-translation">译文。</p></section>'
local book,chapter={bookId='CB_fetch'},{chapterUid=2,title='Test'}

local function transport(ready_after)
    local http={requests={},pages=0,ready_after=ready_after}
    function http:download(url,opt)
        self.pages=self.pages+1
        self.page_options=opt
        return '<html><body>{"psvts":"server-ps","pclts":"page-pc"}</body></html>',200,url
    end
    function http:request(opt)
        self.requests[#self.requests+1]=opt
        local body=opt.body
        assert(body.s==Protocol.web_sign(Protocol.query(body)),'translation fields were changed after signing')
        if body.sc==0 then
            assert(body.pc=='page-pc' and body.prevChapter==nil,'actual request lost the page reader nonce')
            assert(opt.headers['Cache-Control'] and opt.headers.Pragma=='no-cache' and self.page_options.headers['Cache-Control'])
        end
        if self.empty_browser and body.sc==0 then return '{}',200 end
        if self.empty_all then return '{}',200 end
        if opt.url:match('e_0$') then return '<html><head></head><body>',200 end
        if opt.url:match('e_1$') then
            return ((body.sc==0 or self.compatible_translation) and self.pages>=self.ready_after) and translated or original,200
        end
        if opt.url:match('e_3$') then return '</body></html>',200 end
        if opt.url:match('e_2$') then assert(body.st==1); return '.wr-translation{display:none;}',200 end
        error('unexpected shard: '..opt.url)
    end
    return http
end

do
    local http=transport(1)
    local reader=Reader:new(http,{})
    local xhtml=reader:chapter(book,chapter,'epub',{images=false,keepalive=true})
    assert(not Generation.content_ready(Codec.body_fragment(xhtml)) and #http.requests==4)
    for _,request in ipairs(http.requests) do assert(request.body.sc==1 and request.body.prevChapter==false) end
    assert(not http.page_options.headers['Cache-Control'],'ordinary request unexpectedly changed')
end
do
    sleeps={}
    local http=transport(2)
    local reader=Reader:new(http,{})
    local xhtml,style,assets,state=reader:chapter(book,chapter,'epub',{translation=true,images=false,keepalive=true})
    assert(Generation.content_ready(Codec.body_fragment(xhtml)) and http.pages==2 and #http.requests==12,
        'reader returned stale originals instead of retrying the current chapter')
    assert(#sleeps==1 and sleeps[1]==3)
    assert(state.raw_xhtml==xhtml and state.coord_html==xhtml and #assets==0 and style:find('wr-translation',1,true))
    for _,request in ipairs(http.requests) do assert(request.keepalive and request.headers['Cache-Control']) end
end
do
    sleeps={}
    local http=transport(999)
    local reader=Reader:new(http,{})
    local ok,err=pcall(reader.chapter,reader,book,chapter,'epub',{translation=true,images=false})
    assert(not ok and tostring(err):find('[MiuReadTranslationContentPending]',1,true))
    assert(Generation.friendly_error(err) and http.pages==3 and #http.requests==24 and #sleeps==2,
        'unavailable translated content was accepted or retried indefinitely')
end
do
    local http=transport(1)
    local reader=Reader:new(http,{})
    local xhtml=reader:chapter(book,chapter,'txt',{translation=true,images=false})
    assert(Generation.content_ready(Codec.body_fragment(xhtml)) and #http.requests==4,
        'translated imported TXT book did not use the browser EPUB representation')
end
do
    local fields=Protocol.content_fields(book.bookId,2,'server-ps',false,{translation=true,pclts='  '})
    assert(fields.sc==0 and fields.pc~='' and fields.pc~='  ','missing page nonce destroyed fallback signing')
end
do
    local http=transport(999)
    local reader=Reader:new(http,{})
    local xhtml=reader:chapter(book,chapter,'epub',{translation=true,require_translation=false,images=false})
    assert(not Generation.content_ready(Codec.body_fragment(xhtml)) and #http.requests==4,
        'optional next chapter prevented installing a completed current chapter')
end
do
    -- The real Preface failure: a parent with 1595 words returned empty sc=0
    -- content. A successful compatible response must retain actual text and
    -- the UID; directory metadata cannot turn the refresh into a title page.
    local http=transport(1)
    http.empty_browser=true; http.compatible_translation=true
    local reader=Reader:new(http,{})
    local preface={chapterUid=4,title='Preface',wordCount=1595,isPart=true}
    local xhtml,_,_,state=reader:chapter(book,preface,'epub',{translation=true,images=false})
    assert(Generation.content_ready(Codec.body_fragment(xhtml)) and not state.structural and #http.requests==5)
    assert(http.requests[1].body.sc==0)
    for index=2,5 do
        local request=http.requests[index]
        assert(request.body.sc==1 and request.body.prevChapter==false and request.body.pc~='page-pc')
        assert(request.headers['Cache-Control'],'compatibility fallback reused a cached response')
    end
end
do
    sleeps={}
    local http=transport(1)
    http.empty_all=true
    local reader=Reader:new(http,{})
    local ok,err=pcall(reader.chapter,reader,book,{chapterUid=4,title='Preface',wordCount=1595,isPart=true},
        'epub',{translation=true,images=false})
    assert(not ok and tostring(err):find('[MiuReadTranslationContentPending]',1,true),
        'empty translated Preface was accepted as a structural page')
    assert(http.pages==3 and #http.requests==9 and #sleeps==2 and sleeps[1]==3 and sleeps[2]==6,
        'empty translated chapter did not use bounded content retries')
end
do
    -- Authentication and cancellation are never treated as stale content or
    -- sent to an alternate request path.
    local http=transport(1)
    function http:request(opt) self.requests[#self.requests+1]=opt; error('download cancelled') end
    local reader=Reader:new(http,{})
    local ok,err=pcall(reader.chapter,reader,book,chapter,'epub',{translation=true,images=false})
    assert(not ok and tostring(err):find('download cancelled',1,true) and #http.requests==1)
end
do
    local http=transport(1)
    function http:request(opt) self.requests[#self.requests+1]=opt; error('test-auth-error') end
    local reader=Reader:new(http,{})
    function reader:_recover_login_session() return false,'test expired login' end
    local ok,err=pcall(reader.chapter,reader,book,chapter,'epub',{translation=true,images=false})
    assert(not ok and tostring(err):find('test-auth-error',1,true) and #http.requests==1)
end
do
    local http=transport(1)
    http.empty_all=true
    local reader=Reader:new(http,{})
    local xhtml,_,_,state=reader:chapter(book,{chapterUid=4,title='Part',isPart=true},'epub',{images=false})
    assert(state.structural and xhtml:find('miu-part-page',1,true) and http.pages==1 and #http.requests==2,
        'ordinary confirmed empty catalog items lost their existing structure-page handling')
end
print('Translation fetch: browser and compatibility requests, translated Preface empty-page prevention, signing, bounded retries and original download compatibility passed')
