local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local FONT_CSS_CACHE_LIMIT = 8
local font_css_cache = {}
local font_css_cache_order = {}

local function screen_ratios()
    return 0.91, 0.60
end

local function safe_margins()
    local w, h = Screen:getWidth(), Screen:getHeight()
    local side = math.max(Screen:scaleBySize(6), math.floor(w * 0.02))
    local vertical = math.max(Screen:scaleBySize(8), math.floor(h * 0.03))
    return side, vertical
end

local function dirty_region(widget, dimen)
    if not dimen then return end
    UIManager:setDirty(widget, function()
        return "partial", dimen
    end)
end

local function contains(dimen, pos)
    return dimen and pos and dimen:contains(pos)
end

local Popup = InputContainer:extend{
    html = nil,
    source_html = nil,
    font_size = Screen:scaleBySize(19),
    font_name = nil,
    width_ratio = nil,
    height_ratio = nil,
    css = "",
    metrics = nil,
    dialog = nil,
    on_close_callback = nil,
    closing = false,
    close_dimen = nil,
    close_hit_dimen = nil,
}

local function css_string(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\"):gsub("'", "\\'")
    return value
end

local function cache_font_css(key, value)
    if font_css_cache[key] == nil then
        font_css_cache_order[#font_css_cache_order + 1] = key
        if #font_css_cache_order > FONT_CSS_CACHE_LIMIT then
            local expired = table.remove(font_css_cache_order, 1)
            font_css_cache[expired] = nil
        end
    end
    font_css_cache[key] = value
    return value
end

local function can_embed_font(path, face_index)
    local ext = tostring(path or ""):lower():match("%.([%w]+)$")
    if ext == "ttf" or ext == "otf" then return true end
    if ext == "ttc" or ext == "otc" then
        local index = tonumber(face_index)
        return index == nil or index == 0
    end
    return false
end

function Popup:_book_font_css()
    local font_name = tostring(self.font_name or ""):match("^%s*(.-)%s*$")
    if font_name == "" then return "" end
    if font_css_cache[font_name] ~= nil then return font_css_cache[font_name] end

    local escaped_name = css_string(font_name)
    local ok, cre = pcall(function()
        return require("document/credocument"):engineInit()
    end)
    if not ok or not cre or type(cre.getFontFaceFilenameAndFaceIndex) ~= "function" then
        return cache_font_css(
            font_name,
            string.format("@page{font-family:'%s'} html,body{font-family:'%s'!important}", escaped_name, escaped_name)
        )
    end

    -- The popup CSS uses normal weight and style throughout. Resolving four
    -- font variants made the first popup noticeably slower on older Kindles,
    -- so only the regular face is embedded. The book font is still preserved.
    local family = "MiuReadBookFont"
    local got, font_path, face_index = pcall(
        cre.getFontFaceFilenameAndFaceIndex,
        font_name, false, false
    )
    local css
    if got and type(font_path) == "string" and font_path ~= "" and can_embed_font(font_path, face_index) then
        css = string.format(
            "@font-face{font-family:'%s';src:url('%s')}\n@page{font-family:'%s','%s'} html,body{font-family:'%s','%s'!important}",
            family, css_string(font_path), family, escaped_name, family, escaped_name
        )
    else
        css = string.format(
            "@page{font-family:'%s'} html,body{font-family:'%s'!important}",
            escaped_name, escaped_name
        )
    end
    return cache_font_css(font_name, css)
end

function Popup:init()
    self.html = tostring(self.html or "")
    self.source_html = tostring(self.source_html or "")
    if self.html == "" then self.html = "<p>没有想法内容</p>" end

    local font_css = self:_book_font_css()
    if font_css ~= "" then
        self.css = font_css .. "\n" .. tostring(self.css or "")
    end

    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local auto_w, auto_h = screen_ratios()
    local width_ratio = math.max(0.86, math.min(0.92, tonumber(self.width_ratio) or auto_w))
    local height_ratio = math.max(0.48, math.min(0.64, tonumber(self.height_ratio) or auto_h))
    local side_margin, vertical_margin = safe_margins()

    self.width = math.min(math.floor(screen_w * width_ratio), screen_w - side_margin * 2)
    self.max_height = math.min(
        math.floor(screen_h * height_ratio),
        screen_h - vertical_margin * 2
    )
    self.dialog = self
    self.closing = false

    if Device:isTouchDevice() then
        self.ges_events = {
            TapPage = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{x=0, y=0, w=screen_w, h=screen_h},
                },
            },
        }
    end

    if Device:hasKeys() then
        local group = Device.input.group or {}
        self.key_events = { Close = { { group.Back } } }
        local previous = group.PgBack or group.PageBack or group.PageBackward or group.Left
        local following = group.PgFwd or group.PageForward or group.PageNext or group.Right
        if previous then self.key_events.ScrollUp = { { previous } } end
        if following then self.key_events.ScrollDown = { { following } } end
    end

    self:_build()
end

