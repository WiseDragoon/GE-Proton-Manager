-- Background tasks on top of Millennium's coroutine support.
--
-- millennium.start_coroutine() schedules a coroutine on the plugin's event loop and
-- millennium.yield_readable(fd) suspends it until fd becomes readable. Timers,
-- downloads and subprocesses are built on those two calls, so frontend calls keep
-- being answered while long operations are running.
--
-- Two properties of the host event loop shape this module:
--  * it keeps only a raw pointer to a suspended coroutine, so `tasks` holds a strong
--    reference until the coroutine finishes;
--  * it resumes on POLLIN only, never on POLLHUP, so a pipe must never be awaited for
--    EOF. Subprocesses print an exit marker instead and polling stops once it arrives.

local ffi = require("ffi")
local logger = require("logger")
local millennium = require("millennium")
local utils = require("utils")
local native = require("native")

local C = native.C

local M = {}

M.CANCELLED = "cancelled"

local USER_AGENT = "GE-Proton-Manager (Millennium plugin)"
-- Downloads wake up every TICK_MS and then keep reading data as it arrives for DRAIN_MS
-- (blocking in curl_multi_wait), so frontend calls wait at most DRAIN_MS. Reading only
-- what is buffered at each tick would let the TCP receive window fill up between ticks
-- and throttle the sender to a fraction of the connection's speed.
local TICK_MS = 10
local DRAIN_MS = 8
local BUFFER_SIZE = 256 * 1024
local EXIT_MARKER = "__GPM_EXIT__:"

local tasks = {}

--- Runs fn(...) as a background task. Errors are logged, never propagated.
---@param name string
---@param fn function
function M.spawn(name, fn, ...)
    local args = { n = select("#", ...), ... }
    local co
    co = coroutine.create(function()
        local ok, err = xpcall(function()
            fn(unpack(args, 1, args.n))
        end, debug.traceback)
        if not ok then
            logger:error(name .. " failed: " .. tostring(err))
        end
        tasks[co] = nil
    end)
    tasks[co] = name
    millennium.start_coroutine(co)
end

-- ============= Timers =============

local expirations = ffi.new("uint64_t[1]")

local function set_ms(spec, ms)
    spec.tv_sec = math.floor(ms / 1000)
    spec.tv_nsec = math.floor(ms % 1000) * 1000000
end

local function timer(first_ms, interval_ms)
    local fd = C.timerfd_create(native.CLOCK_BOOTTIME, native.TFD_NONBLOCK + native.TFD_CLOEXEC)
    if fd < 0 then
        error("timerfd_create failed")
    end
    local spec = ffi.new("gpm_itimerspec")
    set_ms(spec.it_value, math.max(1, first_ms)) -- a zero value would disarm the timer
    set_ms(spec.it_interval, interval_ms)
    if C.timerfd_settime(fd, 0, spec, nil) ~= 0 then
        C.close(fd)
        error("timerfd_settime failed")
    end
    return fd
end

local function wait_timer(fd)
    millennium.yield_readable(fd)
    C.read(fd, expirations, 8)
end

--- Suspends the current task.
---@param ms integer
function M.sleep(ms)
    local fd = timer(ms, 0)
    wait_timer(fd)
    C.close(fd)
end

-- ============= Subprocesses =============

--- Quotes a string as a single POSIX shell word.
---@param value string
---@return string
function M.quote(value)
    return "'" .. (value:gsub("'", "'\\''")) .. "'"
end

--- Runs a shell command in the background and waits for it to exit.
---@param command string
---@return integer exit_code -1 if the command could not be run
---@return string output combined stdout and stderr
function M.run(command)
    local pipe = C.popen("{ " .. command .. "; } </dev/null 2>&1; echo " .. EXIT_MARKER .. "$?", "r")
    if pipe == nil then
        return -1, "could not start the command"
    end
    local fd = C.fileno(pipe)
    local buffer = ffi.new("char[4096]")
    local output, code = "", nil
    while not code do
        millennium.yield_readable(fd)
        local count = tonumber(C.read(fd, buffer, 4096))
        if count <= 0 then
            break -- the shell died before printing the marker
        end
        output = output .. ffi.string(buffer, count)
        code = output:match(EXIT_MARKER .. "(%d+)\n$")
    end
    C.pclose(pipe)
    return tonumber(code) or -1, (output:gsub(EXIT_MARKER .. "%d*\n?$", ""))
end

-- ============= HTTP =============

