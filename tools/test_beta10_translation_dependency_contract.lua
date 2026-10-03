local TOOL_DIR=tostring(arg and arg[0] or ''):gsub('\\','/'):match('^(.*)/[^/]+$') or '.'
local ROOT=TOOL_DIR..'/../miuread.koplugin/'
package.path=TOOL_DIR..'/?.lua;'..ROOT..'?.lua;'..package.path

-- translation.lua must stay loadable without the KOReader utility/runtime tree.
-- If a future change reintroduces a module-level miuread.util dependency, fail
-- before any translation behavior is exercised.
package.preload['miuread.util']=function()
    error('translation loaded miuread.util at module scope')
end

local current_book_id=' 123456789 '
package.preload['miuread.epub_installer']=function()
    return {
        visit_chapter_text=function(_,callback)
            local ok,err=callback(
                '<html><body data-miuread-chapter="1"><p>Plain text</p></body></html>',
                1,{uid='1'}
            )
            if not ok then return nil,err end
            return true,{book_id=current_book_id}
        end,
    }
end

local T=require('miuread.translation')
local profile,err=T.inspect('dummy.epub')
assert(profile and profile.book_id=='123456789',tostring(err))

current_book_id='   '
local missing,missing_err=T.inspect('dummy.epub')
assert(missing==nil and missing_err=='translation_book_identity_missing',tostring(missing_err))

print('beta10 translation dependency contract: PASS')
