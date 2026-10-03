-- beta.26 regression: setClipboardText is a plain function, never a method.
local main=assert(io.open('miuread.koplugin/main.lua','rb')):read('*a')
local excerpt=assert(io.open('miuread.koplugin/miuread/book_excerpt_dialog.lua','rb')):read('*a')
assert(main:find('pcall%(Device%.input%.setClipboardText,text%)'),'thought clipboard must pass text only')
assert(not main:find('setClipboardText,Device%.input,text'),'thought clipboard must not pass Device.input')
assert(excerpt:find('setClipboardText, clean_text%(self%.context%.text%)'),'excerpt clipboard must pass text only')
assert(not excerpt:find('setClipboardText, Device%.input'),'excerpt clipboard must not pass Device.input')
print('clipboard: PASS')
