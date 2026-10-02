"""Check translation CSS after EPUB fragment import, including the Issue #79 bug.

Requires lupa (LuaJIT 2.1), lxml, tinycss2 and cssselect2. An optional EPUB
argument checks cached device chapters as well. All source files are read-only.
This models CRE's fragment-aware #id matching; it is not a Kindle render test.
"""

from pathlib import Path
import re
import sys
from zipfile import ZipFile

import cssselect2
from lxml import etree, html as html_parser
from lupa.luajit21 import LuaRuntime
import tinycss2


ROOT = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("package.path = " + repr((ROOT / "miuread.koplugin/?.lua").as_posix()) + " .. ';' .. package.path")
translation = lua.eval("require('miuread.translation')")


class FragmentAwareElement(cssselect2.ElementWrapper):
    @property
    def id(self):
        value = self.etree_element.get("id", "")
        # lvtinydom.cpp converts id -> "_doc_fragment_N_ source-id".
        # lvstsheet.cpp's cssrt_id recovers it; cssrt_attreq in older CRE
        # compares the complete attribute instead. Leave the actual DOM
        # attribute untouched so [id="source-id"] still fails as on device.
        # https://github.com/koreader/crengine/blob/60a5fbc1531f76a47c54699d487390e2e2cb1c14/crengine/src/lvstsheet.cpp#L5750-L5771
        match = re.match(r"^_doc_fragment_\d+_ (.*)$", value)
        return match.group(1) if match else value


def make_profile(chapters):
    profile = lua.table_from({"blocks": 0, "separable": True})
    analyzed = []
    for index, html in enumerate(chapters, 1):
        result = translation.analyze(html, str(index), index)
        assert result is not None and not isinstance(result, tuple)
        analyzed.append(result)
        profile.blocks += result.blocks
        if result.blocks and not result.separable:
            profile.separable = False
    profile.chapters = lua.table_from(analyzed)
    return profile


def imported_dom(chapters, recover_html=False):
    merged = etree.Element("body")
    for index, html in enumerate(chapters):
        encoded = html.encode("utf-8")
        document = html_parser.document_fromstring(encoded, parser=html_parser.HTMLParser(encoding="utf-8")) if recover_html else etree.fromstring(encoded)
        # Namespaces are not part of CRE's HTML element selector names.
        for node in document.iter():
            if isinstance(node.tag, str):
                node.tag = etree.QName(node).localname
                if node.get("id") is not None:
                    node.set("id", f"_doc_fragment_{index}_ " + node.get("id"))
        fragment = etree.SubElement(merged, "DocFragment")
        fragment.append(document.find("body"))
    return merged


def visible(css, dom):
    matcher = cssselect2.Matcher()
    # WeRead's embedded stylesheet hides translations by default.
    stylesheet = ".wr-translation { display: none !important; }\n" + css
    for rule in tinycss2.parse_stylesheet(stylesheet, skip_comments=True, skip_whitespace=True):
        assert rule.type == "qualified-rule"
        declarations = [item for item in tinycss2.parse_declaration_list(rule.content)
                        if item.type == "declaration" and item.lower_name == "display"]
        for selector in cssselect2.compile_selector_list(rule.prelude):
            matcher.add_selector(selector, declarations)
    nodes, hidden = [], set()
    for node in FragmentAwareElement.from_html_root(dom).iter_subtree():
        display, priority = "block", (-1, (0, 0, 0), -1)
        for specificity, order, pseudo, declarations in matcher.match(node):
            assert pseudo is None
            for declaration in declarations:
                weight = (int(declaration.important), specificity, order)
                if weight >= priority:
                    priority = weight
                    display = tinycss2.serialize(declaration.value).strip()
        if display == "none" or (node.parent is not None and node.parent.etree_element in hidden):
            hidden.add(node.etree_element)
        else:
            nodes.append(node)
    return nodes


def font_sizes(stylesheet, dom, reader_size):
    """Model CRE's inheritance and rem base (the reader's default font size)."""
    matcher = cssselect2.Matcher()
    for rule in tinycss2.parse_stylesheet(stylesheet, skip_comments=True, skip_whitespace=True):
        if rule.type != "qualified-rule":
            continue
        declarations = [item for item in tinycss2.parse_declaration_list(rule.content)
                        if item.type == "declaration" and item.lower_name == "font-size"]
        for selector in cssselect2.compile_selector_list(rule.prelude):
            matcher.add_selector(selector, declarations)
    sizes = {}
    for node in FragmentAwareElement.from_html_root(dom).iter_subtree():
        parent_size = sizes[node.parent.etree_element] if node.parent is not None else reader_size
        size, priority = parent_size, (-1, (0, 0, 0), -1)
        candidates = []
        for specificity, order, pseudo, declarations in matcher.match(node):
            for declaration in declarations:
                candidates.append(((int(declaration.important), (0,) + specificity, order), declaration))
        for order, declaration in enumerate(tinycss2.parse_declaration_list(node.etree_element.get("style", ""))):
            if declaration.type == "declaration" and declaration.lower_name == "font-size":
                candidates.append(((int(declaration.important), (1, 0, 0, 0), order), declaration))
        for weight, declaration in candidates:
            if weight >= priority:
                priority = weight
                value = tinycss2.serialize(declaration.value).strip()
                if value.endswith("%"):
                    size = parent_size * float(value[:-1]) / 100
                elif value.endswith("rem"):
                    # lvrend.cpp lengthToPx(css_val_rem) uses getDefaultFont(),
                    # rather than the embedded html { font-size:16px } value.
                    size = reader_size * float(value[:-3])
                elif value.endswith("em"):
                    size = parent_size * float(value[:-2])
                elif value.endswith("px"):
                    size = float(value[:-2])
                else:
                    assert value == "inherit", value
                    size = parent_size
        sizes[node.etree_element] = size
    return sizes


