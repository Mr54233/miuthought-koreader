local FFIUtil = require("ffi/util")
local Json = require("miuthought.json")
local U = require("miuthought.util")
local UIManager = require("ui/uimanager")
local Device = require("device")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local DownloadTask = {}
DownloadTask.__index = DownloadTask

local function lower_worker_priority()
    local ok,ffi=pcall(require,"ffi")
    if not ok or not ffi then return end
    pcall(ffi.cdef,"int setpriority(int which, int who, int prio);")
    pcall(function() ffi.C.setpriority(0,0,10) end)
end

local function serializable_copy(value, seen)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" or kind == "nil" then return value end
    if kind ~= "table" then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local out = {}
    for k, v in pairs(value) do
        if type(k) == "string" or type(k) == "number" then
            local x = serializable_copy(v, seen)
            if x ~= nil then out[k] = x end
        end
    end
    return out
end

function DownloadTask:new(store)
    return setmetatable({
        store = store,
        job = nil,
        poll_task = nil,
        standby_held = false,
        keep_awake_enabled = true,
        backgrounded = false,
        foreground_poll_interval = 0.40,
        background_poll_interval = 1.50,
        owner_path = store.temp_dir .. "/download-task-owner.json",
        owner_token = tostring(os.time()) .. "-" .. tostring(math.random(100000,999999)),
    }, self)
end

function DownloadTask:set_backgrounded(value)
    self.backgrounded = value == true
end

function DownloadTask:last_state()
    return self.job and self.job.last_progress_state or nil
end

local function read_json(path)
    local raw=U.read_file(path,true)
    if not raw then return nil end
    local ok,value=pcall(Json.decode,raw)
    if ok and type(value)=="table" then return value end
end

local function file_exists(path)
    return tostring(path or "")~="" and lfs.attributes(path)~=nil
end

local function file_mtime(path)
    local attr=lfs.attributes(path)
    return attr and tonumber(attr.modification or attr.change) or nil
end

local function process_exists(pid)
    pid=tonumber(pid)
    if not pid or pid<=1 then return false end
    local proc="/proc/"..tostring(pid)
    if lfs.attributes("/proc","mode")~="directory" then return nil end
    if lfs.attributes(proc,"mode")~="directory" then return false end
    local status=U.read_file(proc.."/status",true) or ""
    local state=status:match("[\r\n]State:%s*([A-Z])") or status:match("^State:%s*([A-Z])")
    if state=="Z" or state=="X" then return false end
    return true
end

function DownloadTask:_claim(pid)
    return U.atomic_write(self.owner_path,Json.encode({
        token=self.owner_token,pid=tonumber(pid),updated_at=os.time(),
    }),true)
end

function DownloadTask:_owns_job()
    local owner=read_json(self.owner_path)
    return owner and tostring(owner.token or "")==tostring(self.owner_token)
        and tonumber(owner.pid or 0)==tonumber(self.job and self.job.pid or 0)
end

function DownloadTask:descriptor()
    local job=self.job
    if not job then return nil end
    return {
        pid=job.pid,progress_path=job.progress_path,result_path=job.result_path,
        cancel_path=job.cancel_path,worker_settings_path=job.worker_settings_path,
        started_at=job.started_at,owner_token=self.owner_token,task_token=job.task_token,
    }
end

function DownloadTask:_reset_device_timeout()
    if not self.keep_awake_enabled then return false end
    local powerd = Device and Device.powerd
    if powerd and type(powerd.resetT1Timeout) == "function" then
        local ok, err = pcall(powerd.resetT1Timeout, powerd)
        if not ok then logger.warn("[MiuRead][DownloadTask] Kindle T1 reset failed", tostring(err)) end
        return ok
    end
    return false
end

function DownloadTask:_hold_awake()
    if not self.keep_awake_enabled or self.standby_held then return end
    local ok, err = pcall(function() UIManager:preventStandby() end)
    if ok then
        self.standby_held = true
        local reset = self:_reset_device_timeout()
        logger.info("[MiuRead][DownloadTask] standby lock acquired", "t1_reset=", tostring(reset))
    else
        logger.warn("[MiuRead][DownloadTask] standby lock failed", tostring(err))
    end
end

function DownloadTask:_release_awake()
    if not self.standby_held then return end
    self.standby_held = false
    pcall(function() UIManager:allowStandby() end)
    logger.info("[MiuRead][DownloadTask] standby lock released")
