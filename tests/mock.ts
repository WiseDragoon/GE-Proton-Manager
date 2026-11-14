// Stand-in for Millennium's host process: runs the backend in Millennium's real Lua VM
// binary and speaks its IPC protocol (little-endian u32 length + msgpack frames).
import { encode, decode } from '@msgpack/msgpack';
import net from 'node:net';
import fs from 'node:fs';
import { spawn, type ChildProcess } from 'node:child_process';

const LUAVM = '/usr/lib/millennium/libmillennium_luavm_x64';
// Millennium runs plugin backends inside Steam's runtime container. RUNTIME=1 does the same,
// so the backend sees that environment's libraries (libcurl 7.74, no curl binary).
const STEAM_RUNTIME = (process.env.HOME ?? '') + '/.local/share/Steam/steamrt64/pv-runtime/steam-runtime-steamrt/run';

export interface Vm {
	/** Calls a global backend function the way the frontend does. */
	evaluate(method: string, args?: unknown[]): Promise<{ value: any; ms: number }>;
	/** Sends a raw request to the VM. */
	call(method: string, params?: unknown): Promise<any>;
	/** Changes a plugin setting the way the frontend's usePluginConfig does. */
	setConfig(key: string, value: unknown): Promise<void>;
	logs: string[];
	frontendCalls: any[];
	config: Record<string, unknown>;
	stop(): Promise<void>;
}

export function luavmAvailable() {
	return fs.existsSync(LUAVM);
}

/** sock should be a short relative path: unix socket paths are limited to 108 bytes. */
export async function startVm(opts: { backendDir: string; steamPath: string; sock: string; verbose?: boolean }): Promise<Vm> {
	try {
		fs.unlinkSync(opts.sock);
	} catch {}
	const logs: string[] = [];
	const frontendCalls: any[] = [];
	const config: Record<string, unknown> = {};
	const pending = new Map<number, (msg: any) => void>();
	let nextId = 1;
	let conn!: net.Socket;
	let child!: ChildProcess;

	const send = (msg: unknown) => {
		const payload = encode(msg);
		const header = Buffer.alloc(4);
		header.writeUInt32LE(payload.length);
		conn.write(Buffer.concat([header, Buffer.from(payload)]));
	};
	const call = (method: string, params: unknown = null) =>
		new Promise<any>((resolve, reject) => {
			const id = nextId++;
			pending.set(id, (msg) => (msg.error ? reject(new Error(msg.error)) : resolve(msg.result)));
			send({ type: 'req', id, method, params });
		});

	const handleRequest = (method: string, params: any): unknown => {
		switch (method) {
			case 'ready':
				return { ok: true };
			case 'steam_path':
				return { path: opts.steamPath };
			case 'version':
				return { version: '3.0.0-test' };
			case 'install_path':
				return { path: '/usr/lib/millennium' };
			case 'config_get':
				return { value: config[params.key] ?? null };
			case 'config_set':
				config[params.key] = params.value;
				return { ok: true };
			case 'config_delete':
				delete config[params.key];
				return { ok: true };
			case 'config_get_all':
				return { config };
			case 'call_frontend_method':
				frontendCalls.push(params);
				return { success: true, returnJson: null };
			default:
				return { error: 'mock: unsupported ' + method };
		}
	};

	const connected = new Promise<void>((resolve, reject) => {
		const server = net.createServer((socket) => {
			conn = socket;
			let buffer = Buffer.alloc(0);
			socket.on('data', (chunk) => {
				buffer = Buffer.concat([buffer, chunk]);
				while (buffer.length >= 4) {
					const len = buffer.readUInt32LE(0);
					if (buffer.length < 4 + len) break;
					const msg: any = decode(buffer.subarray(4, 4 + len));
					buffer = buffer.subarray(4 + len);
					if (msg.type === 'res') {
						pending.get(msg.id)?.(msg);
						pending.delete(msg.id);
					} else if (msg.type === 'notify' && msg.method === 'log') {
						const line = `[${msg.params.level}] ${msg.params.message}`;
						logs.push(line);
						if (opts.verbose) console.log('  VM', line);
					} else if (msg.type === 'req') {
						send({ type: 'res', id: msg.id, result: handleRequest(msg.method, msg.params) });
					}
				}
			});
			server.close();
			resolve();
		});
		server.listen(opts.sock);
		// the container sees the host's /usr under /run/host
		const command = process.env.RUNTIME ? [STEAM_RUNTIME, '--', '/run/host' + LUAVM] : [LUAVM];
		child = spawn(command[0], [...command.slice(1), opts.sock], { stdio: ['ignore', 'ignore', opts.verbose ? 'inherit' : 'ignore'] });
		child.on('exit', (code) => {
			server.close();
			reject(new Error(`the Lua VM exited before connecting (code ${code})`));
		});
	});
	await connected;
	const init = await call('init', {
		plugin_name: 'ge-proton-manager',
		backend_dir: opts.backendDir,
		backend_file: opts.backendDir + '/main.lua',
		plugin_format: 0,
		steam_path: opts.steamPath,
	});
	if (!init?.ok) throw new Error('init failed: ' + JSON.stringify(init));

	return {
		logs,
		frontendCalls,
		config,
		call,
		async evaluate(methodName, args = []) {
			const started = performance.now();
			const res = await call('evaluate', { methodName, argumentList: args });
			const ms = performance.now() - started;
			if (!res.success) throw new Error(`${methodName}: ${res.error}`);
			return { value: res.value, ms };
		},
		async setConfig(key, value) {
			config[key] = value;
			await call('config_changed', { key, value });
		},
		async stop() {
			try {
				await Promise.race([call('shutdown'), new Promise((resolve) => setTimeout(resolve, 2000))]);
			} catch {}
			conn.destroy();
			child.kill();
		},
	};
}
