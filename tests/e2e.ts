// End-to-end tests: runs the backend in Millennium's Lua VM against a fake Steam folder
// and fake GE-Proton releases (file:// downloads), driving it the way the frontend does.
//
//   bun run test             (RUNTIME=1 runs it inside Steam's runtime container, like Millennium)
//
// Needs Millennium installed (its Lua VM binary) and tar, gzip and sha512sum.
import { startVm, luavmAvailable, type Vm } from './mock';
import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

if (!luavmAvailable()) {
	console.error('Millennium is not installed: its Lua VM is needed to run the backend');
	process.exit(2);
}

const BACKEND = path.resolve(import.meta.dir, '../backend');
const LATEST = 'GE-Proton-latest';
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'gpm-test-'));
const STEAM = TMP + '/steam';
const CT = STEAM + '/compatibilitytools.d';
const WORK = CT + '/.ge-proton-manager.tmp';
process.chdir(TMP); // keeps the VM's socket path short

let failures = 0;
function check(name: string, condition: boolean, detail: unknown = '') {
	console.log(`${condition ? 'PASS' : 'FAIL'} ${name}${condition ? '' : ' :: ' + JSON.stringify(detail)}`);
	if (!condition) failures++;
}
const read = (file: string) => (fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null);
const marker = (name: string) => read(`${CT}/${name}/.ge-proton-manager`)?.trim();
function sh(command: string) {
	const result = spawnSync('bash', ['-c', command], { encoding: 'utf8' });
	if (result.status !== 0) throw new Error(`${command}: ${result.stderr}`);
	return result.stdout;
}

// ---------- fixtures ----------

function vdf(name: string) {
	return `"compatibilitytools"\n{\n  "compat_tools"\n  {\n    "${name}" // Internal name of this tool\n    {\n      "install_path" "."\n      "display_name" "${name}"\n      "from_oslist"  "windows"\n      "to_oslist"    "linux"\n    }\n  }\n}\n`;
}

function installedTool(name: string) {
	fs.mkdirSync(`${CT}/${name}`, { recursive: true });
	fs.writeFileSync(`${CT}/${name}/compatibilitytool.vdf`, vdf(name));
	fs.writeFileSync(`${CT}/${name}/version`, `1600000000 ${name}\n`);
}

// A release archive like GE's: one directory holding the tool, plus a .sha512sum file.
function archive(dir: string, opts: { checksum?: 'good' | 'bad' | 'none'; escaping?: boolean } = {}) {
	const assets = TMP + '/assets';
	const file = `${assets}/${dir}.tar.gz`;
	if (opts.escaping) {
		// a malicious archive: every member tries to escape the extraction directory
		fs.mkdirSync(assets, { recursive: true });
		sh(`python3 -I -c 'import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as tar:
    for i in range(200):
        info = tarfile.TarInfo("../escaped-%d" % i)
        info.size = 2
        tar.addfile(info, io.BytesIO(b"x\\n"))' '${file}'`);
	} else {
		const source = `${TMP}/src/${dir}`;
		fs.mkdirSync(source + '/files', { recursive: true });
		fs.writeFileSync(source + '/compatibilitytool.vdf', vdf(dir));
		fs.writeFileSync(source + '/version', `1700000000 ${dir}\n`);
		fs.writeFileSync(source + '/proton', '#!/bin/sh\n', { mode: 0o755 });
		fs.writeFileSync(source + '/files/filler', crypto.randomBytes(2 * 1024 * 1024));
		fs.mkdirSync(assets, { recursive: true });
		sh(`tar -C '${TMP}/src' -czf '${file}' '${dir}'`);
	}
	const list = [{ name: `${dir}.tar.gz`, browser_download_url: 'file://' + file, size: fs.statSync(file).size }];
	const checksum = opts.checksum ?? 'good';
	if (checksum !== 'none') {
		const sum = checksum === 'good' ? sh(`sha512sum '${file}'`).split(' ')[0] : '0'.repeat(128);
		fs.writeFileSync(`${assets}/${dir}.sha512sum`, `${sum}  ${dir}.tar.gz\n`);
		list.push({ name: `${dir}.sha512sum`, browser_download_url: `file://${assets}/${dir}.sha512sum`, size: 150 });
	}
	return list;
}

function release(tag: string, date: string, assets: unknown[], prerelease = false) {
	return { tag_name: tag, published_at: date, prerelease, draft: false, assets };
}