end

function DownloadTask:available()
    return type(FFIUtil.runInSubProcess) == "function"
        and type(FFIUtil.isSubProcessDone) == "function"
end

function DownloadTask:busy()
    return self.job ~= nil
end

function DownloadTask:_schedule()
    if self.poll_task then return end
    local task
    task = function()
        if self.poll_task ~= task then return end
        self.poll_task = nil
        self:_poll()
    end
    self.poll_task = task
    local interval = self.backgrounded and self.background_poll_interval or self.foreground_poll_interval
    UIManager:scheduleIn(interval, task)
end

function DownloadTask:_read_progress(job)
    local raw = U.read_file(job.progress_path, true)
    if not raw or raw == job.last_progress_raw then return false end
    local ok, state = pcall(Json.decode, raw)
    if ok and type(state) == "table" then
        if job.task_token and tostring(state.task_token or "")~=tostring(job.task_token) then
            job.token_mismatch=true
            logger.warn("[MiuRead][DownloadTask] progress task identity mismatch")
            return false
        end
        job.last_progress_raw = raw
        job.last_progress_state = state
        job.last_progress_at = tonumber(state.updated_at) or file_mtime(job.progress_path) or os.time()
        job.waiting_notified = false
        if self.keep_awake_enabled and not self.standby_held then self:_hold_awake() end
        if job.on_progress then job.on_progress(state) end
        return true
    end
    return false
end

function DownloadTask:_finish(job, forced_error)
    self:_read_progress(job)
    local raw = U.read_file(job.result_path, true)
    local result
    if forced_error then
        result = {ok = false, error = forced_error}
    elseif not raw then
        local stage = job.last_progress_state and job.last_progress_state.stage
        if stage == "package" then
            result = {ok = false, error = "EPUB 生成进程异常退出；原有完整书未被覆盖，已下载章节仍保存在断点缓存。请再次下载继续。"}
        else
            result = {ok = false, error = "下载子进程异常退出；已完成的下载进度会继续保留。"}
        end
    else
        local ok, decoded = pcall(Json.decode, raw)
        result = ok and decoded or {ok = false, error = "下载结果无法解析"}
    end

    os.remove(job.progress_path)
    os.remove(job.result_path)
    os.remove(job.cancel_path)
    if job.worker_settings_path then os.remove(job.worker_settings_path) end
    if self:_owns_job() then os.remove(self.owner_path) end
    self.job = nil
    self:_release_awake()
    if job.on_done then job.on_done(result) end
end

function DownloadTask:_poll()
    local job = self.job
    if not job then return end
    if not self:_owns_job() then
        logger.info("[MiuRead][DownloadTask] controller ownership transferred","pid=",tostring(job.pid))
        self.job=nil
        self:_release_awake()
        return
    end

    self:_read_progress(job)
    if job.token_mismatch then
        self:_finish(job,"后台下载任务身份不匹配；断点已保留，请重新开始下载。")
        return
    end
    if file_exists(job.result_path) then self:_finish(job); return end

    local now=os.time()
    if not job.last_keepalive or now-job.last_keepalive>=5 then
        job.last_keepalive=now
        local reset=self:_reset_device_timeout()
        if reset then logger.dbg("[MiuRead][DownloadTask] Kindle T1 timer reset") end
    end

    local alive=process_exists(job.pid)
    local done_ok,done=pcall(FFIUtil.isSubProcessDone,job.pid,false)
    if not done_ok then
        logger.warn("[MiuRead][DownloadTask] poll failed",tostring(done))
        if alive~=false then self:_schedule(); return end
    end

    -- On Android a recreated KOReader UI may report waitpid() as done even
    -- while the original worker is still alive. /proc and the result file are
    -- therefore authoritative; waitpid() is only a fallback.
    if alive==true or (alive==nil and done_ok and done==false) then
        job.dead_seen_at=nil
        if job.cancel_requested_at and now-job.cancel_requested_at>=8 then
            pcall(FFIUtil.terminateSubProcess,job.pid)
            self:_finish(job,"下载已取消")
            return
        end
        local activity=tonumber(job.last_progress_at or job.started_at) or now
        local idle=math.max(0,now-activity)
        if idle>=120 and not job.waiting_notified then
            job.waiting_notified=true
            local state=U.copy(job.last_progress_state or {})
            state.waiting_network=true
            state.message="等待网络或服务器响应"
            state.updated_at=now
            if job.on_progress then job.on_progress(state) end
        end
        if idle>=300 and self.standby_held then
            self:_release_awake()
            logger.info("[MiuRead][DownloadTask] standby lock released while waiting", "pid=", tostring(job.pid))
        end
        self:_schedule()
        return
    end

    job.dead_seen_at=job.dead_seen_at or now
    if now-job.dead_seen_at<8 then self:_schedule(); return end
    self:_finish(job)
