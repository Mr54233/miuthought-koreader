local Json = require("miuthought.json")
local U = require("miuthought.util")
local Adapter = require("miuthought.legacy_adapter_worker")

local Service = {}

local MIN_FINAL_SECONDS = 10

local function sleep(seconds)
    local ok, socket = pcall(require, "socket")
    if ok and socket and type(socket.sleep) == "function" then
        socket.sleep(seconds)
        return
    end
    os.execute("sleep " .. tostring(math.max(1, math.floor(seconds or 1))))
end

local function process_helpers()
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil end
    pcall(function()
        ffi.cdef[[
            int getpid(void);
            int setpriority(int which, int who, int prio);
            int kill(int pid, int sig);
        ]]
    end)
    return ffi
end

local ffi = process_helpers()

local function lower_priority()
    if not ffi then return end
    pcall(function() ffi.C.setpriority(0, ffi.C.getpid(), 19) end)
end

local function own_pid()
    if not ffi then return nil end
    local ok, pid = pcall(function() return tonumber(ffi.C.getpid()) end)
    return ok and pid or nil
end

local function remove_lock_dir(path)
    if not path then return end
    local ok, lfs = pcall(require, "lfs")
    if ok and lfs and type(lfs.rmdir) == "function" then pcall(lfs.rmdir, path) end
end

local function parent_alive(pid)
    pid = tonumber(pid)
    if not pid or pid <= 1 or not ffi then return true end
    local ok, result = pcall(function() return ffi.C.kill(pid, 0) end)
    return not ok or result == 0
end

local function read_json(path)
    local raw = U.read_file(path, true)
    if not raw then return nil end
    local ok, value = pcall(Json.decode, raw)
    if ok and type(value) == "table" then return value end
end

local function write_status(path, value)
    value = value or {}
    value.written_at = os.time()
    return U.atomic_write(path, Json.encode(value), true)
end

local function public_result(result)
    result = type(result) == "table" and result or {}
    return {
        accepted = result.accepted == true,
        response = result.response or {},
        error = result.error,
        error_kind = result.error_kind,
        path = result.path,
        context_changed = result.context_changed == true,
        position = result.position,
        cookies_changed = result.cookies_changed == true,
        cookies = result.cookies_changed and result.cookies or nil,
        wr_ticket_changed = result.wr_ticket_changed == true,
        wr_ticket = result.wr_ticket_changed and result.wr_ticket or nil,
        wr_wrpa_changed = result.wr_wrpa_changed == true,
        wr_wrpa = result.wr_wrpa_changed and result.wr_wrpa or nil,
        response_summary = result.response_summary,
        attempts = result.attempts,
        payload_public = result.payload_public,
    }
end

