import {
	definePlugin,
	DialogButton,
	DialogButtonPrimary,
	DialogControlsSectionHeader,
	DropdownItem,
	Field,
	ProgressBar,
	toaster,
	Toggle,
	usePluginConfig,
} from 'millennium';
import { CSSProperties, ReactNode, useEffect, useRef, useState } from 'react';

const TITLE = 'GE-Proton Manager';
const AUTO_UPDATE_KEY = 'auto_update_latest';
const ARCH_KEY = 'architecture';
const INITIAL_RELEASES = 15;
// Millennium shows plugin settings in a narrow side panel: a row holds one compact
// button next to its text; anything wider goes below the text (see Actions).
const BUTTON: CSSProperties = { width: 'auto', minWidth: '100px' };

// Steam spaces dialog sections only inside its own dialogs, which this panel is not.
const SECTION_GAP = '22px';

/** Buttons below a Field's text, one per line across its full width. */
const Actions = ({ children }: { children: ReactNode }) => (
	<div style={{ display: 'flex', flexDirection: 'column', gap: '8px', width: '100%' }}>{children}</div>
);

const Section = ({ title, children }: { title: ReactNode; children: ReactNode }) => (
	<div style={{ marginBottom: SECTION_GAP }}>
		<DialogControlsSectionHeader>{title}</DialogControlsSectionHeader>
		{children}
	</div>
);

// Lua serialises empty tables as {} rather than []
const asList = <T,>(value: T[] | null | undefined): T[] => (Array.isArray(value) ? value : []);
const byNameDescending = (a: { name: string }, b: { name: string }) => b.name.localeCompare(a.name, undefined, { numeric: true });
const formatSize = (bytes: number) => (bytes >= 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : `${Math.round(bytes / 1e6)} MB`);
const formatDate = (iso: string) => (iso ? new Date(iso).toLocaleDateString() : 'Unknown date');

/** Whether an operation on target is running ('running'), waiting in the queue ('queued') or neither. */
function operationOn(state: GeState, kind: string, target: string): 'running' | 'queued' | undefined {
	if (state.job?.kind === kind && state.job.target === target) return 'running';
	return asList(state.queue).some((operation) => operation.kind === kind && operation.target === target) ? 'queued' : undefined;
}

/** @ffi */
export function notify(ok: boolean, message: string): void {
	toaster.toast({ title: ok ? TITLE : `${TITLE}: failed`, body: message });
}

async function run(action: Promise<string | null | undefined>, refresh: () => void) {
	const error = await action;
	if (error) notify(false, error);
	refresh();
}

/** Polls the backend, faster while something is in progress. */
function useBackendState(): [GeState | undefined, string | undefined, () => void] {
	const [state, setState] = useState<GeState>();
	const [error, setError] = useState<string>();
	const [generation, setGeneration] = useState(0);

	useEffect(() => {
		let active = true;
		let timer: number | undefined;
		const poll = async () => {
			let delay = 2000;
			try {
				const next = await backend.get_state();
				if (!active) return;
				setState(next);
				setError(undefined);
				if (next.job || next.releases_loading) delay = 500;
			} catch (failure) {
				if (!active) return;
				setError(failure instanceof Error ? failure.message : String(failure));
			}
			timer = window.setTimeout(poll, delay);
		};
		poll();
		return () => {
			active = false;
			window.clearTimeout(timer);
		};
	}, [generation]);

	return [state, error, () => setGeneration((value) => value + 1)];
}

/**
 * Remove asks for a second click instead of opening a dialog: dialogs open in Steam's main
 * window, behind the settings window this panel is shown in.
 */
function RemoveButton({ state, name, refresh, style }: { state: GeState; name: string; refresh: () => void; style?: CSSProperties }) {
	const [armed, setArmed] = useState(false);
	const removal = operationOn(state, 'remove', name);
	useEffect(() => {
		if (!armed) return undefined;
		const timer = window.setTimeout(() => setArmed(false), 4000);
		return () => window.clearTimeout(timer);
	}, [armed]);
	const onClick = () => {
		if (armed) run(backend.remove_tool(name), refresh);
		setArmed(!armed);
	};
	return (
		<DialogButton style={style} disabled={!!removal} onClick={onClick}>
			{removal === 'running' ? 'Removing…' : removal === 'queued' ? 'Queued' : armed ? 'Confirm' : 'Remove'}
		</DialogButton>
	);
}

const STAGES: Record<string, string> = {
	pending: 'Starting…',
	verify: 'Verifying checksum…',
	extract: 'Extracting…',
	install: 'Installing…',
	remove: 'Removing…',
};

