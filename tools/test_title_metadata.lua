-- beta.26 metadata parser regression checks against shipped implementation text.
local src=assert(io.open('miuread.koplugin/miuread/local_metadata.lua','rb')):read('*a')
assert(src:find('METADATA_EXTRACTOR_VERSION = 6',1,true),'extractor version bumped')
assert(src:find('decode_numeric_entities',1,true),'numeric entities supported')
assert(src:find('strip_cdata',1,true),'CDATA supported')
assert(src:find('local function xml_text',1,true),'identity fields use XML text')
assert(src:find('book.in_account_shelf==true',1,true),'account identity protected')
assert(src:find('protected_title',1,true) and src:find('read_miuread_manifest',1,true),'MiuRead manifest protection retained')
print('title metadata: PASS')
