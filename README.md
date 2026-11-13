# GE-Proton Manager

A [Millennium](https://github.com/SteamClientHomebrew/Millennium) plugin that installs
[GloriousEggroll's GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom) builds
straight into Steam.

- Lists every GE-Proton release from GitHub and installs or removes any of them. Installs
  and removals queue up and run one after another, even with the panel closed.
- Provides **GE-Proton-latest**, a virtual version that always contains the newest stable
  release. Games set to it keep working across updates because its Steam tool name never
  changes.
- Optionally keeps GE-Proton-latest up to date: checked when Steam starts and every 6 hours.
  An update never replaces it while a running game uses it; it is retried later instead.

Linux only, like GE-Proton itself.

## Building

Requires Millennium 3 (Lua backends) and [Bun](https://bun.sh).

```bash
bun install
bun run build
```

`bun run build` installs the plugin into `~/.local/share/millennium/plugins` and, when
Steam is running, enables and restarts it through Millennium's developer socket.
`bun run dev` does the same on every source change.

## Using it

Open Millennium's settings and select **GE-Proton Manager**.

Steam only detects added or removed compatibility tools when it starts (it has no way to
rescan them), so after installing or removing a version the panel shows a **Restart Steam**
button until Steam has been restarted. Updating GE-Proton-latest needs no restart.

Recent releases are published for x86_64 and aarch64. **Settings → Architecture** picks which
build to download; *Automatic* uses the architecture Steam runs as, which is x86_64 on ARM
machines that run Steam under emulation, so choose aarch64 there.

Builds go to `<Steam>/compatibilitytools.d`, named as in their archive (for example
`GE-Proton11-12-x86_64`, which is also the name Steam shows). Builds installed by other
tools appear in the list as well and can be removed from it.

If something else also maintains `GE-Proton-latest` (for example a separate updater script),
disable one of the two. A GE-Proton-latest that this plugin did not install has an unknown
version, so the first update check replaces it.

## How it works

- `backend/` (Lua) does all the work. Long operations run as background tasks on
  Millennium's coroutine API (`millennium.start_coroutine` / `yield_readable`), so the panel
  stays responsive. Downloads use libcurl through LuaJIT's FFI because Millennium's
  `http.download` blocks the plugin, and every other plugin's calls into its backend, for the
  whole transfer.
- An install downloads to a scratch directory inside `compatibilitytools.d`, checks the
  release's SHA-512 checksum, unpacks it and moves it into place, so Steam never sees a
  partial build. Replacing an existing build is undone if the final move fails.
- GE-Proton-latest is a regular build with its name rewritten in `compatibilitytool.vdf`
  (which Steam maps games to) and in `version` (which Steam lists it under), so Steam only
  ever sees GE-Proton-latest, whichever release it contains.
- Each installed build gets a `.ge-proton-manager` file with the release tag and architecture
  it came from; the `version` file cannot tell, since GE-Proton-latest's is rewritten.
- A build counts as in use when a running process's command line refers to its directory
  (the `proton` script, wineserver).
- Whether Steam needs a restart is read from Steam's own `logs/compat_log.txt`, which lists
  every tool it registered when it last started.
- `frontend/index.tsx` is the settings panel. It polls the backend for progress and shows a
  Steam notification when an operation finishes.