function JobProgress({ job }: { job: GeJob }) {
	const downloading = job.stage === 'download';
	const description = downloading ? `Downloading ${formatSize(job.downloaded)} of ${formatSize(job.total)}` : (STAGES[job.stage] ?? job.stage);
	return (
		<Field label={`${job.kind === 'remove' ? 'Removing' : 'Installing'} ${job.target}`} description={description} childrenLayout="below">
			<div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
				<div style={{ flex: 1 }}>
					<ProgressBar nProgress={downloading && job.total > 0 ? (job.downloaded / job.total) * 100 : 0} indeterminate={!downloading} />
				</div>
				{job.kind === 'install' && (
					<DialogButton style={BUTTON} onClick={() => backend.cancel(job.target)}>
						Cancel
					</DialogButton>
				)}
			</div>
		</Field>
	);
}

function LatestSection({ state, refresh }: { state: GeState; refresh: () => void }) {
	const [autoUpdate, setAutoUpdate] = usePluginConfig<boolean>(AUTO_UPDATE_KEY);
	const installed = state.latest_installed ?? undefined;
	const newest = state.latest?.tag;
	const installing = operationOn(state, 'install', state.latest_name);
	const updatable = installed !== undefined && state.latest_update_available;
	const contents = installed || 'an unknown version';

	let status: string;
	if (installed === undefined) status = 'Not installed';
	else if (updatable) status = `Update available: ${newest}`;
	else if (newest) status = `Up to date: ${installed}`;
	else status = `Contains ${contents}`;

	return (
		<Section title={state.latest_name}>
			<Field
				label={status}
				description={`${updatable ? `Contains ${contents}. ` : ''}Always holds the newest release, so games set to it stay current.`}
				childrenLayout="below"
				childrenContainerWidth="max"
			>
				<Actions>
					<DialogButton disabled={!!installing || !newest || (installed !== undefined && !updatable)} onClick={() => run(backend.install_latest(), refresh)}>
						{installing === 'running' ? 'Installing…' : installing === 'queued' ? 'Queued' : installed === undefined ? 'Install' : updatable ? 'Update' : 'Up to date'}
					</DialogButton>
					{installed !== undefined && <RemoveButton state={state} name={state.latest_name} refresh={refresh} />}
				</Actions>
			</Field>
			<Field label="Update automatically" description="When Steam starts and every 6 hours, never while a game is using it.">
				<Toggle value={autoUpdate !== false} onChange={(checked) => setAutoUpdate(checked)} />
			</Field>
		</Section>
	);
}

function InstalledSection({ state, refresh }: { state: GeState; refresh: () => void }) {
	const tools = asList(state.installed).sort(byNameDescending);
	return (
		<Section title="Installed versions">
			{tools.length === 0 && <Field label="No GE-Proton versions installed" />}
			{tools.map((tool) => (
				<Field key={tool.name} label={tool.name} description={tool.tag && tool.tag !== tool.name ? `Release ${tool.tag}` : undefined}>
					<RemoveButton state={state} name={tool.name} style={BUTTON} refresh={refresh} />
				</Field>
			))}
		</Section>
	);
}

function ReleasesSection({ state, refresh }: { state: GeState; refresh: () => void }) {
	const [releases, setReleases] = useState<GeRelease[]>([]);
	const [showAll, setShowAll] = useState(false);

	useEffect(() => {
		backend.refresh_releases(false).then(refresh);
	}, []);
	useEffect(() => {
		if (state.releases_revision > 0) backend.get_releases().then((list) => setReleases(asList(list)));
	}, [state.releases_revision]);

	const installedTags = new Set(
		asList(state.installed)
			.filter((tool) => tool.arch === state.arch)
			.map((tool) => tool.tag),
	);
	const shown = showAll ? releases : releases.slice(0, INITIAL_RELEASES);

	const buttonLabel = (release: GeRelease) => {
		const installing = operationOn(state, 'install', release.tag);
		if (installing === 'running') return 'Installing…';
		if (installing === 'queued') return 'Queued';
		if (installedTags.has(release.tag)) return 'Installed';
		if (release.size === 0) return 'No build';
		return 'Install';
	};

	return (
		<Section title="Available versions">
			<Field
				label={state.releases_loading ? 'Loading from GitHub…' : `${releases.length} releases`}
				description={state.releases_error ?? 'Downloads are checksum-verified.'}
			>
				<DialogButton style={BUTTON} disabled={state.releases_loading} onClick={() => backend.refresh_releases(true).then(refresh)}>
					Refresh
				</DialogButton>
			</Field>
			{shown.map((release) => (
				<Field
					key={release.tag}
					label={release.tag}
					description={[formatDate(release.published_at), release.size > 0 && formatSize(release.size), release.prerelease && 'Pre-release']
						.filter(Boolean)
						.join(' · ')}
				>
					<DialogButton
						style={BUTTON}
						disabled={buttonLabel(release) !== 'Install'}
						onClick={() => run(backend.install_release(release.tag), refresh)}
					>
						{buttonLabel(release)}
					</DialogButton>
				</Field>
			))}
			{!showAll && releases.length > INITIAL_RELEASES && (
				<Field label={`${releases.length - INITIAL_RELEASES} older releases`}>
					<DialogButton style={BUTTON} onClick={() => setShowAll(true)}>
						Show all
					</DialogButton>
				</Field>
			)}
		</Section>
	);
}