def verify(chapters, expected, recover_html=False):
    profile = make_profile(chapters)
    assert profile.separable
    dom = imported_dom(chapters, recover_html)
    for mode in ("original", "bilingual", "translation"):
        nodes = visible(translation.css(profile, mode), dom)
        originals = sum(bool(node.etree_element.get("id")) and "wr-translation" not in node.classes
                        for node in nodes)
        translated = sum("wr-translation" in node.classes for node in nodes)
        assert (originals, translated) == expected[mode], (mode, originals, translated)
    # Reproduce the old bug on the same imported DOM before checking the fix:
    # original-ID equality loses every hide rule, but classes still show Chinese.
    old_css = re.sub(r"#([A-Za-z_][A-Za-z0-9_-]*)", r'[id="\1"]', translation.css(profile, "translation"))
    assert sum(bool(node.etree_element.get("id")) and "wr-translation" not in node.classes
               for node in visible(old_css, dom)) > expected["translation"][0]


def chapter(uid, body):
    return f'<html><head/><body data-miuread-chapter="{uid}"><section>{body}</section></body></html>'


chapters = [chapter(uid, '<h1 id="title">Title</h1><h1 id="title" class="wr-translation">Heading translation</h1>'
                          '<p id="p1">Original</p><p id="p1" class="extra wr-translation">Translation</p>'
                          '<p id="keep">No translation yet</p>'
                          '<p id="empty">Empty placeholder</p><p id="empty" class="wr-translation">&#160;</p>')
            for uid in ("1", "2")]
verify(chapters, {"original": (8, 0), "bilingual": (8, 6), "translation": (4, 6)})

# Reproduce shrunken translated body text, including a server id selector.
# Reader-controlled percentages follow later reader font changes; headings,
# English paragraphs and chapters outside the inspected scope retain their size.
size_dom = imported_dom(chapters + [chapter("99", '<p id="p1" class="wr-translation">Outside</p>')])
server_sizes = ('h1 { font-size: 200%; } p { font-size: 100%; } '
                'p.wr-translation { font-size: 70% !important; } '
                '#p1.wr-translation { font-size: 70% !important; }')
small = font_sizes(server_sizes, size_dom, 24)
first_body = size_dom[0].find("body")
translated_p = first_body.find("section/p[@class='extra wr-translation']")
assert abs(small[translated_p] - 16.8) < 0.001
for mode in ("bilingual", "translation"):
    for scale, reader_size in ((100, 24), (120, 24), (120, 30)):
        css = translation.css(make_profile(chapters), mode, scale)
        sizes = font_sizes(server_sizes + css, size_dom, reader_size)
        assert abs(sizes[translated_p] - reader_size * scale / 100) < 0.001
        assert sizes[first_body.find("section/p")] == reader_size
        assert sizes[first_body.find("section/h1[@class='wr-translation']")] == reader_size * 2
        outside_p = size_dom[-1].find("body/section/p")
        assert abs(sizes[outside_p] - reader_size * 0.7) < 0.001
assert "font-size:" not in translation.css(make_profile(chapters), "original", 120)

# Reproduce the uploaded PDF-converted EPUB, including id-less paragraphs,
# duplicate heading ids, nested English spans and an unstyled Chinese block.
pdf_chapters = [chapter("4", '<p><span style="font-size:2.1rem">Title</span></p><p class="wr-translation">Title translation</p>'
                       '<p><span style="font-size:.88rem">Body words</span></p><p class="wr-translation">Body translation</p>'
                       '<p id="sub"><span style="font-size:1.58rem">Subtitle</span></p><p id="sub" class="wr-translation">Subtitle translation</p>')]
