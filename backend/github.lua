-- GE-Proton releases from GitHub. Must be called from an async task.

local json = require("json")
local async = require("async")

local M = {}

local API = "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases"

-- Newer releases ship one tarball per architecture ("-x86_64", "-aarch64"), older ones a
-- single unsuffixed x86_64 tarball.
local function archive_arch(name)
    return name:find("aarch64", 1, true) and "aarch64" or "x86_64"
end

-- Builds of a release keyed by architecture: { url, size, checksum_url }.
local function parse_builds(assets)
    local builds, names = {}, {}
    for _, asset in ipairs(assets) do
        local name = asset.name
        if type(name) == "string" and name:find("%.tar%.[gx]z$") then
            local arch = archive_arch(name)
            if not builds[arch] or name:find(arch, 1, true) then
                builds[arch] = { url = asset.browser_download_url, size = tonumber(asset.size) or 0 }
                names[arch] = name
            end
        end
    end
    for arch, build in pairs(builds) do
        local checksum_name = names[arch]:gsub("%.tar%.[gx]z$", "") .. ".sha512sum"
        for _, asset in ipairs(assets) do
            if asset.name == checksum_name then
                build.checksum_url = asset.browser_download_url
            end
        end
    end
    return builds
end

local function parse_release(raw)
    if type(raw) ~= "table" or raw.draft == true or type(raw.tag_name) ~= "string" then
        return nil
    end
    return {
        tag = raw.tag_name,
        published_at = type(raw.published_at) == "string" and raw.published_at or "",
        prerelease = raw.prerelease == true,
        builds = parse_builds(type(raw.assets) == "table" and raw.assets or {}),
    }
end

local function describe(err)
    if err:find("403", 1, true) or err:find("429", 1, true) then
        return "GitHub API rate limit reached, try again later"
    end
    return "Could not reach GitHub: " .. err
end

--- Fetches releases, newest first.
---@param max_pages integer
---@param per_page integer
---@return table[]|nil releases
---@return string|nil error
---@return boolean complete whether every release was fetched
function M.fetch(max_pages, per_page)
    local releases = {}
    for page = 1, max_pages do
        local body, err = async.fetch(string.format("%s?per_page=%d&page=%d", API, per_page, page))
        if not body then
            return nil, describe(err), false
        end
        local ok, list = pcall(json.decode, body)
        if not ok or type(list) ~= "table" then
            return nil, "Unexpected response from GitHub", false
        end
        for _, raw in ipairs(list) do
            local release = parse_release(raw)
            if release then
                releases[#releases + 1] = release
            end
        end
        if #list < per_page then
            return releases, nil, true
        end
    end
    return releases, nil, false
end

--- The newest stable GE-Proton release with a build for arch: what GE-Proton-latest
--- tracks. Pre-releases and one-off builds (e.g. "GE-Proton7-51-diablo_4_beta") are skipped.
---@param releases table[]
---@param arch string
---@return table|nil
function M.latest(releases, arch)
    for _, release in ipairs(releases) do
        if not release.prerelease and release.builds[arch] and release.tag:match("^GE%-Proton%d+%-%d+$") then
            return release
        end
    end
    return nil
end

return M