end

function DownloadTask:cancel()
    local job = self.job
    if not job or job.cancel_requested_at or not self:_owns_job() then return end
    job.cancel_requested_at = os.time()
    U.atomic_write(job.cancel_path, "1", true)
end

function DownloadTask:attach(descriptor,on_progress,on_done)
    if self.job then return false,"已有下载任务正在运行" end
    if not self:available() then return false,"当前 KOReader 不支持下载子进程" end
    descriptor=type(descriptor)=="table" and descriptor or nil
    local pid=descriptor and tonumber(descriptor.pid)
    if not pid or not descriptor.progress_path or not descriptor.result_path
        or not descriptor.cancel_path then return false,"下载任务记录不完整" end
    self.keep_awake_enabled=self.store:preferences().download_keep_awake~=false
    self.job={
        pid=pid,progress_path=descriptor.progress_path,result_path=descriptor.result_path,
        cancel_path=descriptor.cancel_path,worker_settings_path=descriptor.worker_settings_path,
        on_progress=on_progress,on_done=on_done,last_progress_raw=nil,last_progress_state=nil,
        last_progress_at=nil,last_keepalive=0,started_at=descriptor.started_at,dead_seen_at=nil,waiting_notified=false,
        task_token=descriptor.task_token,
    }
    self.backgrounded=true
    self:_read_progress(self.job)
    if self.job.token_mismatch then
        self.job=nil
        return false,"后台下载任务身份不匹配"
    end
    local done_ok,done=pcall(FFIUtil.isSubProcessDone,pid,false)
    local alive=process_exists(pid)
    if not done_ok and alive==nil then
        self.job=nil
        return false,"无法接管后台下载："..tostring(done)
    end
    self:_claim(pid)
    self:_hold_awake()
    logger.info("[MiuRead][DownloadTask] attached","pid=",tostring(pid),
        "done=",tostring(done_ok and done or "unknown"),"alive=",tostring(alive))
    if file_exists(self.job.result_path) then
        local attached_job=self.job
        UIManager:scheduleIn(0,function()
            if self.job==attached_job and self:_owns_job() then self:_finish(attached_job) end
        end)
    else
        if alive==false and done_ok and done==true then self.job.dead_seen_at=os.time() end
        self:_schedule()
    end
    return true
end

