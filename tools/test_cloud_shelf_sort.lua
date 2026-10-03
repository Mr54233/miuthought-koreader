-- Static contract for 5.9 cloud-order default.
local f=assert(io.open("miuread.koplugin/miuread/unified_library.lua","rb")); local s=f:read("*a"); f:close()
assert(s:find('cloud="云端顺序"',1,true),"cloud label")
assert(s:find('if sort == "cloud" then',1,true),"cloud comparator")
local m=assert(io.open("miuread.koplugin/main.lua","rb")); local x=m:read("*a"); m:close()
assert(x:find('sort=section=="shelf" and "cloud" or "recent"',1,true),"shelf defaults cloud")
print("cloud shelf sort: PASS")
