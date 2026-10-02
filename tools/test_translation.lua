local TOOL_DIR=tostring(arg and arg[0] or ''):gsub('\\','/'):match('^(.*)/[^/]+$') or '.'
local ROOT=TOOL_DIR..'/../miuread.koplugin/'
package.path=TOOL_DIR..'/?.lua;'..ROOT..'?.lua;'..package.path
local T=require('miuread.translation')

local function chapter(body,uid)
    return '<html><head><title>Test</title></head><body data-miuread-chapter="'..(uid or '1')..'"><section>'..body..'</section></body></html>'
end
local function profile(result)
    return {blocks=result.blocks,chapters={result},separable=result.separable}
end
local sample=chapter('<h1 id="title">Morning</h1><h1 id="title" class="wr-translation">早晨</h1>'
    ..'<p id="p1">First <em>paragraph</em>.</p><p id="p1" class="extra wr-translation">第一段。</p>'
    ..'<p id="p2">Not translated yet.</p>')
local result=assert(T.analyze(sample,'1',1))
assert(result.blocks==2 and #result.pairs==2 and result.separable,'adjacent translation blocks were not paired')
assert(T.normalize_mode('bogus')=='original' and T.normalize_mode(nil)=='original','invalid mode must retain originals')
local original=T.css(profile(result),'original')
local bilingual=T.css(profile(result),'bilingual')
local translated=T.css(profile(result),'translation')
assert(original:find('display: none !important;',1,true),'original mode does not hide translations')
assert(bilingual:find('h1.wr-translation',1,true) and bilingual:find('p.wr-translation',1,true),'bilingual mode lost headings or paragraphs')
assert(translated:find('#p1 { display: none',1,true),'translated mode must use a CRE fragment-aware ID selector')
assert(not translated:find('#p2',1,true),'an untranslated paragraph would become blank')
assert(not translated:find('[id=',1,true),'raw ID equality cannot match IDs rewritten during EPUB import')
assert(translated:find('body[data-miuread-chapter="1"]',1,true),'CSS can leak into other chapters')
assert(T.css({blocks=0,chapters={},separable=false},'translation')==nil,'no-translation book must remain readable')
local empty=assert(T.analyze(chapter('<p id="p">Keep reading.</p><p id="p" class="wr-translation">&#160;<br/></p>')))
assert(empty.blocks==0 and #empty.pairs==0,'empty translation placeholder hides the original paragraph')

-- PDF-converted text uses rem on English spans, but leaves Chinese paragraphs
-- inheriting a fixed root size. Font inference does not authorize hiding an
-- id-less source, and never edits paragraph markup or native positions.
local pdf=assert(T.analyze(chapter('<p><span style="font-size:2.1rem">Heading</span></p><p class="wr-translation">标题</p>'
    ..'<p><span style="font-size:0.88rem">Body text</span><sup style="font-size:0.75rem">1</sup></p><p class="wr-translation">正文</p>')))
assert(#pdf.typography==2 and pdf.typography[1].font_rem==2.1 and pdf.typography[2].font_rem==.88,
    'converted heading/body sizes were not identified')
assert(not pdf.separable and T.css(profile(pdf),'translation')==nil,'font inference made an id-less source hideable')
local pdf_css=T.css(profile(pdf),'bilingual',120)
assert(pdf_css:find('font-size: 1.056rem !important;',1,true),'translated PDF body still inherits the fixed root size')
assert(pdf_css:find('font-size: 2.52rem !important;',1,true),'converted heading size was lost')
assert(not T.css(profile(pdf),'original'):find('font-size:',1,true),'original mode changed PDF fonts')
local mixed=assert(T.analyze(chapter('<p><span style="font-size:.88rem">AAA</span><span style="font-size:18px">BBB</span></p>'
    ..'<p class="wr-translation">正文</p>')))
assert(#mixed.typography==0,'ambiguous mixed font sizes were inferred')
local close_sizes=assert(T.analyze(chapter('<p><span style="font-size:.83rem">Short label</span>'
    ..'<span style="font-size:.88rem">Longer explanatory text</span></p><p class="wr-translation">正文</p>')))
assert(close_sizes.typography[1].font_rem==.88,'converted paragraph with similar relative sizes still inherits fixed pixels')
local shorthand=assert(T.analyze(chapter('<p style="font-size:.88rem"><span style="font:18px serif">Words</span></p>'
    ..'<p class="wr-translation">正文</p>')))
assert(#shorthand.typography==0,'font shorthand incorrectly inherited a rem size')
local declared=assert(T.analyze(chapter('<p><span style="font-size:.88rem !important;font-size:18px">Words</span></p>'
    ..'<p class="wr-translation">正文</p>')))
assert(declared.typography[1].font_rem==.88,'font inference ignored inline importance')

-- No parent container may be hidden merely because it includes an inline
-- translation. Ambiguous ids and non-adjacent originals are also rejected.
for _,body in ipairs({
    '<p id="p">Original <span class="wr-translation">译文</span></p>',
    '<div class="wr-translation"><p>Original and translation</p></div>',
    '<p id="p">One</p><p id="p">Two</p><p id="p" class="wr-translation">译文</p>',
    '<p id="p">One</p><img/><p id="p" class="wr-translation">译文</p>',
    '<p>One</p><p class="wr-translation">译文</p>',
}) do
    local unsafe=assert(T.analyze(chapter(body),'1',1))
    assert(not unsafe.separable and T.css(profile(unsafe),'translation')==nil,'unsafe structure hides source content')
    assert(T.css(profile(unsafe),'bilingual')~=nil,'unsupported separation should still allow bilingual reading')
end
local commented=assert(T.analyze(chapter('<!-- <p class="wr-translation">fake</p> --><p>Real</p>')))
assert(commented.blocks==0,'comment was mistaken for translated content')
local implicit=assert(T.analyze('<html><body><p>Unclosed paragraph</body></html>'))
assert(implicit.blocks==0 and implicit.recoveries==1 and not implicit.separable,
    'CRE ancestor close recovery incorrectly invented a translated block')
local language_markup='<p id="language">Original <English>text</Chinese> <em id="em">kept</em></p>'
    ..'<p id="language" class="wr-translation">译文 <English>文字</Chinese></p>'
local recovered=assert(T.analyze(chapter(language_markup),'5',5,true))
assert(recovered.blocks==1 and recovered.separable and recovered.recoveries==4,
    'mismatched English/Chinese end tags rejected a verified translation pair')
local em
for _,node in ipairs(recovered.original_nodes) do if node.id=='em' then em=node end end
assert(em and em.path=='/body/section[1]/p[1]/english[1]/em[1]',
    'unmatched Chinese end tag closed the English container and changed native paths')
assert(em.signature and em.markup==nil,'position inspection retained redundant source markup')
local unsafe_recovered=assert(T.analyze(chapter('<p id="p">Original <English>text</Chinese>'
    ..'<p id="p" class="wr-translation">译文</p>')))
assert(unsafe_recovered.blocks==1 and not unsafe_recovered.separable
    and T.css(profile(unsafe_recovered),'translation')==nil,
    'unclosed original container was paired with a nested translation and hidden')
assert(T.analyze('<html><body><p class="wr-translation">incomplete')==nil,
    'unfinished document was accepted through tag recovery')
local raw_head=chapter('<p id="p">One<br></br><area/><embed></embed></p><p id="p" class="wr-translation">译文<br></br></p>')
    :gsub('<title>Test</title>','<title>1 < 2</title><style>p::before{content:"<div>"}</style><script>if (a < b) {}</script>')
local html_voids=assert(T.analyze(raw_head,'1',1))
assert(html_voids.blocks==1 and html_voids.separable,
    'head raw text or explicit void-tag end broke translation pairing')
local quoted=assert(T.analyze(chapter('<p id="a&amp;&quot;&gt;">One</p><p id="a&amp;&quot;&gt;" class="wr-translation">译文</p>')))
local quoted_css=T.css(profile(quoted),'translation')
assert(quoted.separable and quoted_css:find(' > section:nth-of-type(1) > p:nth-of-type(1) { display: none',1,true),
    'an ID unsupported by the CRE identifier parser must use the verified original block path')
assert(quoted_css:find(' > section:nth-of-type(1) > p:nth-of-type(2).wr-translation',1,true)
    and not quoted_css:find('a&',1,true),'unusual ID fallback must retain its translated sibling')
for _,id in ipairs({'123','a.b','a:b','a\\b',string.rep('a',512)}) do
    local unusual=assert(T.analyze(chapter('<div><p id="'..id..'">One</p><p id="'..id..'" class="wr-translation">译文</p></div>')))
    local css=T.css(profile(unusual),'translation')
    assert(css:find(' > section:nth-of-type(1) > div:nth-of-type(1) > p:nth-of-type(1) { display: none',1,true),
        'unsupported ID lost its nested structural fallback')
end

-- Position mapping uses fragment identity and paired block paths, never a
-- percentage or an offset copied between two languages.
assert(T.remap_xpointer(profile(result),'/body/DocFragment[1]/body/section/p[1]/em/text().0','translation')
    =='/body/DocFragment[1]/body/section[1]/p[2]','original paragraph did not map to its translated sibling')
assert(T.remap_xpointer(profile(result),'/body/DocFragment[1]/body/section/p[2]/text().5','original')
    =='/body/DocFragment[1]/body/section[1]/p[1]','translation did not map back to its source paragraph')
assert(T.remap_xpointer(profile(result),'/body/DocFragment[2]/body/section/p[1]','translation')==nil,'position mapping crossed chapters')
assert(T.remap_xpointer(profile(result),'/body/DocFragment[1]/body/section/p[3]','translation')==nil,'untranslated paragraph moved')

-- Exercise the actual plugin methods with a narrow ReaderUI mock: the
-- translation stylesheet composes with user/annotation tweaks, persists per
-- document, rolls back on failure and does not inspect ordinary book opening.
local Plugin={}
local scheduled
local env=setmetatable({Plugin=Plugin,require=require,
    Event={new=function(_,name,value) return {name=name,value=value} end},
    normalized_reader_file=function(path) return path end,
    monotonic_wall_time=os.clock,Config={},
    UIManager={scheduleIn=function(_,_,task) scheduled=task end,unschedule=function() end},
    logger={warn=function() end,info=function() end,dbg=function() end}}, {__index=_G})
require('translation_test_support').load_plugin_methods(ROOT,{'_reader_translation_mode','_reader_translation_font_scale_value','_reader_adjust_translation_font_scale',
    '_reader_translation_profile',
    '_reader_translation_css','_apply_reader_translation_mode','_show_reader_translation_font_scale_panel',
    '_show_reader_translation_panel','_install_marks_getCssText_wrapper','_reader_typography_pending_value',
    '_reader_queue_typography','_reader_typography_apply_now'},env)
local saved={}
local events={}
local inspected=0
local plugin=setmetatable({ui={doc_settings={
    readSetting=function(_,key) return saved[key] end,
    saveSetting=function(_,key,value) saved[key]=value end},
    styletweak={getCssText=function() return '.user { color: black; }' end},
    rolling={xpointer='/body/DocFragment[1]/body/section/p[1]/text().0'},
    document={isXPointerInDocument=function() return true end},
    handleEvent=function(_,event) events[#events+1]=event end},
    _current_document_path=function() return 'book.epub' end,
    _reader_translation_profile=function() inspected=inspected+1; return profile(result) end,
    _annotation_mark_hide_css=function() return '.miu-inline-mark { text-decoration: none; }' end,
    toast=function() end}, {__index=Plugin})
plugin:_install_marks_getCssText_wrapper(plugin.ui.styletweak)
plugin.ui.styletweak:getCssText()
assert(inspected==0,'default book opening scans the entire EPUB')
assert(plugin:_apply_reader_translation_mode('translation'),'mode change failed')
local combined=plugin.ui.styletweak:getCssText()
assert(combined:find('.user',1,true) and combined:find('.miu-inline-mark',1,true) and combined:find('wr-translation',1,true),'CSS composition lost a layer')
assert(saved.miuread_translation_mode=='translation','mode was not saved in this book settings')
assert(saved.miuread_translation_font_scale==100,'default translation body size did not follow reader text size')
assert(events[1].name=='ApplyStyleSheet' and events[2].name=='GotoXPointer','native reflow / paired position restore missing')
plugin.ui.handleEvent=function() error('reflow failed') end
assert(plugin:_apply_reader_translation_mode('bilingual',130)==false and saved.miuread_translation_mode=='translation'
    and saved.miuread_translation_font_scale==100,'failed reflow did not roll back mode and translation size')
saved={}
assert(plugin:_reader_translation_mode()=='original','a fresh document inherited another book mode')
plugin.ui.handleEvent=function(_,event) events[#events+1]=event end
local font_size
plugin.ui.font={onSetFontSize=function(_,value) font_size=value end}
plugin._reader_native_setting_begin=function() end
plugin._mark_reader_busy=function() end
plugin._reader_typography_release_download_guard=function() end
plugin._reader_typography_apply=function(self,generation) return self:_reader_typography_apply_now(generation) end
plugin:_reader_queue_typography('font_size',24)
plugin:_reader_queue_typography('translation_mode','bilingual')
assert(plugin._reader_typography_pending.translation_mode=='bilingual','typography queue discarded the string display mode')
scheduled()
assert(font_size==24 and saved.miuread_translation_mode=='bilingual','font / translation batch did not apply both changes')

local before_events=#events
plugin:_reader_adjust_translation_font_scale(20)
assert(plugin:_reader_translation_font_scale_value()==120,'pending translation size was not reflected in controls')
scheduled()
assert(saved.miuread_translation_font_scale==120 and font_size==24,'translation resize changed the English body size')
assert(saved.miuread_translation_mode=='bilingual' and #events==before_events+1,'translation resize changed mode or reflowed twice')
assert(plugin.ui.styletweak:getCssText():find('font-size: 120% !important;',1,true),'translation resize did not reach the stylesheet')
local reopened=setmetatable({ui=plugin.ui,_reader_typography_pending_value=function() end},{__index=Plugin})
assert(reopened:_reader_translation_font_scale_value()==120,'reopened book lost its translation size')
assert(T.normalize_font_scale(nil)==100 and T.normalize_font_scale(-100)==80 and T.normalize_font_scale(999)==180)
local shown
env.ReaderSettingsDialog={show=function(opts) shown=opts end}
plugin:_show_reader_translation_panel(function() end)
local rows=shown.rows()
assert(rows[#rows].label=='译文正文大小' and rows[#rows].value=='120%' and rows[#rows].enabled)
rows[#rows].callback()
assert(shown.title=='译文正文大小' and shown.hero().value=='120%')
shown.hero().on_increase(); assert(shown.hero().value=='130%')
scheduled(); assert(saved.miuread_translation_font_scale==130)
shown.rows()[1].callback(); scheduled(); assert(saved.miuread_translation_font_scale==100)

-- Repeated native stylesheet requests reuse both parsing and CSS. A changed
-- file, ReaderUI document, display mode or scale must invalidate the cache.
local attr={size=100,modification=1}
env.lfs={attributes=function() return attr end}
local inspect_original,css_original=T.inspect,T.css
local inspections,styles=0,0
T.inspect=function() inspections=inspections+1; return profile(result) end
T.css=function(...) styles=styles+1; return css_original(...) end
local cache_settings={miuread_translation_mode='bilingual',miuread_translation_font_scale=100}
local cached_plugin=setmetatable({ui={document={},doc_settings={readSetting=function(_,key) return cache_settings[key] end}},
    _current_document_path=function() return 'cached.epub' end,
    _reader_typography_pending_value=function() end},{__index=Plugin})
local first=cached_plugin:_reader_translation_css()
assert(first==cached_plugin:_reader_translation_css() and inspections==1 and styles==1,
    'repeated stylesheet reads rebuilt chapter selectors')
cache_settings.miuread_translation_font_scale=120
assert(cached_plugin:_reader_translation_css()~=first and inspections==1 and styles==2)
cache_settings.miuread_translation_mode='original'
assert(cached_plugin:_reader_translation_css()~=first and inspections==1 and styles==3)
attr.modification=2; cached_plugin:_reader_translation_css()
assert(inspections==2 and styles==4,'changed EPUB kept stale translation CSS')
cached_plugin.ui.document={}; cached_plugin:_reader_translation_css()
assert(inspections==3 and styles==5,'new reader document kept stale translation CSS')
T.inspect,T.css=inspect_original,css_original

print('translation display: pairing, fallback, CSS composition, position mapping and persistence passed')
