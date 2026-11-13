local logger = require("logger")
local millennium = require("millennium")
local native = require("native")
local api = require("api")

local function on_load()
    -- Millennium starts plugin processes with PR_SET_PDEATHSIG=SIGHUP, which also fires
    -- when the *thread* that started the process exits (for example after `bun run build`
    -- restarted the plugin through Millennium's developer socket). The Lua host then
    -- treats the interrupted poll() as fatal and shuts the plugin down. Steam exiting is
    -- still noticed: the host stops when its IPC socket closes.
    native.C.signal(native.SIGHUP, native.SIG_IGN)
    api.start()
    millennium.ready()
end

-- Operations still running are abandoned; their leftovers are removed on the next load.
local function on_unload()
    logger:info("GE-Proton Manager unloaded")
end

return {
    on_load = on_load,
    on_unload = on_unload,
}