function Popup:_free_widgets()
    if self.sourcewidget then pcall(function() self.sourcewidget:free() end) end
    if self.htmlwidget then pcall(function() self.htmlwidget:free() end) end
    if self.close_button then pcall(function() self.close_button:free() end) end
    self.sourcewidget = nil
    self.htmlwidget = nil
    self.close_button = nil
end

function Popup:_new_html_widget(width, height, html, scrollable)
    return ScrollHtmlWidget:new{
        html_body = tostring(html or ""),
        is_xhtml = true,
        css = self.css or "",
        default_font_size = self.font_size,
        width = width,
        height = height,
        scroll_bar_width = scrollable == false and 1 or math.max(1, Screen:scaleBySize(2)),
        text_scroll_span = scrollable == false and 1 or math.max(1, Screen:scaleBySize(1)),
        dialog = self,
    }
end

function Popup:_comments_height(width, max_height, minimum)
    local metrics = type(self.metrics) == "table" and self.metrics or {}
    local count = math.max(0, tonumber(metrics.comment_count) or 0)
    local units = type(metrics.comment_units) == "table" and metrics.comment_units or {}
    local chars = type(metrics.comment_chars) == "table" and metrics.comment_chars or {}

    -- Estimate the final height from the same em values used by popup_css().
    -- This avoids creating a full MuPDF widget only to measure and recreate it.
    -- A slight overestimate is intentional: underestimated content remains
    -- scrollable, while the maximum height is still capped at the user setting.
    local content_font = math.max(1, self.font_size * 0.80)
    local usable_width = math.max(content_font * 7, width - self.font_size * 0.62 - Screen:scaleBySize(5))
    local units_per_line = math.max(7, usable_width / content_font)
    local estimated = self.font_size * 0.38 -- body top and bottom padding

    if self.source_html == "" then
        estimated = estimated + self.font_size * 0.72 -- comments heading
    end

    if count == 0 then
        estimated = estimated + self.font_size * 1.65
    else
        for i = 1, count do
            local item_units = tonumber(units[i]) or tonumber(chars[i]) or 1
            local lines = math.max(1, math.ceil(item_units / units_per_line - 0.001))
            estimated = estimated
                + self.font_size * 0.54 -- author and like row
                + lines * content_font * 1.20
                + self.font_size * 0.35 -- comment padding and content margin
            if i > 1 then estimated = estimated + self.font_size * 0.31 end
            if estimated >= max_height then return max_height end
        end
    end

    estimated = estimated + math.max(Screen:scaleBySize(4), self.font_size * 0.10)
    return math.max(minimum, math.min(max_height, math.ceil(estimated)))
end


function Popup:_source_height(width, max_height)
    local metrics = type(self.metrics) == "table" and self.metrics or {}
    local source_units = tonumber(metrics.source_units)
        or tonumber(metrics.source_chars)
        or 1

    -- The source text is rendered at .68em. Account for the HTML body and
    -- source-box horizontal padding, then estimate the actual wrapped lines.
    local source_font = math.max(1, self.font_size * 0.68)
    local horizontal_padding = self.font_size * (0.52 + 0.46) + Screen:scaleBySize(4)
    local usable_width = math.max(source_font * 6, width - horizontal_padding)
    local units_per_line = math.max(6, usable_width / source_font)
    local lines = math.max(1, math.min(3, math.ceil(source_units / units_per_line - 0.001)))

    -- Mirrors popup_css(): body vertical padding, panel heading, source-box
    -- padding/border and the real number of source lines. A small safety pad
    -- avoids clipping from font rounding without leaving a blank viewport.
    local body_padding = self.font_size * (0.18 + 0.20)
    local heading_height = self.font_size * (0.52 * 1.02 + 0.16)
    local source_lines = lines * self.font_size * 0.68 * 1.15
    local box_padding = self.font_size * (0.17 * 2) + 2
    local safety = math.max(2, Screen:scaleBySize(3))
    local estimated = math.ceil(body_padding + heading_height + source_lines + box_padding + safety)

    return math.max(Screen:scaleBySize(38), math.min(max_height, estimated))
end

