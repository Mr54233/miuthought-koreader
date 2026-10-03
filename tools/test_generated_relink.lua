-- beta.26 generated-book relink is reachable from manual Home refresh.
local main=assert(io.open('miuread.koplugin/main.lua','rb')):read('*a')
local store=assert(io.open('miuread.koplugin/miuread/store.lua','rb')):read('*a')
assert(main:find('function Plugin:_home_relink_generated_files',1,true),'relink dispatcher exists')
assert(main:find('self:_home_relink_generated_files(true)',1,true),'manual refresh invokes relink')
assert(store:find('function Store:orphan_miuread_files',1,true),'orphan candidate scan exists')
assert(store:find('self:file_record_fast(path,false)',1,true),'candidate scan is cheap before unzip')
assert(main:find('UIManager:scheduleIn(.04,step)',1,true),'relink is incremental rather than a blocking loop')
print('generated relink: PASS')
