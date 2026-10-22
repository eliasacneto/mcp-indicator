import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {basename, displayName} from './detector.js';

const heldProcs = [];

export function delay(ms) {
    return new Promise(resolve => {
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
            resolve();
            return GLib.SOURCE_REMOVE;
        });
    });
}

export function isLocalHttp(server) {
    return (server.transport === 'http' || server.transport === 'sse') && server.httpLocal;
}

export function releaseHeld() {
    for (const proc of heldProcs) {
        try {
            proc.force_exit();
        } catch {
            /* ignore */
        }
    }
    heldProcs.length = 0;
}

function readTextFile(path) {
    try {
        const file = Gio.File.new_for_path(path);
        if (!file.query_exists(null))
            return null;
        const [, bytes] = file.load_contents(null);
        return new TextDecoder('utf-8').decode(bytes);
    } catch {
        return null;
    }
}

export function loadUserServiceUnits() {
    const dir = GLib.build_filenamev([GLib.get_user_config_dir(), 'systemd', 'user']);
    const units = [];
    let enumerator;
    try {
        enumerator = Gio.File.new_for_path(dir).enumerate_children(
            'standard::name',
            Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
            null
        );
    } catch {
        return units;
    }

    let info;
    while ((info = enumerator.next_file(null)) !== null) {
        const name = info.get_name();
        if (!name.endsWith('.service'))
            continue;
        const text = readTextFile(GLib.build_filenamev([dir, name]));
        if (!text)
            continue;
        const joined = text.replace(/\\\n/g, ' ');
        const execStarts = [];
        for (const line of joined.split('\n')) {
            if (line.startsWith('ExecStart='))
                execStarts.push(line.slice('ExecStart='.length).replace(/^[@:~-]+/, '').trim());
        }
        units.push({
            name,
            execStart: execStarts.join(' '),
        });
    }
    try {
        enumerator.close(null);
    } catch {
        /* ignore */
    }
    return units;
}

export function unitForServer(server, units) {
    const short = displayName(server.name);
    for (const unit of units) {
        const base = unit.name.replace(/\.service$/, '');
        if (base === server.name || base === short)
            return unit.name;
    }

    const genericCmd = new Set(['python', 'python3', 'node', 'nodejs', 'npx', 'bash', 'sh']);
    const cmdBase = basename(server.command || '');
    if (server.command && !genericCmd.has(cmdBase)) {
        const hits = units.filter(u => (u.execStart || '').includes(server.command));
        if (hits.length === 1)
            return hits[0].name;
    }

    const distinctive = (server.args || []).filter(a =>
        String(a).includes('/') || /mcp/i.test(String(a)));
    if (distinctive.length) {
        const hits = units.filter(u =>
            distinctive.every(a => (u.execStart || '').includes(String(a))));
        if (hits.length === 1)
            return hits[0].name;
    }

    if (server.httpPort) {
        const hits = units.filter(u => {
            const exec = u.execStart || '';
            return exec.includes(`:${server.httpPort}`) ||
                exec.includes(`--port ${server.httpPort}`) ||
                exec.includes(`--port=${server.httpPort}`);
        });
        if (hits.length === 1)
            return hits[0].name;
    }
    return null;
}

export function isUnitActive(unit) {
    if (!unit)
        return false;
    try {
        const [ok, stdout] = GLib.spawn_sync(
            null,
            ['systemctl', '--user', 'is-active', unit],
            null,
            GLib.SpawnFlags.SEARCH_PATH,
            null
        );
        const text = new TextDecoder('utf-8').decode(stdout).trim();
        return Boolean(ok) && text === 'active';
    } catch {
        return false;
    }
}

export function attachUnits(servers) {
    const units = loadUserServiceUnits();
    for (const server of servers) {
        server.unit = unitForServer(server, units);
        server.unitActive = server.unit ? isUnitActive(server.unit) : false;
        if (server.unit && !configArgv(server)) {
            const match = units.find(u => u.name === server.unit);
            if (match?.execStart)
                server.unitArgv = match.execStart.split(/\s+/).filter(Boolean);
        }
    }
}

