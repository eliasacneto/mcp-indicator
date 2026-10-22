import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

export const DEFAULT_CONFIGS = [
    {rel: '.cursor/mcp.json', source: 'Cursor'},
    {rel: '.config/Code/User/mcp.json', source: 'VS Code'},
    {rel: '.config/Code - OSS/User/mcp.json', source: 'VS Code'},
    {rel: '.claude.json', source: 'Claude'},
    {rel: '.config/Claude/claude_desktop_config.json', source: 'Claude Desktop'},
    {rel: '.config/opencode/opencode.json', source: 'OpenCode'},
    {rel: '.gemini/config/mcp_config.json', source: 'Gemini'},
    {rel: '.copilot/mcp-config.json', source: 'Copilot'},
    {rel: '.lmstudio/mcp.json', source: 'LM Studio'},
    {rel: '.codeium/windsurf/mcp_config.json', source: 'Windsurf'},
    {rel: '.config/Cursor/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json', source: 'Cline'},
    {rel: '.vscode/mcp.json', source: 'VS Code'},
];

const GENERIC_COMMANDS = new Set([
    'npx', 'npm', 'pnpm', 'yarn', 'bun', 'deno',
    'uvx', 'uv', 'python', 'python3', 'node', 'nodejs',
    'docker', 'podman', 'sh', 'bash', 'env',
]);

const GENERIC_ARGS = new Set([
    '-y', '--yes', '-yq', '--quiet', '-q', '-i', '--rm',
    'run', 'npx', 'uvx', 'uv', 'python', 'python3',
    'node', 'nodejs', 'bun', 'deno', 'docker', 'podman',
    '--registry',
]);

export function expandUser(path) {
    if (!path)
        return path;
    if (path === '~')
        return GLib.get_home_dir();
    if (path.startsWith('~/'))
        return GLib.build_filenamev([GLib.get_home_dir(), path.slice(2)]);
    return path;
}

export function basename(path) {
    if (!path)
        return '';
    const i = String(path).lastIndexOf('/');
    return i >= 0 ? path.slice(i + 1) : path;
}

export function displayName(name) {
    const text = String(name || '');
    if (text.includes('/'))
        return text.slice(text.lastIndexOf('/') + 1);
    return text;
}

function distinctiveArgs(args) {
    const out = [];
    const list = args || [];
    for (let i = 0; i < list.length; i++) {
        const a = String(list[i]);
        if (GENERIC_ARGS.has(a) || a === '--registry') {
            if (a === '--registry' && i + 1 < list.length)
                i++;
            continue;
        }
        if (a.startsWith('--registry='))
            continue;
        if (a.length > 1)
            out.push(a);
    }
    return out;
}

export function parseJsonLoose(text) {
    if (!text || !String(text).trim())
        return null;
    try {
        return JSON.parse(text);
    } catch {
        let s = String(text).replace(/\/\*[\s\S]*?\*\//g, '');
        s = s.replace(/(^|[^:\\])\/\/.*$/gm, '$1');
        s = s.replace(/,\s*([}\]])/g, '$1');
        try {
            return JSON.parse(s);
        } catch {
            return null;
        }
    }
}

export function parseHttpUrl(url) {
    const m = String(url || '').match(
        /^(https?):\/\/([^/?#:]+)(?::(\d+))?(\/[^?#]*)?/i
    );
    if (!m)
        return null;
    const scheme = m[1].toLowerCase();
    const host = m[2].toLowerCase();
    const port = Number(m[3]) || (scheme === 'https' ? 443 : 80);
    const path = m[4] || '/';
    const local = ['127.0.0.1', 'localhost', '::1', '0.0.0.0', '[::1]'].includes(host);
    return {scheme, host, port, path, local, href: url};
}

export function loadBytes(path, cancellable = null) {
    return new Promise(resolve => {
        const file = Gio.File.new_for_path(path);
        file.load_contents_async(cancellable, (src, res) => {
            try {
                const [, bytes] = src.load_contents_finish(res);
                resolve(bytes && bytes.length ? bytes : null);
            } catch {
                resolve(null);
            }
        });
    });
}

export async function readTextFile(path, cancellable = null) {
    const bytes = await loadBytes(path, cancellable);
    if (!bytes)
        return null;
    return new TextDecoder('utf-8').decode(bytes);
}

function normalizeServer(name, cfg, source) {
    if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg))
        return null;

    const disabled = cfg.disabled === true || cfg.enabled === false;
    let command = cfg.command || null;
    let args = Array.isArray(cfg.args) ? cfg.args.map(String) : [];

    if (Array.isArray(command)) {
        args = command.slice(1).map(String);
        command = command[0] ? String(command[0]) : null;
    } else if (command != null) {
        command = String(command);
    }

    const url = cfg.url || cfg.serverUrl || cfg.httpUrl || null;
    const type = String(cfg.type || '').toLowerCase();
    const isHttp = Boolean(url) ||
        type === 'http' || type === 'sse' || type === 'remote' || type === 'streamable-http';

    if (!command && !url)
        return null;

    const parsed = url ? parseHttpUrl(url) : null;
    return {
        name: String(name),
        source,
        command,
        args,
        url: url ? String(url) : null,
        transport: isHttp ? (type === 'sse' ? 'sse' : 'http') : 'stdio',
        disabled,
        httpHost: parsed?.host || null,
        httpPort: parsed?.port || null,
        httpPath: parsed?.path || null,
        httpLocal: parsed?.local || false,
    };
}

