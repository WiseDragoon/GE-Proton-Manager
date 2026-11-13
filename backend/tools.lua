-- GE-Proton builds inside Steam's compatibilitytools.d directory.
-- install() and remove() must be called from an async task.

local fs = require("fs")
local millennium = require("millennium")
local async = require("async")

local M = {}

--- Directory (and Steam tool name) of the build that follows the newest release.
M.LATEST = "GE-Proton-latest"

-- Scratch space inside compatibilitytools.d, so finished builds can be moved into place
-- atomically. Steam only registers tools whose own directory holds a compatibilitytool.vdf.
local WORK_DIR = ".ge-proton-manager.tmp"
-- Written into every build this plugin installs: "<release tag> <architecture>". The
-- `version` file cannot be used for this: GE-Proton-latest's names GE-Proton-latest
-- itself, and other builds' sometimes hold a git describe string.
local MARKER_FILE = ".ge-proton-manager"
-- Free space required before downloading: the archive plus the unpacked build (~3x).
local SPACE_FACTOR = 4

local steam_root

local function steam_dir()
    if not steam_root then
        local steam = millennium.steam_path()
        if not steam or steam == "" then
            steam = (os.getenv("HOME") or "") .. "/.steam/steam"
        end
        -- ~/.steam/steam is usually a symlink; show and use the real location
        steam_root = fs.canonical(steam) or steam
    end
    return steam_root
end

---@return string
function M.compat_dir()
    return fs.join(steam_dir(), "compatibilitytools.d")
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function write_file(path, content)
    local file, err = io.open(path, "wb")
    if not file then
        return nil, err
    end
    local ok, write_err = file:write(content)
    file:close()
    if not ok then
        return nil, write_err
    end
    return true
end

--- Whether name is a directory this plugin may manage: a single path segment that
--- looks like a GE-Proton build ("GE-Proton10-34", "GE-Proton11-12-x86_64",
--- "Proton-6.21-GE-2", "GE-Proton-latest").
---@param name any
---@return boolean
function M.is_ge_name(name)
    return type(name) == "string"
        and name:sub(1, 1) ~= "."
        and not name:find("/", 1, true)
        and (name:find("GE%-Proton") or name:find("Proton%-GE") or name:find("%-GE%-")) ~= nil
end

local function vdf_tool_name(vdf)
    return vdf and vdf:match('"compat_tools"%s*{%s*"([^"]+)"')
end

-- Release tag and architecture of a build installed by another tool, from its name.
local function guess_tag(name)
    if name == M.LATEST then
        return nil
    end
    return (name:gsub("^Proton%-", ""):gsub("%-x86_64$", ""):gsub("%-aarch64$", ""))
end

local function guess_arch(name)
    return name:find("aarch64", 1, true) and "aarch64" or "x86_64"
end

---@class InstalledTool
---@field name string directory name
---@field tool_name string name Steam knows the tool by
---@field tag string|nil release tag, when known
---@field arch string architecture of the build

--- GE-Proton builds currently installed.
---@return InstalledTool[]
function M.list()
    local tools = {}
    for _, entry in ipairs(fs.list(M.compat_dir()) or {}) do
        if entry.is_directory and M.is_ge_name(entry.name) then
            local vdf = read_file(fs.join(entry.path, "compatibilitytool.vdf"))
            if vdf then
                local tag, arch = (read_file(fs.join(entry.path, MARKER_FILE)) or ""):match("^%s*(%S*)%s*(%S*)")
                tools[#tools + 1] = {
                    name = entry.name,
                    tool_name = vdf_tool_name(vdf) or entry.name,
                    tag = tag ~= "" and tag or guess_tag(entry.name),
                    arch = arch ~= "" and arch or guess_arch(entry.name),
                }
            end
        end
    end
    return tools
end

---@param name string
---@return InstalledTool|nil
function M.find(name)
    for _, tool in ipairs(M.list()) do
        if tool.name == name then
            return tool
        end
    end
    return nil
end

-- Steam scans compatibilitytools.d only when it starts. Its logs/compat_log.txt records
-- each start ("Client version: ...") and every tool it registers, right after the folder
-- it was read from: the only record of which builds the running Steam knows.
local SESSION_START = "Client version:"
local registered = { stamp = nil, names = nil }

local function last_find(text, needle)
    local found, position = nil, 1
    while true do
        local at = text:find(needle, position, true)
        if not at then
            return found
        end
        found, position = at, at + 1
    end
end

-- Log of the running Steam session. Steam moves the log to compat_log.previous.txt when it
-- grows past ~8 MB, which can happen moments after it started.
local function current_session(logs)
    local current = read_file(fs.join(logs, "compat_log.txt")) or ""
    local start = last_find(current, SESSION_START)
    if start then
        return current:sub(start)
    end
    local previous = read_file(fs.join(logs, "compat_log.previous.txt")) or ""
    start = last_find(previous, SESSION_START)
    return start and previous:sub(start) .. current or nil
