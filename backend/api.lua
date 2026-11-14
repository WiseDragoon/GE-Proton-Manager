-- State shared with the frontend and the functions it calls (marked ---@ffi).
-- Every call returns immediately; downloads and installs run as background tasks and
-- the frontend polls get_state() for progress.

local logger = require("logger")
local millennium = require("millennium")
local async = require("async")
local github = require("github")
local tools = require("tools")

local M = {}

local AUTO_UPDATE_KEY = "auto_update_latest"
local ARCH_KEY = "architecture" -- "auto", "x86_64" or "aarch64"
local STARTUP_DELAY_MS = 60 * 1000
local CHECK_INTERVAL_MS = 6 * 60 * 60 * 1000
local RETRY_INTERVAL_MS = 30 * 60 * 1000
local RELEASES_TTL_S = 10 * 60

-- Architecture this plugin's process runs as. Millennium only ships x86 builds, so on
-- an ARM machine running Steam under emulation this is still x86_64: the architecture
-- setting overrides it.
local DETECTED_ARCH = jit.arch == "arm64" and "aarch64" or "x86_64"
local ARCHITECTURES = { x86_64 = true, aarch64 = true }
local arch = DETECTED_ARCH

local releases = {
    list = {},        -- newest first
    complete = false, -- list holds every release, not just the newest ones
    fetched_at = 0,
    loading = false,
    error = nil,
    revision = 0,     -- bumped whenever what get_releases() returns changes
}

local job = nil  -- operation running now
local queue = {} -- operations waiting for it, oldest first
local last_result = nil

-- The release GE-Proton-latest should contain.
local function newest()
    return github.latest(releases.list, arch)
end