export function extractServers(data, source) {
    if (!data || typeof data !== 'object')
        return [];

    const buckets = [];
    if (data.mcpServers && typeof data.mcpServers === 'object' && !Array.isArray(data.mcpServers))
        buckets.push(data.mcpServers);
    if (data.servers && typeof data.servers === 'object' && !Array.isArray(data.servers))
        buckets.push(data.servers);
    if (data.mcp && typeof data.mcp === 'object' && !Array.isArray(data.mcp))
        buckets.push(data.mcp);

    const out = [];
    for (const bucket of buckets) {
        for (const [name, cfg] of Object.entries(bucket)) {
            const server = normalizeServer(name, cfg, source);
            if (server)
                out.push(server);
        }
    }
    return out;
}

export function identityFor(server) {
    if (server.url) {
        const parsed = parseHttpUrl(server.url);
        if (parsed) {
            const host = parsed.local ? '127.0.0.1' : parsed.host;
            return `http:${host}:${parsed.port}${parsed.path}`;
        }
        return `http:${server.url}`;
    }
    const base = basename(server.command || server.name);
    const dist = distinctiveArgs(server.args).join(' ');
    return `stdio:${base}:${dist}`;
}

function mergeServers(list) {
    const map = new Map();
    for (const server of list) {
        const id = identityFor(server);
        const prev = map.get(id);
        if (!prev) {
            map.set(id, {
                ...server,
                id,
                sources: [server.source],
                pids: [],
            });
            continue;
        }
        if (!prev.sources.includes(server.source))
            prev.sources.push(server.source);
        prev.disabled = prev.disabled && server.disabled;
        if (!prev.command && server.command) {
            prev.command = server.command;
            prev.args = server.args;
        }
        if (!prev.url && server.url) {
            prev.url = server.url;
            prev.httpHost = server.httpHost;
            prev.httpPort = server.httpPort;
            prev.httpPath = server.httpPath;
            prev.httpLocal = server.httpLocal;
            prev.transport = server.transport;
        }
    }
    return [...map.values()];
}

export async function loadConfiguredServers(extraPaths = []) {
    const home = GLib.get_home_dir();
    const specs = DEFAULT_CONFIGS.map(item => ({
        path: GLib.build_filenamev([home, item.rel]),
        source: item.source,
    }));
    for (const raw of extraPaths) {
        const path = expandUser(String(raw).trim());
        if (path)
            specs.push({path, source: 'Extra'});
    }

    const found = [];
    const errors = [];
    const seen = new Set();
    const unique = [];
    for (const spec of specs) {
        if (seen.has(spec.path))
            continue;
        seen.add(spec.path);
        unique.push(spec);
    }
    const texts = await Promise.all(unique.map(spec => readTextFile(spec.path)));
    for (let i = 0; i < unique.length; i++) {
        const text = texts[i];
        if (text === null)
            continue;
        const spec = unique[i];
        const data = parseJsonLoose(text);
        if (!data) {
            errors.push(`${spec.source}: JSON inválido em ${spec.path}`);
            continue;
        }
        found.push(...extractServers(data, spec.source));
    }
    return {servers: mergeServers(found), errors};
}

export async function listUserProcesses() {
    const names = [];
    let enumerator;
    try {
        enumerator = Gio.File.new_for_path('/proc').enumerate_children(
            'standard::name',
            Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
            null
        );
    } catch {
        return [];
    }

    let info;
    while ((info = enumerator.next_file(null)) !== null) {
        const name = info.get_name();
        if (/^\d+$/.test(name))
            names.push(name);
    }
    try {
        enumerator.close(null);
    } catch {
        /* ignore */
    }

    const jobs = names.map(async name => {
        const bytes = await loadBytes(`/proc/${name}/cmdline`);
        if (!bytes)
            return null;
        const cmdline = new TextDecoder('utf-8').decode(bytes).replace(/\0/g, ' ').trim();
        if (!cmdline)
            return null;
        const cbytes = await loadBytes(`/proc/${name}/comm`);
        const comm = cbytes ? new TextDecoder('utf-8').decode(cbytes).trim() : '';
        return {pid: Number(name), cmdline, comm};
    });
    return (await Promise.all(jobs)).filter(Boolean);
}