end

-- Tool names the running Steam registered from compatibilitytools.d, nil if unknown.
local function registered_with_steam()
    local logs = fs.join(steam_dir(), "logs")
    local log = fs.join(logs, "compat_log.txt")
    local stamp = tostring(fs.file_size(log)) .. ":" .. tostring(fs.last_write_time(log))
    if registered.stamp ~= stamp then
        local session = current_session(logs)
        local names = nil
        if session then
            names = {}
            local dir = M.compat_dir()
            dir = fs.canonical(dir) or dir
            -- Steam writes this log with \r\n line endings
            local pattern = "Processing local tool list at ([^\r\n]*)/[^/\r\n]+/compatibilitytool%.vdf%.%.%.\r?\n[^\r\n]*Registering tool ([^\r\n]*), AppID 0"
            for folder, name in session:gmatch(pattern) do
                if fs.canonical(folder) == dir then
                    names[name] = true
                end
            end
        end
        registered.stamp, registered.names = stamp, names
    end
    return registered.names
end

--- Whether Steam must restart to see the builds as they are now: one was added that it
--- did not register when it started, or one it registered has been removed.
---@param tools InstalledTool[]
---@return boolean
function M.restart_required(tools)
    local names = registered_with_steam()
    if not names then
        return false
    end
    local present = {}
    for _, tool in ipairs(tools) do
        present[tool.tool_name] = true
        if not names[tool.tool_name] then
            return true
        end
    end
    for name in pairs(names) do
        if not present[name] then
            return true
        end
    end
    return false
end

--- Whether a running process (the proton script, wineserver, a game) uses the build.
--- Replacing or deleting it underneath a running game would crash the game.
---@param name string
---@return boolean
function M.in_use(name)
    local ok, entries = pcall(fs.list, "/proc")
    if not ok or not entries then
        return true -- cannot tell, so assume it is
    end
    local needle = "/compatibilitytools.d/" .. name .. "/"
    for _, entry in ipairs(entries) do
        if entry.name:match("^%d+$") then
            local cmdline = read_file("/proc/" .. entry.name .. "/cmdline")
            if cmdline and cmdline:find(needle, 1, true) then
                return true
            end
        end
    end
    return false
end

local function remove_tree(path)
    async.run("rm -rf " .. async.quote(path))
end

-- Deletes an operation's scratch directory, and the scratch root once it is empty.
local function clear_work(path)
    remove_tree(path)
    os.remove(fs.join(M.compat_dir(), WORK_DIR))
end

--- Removes leftovers of operations interrupted by Steam exiting.
function M.clean_work_dir()
    remove_tree(fs.join(M.compat_dir(), WORK_DIR))
end

-- Turns an unpacked build into GE-Proton-latest. Steam maps games to the internal name
-- in compatibilitytool.vdf and lists the tool under the name in its `version` file
-- ("<build timestamp> <name>"), so both must say GE-Proton-latest for games set to it
-- to keep using it, under that name, across updates.
local function rename_tool(path, new_name)
    local vdf_file = fs.join(path, "compatibilitytool.vdf")
    local vdf = read_file(vdf_file)
    local old_name = vdf_tool_name(vdf)
    if not old_name then
        return nil, "compatibilitytool.vdf has an unexpected format"
    end
    local escaped = old_name:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    vdf = vdf:gsub(escaped, new_name)
    vdf = vdf:gsub('("display_name"%s*)"[^"]*"', '%1"' .. new_name .. '"')
    local ok, err = write_file(vdf_file, vdf)
    if not ok then
        return nil, err
    end

    local version_file = fs.join(path, "version")
    local version = read_file(version_file)
    if not version then
        return nil, "the build has no version file"
    end
    local timestamp = version:match("^(%d+)%s")
    return write_file(version_file, (timestamp and timestamp .. " " or "") .. new_name .. "\n")
end

---@class InstallProgress
---@field stage string
---@field downloaded number
---@field total number
---@field cancel boolean

---@class BuildToInstall
---@field tag string release tag
---@field arch string
---@field url string
---@field size number
---@field checksum_url string|nil

