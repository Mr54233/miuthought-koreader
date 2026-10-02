"""Exercise real generated EPUBs through LuaJIT, without a WeRead account.

Requires lupa (LuaJIT 2.1). Only the temporary test directory is written.
The EPUB builder, stored ZIP reader, validators and position migration are
production modules; JSON and lfs are adapted to the host Python runtime.
"""

import json
from pathlib import Path
import tempfile
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile

from lupa.luajit21 import LuaRuntime, lua_type


ROOT = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)


def from_lua(value):
    if lua_type(value) != "table":
        return value
    keys = list(value.keys())
    if keys and set(keys) == set(range(1, len(keys) + 1)):
        return [from_lua(value[index]) for index in range(1, len(keys) + 1)]
    return {key: from_lua(item) for key, item in value.items()}


def to_lua(value):
    if isinstance(value, (dict, list)):
        return lua.table_from(value, recursive=True)
    return value


lua.globals().json_encode = lambda value: json.dumps(from_lua(value), ensure_ascii=False, separators=(",", ":"))
lua.globals().json_decode = lambda value: to_lua(json.loads(value))
lua.execute("""
package.preload['json']=function() return {encode=json_encode,decode=json_decode} end
package.preload['logger']=function() return {info=function() end,warn=function() end,dbg=function() end} end
package.preload['util']=function() return {} end -- KOReader helpers outside the packaging path.
package.preload['miuread.http']=function() return {} end -- No network calls in these tests.
""")
lua.execute("package.path = " + repr((ROOT / "miuread.koplugin/?.lua").as_posix()) + " .. ';' .. package.path")
lua.execute("package.path = " + repr((ROOT / "tools/?.lua").as_posix()) + " .. ';' .. package.path")