function Service.run(job)
    job = job or {}
    local job_path = assert(job.job_path, "missing job path")
    local control_path = assert(job.control_path, "missing control path")
    local status_path = assert(job.status_path, "missing status path")
    local context_path = assert(job.context_path, "missing context path")
    local stop_path = assert(job.stop_path, "missing stop path")
    local owner_path = job.owner_path
    local lock_path = job.lock_path
    local parent_pid = tonumber(job.parent_pid)
    local poll_interval = math.max(0.5, tonumber(job.poll_interval) or 1)

    lower_priority()

    local generation = 0
    local sequence = 0
    local current_job = nil
    local book = {}
    local auth = {}
    local next_due = 0
    local last_control_state = nil
    local last_report_at = 0
    local last_flush_seq = 0

    local function run_report(control, elapsed, final_flush, reason)
        local interval = math.max(10, tonumber(current_job.interval) or 30)
        elapsed = math.max(1, math.floor(tonumber(elapsed) or interval))
        sequence = sequence + 1
        local report_job = {
            book_id = tostring(current_job.book_id or ""),
            book_title = tostring(current_job.book_title or current_job.book_id or ""),
            book = book,
            progress_ratio = tonumber(control.progress_ratio) or 0,
            elapsed_seconds = elapsed,
            cookies = auth.cookies or {},
            api_key = auth.api_key or "",
            wr_ticket = auth.wr_ticket or "",
            wr_wrpa = auth.wr_wrpa or "",
            allow_renewal = false,
        }
        local attempted_at = os.time()
        local ok, result = pcall(Adapter.run, report_job)
        local completed_at = os.time()
        last_report_at = completed_at

        if ok and type(result) == "table" then
            if type(result.legacy_context) == "table" then
                book = U.copy(result.legacy_context)
                if result.context_changed then
                    U.atomic_write(context_path, Json.encode(book), true)
                end
            end
            if result.cookies_changed and type(result.cookies) == "table" then auth.cookies = U.copy(result.cookies) end
            if result.wr_ticket_changed then auth.wr_ticket = result.wr_ticket or "" end
            if result.wr_wrpa_changed then auth.wr_wrpa = result.wr_wrpa or "" end

            local out = public_result(result)
            out.generation = generation
            out.seq = sequence
            out.state = result.accepted and "waiting" or "error"
            out.attempted_at = attempted_at
            out.completed_at = completed_at
            out.elapsed_seconds = elapsed
            out.final_flush = final_flush == true
            out.flush_reason = reason
            out.next_due = final_flush and 0 or (completed_at + interval)
            out.book_id = tostring(current_job.book_id or "")
            write_status(status_path, out)
            return out.next_due
        end

        local due = final_flush and 0 or (completed_at + interval)
        write_status(status_path, {
            generation = generation,
            seq = sequence,
            state = "error",
            accepted = false,
            error = tostring(result or "read report service failed"),
            attempted_at = attempted_at,
            completed_at = completed_at,
            elapsed_seconds = elapsed,
            final_flush = final_flush == true,
            flush_reason = reason,
            next_due = due,
            book_id = tostring(current_job.book_id or ""),
        })
        return due
    end

    write_status(status_path, {
        generation = 0,
        seq = 0,
        state = "service_waiting",
        started_at = os.time(),
        service_version = tonumber(job.service_version) or 0,
    })

    while true do
        if U.file_exists(stop_path) or not parent_alive(parent_pid) then break end

        local control = read_json(control_path)
        if control and tonumber(control.generation or 0) ~= generation then
            local requested = tonumber(control.generation or 0) or 0
            local loaded = read_json(job_path)
            if loaded and tonumber(loaded.generation or 0) == requested then
                generation = requested
                current_job = loaded
                book = U.copy(loaded.book or {})
                auth = U.copy(loaded.auth or {})
                local interval = math.max(10, tonumber(loaded.interval) or 30)
                local first_delay = math.max(5, math.min(interval, tonumber(loaded.first_delay) or interval))
                local now = os.time()
                next_due = now + first_delay
                last_report_at = now
                last_flush_seq = 0
                last_control_state = nil
                U.atomic_write(context_path, Json.encode(book), true)
                write_status(status_path, {
                    generation = generation,
                    seq = sequence,
                    state = "waiting",
                    next_due = next_due,
                    book_id = tostring(loaded.book_id or ""),
                    first_delay = first_delay,
                    service_version = tonumber(job.service_version) or 0,
                })
            end
        end

        if current_job and control and tonumber(control.generation or 0) == generation
            and tostring(control.controller_token or "") == tostring(current_job.controller_token or "")
        then
            local active = control.active == true
            local state_key = active and "active" or "inactive"
            local flush_seq = tonumber(control.flush_seq or 0) or 0
            local pending_flush = flush_seq > last_flush_seq

            if state_key ~= last_control_state then
                last_control_state = state_key
                if not active then
                    next_due = 0
                    if not pending_flush then
                        write_status(status_path, {
                            generation = generation,
                            seq = sequence,
                            state = "inactive",
                            book_id = tostring(current_job.book_id or ""),
                        })
                    end
                elseif next_due <= 0 then
                    local interval = math.max(10, tonumber(current_job.interval) or 30)
                    local first_delay = math.max(5, math.min(interval, tonumber(current_job.first_delay) or interval))
                    local now = os.time()
                    last_report_at = now
                    next_due = now + first_delay
                end
            end

            if pending_flush then
                last_flush_seq = flush_seq
                local now = os.time()
                local elapsed = math.floor(tonumber(control.flush_elapsed) or math.max(0, now - last_report_at))
                if elapsed >= MIN_FINAL_SECONDS then
                    next_due = run_report(control, elapsed, true, tostring(control.flush_reason or "stop"))
                else
                    next_due = 0
                    write_status(status_path, {
                        generation = generation,
                        seq = sequence,
                        state = "inactive",
                        accepted = nil,
                        final_flush = true,
                        flush_skipped = true,
                        flush_reason = tostring(control.flush_reason or "stop"),
                        elapsed_seconds = elapsed,
                        book_id = tostring(current_job.book_id or ""),
                    })
                end
            elseif active then
                local now = os.time()
                local interval = math.max(10, tonumber(current_job.interval) or 30)
                local idle_timeout = math.max(interval, tonumber(current_job.idle_timeout) or 600)
                local last_activity = tonumber(control.last_activity) or now
                local idle = now - last_activity

                if now >= next_due then
                    if idle <= idle_timeout then
                        local elapsed = math.max(1, now - last_report_at)
                        next_due = run_report(control, elapsed, false, "interval")
                    else
                        next_due = now + interval
                    end
                end
            end
        end

        sleep(poll_interval)
    end

    write_status(status_path, {
        generation = generation,
        seq = sequence,
        state = "service_stopped",
        stopped_at = os.time(),
        service_version = tonumber(job.service_version) or 0,
    })
    if owner_path then
        local owner = read_json(owner_path)
        if not owner or tonumber(owner.pid) == own_pid() then os.remove(owner_path) end
    end
    remove_lock_dir(lock_path)
    return true
end

return Service