--- Downloads, verifies and installs a build. Progress is reported through job and
--- setting job.cancel aborts at the next checkpoint.
---@param release BuildToInstall
---@param job InstallProgress
---@param as_latest boolean install as GE-Proton-latest instead of the release's own directory
---@return string|nil name installed directory
---@return string|boolean error, or whether an existing build was replaced
function M.install(release, job, as_latest)
    local dir = M.compat_dir()
    local work = fs.join(dir, WORK_DIR, "job")
    local function fail(message)
        clear_work(work)
        return nil, message
    end

    remove_tree(work)
    local created, create_error = fs.create_directories(work)
    if created == nil then
        return nil, "Cannot create " .. work .. ": " .. tostring(create_error)
    end

    local space = fs.space_info(dir)
    local needed = release.size * SPACE_FACTOR
    if space and space.available < needed then
        return fail(string.format("Not enough free disk space: %.1f GB needed, %.1f GB available",
            needed / 1e9, space.available / 1e9))
    end

    job.stage = "download"
    job.total = release.size
    local archive = fs.join(work, "archive" .. (release.url:match("%.tar%.[gx]z$") or ".tar.gz"))
    local downloaded, download_error = async.download(release.url, archive, function(received, expected)
        job.downloaded = received
        if expected > 0 then
            job.total = expected
        end
    end, function()
        return job.cancel
    end)
    if not downloaded then
        return fail(download_error == async.CANCELLED and "Cancelled" or ("Download failed: " .. download_error))
    end
    if fs.file_size(archive) ~= release.size then
        return fail("Download incomplete, please try again")
    end

    if release.checksum_url then
        job.stage = "verify"
        local checksum, checksum_error = async.fetch(release.checksum_url)
        if not checksum then
            return fail("Could not download the checksum: " .. checksum_error)
        end
        local expected = checksum:match("^%s*(%x+)")
        local code, output = async.run("sha512sum " .. async.quote(archive))
        local actual = code == 0 and output:match("^(%x+)") or nil
        if not expected or not actual or actual:lower() ~= expected:lower() then
            return fail("Checksum mismatch, the download is corrupt")
        end
    end
    if job.cancel then
        return fail("Cancelled")
    end

    job.stage = "extract"
    local unpacked = fs.join(work, "unpacked")
    fs.create_directories(unpacked)
    -- the archive is deleted with the rest of `work` by clear_work(), in the background:
    -- unlinking a ~500 MB file here would block the plugin for a noticeable time
    local code, output = async.run("tar -xf " .. async.quote(archive) .. " -C " .. async.quote(unpacked))
    if code ~= 0 then
        return fail("Extraction failed: " .. output)
    end
    local entries = fs.list(unpacked) or {}
    local root = entries[1]
    if #entries ~= 1 or not root.is_directory or not fs.is_file(fs.join(root.path, "compatibilitytool.vdf")) then
        return fail("The archive does not contain a compatibility tool")
    end

    local name = as_latest and M.LATEST or root.name
    if not M.is_ge_name(name) then
        return fail("Unexpected build name: " .. name)
    end
    if as_latest then
        local renamed, rename_error = rename_tool(root.path, M.LATEST)
        if not renamed then
            return fail("Could not prepare " .. M.LATEST .. ": " .. tostring(rename_error))
        end
    end
    local marked, mark_error = write_file(fs.join(root.path, MARKER_FILE), release.tag .. " " .. release.arch .. "\n")
    if not marked then
        return fail("Could not write to the build: " .. tostring(mark_error))
    end
    if job.cancel then
        return fail("Cancelled")
    end

    job.stage = "install"
    local target = fs.join(dir, name)
    local previous = fs.join(work, "previous")
    local replacing = fs.exists(target)
    if replacing then
        if M.in_use(name) then
            return fail(name .. " is in use by a running game, close it and try again")
        end
        local moved, move_error = fs.rename(target, previous)
        if not moved then
            return fail("Could not replace " .. name .. ": " .. tostring(move_error))
        end
    end
    local placed, place_error = fs.rename(root.path, target)
    if not placed then
        if fs.exists(previous) then
            fs.rename(previous, target)
        end
        return fail("Could not install " .. name .. ": " .. tostring(place_error))
    end
    clear_work(work)
    return name, replacing
end

--- Deletes an installed build.
---@param name string
---@return boolean|nil ok
---@return string|nil error
function M.remove(name)
    if not M.is_ge_name(name) then
        return nil, "Not a GE-Proton build: " .. tostring(name)
    end
    local dir = M.compat_dir()
    local path = fs.join(dir, name)
    if not fs.is_directory(path) then
        return nil, name .. " is not installed"
    end
    if M.in_use(name) then
        return nil, name .. " is in use by a running game, close it and try again"
    end
    -- move it out of compatibilitytools.d first so Steam never sees a half-deleted tool
    local trash = fs.join(dir, WORK_DIR, "removed-" .. name)
    fs.create_directories(fs.join(dir, WORK_DIR))
    remove_tree(trash)
    local moved, move_error = fs.rename(path, trash)
    if not moved then
        return nil, "Could not remove " .. name .. ": " .. tostring(move_error)
    end
    clear_work(trash)
    return true
end

return M