export function readArgv(pid) {
    if (!Number.isInteger(pid) || pid <= 1)
        return null;
    try {
        const [, bytes] = Gio.File.new_for_path(`/proc/${pid}/cmdline`).load_contents(null);
        const parts = new TextDecoder('utf-8').decode(bytes).split('\0').filter(Boolean);
        return parts.length ? parts : null;
    } catch {
        return null;
    }
}

export function pidAlive(pid) {
    if (!Number.isInteger(pid) || pid <= 1)
        return false;
    return Gio.File.new_for_path(`/proc/${pid}`).query_exists(null);
}

function cmdlineOf(pid) {
    const argv = readArgv(pid);
    return argv ? argv.join(' ') : '';
}

export function pidsStillOurs(pids, server) {
    const out = [];
    for (const pid of pids || []) {
        if (!pidAlive(pid))
            continue;
        const cmd = cmdlineOf(pid);
        if (!cmd)
            continue;
        const command = server.command || '';
        const base = basename(command);
        if (command && (cmd.includes(command) || (base && cmd.includes(base)))) {
            out.push(pid);
            continue;
        }
        if (server.httpPort && cmd.includes(String(server.httpPort))) {
            out.push(pid);
            continue;
        }
        const name = String(server.name || '');
        if (name && cmd.toLowerCase().includes(name.toLowerCase())) {
            out.push(pid);
            continue;
        }
        if (server.orphan)
            out.push(pid);
    }
    return out;
}

function signalPids(pids, signal) {
    for (const pid of pids) {
        if (!Number.isInteger(pid) || pid <= 1)
            continue;
        try {
            Gio.Subprocess.new(
                ['kill', `-${signal}`, String(pid)],
                Gio.SubprocessFlags.NONE
            );
        } catch (error) {
            console.error(`[MCP Indicator] kill -${signal} ${pid}: ${error}`);
        }
    }
}

export function systemctlUser(action, unit) {
    return new Promise(resolve => {
        try {
            const proc = Gio.Subprocess.new(
                ['systemctl', '--user', action, unit],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            );
            proc.communicate_utf8_async(null, null, (p, res) => {
                try {
                    const [, stdout, stderr] = p.communicate_utf8_finish(res);
                    const ok = p.get_exit_status() === 0;
                    const err = `${stderr || ''}${stdout || ''}`.trim();
                    resolve({ok, error: ok ? '' : (err || `systemctl ${action} ${unit}`)});
                } catch (error) {
                    resolve({ok: false, error: error.message});
                }
            });
        } catch (error) {
            resolve({ok: false, error: error.message});
        }
    });
}

export async function stopServer(server) {
    if (server.unit)
        return systemctlUser('stop', server.unit);

    const first = pidsStillOurs(server.pids || [], server);
    if (first.length === 0)
        return {ok: true, error: ''};
    signalPids(first, 'TERM');
    await delay(700);
    const leftover = pidsStillOurs(first, server);
    if (leftover.length)
        signalPids(leftover, 'KILL');
    return {ok: true, error: ''};
}

export function configArgv(server) {
    if (server.command && !String(server.command).includes(' '))
        return [server.command, ...(server.args || []).map(String)];
    return null;
}

export function liveArgv(server) {
    for (const pid of server.pids || []) {
        const argv = readArgv(pid);
        if (argv && argv.length)
            return argv;
    }
    return configArgv(server) || server.unitArgv || null;
}

function isContainerArgv(argv) {
    const base = basename(argv?.[0] || '');
    return base === 'docker' || base === 'podman';
}

function resolveCommand(command) {
    if (!command)
        return command;
    if (command.includes('/'))
        return command;
    const home = GLib.get_home_dir();
    const candidates = [
        `${home}/.nvm/versions/node/v22.21.1/bin/${command}`,
        `${home}/.local/bin/${command}`,
        `/usr/local/bin/${command}`,
        `/usr/bin/${command}`,
    ];
    for (const path of candidates) {
        if (Gio.File.new_for_path(path).query_exists(null))
            return path;
    }
    return command;
}

function prepareArgv(argv) {
    const out = argv.map(String);
    out[0] = resolveCommand(out[0]);
    const base = basename(out[0]);
    if ((base === 'npx' || out[0].endsWith('/npx')) &&
        !out.includes('-y') && !out.includes('--yes'))
        out.splice(1, 0, '-y');
    return out;
}