function Popup:_build()
    self:_free_widgets()

    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local border = math.max(1, tonumber(Size.border.window) or 1)
    local padding = math.max(4, Screen:scaleBySize(4))
    local close_size = math.max(Screen:scaleBySize(18), math.floor(self.font_size * 0.62))
    local close_inset = math.max(4, Screen:scaleBySize(5))
    local inner_w = self.width - padding * 2 - border * 2
    local max_inner_h = self.max_height - padding * 2 - border * 2
    local gap = 0
    local source_h = 0

    if self.source_html ~= "" then
        local minimum_comments = math.max(Screen:scaleBySize(58), math.floor(self.font_size * 2.7))
        gap = math.max(2, Screen:scaleBySize(3))
        local source_max = math.max(
            Screen:scaleBySize(38),
            max_inner_h - minimum_comments - gap
        )
        source_h = self:_source_height(inner_w, source_max)
        self.sourcewidget = self:_new_html_widget(
            inner_w,
            source_h,
            self.source_html,
            false
        )
    end

    local comments_max_h = math.max(
        math.max(Screen:scaleBySize(58), math.floor(self.font_size * 2.7)),
        max_inner_h - source_h - gap
    )
    local comments_min_h = math.min(
        comments_max_h,
        math.max(Screen:scaleBySize(58), math.floor(self.font_size * 2.7))
    )
    self.comments_height = self:_comments_height(
        inner_w,
        comments_max_h,
        comments_min_h
    )
    self.htmlwidget = self:_new_html_widget(
        inner_w,
        self.comments_height,
        self.html,
        true
    )

    local body_content
    if self.sourcewidget then
        body_content = VerticalGroup:new{
            align = "left",
            self.sourcewidget,
            VerticalSpan:new{width=gap},
            self.htmlwidget,
        }
    else
        body_content = self.htmlwidget
    end

    local inner_h = source_h + gap + self.comments_height
    self.height = inner_h + padding * 2 + border * 2
    self.popup_dimen = Geom:new{
        x = math.floor((screen_w - self.width) / 2),
        y = math.floor((screen_h - self.height) / 2),
        w = self.width,
        h = self.height,
    }

    local body_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = border,
        margin = 0,
        padding = padding,
        body_content,
    }

    self.close_button = Button:new{
        text = "×",
        width = close_size,
        height = close_size,
        margin = 0,
        padding = 0,
        bordersize = 0,
        text_font_face = "cfont",
        text_font_size = math.max(13, math.floor(self.font_size * 0.50)),
        text_font_bold = true,
        show_parent = self,
        callback = function() self:_request_close() end,
    }
    self.close_button.overlap_offset = {
        self.width - close_size - border - close_inset,
        border + close_inset,
    }

    self.close_dimen = Geom:new{
        x = self.popup_dimen.x + self.width - close_size - border - close_inset,
        y = self.popup_dimen.y + border + close_inset,
        w = close_size,
        h = close_size,
    }

    local hit_pad = Screen:scaleBySize(8)
    self.close_hit_dimen = Geom:new{
        x = math.max(self.popup_dimen.x, self.close_dimen.x - hit_pad),
        y = math.max(self.popup_dimen.y, self.close_dimen.y - hit_pad),
        w = math.min(self.popup_dimen.x + self.popup_dimen.w, self.close_dimen.x + self.close_dimen.w + hit_pad)
            - math.max(self.popup_dimen.x, self.close_dimen.x - hit_pad),
        h = math.min(self.popup_dimen.y + self.popup_dimen.h, self.close_dimen.y + self.close_dimen.h + hit_pad)
            - math.max(self.popup_dimen.y, self.close_dimen.y - hit_pad),
    }

    self.container = OverlapGroup:new{
        dimen = Geom:new{w=self.width, h=self.height},
        allow_mirroring = false,
        body_frame,
        self.close_button,
    }
    self.container.overlap_offset = {self.popup_dimen.x, self.popup_dimen.y}
    self[1] = OverlapGroup:new{
        dimen = Screen:getSize(),
        allow_mirroring = false,
        self.container,
    }
end

function Popup:onShow()
    dirty_region(self, self.popup_dimen)
end

function Popup:onCloseWidget()
    local old_dimen = self.popup_dimen and self.popup_dimen:copy() or nil
    self.closing = true
    self:_free_widgets()
    if self.on_close_callback then
        local callback = self.on_close_callback
        self.on_close_callback = nil
        pcall(callback)
    end
    dirty_region(nil, old_dimen)
end

function Popup:_request_close()
    if self.closing then return true end
    self.closing = true
    UIManager:close(self)
    return true
end

function Popup:_tap_hits_close(pos)
    return contains(self.close_button and self.close_button.dimen, pos)
        or contains(self.close_dimen, pos)
        or contains(self.close_hit_dimen, pos)
end

function Popup:handleEvent(event)
    if not self.closing and event and event.handler == "onGesture" then
        local ges = event.args and event.args[1]
        if ges and ges.ges == "tap" and self:_tap_hits_close(ges.pos) then
            return self:_request_close()
        end
    end
    return InputContainer.handleEvent(self, event)
end

function Popup:onClose() return self:_request_close() end

function Popup:onScrollDown()
    if self.closing or not self.htmlwidget then return true end
    self.htmlwidget:onScrollDown()
    return true
end

function Popup:onScrollUp()
    if self.closing or not self.htmlwidget then return true end
    self.htmlwidget:onScrollUp()
    return true
end

function Popup:onTapPage(_, ges)
    if self.closing then return true end
    local pos = ges and ges.pos
    if not pos then return true end

    if self:_tap_hits_close(pos) then
        return self:_request_close()
    end

    if not self.popup_dimen or pos:notIntersectWith(self.popup_dimen) then
        return self:_request_close()
    end

    return true
end

local M = {}

function M.show(opts)
    opts = opts or {}
    return UIManager:show(Popup:new{
        html = opts.html,
        source_html = opts.source_html,
        font_size = opts.font_size,
        font_name = opts.font_name,
        width_ratio = opts.width_ratio,
        height_ratio = opts.height_ratio,
        css = opts.css or "",
        metrics = opts.metrics,
        on_close_callback = opts.on_close,
    })
end

return M
