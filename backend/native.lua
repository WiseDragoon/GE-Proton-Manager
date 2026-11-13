-- LuaJIT FFI bindings for the OS facilities Millennium's Lua API does not offer:
-- timers (timerfd), pipes to subprocesses (popen) and a non-blocking HTTP client
-- (the libcurl multi interface). Millennium's own http.download blocks the plugin's
-- IPC channel for the whole transfer, which is unusable for ~500 MB archives.

local ffi = require("ffi")

ffi.cdef [[
typedef struct FILE FILE;
FILE *popen(const char *command, const char *type);
int pclose(FILE *stream);
int fileno(FILE *stream);
FILE *fopen(const char *path, const char *mode);
int fclose(FILE *stream);
long read(int fd, void *buf, unsigned long count);
int close(int fd);

typedef void (*gpm_sighandler)(int);
gpm_sighandler signal(int signum, gpm_sighandler handler);

typedef struct { long tv_sec; long tv_nsec; } gpm_timespec;
typedef struct { gpm_timespec it_interval; gpm_timespec it_value; } gpm_itimerspec;
int timerfd_create(int clockid, int flags);
int timerfd_settime(int fd, int flags, const gpm_itimerspec *new_value, gpm_itimerspec *old_value);

typedef struct gpm_curl gpm_curl;
typedef struct gpm_curlm gpm_curlm;
typedef struct { int msg; gpm_curl *easy_handle; union { void *whatever; int result; } data; } gpm_curlmsg;
gpm_curl *curl_easy_init(void);
int curl_easy_setopt(gpm_curl *curl, int option, ...);
int curl_easy_getinfo(gpm_curl *curl, int info, ...);
void curl_easy_cleanup(gpm_curl *curl);
const char *curl_easy_strerror(int code);
gpm_curlm *curl_multi_init(void);
int curl_multi_add_handle(gpm_curlm *multi, gpm_curl *easy);
int curl_multi_remove_handle(gpm_curlm *multi, gpm_curl *easy);
int curl_multi_perform(gpm_curlm *multi, int *running_handles);
int curl_multi_wait(gpm_curlm *multi, void *extra_fds, unsigned int extra_nfds, int timeout_ms, int *numfds);
gpm_curlmsg *curl_multi_info_read(gpm_curlm *multi, int *msgs_in_queue);
int curl_multi_cleanup(gpm_curlm *multi);
const char *curl_multi_strerror(int code);
]]

local M = {
    C = ffi.C,

    SIGHUP = 1,
    SIG_IGN = ffi.cast("gpm_sighandler", 1),

    CLOCK_BOOTTIME = 7, -- keeps counting while the machine is suspended
    TFD_NONBLOCK = 2048,
    TFD_CLOEXEC = 524288,

    CURLOPT_WRITEDATA = 10001,
    CURLOPT_URL = 10002,
    CURLOPT_ERRORBUFFER = 10010,
    CURLOPT_USERAGENT = 10018,
    CURLOPT_LOW_SPEED_LIMIT = 19,
    CURLOPT_LOW_SPEED_TIME = 20,
    CURLOPT_FAILONERROR = 45,
    CURLOPT_FOLLOWLOCATION = 52,
    CURLOPT_MAXREDIRS = 68,
    CURLOPT_CONNECTTIMEOUT = 78,
    CURLOPT_BUFFERSIZE = 98,
    CURLOPT_NOSIGNAL = 99,

    CURLINFO_RESPONSE_CODE = 0x200002,
    CURLINFO_SIZE_DOWNLOAD_T = 0x600008,
    CURLINFO_CONTENT_LENGTH_DOWNLOAD_T = 0x60000F,

    CURLMSG_DONE = 1,
}

local curl_lib, curl_error

--- Loads libcurl on first use. Steam's runtime ships libcurl.so.4; the other names
--- cover hosts where the plugin VM runs outside of it.
---@return table|nil lib
---@return string|nil error
function M.curl()
    if curl_lib or curl_error then
        return curl_lib, curl_error
    end
    for _, name in ipairs({ "libcurl.so.4", "libcurl-gnutls.so.4", "curl" }) do
        local ok, lib = pcall(ffi.load, name)
        if ok then
            curl_lib = lib
            return curl_lib
        end
    end
    curl_error = "libcurl could not be loaded"
    return nil, curl_error
end

return M