pdf_dom = imported_dom(pdf_chapters)
pdf_profile = make_profile(pdf_chapters)
assert not pdf_profile.separable  # Inferring sizes cannot justify hiding originals.
fixed_root = 'body[data-miuread-chapter="4"] { font-size:16px; }'
pdf_section = pdf_dom[0].find("body/section")
pdf_original = pdf_section[2][0]
pdf_translation = pdf_section[3]
before = font_sizes(fixed_root, pdf_dom, 30)
assert before[pdf_translation] == 16 and before[pdf_original] == 26.4
for scale in (100, 120):
    for reader_size in (24, 30):
        sizes = font_sizes(fixed_root + translation.css(pdf_profile, "bilingual", scale), pdf_dom, reader_size)
        assert abs(sizes[pdf_translation] - reader_size * .88 * scale / 100) < .001
        assert abs(sizes[pdf_original] - reader_size * .88) < .001
        assert abs(sizes[pdf_section[1]] - reader_size * 2.1 * scale / 100) < .001
        assert abs(sizes[pdf_section[5]] - reader_size * 1.58 * scale / 100) < .001
assert "rem !important" not in translation.css(pdf_profile, "original", 120)

# Independently parse the device's reported mismatched language end tags as
# HTML, then verify actual CSS matching on that recovered DOM. The original
# and Chinese text must remain separate sibling paragraphs; hiding the source
# must also hide its nested custom-language element.
language_markup = [chapter("5", '<p id="language">Original <English>words</Chinese></p>'
                               '<p id="language" class="wr-translation">Translation <English>words</Chinese></p>'
                               '<p id="keep">Untranslated paragraph</p>')]
verify(language_markup, {"original": (2, 0), "bilingual": (2, 1), "translation": (1, 1)}, recover_html=True)
language_dom = imported_dom(language_markup, recover_html=True)
language_nodes = visible(translation.css(make_profile(language_markup), "translation"), language_dom)
assert not any(node.etree_element.text == "Original " for node in language_nodes)
assert len([node for node in language_nodes if node.etree_element.tag == "english"]) == 1

unusual = [chapter("3", '<div><p id="123">First</p><p id="123" class="wr-translation">First translation</p>'
                        '<p id="a&amp;&quot;&gt;">Second</p><p id="a&amp;&quot;&gt;" class="wr-translation">Second translation</p></div>')]
unusual_profile = make_profile(unusual)
assert unusual_profile.separable
assert len([node for node in visible(translation.css(unusual_profile, "translation"), imported_dom(unusual))
            if node.etree_element.get("id") and "wr-translation" not in node.classes]) == 0

# Scope isolation: a chapter outside the inspected profile remains original.
outside = chapters + [chapter("99", '<p id="p1">Outside</p><p id="p1" class="wr-translation">Outside translation</p>')]
outside_nodes = visible(translation.css(make_profile(chapters), "translation"), imported_dom(outside))
assert any(node.etree_element.text == "Outside" for node in outside_nodes)
assert not any(node.etree_element.text == "Outside translation" for node in outside_nodes)

if len(sys.argv) > 1:
    with ZipFile(sys.argv[1]) as archive:
        cached = []
        for index, name in enumerate(sorted(name for name in archive.namelist()
                                           if re.fullmatch(r"OEBPS/text/chapter-\d+\.xhtml", name)), 1):
            html = archive.read(name).decode("utf-8")
            # Local display-probe copies omit MiuRead identity. Reinstate a
            # chapter scope only in memory so their device text can be tested.
            if "data-miuread-chapter=" not in html:
                html = html.replace("<body>", f'<body data-miuread-chapter="{index}">', 1)
            cached.append(html)
    cached_profile = make_profile(cached)
    cached_dom = imported_dom(cached, recover_html=True)
    assert cached_profile.blocks > 0
    shown = visible(translation.css(cached_profile, "bilingual"), cached_dom)
    assert sum("wr-translation" in node.classes for node in shown) == cached_profile.blocks
    font_rules = sum(len(chapter.typography) for chapter in cached_profile.chapters.values())
    if font_rules:
        # The attached full book has the actual root/span mismatch. Verify all
        # inferred blocks under two reader sizes and two translation scales.
        fixed_roots = "\n".join(f'body[data-miuread-chapter="{chapter.chapter_uid}"] {{ font-size:16px; }}'
                                for chapter in cached_profile.chapters.values() if chapter.blocks)
        for scale in (100, 120):
            for reader_size in (24, 30):
                sizes = font_sizes(fixed_roots + translation.css(cached_profile, "bilingual", scale), cached_dom, reader_size)
                for chapter in cached_profile.chapters.values():
                    body = cached_dom[chapter.fragment_index - 1].find("body")
                    for pair in chapter.typography.values():
                        target = body
                        for tag, index in re.findall(r"/([\w-]+)\[(\d+)\]", pair.translation_path):
                            target = [child for child in target if child.tag == tag][int(index) - 1]
                        factor = 1 if re.fullmatch("h[1-6]", pair.tag) else scale / 100
                        assert abs(sizes[target] - reader_size * pair.font_rem * factor) < .002
    print(f"Attached EPUB: {len(cached)} chapters, {cached_profile.blocks} translated blocks, {font_rules} reader-relative font rules passed")

print("CSS regression: rewritten IDs, old-bug reproduction, untranslated paragraphs, unusual IDs and chapter isolation passed")