--- Downloads url into path. Redirects are followed and HTTP errors fail the transfer.
---@param url string
---@param path string
---@param on_progress? fun(received: number, expected: number) expected is -1 when unknown
---@param is_cancelled? fun(): boolean
---@return boolean|nil ok
---@return string|nil error M.CANCELLED when is_cancelled() aborted the transfer
function M.download(url, path, on_progress, is_cancelled)
    local curl, load_error = native.curl()
    if not curl then
        return nil, load_error
    end
    local file = C.fopen(path, "wb")
    if file == nil then
        return nil, "cannot write " .. path
    end

    local easy = curl.curl_easy_init()
    local multi = curl.curl_multi_init()
    local error_buffer = ffi.new("char[256]")
    local function long(value)
        return ffi.cast("long", value)
    end
    curl.curl_easy_setopt(easy, native.CURLOPT_URL, url)
    curl.curl_easy_setopt(easy, native.CURLOPT_WRITEDATA, ffi.cast("void *", file))
    curl.curl_easy_setopt(easy, native.CURLOPT_ERRORBUFFER, error_buffer)
    curl.curl_easy_setopt(easy, native.CURLOPT_USERAGENT, USER_AGENT)
    curl.curl_easy_setopt(easy, native.CURLOPT_FOLLOWLOCATION, long(1))
    curl.curl_easy_setopt(easy, native.CURLOPT_MAXREDIRS, long(10))
    curl.curl_easy_setopt(easy, native.CURLOPT_FAILONERROR, long(1))
    curl.curl_easy_setopt(easy, native.CURLOPT_NOSIGNAL, long(1))
    curl.curl_easy_setopt(easy, native.CURLOPT_BUFFERSIZE, long(BUFFER_SIZE))
    curl.curl_easy_setopt(easy, native.CURLOPT_CONNECTTIMEOUT, long(30))
    -- give up on stalled transfers: below 1 KiB/s for a whole minute
    curl.curl_easy_setopt(easy, native.CURLOPT_LOW_SPEED_LIMIT, long(1024))
    curl.curl_easy_setopt(easy, native.CURLOPT_LOW_SPEED_TIME, long(60))
    curl.curl_multi_add_handle(multi, easy)

    local running = ffi.new("int[1]")
    local ready = ffi.new("int[1]")
    local queued = ffi.new("int[1]")
    local received = ffi.new("int64_t[1]")
    local expected = ffi.new("int64_t[1]")
    local ticker = timer(TICK_MS, TICK_MS)

    -- transfers for up to DRAIN_MS, reading data as it arrives; returns an error message on failure
    local function perform()
        local deadline = utils.time_ms() + DRAIN_MS
        while true do
            local status = curl.curl_multi_perform(multi, running)
            local remaining = deadline - utils.time_ms()
            if status == 0 and running[0] ~= 0 and remaining > 0 then
                status = curl.curl_multi_wait(multi, nil, 0, remaining, ready)
            end
            if status ~= 0 then
                return ffi.string(curl.curl_multi_strerror(status))
            end
            if running[0] == 0 or remaining <= 0 then
                return nil
            end
        end
    end

    -- returns nil on success or an error message
    local function transfer()
        while true do
            local perform_error = perform()
            if perform_error then
                return perform_error
            end
            if on_progress then
                curl.curl_easy_getinfo(easy, native.CURLINFO_SIZE_DOWNLOAD_T, received)
                curl.curl_easy_getinfo(easy, native.CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, expected)
                on_progress(tonumber(received[0]), tonumber(expected[0]))
            end
            if running[0] == 0 then
                local message = curl.curl_multi_info_read(multi, queued)
                local code = -1
                if message ~= nil and message.msg == native.CURLMSG_DONE then
                    code = message.data.result
                end
                if code == 0 then
                    return nil
                end
                if error_buffer[0] ~= 0 then
                    return ffi.string(error_buffer)
                end
                return ffi.string(curl.curl_easy_strerror(code))
            end
            if is_cancelled and is_cancelled() then
                return M.CANCELLED
            end
            wait_timer(ticker)
        end
    end

    local ok, result = pcall(transfer)
    C.close(ticker)
    curl.curl_multi_remove_handle(multi, easy)
    curl.curl_easy_cleanup(easy)
    curl.curl_multi_cleanup(multi)
    C.fclose(file)
    if not ok then
        error(result, 0)
    end
    if result then
        return nil, result
    end
    return true
end

--- Fetches a small response (API calls, checksum files) into memory.
---@param url string
---@return string|nil body
---@return string|nil error
function M.fetch(url)
    local path = os.tmpname()
    local ok, err = M.download(url, path)
    local body
    if ok then
        local file = io.open(path, "rb")
        if file then
            body = file:read("*a")
            file:close()
        end
    end
    os.remove(path)
    if not ok then
        return nil, err
    end
    if not body then
        return nil, "could not read the response"
    end
    return body
end

return M