function DownloadTask:start(book, options, on_progress, on_done)
    if self.job then return false, "已有下载任务正在运行" end
    if not self:available() then return false, "当前 KOReader 不支持下载子进程" end

    local stamp = tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))
    local progress_path = self.store.temp_dir .. "/download-progress-" .. stamp .. ".json"
    local result_path = self.store.temp_dir .. "/download-result-" .. stamp .. ".json"
    local cancel_path = self.store.temp_dir .. "/download-cancel-" .. stamp
    local worker_settings_path = self.store.temp_dir .. "/download-settings-" .. stamp .. ".lua"
    self.store:flush()
    local copied, copy_error = U.copy_file(self.store.settings_path, worker_settings_path)
    if not copied then return false, "无法建立安全下载状态副本：" .. tostring(copy_error or "未知错误") end
    local worker_data_dir = self.store.data_dir
    local task_token = stamp .. "-" .. tostring(math.random(100000,999999))
    local clean_book = serializable_copy(book)
    local clean_options = serializable_copy(options or {})
    self.keep_awake_enabled = self.store:preferences().download_keep_awake ~= false
    clean_options.cancelled = nil

    local child = function()
        lower_worker_priority()
        local Store = require("miuthought.store")
        local Http = require("miuthought.http")
        local Api = require("miuthought.api")
        local Reader = require("miuthought.reader")
        local Annotations = require("miuthought.annotations")
        local Downloader = require("miuthought.downloader")
        local JsonChild = require("miuthought.json")
        local UChild = require("miuthought.util")
        local LoggerChild = require("logger")

        local function emit(state)
            state = state or {}
            state.task_token = task_token
            state.updated_at = os.time()
            local ok, encoded = pcall(JsonChild.encode, state)
            if ok then UChild.atomic_write(progress_path, encoded, true) end
        end

        local ok, value = xpcall(function()
            local store = Store:new{
                settings_path = worker_settings_path,
                data_dir = worker_data_dir,
                isolated = true,
            }
            local http = Http:new(store)
            local reader = Reader:new(http, store)
            local api = Api:new(http, store, reader)
            local annotations = Annotations:new(api)
            local downloader = Downloader:new(reader, api, annotations, store, http)
            clean_options.cancelled = function()
                return UChild.file_exists(cancel_path)
            end
            emit{stage = "prepare", current = 0, total = 1, chapter = clean_book.title or ""}
            local record = downloader:book(clean_book, clean_options, function(stage, current, total, chapter, detail)
                detail = detail or {}
                local percent
                if stage == "package" then
                    percent = 0.96
                elseif total and total > 0 then
                    local base = (math.max(1, current) - 1) / total
                    local step = 0
                    if stage == "resume" then step = 0.90
                    elseif stage == "content" then step = 0.08
                    elseif stage == "underlines" then step = 0.35
                    elseif stage == "thoughts" then step = 0.55
                    elseif stage == "footnotes" then step = 0.75
                    elseif stage == "images" then step = 0.88 end
                    percent = math.min(0.94, base * 0.94 + step / total)
                end
                if stage == "package" then
                    detail.message = detail.message or "正在低内存生成并验证 EPUB"
                end
                emit{
                    stage = stage,
                    current = current,
                    total = total,
                    chapter = chapter,
                    batch = detail.batch,
                    batch_total = detail.batches,
                    underlines = detail.underlines,
                    thoughts = detail.thoughts,
                    percent = percent,
                    message = detail.message,
                }
            end)
            return {
                record = record,
                auth = store:auth(),
                session = store:session(clean_book.bookId),
            }
        end, debug.traceback)

        local payload
        if ok then
            emit{stage = "done", current = 1, total = 1, percent = 1, chapter = clean_book.title or ""}
            payload = {
                ok = true,
                value = serializable_copy(value and value.record),
                auth = serializable_copy(value and value.auth),
                session = serializable_copy(value and value.session),
            }
        else
            local raw_error = tostring(value)
            LoggerChild.warn("[MiuRead][DownloadTask] child failed", raw_error)
            local display_error = raw_error:match("^(.-)\nstack traceback:") or raw_error
            -- File paths and line numbers are useful in logs but confusing in
            -- the download dialog. Keep the actual reason only.
            display_error = display_error:gsub("^.-%.lua:%d+:%s*", "")
            if raw_error:lower():find("not enough memory", 1, true) then
                display_error = "设备内存不足，未生成新的 EPUB。原有完整书未被覆盖，已完成章节仍保存在断点缓存；再次下载时会继续。"
            end
            emit{stage = UChild.file_exists(cancel_path) and "cancelled" or "error", message = display_error}
            payload = {ok = false, error = display_error}
        end
        local encoded = JsonChild.encode(payload)
        UChild.atomic_write(result_path, encoded, true)
    end

    local ok, pid, err = pcall(FFIUtil.runInSubProcess, child, false, false)
    if not ok or not pid then
        os.remove(worker_settings_path)
        return false, tostring(err or pid or "无法启动下载子进程")
    end

    self.job = {
        pid = pid,
        progress_path = progress_path,
        result_path = result_path,
        cancel_path = cancel_path,
        worker_settings_path = worker_settings_path,
        on_progress = on_progress,
        on_done = on_done,
        last_progress_raw = nil,
        last_progress_state = nil,
        last_progress_at = nil,
        last_keepalive = 0,
        dead_seen_at = nil,
        waiting_notified = false,
        task_token = task_token,
        started_at = os.time(),
    }
    self:_claim(pid)
    self.backgrounded = false
    self:_hold_awake()
    logger.info("[MiuRead][DownloadTask] started", "pid=", tostring(pid))
    self:_schedule()
    return true
end

return DownloadTask