function SettingsSection({ state }: { state: GeState }) {
	const [arch, setArch] = usePluginConfig<string>(ARCH_KEY);
	return (
		<Section title="Settings">
			<DropdownItem
				label="Architecture"
				description="Which build of each release to download. Automatic uses the architecture Steam runs as."
				rgOptions={[
					{ data: 'auto', label: `Automatic (${state.detected_arch})` },
					{ data: 'x86_64', label: 'x86_64' },
					{ data: 'aarch64', label: 'aarch64 (ARM)' },
				]}
				selectedOption={arch ?? 'auto'}
				onChange={(option) => setArch(option.data)}
				layout="below"
				childrenContainerWidth="max"
			/>
			<Field
				label="Install location"
				description={<span style={{ wordBreak: 'break-all' }}>{state.compat_dir}</span>}
			/>
		</Section>
	);
}

/** Steam only reads compatibility tools when it starts. */
function RestartNotice({ label, description }: { label: string; description: string }) {
	return (
		<Field label={label} description={description} childrenLayout="below" childrenContainerWidth="max">
			<Actions>
				<DialogButtonPrimary onClick={() => SteamClient.User.StartRestart(false)}>Restart Steam</DialogButtonPrimary>
			</Actions>
		</Field>
	);
}

const STATUS_BAR: CSSProperties = {
	position: 'sticky',
	top: 0,
	zIndex: 10,
	marginBottom: SECTION_GAP,
	background: '#1e2229',
	boxShadow: '0 8px 12px -6px rgba(0, 0, 0, 0.8)',
};

/**
 * Progress and the restart notice stay pinned to the top while the panel scrolls, so they
 * are seen after installing from far down the list. Should the panel not allow pinning,
 * the bar scrolls into view when something new appears in it instead.
 */
function StatusBar({ state }: { state: GeState }) {
	const bar = useRef<HTMLDivElement>(null);
	const queue = asList(state.queue);
	const visible = !!state.job || queue.length > 0 || state.restart_required;
	useEffect(() => {
		if (visible) bar.current?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
	}, [state.job?.target, queue.length, state.restart_required]);
	if (!visible) return null;
	return (
		<div ref={bar} style={STATUS_BAR}>
			{state.job && <JobProgress job={state.job} />}
			{queue.map((operation) => (
				<Field key={operation.kind + operation.target} label={operation.target} description={operation.kind === 'remove' ? 'Queued for removal' : 'Queued'}>
					<DialogButton style={BUTTON} onClick={() => backend.cancel(operation.target)}>
						Cancel
					</DialogButton>
				</Field>
			))}
			{state.restart_required && (
				<RestartNotice label="Restart Steam to use the changes" description="Steam only detects added or removed versions when it starts." />
			)}
		</div>
	);
}

function SettingsPanel() {
	const [state, error, refresh] = useBackendState();
	if (error) return <RestartNotice label="The backend is not responding" description={`${error}. Restarting Steam starts it again.`} />;
	if (!state) return <Field label="Loading…" />;

	return (
		<>
			<StatusBar state={state} />
			<LatestSection state={state} refresh={refresh} />
			<SettingsSection state={state} />
			<InstalledSection state={state} refresh={refresh} />
			<ReleasesSection state={state} refresh={refresh} />
		</>
	);
}

const Icon = () => (
	<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
		<path d="M12 3v12" />
		<path d="m7 10 5 5 5-5" />
		<path d="M5 21h14" />
	</svg>
);

export default definePlugin(() => ({
	title: TITLE,
	icon: <Icon />,
	content: <SettingsPanel />,
}));
