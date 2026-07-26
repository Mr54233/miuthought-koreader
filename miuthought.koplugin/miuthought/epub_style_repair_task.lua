local FFIUtil = require("ffi/util")
local Json = require("miuthought.json")
local U = require("miuthought.util")
local UIManager = require("ui/uimanager")
local Device = require("device")
local logger = require("logger")

local EpubStyleRepairTask = {}
EpubStyleRepairTask.__index = EpubStyleRepairTask

local AnnotationStyle = require("miuthought.annotation_style")

local REPAIR_BEGIN = AnnotationStyle.MARKER_BEGIN
local REPAIR_END = AnnotationStyle.MARKER_END
local REPAIR_CSS = AnnotationStyle.CSS

local function clean_paths(paths)
    local out, seen = {}, {}
    for _, path in ipairs(paths or {}) do
        path = tostring(path or "")
        if path ~= "" and path:lower():match("%.epub$") and not seen[path] then
            seen[path] = true
            out[#out + 1] = path
        end
    end
    return out
end

local function os_ok(value)
    if value == true or value == 0 then return true end
    if type(value) == "number" then return value == 0 end
    return false
end

function EpubStyleRepairTask:new(store)
    return setmetatable({store = store, job = nil, poll_task = nil, standby_held = false}, self)
end

function EpubStyleRepairTask:available()
    return type(FFIUtil.runInSubProcess) == "function"
        and type(FFIUtil.isSubProcessDone) == "function"
end

function EpubStyleRepairTask:busy()
    return self.job ~= nil
end

function EpubStyleRepairTask:_reset_device_timeout()
    local powerd = Device and Device.powerd
    if powerd and type(powerd.resetT1Timeout) == "function" then
        pcall(powerd.resetT1Timeout, powerd)
    end
end

function EpubStyleRepairTask:_hold_awake()
    if self.standby_held then return end
    local ok = pcall(function() UIManager:preventStandby() end)
    if ok then self.standby_held = true; self:_reset_device_timeout() end
end

function EpubStyleRepairTask:_release_awake()
    if not self.standby_held then return end
    self.standby_held = false
    pcall(function() UIManager:allowStandby() end)
end

function EpubStyleRepairTask:_schedule()
    if self.poll_task then return end
    local task
    task = function()
        if self.poll_task ~= task then return end
        self.poll_task = nil
        self:_poll()
    end
    self.poll_task = task
    UIManager:scheduleIn(0.20, task)
end

function EpubStyleRepairTask:_finish(job, forced_error)
    local raw = U.read_file(job.result_path, true)
    local result
    if forced_error then
        result = {ok = false, error = forced_error, repaired = 0, skipped = 0, errors = {forced_error}}
    elseif not raw then
        result = {ok = false, error = "书籍修复进程异常退出", repaired = 0, skipped = 0, errors = {"书籍修复进程异常退出"}}
    else
        local ok, decoded = pcall(Json.decode, raw)
        result = ok and decoded or {ok = false, error = "书籍修复结果无法解析", repaired = 0, skipped = 0, errors = {"书籍修复结果无法解析"}}
    end
    os.remove(job.result_path)
    self.job = nil
    self:_release_awake()
    if job.on_done then job.on_done(result) end
end

function EpubStyleRepairTask:_poll()
    local job = self.job
    if not job then return end
    if not job.last_keepalive or os.time() - job.last_keepalive >= 5 then
        job.last_keepalive = os.time()
        self:_reset_device_timeout()
    end
    if os.time() - job.started_at > job.timeout then
        pcall(FFIUtil.terminateSubProcess, job.pid)
        self:_finish(job, "书籍修复超时")
        return
    end
    local ok, done = pcall(FFIUtil.isSubProcessDone, job.pid, false)
    if not ok then
        logger.warn("[MiuRead][EpubStyleRepair] poll failed", tostring(done))
        self:_schedule()
        return
    end
    if not done then
        self:_schedule()
        return
    end
    self:_finish(job)
end

function EpubStyleRepairTask:start(paths, on_done)
    if self.job then return false, "已有书籍修复任务正在运行" end
    if not self:available() then return false, "当前 KOReader 不支持后台修复" end
    paths = clean_paths(paths)
    if #paths == 0 then
        if on_done then on_done({ok = true, repaired = 0, skipped = 0, errors = {}}) end
        return true
    end

    local stamp = tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))
    local result_path = self.store.temp_dir .. "/epub-style-repair-" .. stamp .. ".json"
    local temp_root = self.store.temp_dir .. "/epub-style-repair-" .. stamp
    local child_paths = U.copy(paths)

    local child = function()
        local JsonChild = require("miuthought.json")
        local UChild = require("miuthought.util")
        local EpubChild = require("miuthought.epub")
        local AnnotationStyleChild = require("miuthought.annotation_style")
        local InternalLinksChild = require("miuthought.internal_links")
        local lfsChild = require("libs/libkoreader-lfs")

        local function child_os_ok(value)
            if value == true or value == 0 then return true end
            if type(value) == "number" then return value == 0 end
            return false
        end


        local function read_zip_entry(archive, entry)
            local pipe = io.popen("unzip -p " .. UChild.shell_quote(archive)
                .. " " .. UChild.shell_quote(entry) .. " 2>/dev/null", "r")
            if not pipe then return nil end
            local data = pipe:read("*a")
            pipe:close()
            if data == "" then return nil end
            return data
        end

        local function collect_files(root)
            local entries = {}
            local function walk(dir, relative)
                local names = {}
                for name in lfsChild.dir(dir) do
                    if name ~= "." and name ~= ".." then names[#names + 1] = name end
                end
                table.sort(names)
                for _, name in ipairs(names) do
                    local full = dir .. "/" .. name
                    local rel = relative == "" and name or (relative .. "/" .. name)
                    local mode = lfsChild.attributes(full, "mode")
                    if mode == "directory" then
                        walk(full, rel)
                    elseif mode == "file" then
                        entries[#entries + 1] = {name = rel, source = {path = full}}
                    end
                end
            end
            walk(root, "")
            table.sort(entries, function(a, b)
                if a.name == "mimetype" then return true end
                if b.name == "mimetype" then return false end
                return tostring(a.name) < tostring(b.name)
            end)
            return entries
        end

        local errors = {}
        local repaired = 0
        local skipped = 0
        local links_checked = 0
        local links_rewritten = 0
        local links_unresolved = 0
        UChild.remove_tree(temp_root)
        UChild.mkdir(temp_root)

        for index, path in ipairs(child_paths) do
            local work_dir = temp_root .. "/book-" .. tostring(index)
            local unpack_dir = work_dir .. "/unpacked"
            local temp_epub = tostring(path) .. ".miuread-style-repair.tmp"
            local backup = tostring(path) .. ".miuread-style-repair.bak"
            local function fail(message)
                errors[#errors + 1] = tostring(path) .. "：" .. tostring(message or "修复失败")
                os.remove(temp_epub)
                if UChild.file_exists(backup) and not UChild.file_exists(path) then os.rename(backup, path) end
                UChild.remove_tree(work_dir)
            end

            if not UChild.file_exists(path) then
                fail("文件不存在")
            else
                UChild.remove_tree(work_dir)
                UChild.mkdir(unpack_dir)
                local unzip_rc = os.execute("unzip -q -o " .. UChild.shell_quote(path)
                    .. " -d " .. UChild.shell_quote(unpack_dir) .. " 2>/dev/null")
                if not child_os_ok(unzip_rc) then
                    fail("无法解压 EPUB")
                else
                    local style_path = unpack_dir .. "/OEBPS/style.css"
                    local css, read_error = UChild.read_file(style_path, true)
                    if not css then
                        fail("未找到 OEBPS/style.css：" .. tostring(read_error or "读取失败"))
                    else
                        local meta_raw = UChild.read_file(unpack_dir .. "/OEBPS/miuread.json", true)
                        local book_meta = {}
                        if meta_raw then
                            local meta_ok, decoded_meta = pcall(JsonChild.decode, meta_raw)
                            if meta_ok and type(decoded_meta) == "table" then book_meta = decoded_meta end
                        end
                        local repair_style = tostring(book_meta.variant or "") ~= "clean"
                        local rewritten_css, css_changed
                        if repair_style then rewritten_css, css_changed = AnnotationStyleChild.rewrite_css(css)
                        else rewritten_css, css_changed = css, false end
                        local html_changed = 0
                        local miuread_chapters = 0
                        local html_error
                        local html_entries = {}
                        local function collect_html_tree(dir, relative)
                            local names = {}
                            for name in lfsChild.dir(dir) do
                                if name ~= "." and name ~= ".." then names[#names + 1] = name end
                            end
                            table.sort(names)
                            for _, name in ipairs(names) do
                                local full = dir .. "/" .. name
                                local rel = relative == "" and name or (relative .. "/" .. name)
                                local mode = lfsChild.attributes(full, "mode")
                                if mode == "directory" then
                                    collect_html_tree(full, rel)
                                    if html_error then return end
                                elseif mode == "file" and name:lower():match("%.x?html?$") then
                                    local raw, err = UChild.read_file(full, true)
                                    if not raw then
                                        html_error = "无法读取正文文件：" .. tostring(err or name)
                                        return
                                    end
                                    local is_miuread_chapter = raw:find("data-miuread-book=", 1, true) ~= nil
                                    local rewritten, style_changed
                                    if repair_style then rewritten, style_changed = AnnotationStyleChild.rewrite_xhtml(raw)
                                    else rewritten, style_changed = raw, false end
                                    if is_miuread_chapter then
                                        miuread_chapters = miuread_chapters + 1
                                        if repair_style and not AnnotationStyleChild.xhtml_is_current(rewritten) then
                                            html_error = "章节内虚线样式校验失败：" .. tostring(name)
                                            return
                                        end
                                    end
                                    if style_changed then
                                        local ok_write, write_err = UChild.atomic_write(full, rewritten, true)
                                        if not ok_write then
                                            html_error = "无法改写正文样式：" .. tostring(write_err or rel)
                                            return
                                        end
                                        html_changed = html_changed + 1
                                    end
                                    html_entries[#html_entries + 1] = {path = rel, full = full}
                                    raw, rewritten = nil, nil
                                    collectgarbage("step", 150)
                                end
                            end
                        end
                        collect_html_tree(unpack_dir, "")
                        local link_stats
                        if not html_error then
                            link_stats, html_error = InternalLinksChild.rewrite_files_strict(html_entries, {
                                sample_limit = 12,
                                read_file = function(file) return UChild.read_file(file, true) end,
                                write_file = function(file, data) return UChild.atomic_write(file, data, true) end,
                            })
                            if link_stats then
                                links_checked = links_checked + (tonumber(link_stats.links) or 0)
                                links_rewritten = links_rewritten + (tonumber(link_stats.rewritten) or 0)
                                links_unresolved = links_unresolved + (tonumber(link_stats.unresolved_critical) or 0)
                                html_changed = html_changed + (tonumber(link_stats.files_changed) or 0)
                            end
                            if html_error then
                                local samples = link_stats and link_stats.samples or {}
                                html_error = "内部链接修复失败：" .. tostring(html_error)
                                if #samples > 0 then html_error = html_error .. "：" .. table.concat(samples, "；") end
                            end
                        end
                        if html_error then
                            fail(html_error)
                        elseif miuread_chapters == 0 then
                            fail("未找到觅阅正文章节")
                        elseif not css_changed and html_changed == 0
                            and (not repair_style or AnnotationStyleChild.css_is_current(css)) then
                            skipped = skipped + 1
                            UChild.remove_tree(work_dir)
                        else
                            local wrote, write_error = UChild.atomic_write(style_path, rewritten_css, true)
                            if not wrote then
                                fail("无法写入新样式：" .. tostring(write_error or "写入失败"))
                            else
                                local entries = collect_files(unpack_dir)
                                if #entries == 0 or entries[1].name ~= "mimetype" then
                                    fail("EPUB 结构不完整")
                                else
                                    os.remove(temp_epub)
                                    local built, build_error = xpcall(function()
                                        EpubChild._stream_zip(temp_epub, entries)
                                    end, debug.traceback)
                                    if not built then
                                        fail("重新打包失败：" .. tostring(build_error or "未知错误"))
                                    else
                                        local mime_check = read_zip_entry(temp_epub, "mimetype")
                                        local style_check = read_zip_entry(temp_epub, "OEBPS/style.css")
                                        if mime_check ~= "application/epub+zip"
                                            or not style_check
                                            or (repair_style and not AnnotationStyleChild.css_is_current(style_check)) then
                                            fail("修复后的 EPUB 完整性检查失败")
                                        else
                                            os.remove(backup)
                                            local backed_up, backup_error = os.rename(path, backup)
                                            if not backed_up then
                                                fail("无法创建临时备份：" .. tostring(backup_error or "备份失败"))
                                            else
                                                local replaced, replace_error = os.rename(temp_epub, path)
                                                if not replaced then
                                                    os.rename(backup, path)
                                                    fail("无法覆盖原 EPUB：" .. tostring(replace_error or "替换失败"))
                                                else
                                                    local verify = read_zip_entry(path, "OEBPS/style.css")
                                                    if not verify or (repair_style and not AnnotationStyleChild.css_is_current(verify)) then
                                                        os.remove(path)
                                                        os.rename(backup, path)
                                                        fail("覆盖后校验失败，已恢复原文件")
                                                    else
                                                        os.remove(backup)
                                                        repaired = repaired + 1
                                                        UChild.remove_tree(work_dir)
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        UChild.remove_tree(temp_root)
        local payload = {
            ok = #errors == 0,
            repaired = repaired,
            skipped = skipped,
            total = #child_paths,
            errors = errors,
            links_checked = links_checked,
            links_rewritten = links_rewritten,
            links_unresolved = links_unresolved,
            error = #errors > 0 and table.concat(errors, "\n") or nil,
        }
        UChild.atomic_write(result_path, JsonChild.encode(payload), true)
    end

    local ok, pid, err = pcall(FFIUtil.runInSubProcess, child, false, false)
    if not ok or not pid then return false, tostring(err or pid or "无法启动书籍修复") end
    self:_hold_awake()
    self.job = {
        pid = pid,
        result_path = result_path,
        on_done = on_done,
        started_at = os.time(),
        timeout = math.max(300, #paths * 180),
    }
    self:_schedule()
    return true
end

EpubStyleRepairTask.REPAIR_CSS = REPAIR_CSS
EpubStyleRepairTask.REPAIR_BEGIN = REPAIR_BEGIN
EpubStyleRepairTask.REPAIR_END = REPAIR_END

return EpubStyleRepairTask