const releases = [
	release('GE-Proton99-4', '2026-11-04T00:00:00Z', archive('GE-Proton99-4-x86_64'), true),
	release('GE-Proton99-3', '2026-11-03T00:00:00Z', [...archive('GE-Proton99-3-x86_64'), ...archive('GE-Proton99-3-aarch64')]),
	release('GE-Proton99-2', '2026-11-02T00:00:00Z', archive('GE-Proton99-2-x86_64')),
	release('GE-Proton99-1', '2026-11-01T00:00:00Z', archive('GE-Proton99-1-x86_64')),
	release('GE-Proton99-0', '2026-10-31T00:00:00Z', archive('GE-Proton99-0-x86_64', { checksum: 'bad' })),
	release('GE-Proton98-9', '2026-10-30T00:00:00Z', archive('GE-Proton98-9-x86_64', { checksum: 'none', escaping: true })),
	release('6.5-GE-1', '2021-03-30T00:00:00Z', archive('Proton-6.5-GE-1', { checksum: 'none' })),
];
fs.writeFileSync(TMP + '/releases.json', JSON.stringify(releases));

// Serves the fake releases instead of GitHub's API, and lets tests slow operations down.
fs.writeFileSync(
	TMP + '/inject.lua',
	`local async = require("async")
local real_fetch, real_download = async.fetch, async.download
local slow_download, slow_api = nil, nil
async.fetch = function(url)
    local page = url:match("^https://api%.github%.com/.-[?&]page=(%d+)")
    if not page then return real_fetch(url) end
    if slow_api then async.sleep(slow_api) end
    if page ~= "1" then return "[]" end
    local file = io.open(${JSON.stringify(TMP + '/releases.json')}, "rb")
    local body = file:read("*a")
    file:close()
    return body
end
async.download = function(...)
    if slow_download then async.sleep(slow_download) end
    return real_download(...)
end
function test_slow(download_ms, api_ms)
    slow_download = download_ms > 0 and download_ms or nil
    slow_api = api_ms > 0 and api_ms or nil
end
`,
);

// Steam's state: two tools registered at its last start, and a non-GE directory.
installedTool(LATEST);
installedTool('GE-Proton9-1');
fs.mkdirSync(CT + '/NotGE');
fs.mkdirSync(STEAM + '/logs');
const registered = [LATEST, 'GE-Proton9-1']
	.map((name) => `[2026-11-13 10:00:01] Processing local tool list at ${CT}/${name}/compatibilitytool.vdf...\r\n[2026-11-13 10:00:01] Registering tool ${name}, AppID 0\r\n`)
	.join('');
fs.writeFileSync(STEAM + '/logs/compat_log.txt', `[2026-11-13 10:00:00] Client version: 1763000000\r\n${registered}`);

// Leftovers of an install interrupted by Steam exiting: big enough that deleting them takes a while.
sh(`mkdir -p '${WORK}/job/unpacked/junk' && cd '${WORK}/job/unpacked/junk' && seq 1 30000 | xargs touch`);

// ---------- helpers ----------

const vm: Vm = await startVm({ backendDir: BACKEND, steamPath: STEAM, sock: 'vm.sock', verbose: !!process.env.VERBOSE });
await vm.evaluate('dofile', [TMP + '/inject.lua']);

const state = async () => (await vm.evaluate('get_state')).value;
const slow = (downloadMs: number, apiMs = 0) => vm.evaluate('test_slow', [downloadMs, apiMs]);

/** Polls like the frontend until pred holds; reports the slowest backend answer. */
async function waitFor(pred: (s: any) => boolean, timeoutMs = 30000) {
	const started = Date.now();
	let maxMs = 0;
	const stages = new Set<string>();
	while (Date.now() - started < timeoutMs) {
		const { value, ms } = await vm.evaluate('get_state');
		maxMs = Math.max(maxMs, ms);
		if (value.job) stages.add(value.job.stage);
		if (pred(value)) return { state: value, maxMs, stages: [...stages] };
		await Bun.sleep(25);
	}
	throw new Error('timed out: ' + JSON.stringify(await state()));
}
const idle = () => waitFor((s) => !s.job && Object.keys(s.queue ?? {}).length === 0 && !s.releases_loading);
const queueOf = (s: any) => (Array.isArray(s.queue) ? s.queue : []).map((op: any) => `${op.kind} ${op.target}`);

/** Starts an operation and waits for its result. */
async function operation(fn: string, args: unknown[] = []) {
	const before = (await state()).last_result?.id ?? 0;
	const error = (await vm.evaluate(fn, args)).value;
	if (error) return { error, result: undefined as any, maxMs: 0, stages: [] as string[] };
	const done = await waitFor((s) => !s.job && (s.last_result?.id ?? 0) > before);
	return { error: undefined, result: done.state.last_result, maxMs: done.maxMs, stages: done.stages };
}

/** A process whose command line refers to a tool, like a running game's proton script. */
function fakeGame(name: string): ChildProcess {
	// `; true` stops bash from replacing itself with sleep, which would drop the path
	return spawn('bash', ['-c', 'sleep 60; true', `${CT}/${name}/proton`], { stdio: 'ignore' });
}