function escapeRe(value) {
    return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function hasToken(cmdline, token) {
    if (!token)
        return false;
    const re = new RegExp(`(?:^|[\\s/])${escapeRe(token)}(?:\\s|$)`);
    return re.test(cmdline);
}

export function processMatchesStdio(proc, server) {
    if (!server.command)
        return false;
    const cmd = proc.cmdline;
    const base = basename(server.command);
    const hasCommand = cmd.includes(server.command) || hasToken(cmd, base);
    if (!hasCommand)
        return false;

    const distinctive = distinctiveArgs(server.args);
    if (GENERIC_COMMANDS.has(base) && distinctive.length === 0)
        return false;
    if (distinctive.length === 0)
        return hasCommand;
    return distinctive.every(a => cmd.includes(String(a)));
}

export function processMatchesHttp(proc, server) {
    const port = server.httpPort;
    if (port) {
        const portRe = new RegExp(`(?:--port[= ]|:)${port}\\b`);
        if (portRe.test(proc.cmdline))
            return true;
    }
    const name = String(server.name || '');
    if (proc.comm === name && /\bserve\b/.test(proc.cmdline) && !/\bstatus\b/.test(proc.cmdline))
        return true;
    if (name && proc.cmdline.includes(name) && /\bserve\b/.test(proc.cmdline) &&
        !/\bstatus\b/.test(proc.cmdline) && !/\bextract\b/.test(proc.cmdline))
        return true;
    return false;
}

export function looksLikeMcpProcess(proc) {
    const {cmdline, comm} = proc;
    if (/(?:^|\s)--type=(renderer|gpu-process|utility|zygote)(?:\s|$)/.test(cmdline))
        return false;
    if (comm === 'ChatGPT' || cmdline.includes('/usr/lib/chatgpt/'))
        return false;
    if (/^(docker|podman)\s+run\b/.test(cmdline))
        return false;
    if (/cursor-memory-mcp\/web\.py/.test(cmdline))
        return false;
    if (comm === 'ai-memory' && /\bstatus\b/.test(cmdline) && !/\bserve\b/.test(cmdline))
        return false;

    if (cmdline.includes('modelcontextprotocol'))
        return true;
    if (/-mcp\.(mjs|js|cjs|ts|py)\b/.test(cmdline) || /mcp-server/.test(cmdline))
        return true;
    if (comm === 'gk' && /\bmcp\b/.test(cmdline))
        return true;
    if (comm === 'ai-memory' && /\bserve\b/.test(cmdline))
        return true;
    if (/cursor-memory-mcp\/server\.py/.test(cmdline))
        return true;
    if (/\/mcp[\w.-]*\.(mjs|js|cjs|ts|py)\b/.test(cmdline))
        return true;
    return false;
}

function orphanName(proc) {
    const fromPath = proc.cmdline.match(/([\w.-]*mcp[\w.-]*)/i);
    if (fromPath)
        return fromPath[1];
    return proc.comm || 'mcp';
}

function orphanKey(proc) {
    const script = proc.cmdline.match(/(\S*mcp\S*)/i);
    return script ? script[1] : `${proc.comm}:${proc.cmdline.slice(0, 80)}`;
}

export function groupOrphans(processes) {
    const map = new Map();
    for (const proc of processes) {
        const key = orphanKey(proc);
        if (!map.has(key)) {
            map.set(key, {
                id: `orphan:${key}`,
                name: orphanName(proc),
                sources: ['processo'],
                transport: 'stdio',
                command: proc.cmdline,
                args: [],
                url: null,
                disabled: false,
                httpLocal: false,
                orphan: true,
                pids: [],
            });
        }
        map.get(key).pids.push(proc.pid);
    }
    return [...map.values()];
}

export async function scan(extraPaths = []) {
    const [{servers, errors}, processes] = await Promise.all([
        loadConfiguredServers(extraPaths),
        listUserProcesses(),
    ]);
    const used = new Set();

    for (const server of servers) {
        server.pids = [];
        for (const proc of processes) {
            const match = server.transport === 'stdio'
                ? processMatchesStdio(proc, server)
                : processMatchesHttp(proc, server);
            if (match) {
                server.pids.push(proc.pid);
                used.add(proc.pid);
            }
        }
    }

    const leftover = processes.filter(proc =>
        !used.has(proc.pid) && looksLikeMcpProcess(proc));

    return {
        servers,
        orphans: groupOrphans(leftover),
        errors,
    };
}

export function commandPreview(server) {
    if (server.url)
        return server.url;
    const parts = [];
    if (server.command)
        parts.push(basename(server.command));
    for (const arg of distinctiveArgs(server.args))
        parts.push(basename(String(arg)));
    return parts.join(' ').trim() || server.name;
}