with tempfile.TemporaryDirectory(prefix="miuread-translation-") as directory:
    work = Path(directory).resolve()

    def attributes(path, key=None):
        path = Path(path)
        if not path.exists():
            return None
        stat = path.stat()
        result = {"mode": "directory" if path.is_dir() else "file", "size": stat.st_size, "modification": stat.st_mtime}
        return result.get(key) if key else lua.table_from(result)

    def mkdir(path):
        path = Path(path).resolve()
        assert path == work or work in path.parents, "test write escaped temporary directory"
        path.mkdir(parents=True, exist_ok=True)
        return True

    lua.globals().host_attributes = attributes
    lua.globals().host_mkdir = mkdir
    lua.execute("""
package.preload['libs/libkoreader-lfs']=function()
    return {attributes=host_attributes,mkdir=host_mkdir,dir=function() return function() return nil end end}
end
""")
    lua.globals().work = work.as_posix()
    lua.globals().root = (ROOT / "miuread.koplugin").as_posix()
    lua.execute("""
local Epub=require('miuread.epub')
local Installer=require('miuread.epub_installer')
local Translation=require('miuread.translation')
local Json=require('miuread.json')
local U=require('miuread.util')
local body='<section><h1 id="title">Title</h1><p id="p1">One.</p><p id="p2">Two <em>words</em>.</p><p id="p3">Three.</p></section>'
local translated=body:gsub('(<h1 id="title">.-</h1>)','%1<h1 id="title" class="wr-translation">标题</h1>')
    :gsub('(<p id="(p%d)">.-</p>)',function(original,id) return original..'<p id="'..id..'" class="wr-translation">译文。</p>' end)
local book={bookId='CB_archive',title='Archive regression',author='Test'}
local meta={book_id=book.bookId,variant='clean',task_id='old',chapters={{uid='21'},{uid='22'}}}
local chapters={{uid='21',title='First',body=body},{uid='22',title='Second',body=translated}}
local css='.wr-translation { display: none !important; }'
Epub.build(work..'/old.epub',book,chapters,css,{},nil,meta)
chapters[1].body=translated; meta.task_id='new'
Epub.build(work..'/new.epub',book,chapters,css,{},nil,meta)
local valid=Installer.validate(work..'/new.epub',{book_id=book.bookId,variant='clean',chapters=meta.chapters})
assert(valid,'actual generated EPUB failed validation')
local old_profile=assert(Translation.inspect(work..'/old.epub'))
local new_profile=assert(Translation.inspect(work..'/new.epub'))
assert(old_profile.blocks==4 and new_profile.blocks==8 and new_profile.separable)
local before='/body/DocFragment[1]/body/section/p[2]/em/text().2'
local chinese='/body/DocFragment[2]/body/section/p[4]/text().1'
local settings={last_xpointer='/body/DocFragment[1]/body/section/p[1]/text().0',
    annotations={{pos0=before,pos1=before},{pos0=chinese,pos1=chinese,note='Existing Chinese note'}}}
local migrated=assert(Translation.rebase_settings(work..'/old.epub',work..'/new.epub',settings,'translation'))
assert(migrated.annotations[1].pos0=='/body/DocFragment[1]/body/section[1]/p[3]/em[1]/text().2')
assert(migrated.annotations[2].pos0==chinese and migrated.annotations[2].note=='Existing Chinese note')
assert(migrated.last_xpointer=='/body/DocFragment[1]/body/section[1]/p[2]')
assert(Translation.recover_settings(work..'/old.epub',migrated).annotations[1].pos0==before)
assert(Installer.install(work..'/new.epub',work..'/old.epub',{book_id=book.bookId,chapters=meta.chapters}))
assert(Translation.recover_settings(work..'/old.epub',migrated).annotations[1].pos0==migrated.annotations[1].pos0)
local calls=0
local ok,err=Installer.visit_chapter_text(work..'/old.epub',function() calls=calls+1; return nil,'stop' end)
assert(not ok and err=='stop' and calls==1,'visitor ignored its abort callback')

-- Readable legacy HTML must not prevent inspecting translations elsewhere.
-- Preserve notes on unchanged content; a changed original block must still
-- be rejected even when the reader can recover its unbalanced tags.
local legacy={{uid='21',body=body},{uid='22',body='<section><p id="legacy">Legacy paragraph</section>'}}
Epub.build(work..'/legacy-old.epub',book,legacy,css,{},nil,meta)
legacy[1].body=translated
Epub.build(work..'/legacy-new.epub',book,legacy,css,{},nil,meta)
assert(Translation.inspect(work..'/legacy-new.epub').blocks==4)
local legacy_xp='/body/DocFragment[2]/body/section/p[1]/text().2'
local legacy_notes={last_xpointer=legacy_xp,annotations={{pos0=legacy_xp,pos1=legacy_xp,note='Keep this note'}}}
local kept=assert(Translation.rebase_settings(work..'/legacy-old.epub',work..'/legacy-new.epub',legacy_notes,'translation'))
assert(kept.last_xpointer==legacy_xp and kept.annotations[1].pos0==legacy_xp and kept.annotations[1].note=='Keep this note')
legacy[2].body=legacy[2].body:gsub('Legacy paragraph','Changed paragraph')
Epub.build(work..'/legacy-changed.epub',book,legacy,css,{},nil,meta)
local unsafe,unsafe_reason=Translation.rebase_settings(work..'/legacy-old.epub',work..'/legacy-changed.epub',legacy_notes,'translation')
assert(not unsafe and unsafe_reason:find('translation_position_unverified',1,true),
    'reader tag recovery silently moved a note on changed source text')

-- The device reported expected=english, actual=chinese in chapter 5 while
-- refreshing chapter 4. Preserve the real custom elements and their content,
-- and pair only the outer, verified original/translation paragraphs.
local language_source='<section><p id="language">Original <English>text</Chinese> <em id="em">kept</em></p></section>'
local language_translated=language_source:gsub('</p>','</p><p id="language" class="wr-translation">译文 <English>文字</Chinese></p>')
local language_chapters={{uid='4',body=body},{uid='5',body=language_translated}}
local language_meta={book_id=book.bookId,variant='clean',task_id='language-old',chapters={{uid='4'},{uid='5'}}}
Epub.build(work..'/language-old.epub',book,language_chapters,css,{},nil,language_meta)
language_chapters[1].body=translated; language_meta.task_id='language-new'
Epub.build(work..'/language-new.epub',book,language_chapters,css,{},nil,language_meta)
local language_profile=assert(Translation.inspect(work..'/language-new.epub'))
assert(language_profile.blocks==5 and language_profile.separable and language_profile.recoveries==4)
local language_xp='/body/DocFragment[2]/body/section/p[1]/english[1]/em[1]/text().2'
local language_notes={last_xpointer=language_xp,annotations={{pos0=language_xp,pos1=language_xp,note='Inside custom tag'}}}
local language_kept=assert(Translation.rebase_settings(work..'/language-old.epub',work..'/language-new.epub',language_notes,'bilingual'))
assert(language_kept.last_xpointer==language_xp and language_kept.annotations[1].pos0==language_xp)
assert(language_kept.annotations[1].note=='Inside custom tag')
language_chapters[2].body=language_source
language_meta.task_id='language-source'
Epub.build(work..'/language-source.epub',book,language_chapters,css,{},nil,language_meta)
local language_rebased=assert(Translation.rebase_settings(work..'/language-source.epub',work..'/language-new.epub',language_notes,'translation'))
assert(language_rebased.annotations[1].pos0=='/body/DocFragment[2]/body/section[1]/p[1]/english[1]/em[1]/text().2',
    'adding a translated sibling shifted a note inside the original custom element')
assert(language_rebased.last_xpointer=='/body/DocFragment[2]/body/section[1]/p[2]')

-- Reproduce close -> sidecar migration -> atomic install -> reopen -> CSS
-- using the real plugin installer and real ZIPs. The old original has no ids;
-- the official translated response adds ids/attributes and translated siblings.
local bare_body='<section><p>First.</p><p>Keep <em>these words</em> &amp; offsets.</p></section>'
local bare_translation='<section><p id="a">First.</p><p id="a" class="wr-translation">第一段。</p>'
    ..'<p data-server="42" id="b">Keep <em class="server">these words</em> &#38; offsets.</p>'
    ..'<p id="b" class="wr-translation">保留文字。</p></section>'
local close_target=work..'/close-reopen.epub'
local close_pending=work..'/close-reopen.pending.epub'
local close_meta={book_id=book.bookId,variant='clean',task_id='close-original',chapters={{uid='4'}}}
Epub.build(close_target,book,{{uid='4',body=bare_body}},css,{},nil,close_meta)
close_meta.task_id='close-bilingual'
Epub.build(close_pending,book,{{uid='4',body=bare_translation}},css,{},nil,close_meta)
local sidecar={last_xpointer='/body/DocFragment[1]/body/section/p[2]/text().3',
    annotations={{pos0='/body/DocFragment[1]/body/section/p[2]/em/text().1',
        pos1='/body/DocFragment[1]/body/section/p[2]/em/text().5',note='Keep'}}}
package.preload['docsettings']=function() return {open=function(_,path)
    assert(path==close_target)
    return {data=U.copy(sidecar),flush=function(self,data)
        sidecar=U.copy(data or self.data); return 'sidecar'
    end}
end} end
local Plugin={}
local env=setmetatable({Plugin=Plugin,U=U,EpubInstaller=Installer,logger=require('logger')},{__index=_G})
require('translation_test_support').load_plugin_methods(root,
    {'_install_pending_record','_reader_translation_mode','_reader_translation_font_scale_value','_reader_translation_css',
    '_install_marks_getCssText_wrapper'},env)
local stored,removed
local plugin=setmetatable({store={save_variant=function(_,_,_,record) stored=record end,
    remove_pending_install=function() removed=true end}}, {__index=Plugin})
assert(plugin:_install_pending_record(book.bookId,'clean',nil,{file=close_target,pending_file=close_pending,
    pending_install=true,variant='clean',chapter_map=close_meta.chapters,translation_mode='bilingual'}))
assert(removed and stored.pending_file==nil and not sidecar.miuread_translation_pending_rebase)
assert(sidecar.last_xpointer=='/body/DocFragment[1]/body/section[1]/p[3]/text().3')
assert(sidecar.annotations[1].pos0=='/body/DocFragment[1]/body/section[1]/p[3]/em[1]/text().1')
assert(sidecar.annotations[1].note=='Keep' and sidecar.miuread_translation_mode=='bilingual')
local reopened=assert(Translation.inspect(close_target))
assert(reopened.blocks==2 and reopened.separable)
plugin.ui={doc_settings={readSetting=function(_,key) return sidecar[key] end},
    styletweak={getCssText=function() return css end},document={}}
plugin._current_document_path=function() return close_target end
plugin._reader_translation_profile=function() return reopened end
plugin._annotation_mark_hide_css=function() return nil end
plugin._reader_typography_pending_value=function() end
assert(plugin:_install_marks_getCssText_wrapper(plugin.ui.styletweak))
assert(plugin.ui.styletweak:getCssText():find('p.wr-translation { display: block !important; }',1,true),
    'reopen lost the bilingual stylesheet override')

-- Exercise Downloader:_save, rather than only Epub.build. The real sequence
-- includes resource pruning, old chapter preservation, package validation,
-- translation inspection and deferred installation for an open document.
local Downloader=require('miuread.downloader')
local U=require('miuread.util')
U.free_space=function() return nil end -- df is a device API, not a Windows test dependency.
local target=work..'/open-book.epub'
meta.task_id='open-original'
chapters[1].body=body
Epub.build(target,book,chapters,css,{},nil,meta)
local original_bytes=assert(U.read_file(target,true))
local store={}
function store:epub_root() return work end
function store:epub_path(name) return work..'/'..name end
function store:variant() return {file=target,chapter_map=meta.chapters,variant='clean'} end
function store:save_variant(_,_,record) self.saved=record end
function store:save_book() end
local downloader=Downloader:new(nil,nil,nil,store,{})
local on_disk={}
for index,chapter in ipairs(chapters) do
    local path=work..'/source-'..index..'.xhtml'
    assert(U.atomic_write(path,translated,true))
    on_disk[index]={uid=chapter.uid,title=chapter.title,body_path=path}
end
local opt={generate_translation_uid='21',translation_mode='translation',active_document_path=target,
    expected_chapter_count=2,download_run_id='save-good'}
local saved=downloader:_save(book,on_disk,{},css,nil,U.copy(opt),{})
assert(saved.pending_install and saved.file==target and U.file_exists(saved.pending_file))
assert(Installer.validate(saved.pending_file,{book_id=book.bookId,chapters=meta.chapters}))
assert(Translation.inspect(saved.pending_file).blocks==8)
assert(U.read_file(target,true)==original_bytes,'open EPUB was replaced during a translation download')

assert(U.atomic_write(on_disk[2].body_path,language_translated,true))
local recovery_opt=U.copy(opt); recovery_opt.download_run_id='reader-recovery'
local recovered_save=downloader:_save(book,on_disk,{},css,nil,recovery_opt,{})
assert(recovered_save.pending_install and Translation.inspect(recovered_save.pending_file).blocks==5,
    'a next chapter with recoverable language markup prevented staging current translations')
assert(U.read_file(target,true)==original_bytes,'recoverable next chapter replaced the active EPUB before installation')
assert(U.atomic_write(on_disk[2].body_path,translated,true))

for _,case in ipairs({
    {name='chapters',options={previous_chapter_map={{uid='missing-old-chapter'}}},reason='新 EPUB 缺少旧版本章节：missing-old-chapter'},
    {name='images',options={image_summary={required_missing=2}},reason='EPUB 仍有 2 个必需正文图片资源缺失'},
}) do
    local failed_opt=U.copy(opt)
    for key,value in pairs(case.options) do failed_opt[key]=value end
    failed_opt.download_run_id='save-failed-'..case.name
    store.saved=nil
    local passed,reason=pcall(downloader._save,downloader,book,on_disk,{},css,nil,failed_opt,{})
    assert(not passed and tostring(reason):find(case.reason,1,true),'specific validation reason was lost')
    assert(tostring(reason):find('[MiuReadEpubValidation]',1,true) and tostring(reason):find('未覆盖原文件',1,true))
    assert(U.first_line(reason):find(case.reason,1,true),'reader popup would truncate the useful validation reason')
    assert(U.read_file(target,true)==original_bytes and not store.saved,'failed EPUB changed the original or its record')
    assert(not U.file_exists(target:gsub('%.epub$','')..'.miuread-new-'..failed_opt.download_run_id..'.epub'),
        'invalid temporary EPUB was not removed')
    failed_opt.generate_translation_uid=nil
    passed,reason=pcall(downloader._save,downloader,book,on_disk,{},css,nil,failed_opt,{})
    assert(not passed and tostring(reason):find('书籍内容验证未通过，未覆盖原文件。 [MiuReadEpubValidation]',1,true),
        'ordinary download validation changed its existing error message')
    assert(U.read_file(target,true)==original_bytes and not store.saved,'ordinary validation failure changed the original')
end

local empty_refresh=U.copy(on_disk)
empty_refresh[1].structural=true
local failed_opt=U.copy(opt); failed_opt.download_run_id='empty-current'
local passed,reason=pcall(downloader._save,downloader,book,empty_refresh,{},css,nil,failed_opt,{})
assert(not passed and tostring(reason):find('新 EPUB 缺少旧版本章节：21',1,true),
    'existing current chapter was allowed to become a structural page')
assert(U.read_file(target,true)==original_bytes,'current chapter preservation guard replaced the original')

assert(U.atomic_write(on_disk[2].body_path,'<section><p class="wr-translation>Broken attribute</p></section>',true))
failed_opt.download_run_id='malformed-translation'
passed,reason=pcall(downloader._save,downloader,book,on_disk,{},css,nil,failed_opt,{})
assert(not passed and tostring(reason):find('译文章节解析未通过：chapter=22 unterminated_tag',1,true),
    'translation parse failure was misreported as unavailable translated text')
assert(U.read_file(target,true)==original_bytes,'malformed translated chapter replaced the original')
""")
    with ZipFile(work / "old.epub") as archive:
        assert archive.testzip() is None
        entries = {name: archive.read(name) for name in archive.namelist()}
    for name, replacement, method, expected in (
        ("compressed", entries["OEBPS/text/chapter-0001.xhtml"], ZIP_DEFLATED, None),
        ("oversize", b"<html><body>" + b"x" * (2 * 1024 * 1024) + b"</body></html>", ZIP_STORED, "translation_inspection_size_limit"),
    ):
        path = work / (name + ".epub")
        with ZipFile(path, "w") as archive:
            for entry, data in entries.items():
                chapter = entry == "OEBPS/text/chapter-0001.xhtml"
                archive.writestr(entry, replacement if chapter else data, compress_type=method if chapter else ZIP_STORED)
        lua.globals().candidate = path.as_posix()
        ok, error = lua.eval("function() return require('miuread.epub_installer').visit_chapter_text(candidate,function() return true end) end")()
        assert ok is None and error, f"{name} chapter unexpectedly accepted"
        if expected:
            assert error == expected

print("Real EPUB regression: downloader packaging, detailed validation failures, original preservation, translation inspection, annotation migration, atomic install and reader limits passed")