// ---------- tests ----------

try {
	// Ask for an install right away, while the startup cleanup is still deleting leftovers.
	await vm.evaluate('refresh_releases', [true]);
	await waitFor((s) => !s.releases_loading && s.releases_revision > 0);
	await slow(150); // local downloads are too quick to see their stages otherwise
	let r = await operation('install_release', ['GE-Proton99-1']);
	await slow(0);
	check('install requested during startup cleanup succeeds', r.result?.ok === true, r);
	check('startup cleanup removed leftovers', !fs.existsSync(WORK + '/job/unpacked/junk'));
	check('install went through download and verify', ['download', 'verify'].every((s) => r.stages.includes(s)), r.stages);
	check('backend stayed responsive during install (<50 ms)', r.maxMs < 50, r.maxMs);
	check('installed under its archive directory name', fs.existsSync(CT + '/GE-Proton99-1-x86_64/proton'));
	check('marker records tag and architecture', marker('GE-Proton99-1-x86_64') === 'GE-Proton99-1 x86_64', marker('GE-Proton99-1-x86_64'));
	check('scratch directory removed', !fs.existsSync(WORK));
	check('installing a new tool requires a Steam restart', (await state()).restart_required === true);

	let s = await state();
	check('latest is the newest stable release', s.latest?.tag === 'GE-Proton99-3', s.latest);
	check('unknown GE-Proton-latest counts as outdated', s.latest_update_available === true && s.latest_installed === '', s);
	const list: any[] = (await vm.evaluate('get_releases')).value;
	check('release list shows which releases publish a checksum', list.find((x) => x.tag === 'GE-Proton99-1')?.verified === true && list.find((x) => x.tag === '6.5-GE-1')?.verified === false, list);

	r = await operation('install_release', ['GE-Proton99-0']);
	check('checksum mismatch rejected', r.result?.ok === false && /Checksum/.test(r.result.message), r);
	check('nothing installed after a checksum mismatch', !fs.existsSync(CT + '/GE-Proton99-0-x86_64'));

	r = await operation('install_release', ['GE-Proton98-9']);
	check('extraction failure reported', r.result?.ok === false && /^Extraction failed/.test(r.result.message), r);
	check('extraction failure message stays short', (r.result?.message?.length ?? 0) <= 400, r.result?.message?.length);
	check('archive members cannot escape the extraction directory', sh(`find '${TMP}' -name 'escaped-*'`).trim() === '');

	r = await operation('install_release', ['6.5-GE-1']);
	check('release without a checksum installs', r.result?.ok === true && fs.existsSync(CT + '/Proton-6.5-GE-1/proton'), r);

	check('unknown tag rejected', /Unknown release/.test((await vm.evaluate('install_release', ['../../etc'])).value ?? ''));
	check('removing a non-GE directory rejected', /not installed/.test((await vm.evaluate('remove_tool', ['NotGE'])).value ?? ''));
	check('path traversal rejected', /not installed/.test((await vm.evaluate('remove_tool', ['../GE-Proton9-1'])).value ?? ''));

	// GE-Proton-latest in use by a game
	let game = fakeGame(LATEST);
	await Bun.sleep(100);
	r = await operation('install_latest');
	check('GE-Proton-latest not updated while in use', r.result?.ok === false && /in use/.test(r.result.message), r);
	r = await operation('remove_tool', [LATEST]);
	check('GE-Proton-latest not removed while in use', r.result?.ok === false && /in use/.test(r.result.message), r);
	game.kill();
	await Bun.sleep(100);

	r = await operation('install_latest');
	check('GE-Proton-latest installed', r.result?.ok === true, r);
	const latestVdf = read(`${CT}/${LATEST}/compatibilitytool.vdf`) ?? '';
	check('vdf internal and display names are GE-Proton-latest', /"compat_tools"\s*{\s*"GE-Proton-latest"/.test(latestVdf) && /"display_name"\s*"GE-Proton-latest"/.test(latestVdf), latestVdf);
	check('version file names GE-Proton-latest', read(`${CT}/${LATEST}/version`) === `1700000000 ${LATEST}\n`, read(`${CT}/${LATEST}/version`));
	check('GE-Proton-latest marker records the release', marker(LATEST) === 'GE-Proton99-3 x86_64', marker(LATEST));
	s = await state();
	check('GE-Proton-latest up to date', s.latest_installed === 'GE-Proton99-3' && s.latest_update_available === false, s);

	// Queue: operations run one at a time, in order
	await slow(400);
	check('install starts', !(await vm.evaluate('install_release', ['GE-Proton99-2'])).value);
	check('removal queued', !(await vm.evaluate('remove_tool', ['GE-Proton9-1'])).value);
	check('second install queued', !(await vm.evaluate('install_release', ['GE-Proton99-0'])).value);
	check('duplicate install refused', /already being installed/.test((await vm.evaluate('install_release', ['GE-Proton99-2'])).value ?? ''));
	s = await state();
	check('queue lists waiting operations in order', s.job?.target === 'GE-Proton99-2' && queueOf(s).join(',') === 'remove GE-Proton9-1,install GE-Proton99-0', s);
	check('queued operation cancelled', (await vm.evaluate('cancel', ['GE-Proton99-0'])).value === true);
	await idle();
	await slow(0);
	check('queued operations ran', fs.existsSync(CT + '/GE-Proton99-2-x86_64') && !fs.existsSync(CT + '/GE-Proton9-1'));
	check('cancelled operation never ran', !vm.frontendCalls.some((c) => JSON.stringify(c).includes('GE-Proton99-0-x86_64')));

	// Cancelling a running download
	await slow(300);
	await vm.evaluate('install_release', ['GE-Proton99-4']);
	await waitFor((x) => x.job?.target === 'GE-Proton99-4');
	await vm.evaluate('cancel', ['GE-Proton99-4']);
	await idle();
	await slow(0);
	check('cancelled install left nothing behind', !fs.existsSync(CT + '/GE-Proton99-4-x86_64') && !fs.existsSync(WORK));

	// An update check must not reinstall a GE-Proton-latest whose removal is queued
	fs.writeFileSync(`${CT}/${LATEST}/.ge-proton-manager`, 'GE-Proton99-2 x86_64\n'); // make it outdated
	await slow(500);
	await vm.evaluate('install_release', ['GE-Proton99-1']); // keeps the queue busy
	check('GE-Proton-latest removal queued', !(await vm.evaluate('remove_tool', [LATEST])).value);
	await vm.setConfig('auto_update_latest', true); // runs an update check
	await Bun.sleep(200);
	await idle();
	await slow(0);
	check('update check did not undo a queued removal', !fs.existsSync(`${CT}/${LATEST}`), marker(LATEST));

	// GE-Proton-latest follows architecture changes, whenever they happen
	r = await operation('install_latest');
	check('GE-Proton-latest reinstalled', r.result?.ok === true && marker(LATEST) === 'GE-Proton99-3 x86_64', r);
	await slow(500);
	fs.writeFileSync(`${CT}/${LATEST}/.ge-proton-manager`, 'GE-Proton99-2 x86_64\n');
	await vm.evaluate('install_latest');
	await waitFor((x) => x.job?.target === LATEST);
	await vm.setConfig('architecture', 'aarch64'); // while the x86_64 build installs
	await waitFor(() => marker(LATEST) === 'GE-Proton99-3 aarch64', 15000).catch(() => undefined);
	await idle();
	check('architecture changed during an update: GE-Proton-latest follows it', marker(LATEST) === 'GE-Proton99-3 aarch64', marker(LATEST));

	await vm.evaluate('install_release', ['GE-Proton99-1']); // keeps the queue busy
	await vm.setConfig('architecture', 'x86_64'); // queues the update
	await waitFor((x) => queueOf(x).includes('install ' + LATEST), 5000).catch(() => undefined);
	await vm.setConfig('architecture', 'aarch64');
	await vm.setConfig('architecture', 'x86_64'); // changed again while it waits
	await waitFor(() => marker(LATEST) === 'GE-Proton99-3 x86_64', 15000).catch(() => undefined);
	await idle();
	await slow(0);
	check('architecture changed while an update waits: the update uses the current one', marker(LATEST) === 'GE-Proton99-3 x86_64', marker(LATEST));

	// Overlapping release fetches keep reporting "loading" until the last one ends
	await slow(0, 400);
	await vm.evaluate('refresh_releases', [true]);
	await Bun.sleep(200);
	await vm.setConfig('auto_update_latest', true); // update check: fetches the newest releases
	await Bun.sleep(300);
	check('still loading while a second fetch runs', (await state()).releases_loading === true);
	await idle();
	await slow(0, 0);

	check('Steam needs a restart after tools changed', (await state()).restart_required === true);
	const errors = vm.logs.filter((line) => line.startsWith('[error]') && !/Checksum|Extraction|in use|Cancelled/.test(line));
	check('no unexpected backend errors', errors.length === 0, errors);
} catch (error) {
	check('test run completed', false, String(error));
} finally {
	await vm.stop();
}

console.log(failures === 0 ? 'ALL PASSED' : `${failures} FAILED`);
if (failures === 0) fs.rmSync(TMP, { recursive: true, force: true });
else console.log('Test files kept in ' + TMP);
process.exit(failures === 0 ? 0 : 1);