export function spawnArgv(argv, {keepStdin = false} = {}) {
    if (!argv || argv.length === 0)
        return {ok: false, error: 'sem comando'};
    if (isContainerArgv(argv))
        return {ok: false, error: 'não inicio docker direto; use o serviço systemd'};
    const resolved = prepareArgv(argv);
    try {
        let flags = Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_PIPE;
        flags |= keepStdin
            ? Gio.SubprocessFlags.STDIN_PIPE
            : Gio.SubprocessFlags.STDIN_INHERIT;
        const launcher = new Gio.SubprocessLauncher({flags});
        const home = GLib.get_home_dir();
        const path = [
            `${home}/.local/bin`,
            `${home}/.nvm/versions/node/v22.21.1/bin`,
            GLib.getenv('PATH') || '/usr/bin:/bin',
        ].join(':');
        launcher.setenv('PATH', path, true);
        launcher.setenv('HOME', home, false);
        const proc = launcher.spawnv(resolved);
        if (keepStdin)
            heldProcs.push(proc);
        else
            proc.wait_async(null, () => {});
        return {ok: true, error: ''};
    } catch (error) {
        console.error(`[MCP Indicator] spawn failed: ${error}`);
        return {ok: false, error: error.message};
    }
}

export function canDaemonStart(server) {
    if (server.unit)
        return true;
    if (isLocalHttp(server))
        return true;
    return false;
}

export async function startServer(server, argv) {
    if (server.unit) {
        const action = server.unitActive ? 'restart' : 'start';
        return systemctlUser(action, server.unit);
    }
    if (isLocalHttp(server))
        return spawnArgv(argv, {keepStdin: false});
    return {ok: false, error: 'stdio: o cliente (Cursor/Claude/VS Code) é quem inicia'};
}

export async function restartServer(server, argv) {
    if (server.unit)
        return systemctlUser('restart', server.unit);
    if (isLocalHttp(server)) {
        const stopped = await stopServer(server);
        if (!stopped.ok)
            return stopped;
        await delay(250);
        return spawnArgv(argv, {keepStdin: false});
    }
    return stopServer(server);
}

export function fetchLogs(server, lines = 25) {
    if (!server.unit)
        return {ok: false, lines: [], text: 'sem journal (não é unit systemd)'};
    try {
        const env = [
            ...(GLib.get_environ() || []),
            'SYSTEMD_COLORS=0',
            'SYSTEMD_URLIFY=0',
        ];
        const [ok, stdout, stderr] = GLib.spawn_sync(
            null,
            ['journalctl', '--user', '-u', server.unit, '-n', String(lines), '--no-pager', '-o', 'cat'],
            env,
            GLib.SpawnFlags.SEARCH_PATH,
            null
        );
        const raw = new TextDecoder('utf-8').decode(ok ? stdout : stderr)
            .replace(/\x1b\[[0-9;]*m/g, '')
            .trim();
        const logLines = raw ? raw.split('\n').filter(Boolean).slice(-lines) : [];
        return {
            ok: Boolean(ok && logLines.length),
            lines: logLines,
            text: raw,
        };
    } catch (error) {
        return {ok: false, lines: [], text: error.message};
    }
}

export function probeTcp(host, port, cancellable = null) {
    return new Promise(resolve => {
        const client = new Gio.SocketClient({timeout: 1});
        const target = host === 'localhost' || host === '0.0.0.0' || host === '::1'
            ? '127.0.0.1'
            : host;
        client.connect_to_host_async(target, port, cancellable, (src, res) => {
            try {
                const conn = client.connect_to_host_finish(res);
                try {
                    conn.close(null);
                } catch {
                    /* ignore */
                }
                resolve(true);
            } catch {
                resolve(false);
            }
        });
    });
}

export async function waitForTcp(host, port, timeoutMs, cancellable = null) {
    const deadline = GLib.get_monotonic_time() + timeoutMs * 1000;
    while (GLib.get_monotonic_time() < deadline) {
        if (cancellable?.is_cancelled())
            return false;
        if (await probeTcp(host, port, cancellable))
            return true;
        await delay(500);
    }
    return false;
}