-- Must run inside a task. A partial fetch refreshes only the newest releases.
local function load_releases(complete)
    releases.loading = true
    local ok, list, err, is_complete = pcall(github.fetch, complete and 10 or 1, complete and 100 or 10)
    releases.loading = false
    if not ok then
        list, err = nil, tostring(list)
    end
    if not list then
        releases.error = err
        logger:warn("Fetching releases failed: " .. tostring(err))
        return nil, err
    end
    releases.error = nil
    if complete then
        releases.complete = is_complete
    else
        local fetched = {}
        for _, release in ipairs(list) do
            fetched[release.tag] = true
        end
        for _, release in ipairs(releases.list) do
            if not fetched[release.tag] then
                list[#list + 1] = release
            end
        end
    end
    releases.list = list
    releases.fetched_at = os.time()
    releases.revision = releases.revision + 1
    return newest()
end

local function find_release(tag)
    for _, release in ipairs(releases.list) do
        if release.tag == tag then
            return release
        end
    end
    return nil
end

local function notify_frontend(ok, message)
    local called, err = pcall(function()
        millennium.call_frontend_method("notify", { ok, message })
    end)
    if not called then
        logger:warn("Could not notify the frontend: " .. tostring(err))
    end
end

-- Starts the oldest queued operation, unless one is running. Each outcome with a message
-- is shown as a toast.
local function run_next()
    if job or #queue == 0 then
        return
    end
    local current = table.remove(queue, 1)
    job = current
    async.spawn(current.kind .. " " .. current.target, function()
        local called, ok, message = pcall(current.work, current)
        if not called then
            ok, message = false, "Internal error: " .. tostring(ok)
        end
        if not ok then
            logger:error(current.target .. ": " .. tostring(message))
        elseif message then
            logger:info(message)
        end
        job = nil
        if message then
            last_result = { id = (last_result and last_result.id or 0) + 1, target = current.target, ok = ok, message = message }
            notify_frontend(ok, message)
        end
        run_next()
    end)
end

local function pending(kind, target)
    if job and job.kind == kind and job.target == target then
        return true
    end
    for _, operation in ipairs(queue) do
        if operation.kind == kind and operation.target == target then
            return true
        end
    end
    return false
end

--- Queues work(operation); operations run one at a time, in the order they were queued.
--- work returns ok and a message to show, or no message to finish silently.
---@param internal? boolean housekeeping the frontend does not show
---@return string|nil error why it was not queued
local function enqueue(kind, target, tag, work, internal)
    if pending(kind, target) then
        return target .. " is already " .. (kind == "remove" and "being removed" or "being installed")
    end
    queue[#queue + 1] = { kind = kind, target = target, tag = tag, work = work, internal = internal, stage = "pending", downloaded = 0, total = 0, cancel = false }
    run_next()
    return nil
end

local function install(release, as_latest)
    local build = release.builds[arch]
    if not build then
        return release.tag .. " has no " .. arch .. " build"
    end
    local to_install = {
        tag = release.tag,
        arch = arch,
        url = build.url,
        size = build.size,
        checksum_url = build.checksum_url,
    }
    return enqueue("install", as_latest and tools.LATEST or release.tag, release.tag, function(current)
        -- checked here as well as before swapping, to avoid a pointless download
        if as_latest and tools.in_use(tools.LATEST) then
            return false, tools.LATEST .. " is in use by a running game, close it and try again"
        end
        local name, replaced = tools.install(to_install, current, as_latest)
        if not name then
            return false, replaced
        end
        if as_latest and replaced then
            return true, name .. " updated to " .. release.tag
        end
        local message = name .. " installed" .. (as_latest and " (" .. release.tag .. ")" or "")
        -- Steam only picks up new tools when it starts
        return true, replaced and message or message .. ". Restart Steam to use it"
    end)
end

-- The installed GE-Proton-latest, and whether it should be replaced: it holds another
-- release or another architecture than the newest one.
local function latest_status(installed)
    for _, tool in ipairs(installed) do
        if tool.name == tools.LATEST then
            local target = newest()
            return tool, target ~= nil and (tool.tag ~= target.tag or tool.arch ~= arch)
        end
    end
    return nil, false
end

local function auto_update_enabled()
    return millennium.config.get(AUTO_UPDATE_KEY) ~= false
end

-- Must run inside a task. Returns the delay until the next check.
local function check_latest()
    -- a queued removal would otherwise be undone by the update queued behind it
    if not auto_update_enabled() or not tools.find(tools.LATEST) or pending("remove", tools.LATEST) then
        return CHECK_INTERVAL_MS
    end
    local target = load_releases(false)
    if not target then
        return RETRY_INTERVAL_MS
    end
    local _, outdated = latest_status(tools.list())
    if not outdated then
        return CHECK_INTERVAL_MS
    end
    if tools.in_use(tools.LATEST) then
        logger:info(tools.LATEST .. " update to " .. target.tag .. " postponed")
        return RETRY_INTERVAL_MS
    end
    if not install(target, true) then -- otherwise it is queued already
        logger:info("Updating " .. tools.LATEST .. " to " .. target.tag .. " (" .. arch .. ")")
    end
    return CHECK_INTERVAL_MS
end

local function auto_update_loop()
    async.sleep(STARTUP_DELAY_MS)
    while true do
        local ok, delay = pcall(check_latest)
        if not ok then
            logger:error("Update check failed: " .. tostring(delay))
        end
        async.sleep(ok and delay or RETRY_INTERVAL_MS)
    end
end

local function set_arch(setting)
    arch = ARCHITECTURES[setting] and setting or DETECTED_ARCH
end

function M.start()
    if millennium.config.get(AUTO_UPDATE_KEY) == nil then
        millennium.config.set(AUTO_UPDATE_KEY, true)
    end
    set_arch(millennium.config.get(ARCH_KEY))
    millennium.config.on_change(AUTO_UPDATE_KEY, function(_, enabled)
        if enabled == true then
            async.spawn("update check", check_latest)
        end
    end)
    millennium.config.on_change(ARCH_KEY, function(_, setting)
        set_arch(setting)
        releases.revision = releases.revision + 1 -- sizes and availability depend on it
        async.spawn("update check", check_latest) -- GE-Proton-latest follows it
    end)
    logger:info("Managing " .. arch .. " GE-Proton builds in " .. tools.compat_dir())
    -- queued, so no install or removal can start while it deletes the scratch directory
    enqueue("cleanup", "", nil, function()
        tools.clean_work_dir()
        return true
    end, true)
    async.spawn("auto update", auto_update_loop)
end

-- ============= Frontend API =============

---@class GeRelease
---@field tag string
---@field published_at string ISO 8601
---@field size number size of the build for the current architecture, 0 when there is none
---@field prerelease boolean

---@class GeTool
---@field name string directory inside compatibilitytools.d
---@field tool_name string name Steam knows the tool by
---@field tag string|nil release tag it was installed from, when known
---@field arch string

---@class GeJob
---@field kind string "install" or "remove"
---@field target string directory being installed or removed
---@field tag string|nil release being installed
---@field stage string "pending", "download", "verify", "extract", "install" or "remove"
---@field downloaded number
---@field total number

---@class GeQueued
---@field kind string "install" or "remove"
---@field target string
---@field tag string|nil

---@class GeJobResult
---@field id integer increases with every finished operation
---@field target string
---@field ok boolean
---@field message string

---@class GeState
---@field compat_dir string
---@field arch string architecture of the builds being installed
---@field detected_arch string architecture used when the setting is "auto"
---@field latest_name string directory and Steam tool name of the auto-updating build
---@field latest GeRelease|nil newest stable release, once known
---@field latest_installed string|nil tag installed as GE-Proton-latest ("" when unknown, nil when not installed)
---@field latest_update_available boolean
---@field installed GeTool[] every other installed build
---@field job GeJob|nil operation running now
---@field queue GeQueued[] operations waiting for it, oldest first
---@field last_result GeJobResult|nil
---@field releases_revision integer
---@field releases_loading boolean
---@field releases_error string|nil
---@field restart_required boolean Steam has not seen the builds as they are now

local function public_release(release)
    local build = release.builds[arch]
    return {
        tag = release.tag,
        published_at = release.published_at,
        size = build and build.size or 0,
        prerelease = release.prerelease,
    }
end

---@ffi
---@return GeState
function get_state()
    local all = tools.list()
    local installed = {}
    for _, tool in ipairs(all) do
        if tool.name ~= tools.LATEST then
            installed[#installed + 1] = tool
        end
    end
    local latest_tool, outdated = latest_status(all)
    local target = newest()
    local waiting = {}
    for _, operation in ipairs(queue) do
        if not operation.internal then
            waiting[#waiting + 1] = { kind = operation.kind, target = operation.target, tag = operation.tag }
        end
    end
    return {
        compat_dir = tools.compat_dir(),
        arch = arch,
        detected_arch = DETECTED_ARCH,
        latest_name = tools.LATEST,
        latest = target and public_release(target) or nil,
        latest_installed = latest_tool and (latest_tool.tag or "") or nil,
        latest_update_available = outdated,
        installed = installed,
        job = job and not job.internal and {
            kind = job.kind,
            target = job.target,
            tag = job.tag,
            stage = job.stage,
            downloaded = job.downloaded,
            total = job.total,
        } or nil,
        queue = waiting,
        last_result = last_result,
        releases_revision = releases.revision,
        releases_loading = releases.loading,
        releases_error = releases.error,
        restart_required = tools.restart_required(all),
    }
end

---@ffi
---@return GeRelease[]
function get_releases()
    local list = {}
    for i, release in ipairs(releases.list) do
        list[i] = public_release(release)
    end
    return list
end

---@ffi
--- Fetches the release list from GitHub unless a recent one is cached.
---@param force boolean
---@return boolean started
function refresh_releases(force)
    if releases.loading then
        return false
    end
    if not force and releases.complete and os.time() - releases.fetched_at < RELEASES_TTL_S then
        return false
    end
    releases.loading = true
    async.spawn("refresh releases", load_releases, true)
    return true
end

---@ffi
---@param tag string
---@return string|nil error
function install_release(tag)
    local release = find_release(tag)
    if not release then
        return "Unknown release: " .. tostring(tag)
    end
    return install(release, false)
end

---@ffi
--- Installs or updates GE-Proton-latest.
---@return string|nil error
function install_latest()
    local target = newest()
    if not target then
        return "The newest release is not known yet, refresh the list first"
    end
    return install(target, true)
end

---@ffi
---@param name string
---@return string|nil error
function remove_tool(name)
    if not tools.find(name) then
        return tostring(name) .. " is not installed"
    end
    return enqueue("remove", name, nil, function(current)
        current.stage = "remove"
        local ok, err = tools.remove(name)
        if not ok then
            return false, err
        end
        return true, name .. " removed"
    end)
end

---@ffi
--- Aborts the operation on target if it is running, or drops it from the queue.
---@param target string
---@return boolean cancelled whether there was such an operation
function cancel(target)
    if job and job.target == target then
        job.cancel = true
        return true
    end
    for i, operation in ipairs(queue) do
        if operation.target == target then
            table.remove(queue, i)
            return true
        end
    end
    return false
end

return M
