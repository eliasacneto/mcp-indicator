import GLib from 'gi://GLib';
import Soup from 'gi://Soup';

import {isLocalHttp} from './control.js';

const CLIENT_SOURCES = new Set([
    'Cursor', 'VS Code', 'Claude', 'Claude Desktop',
    'Cline', 'Windsurf', 'Copilot', 'Gemini', 'OpenCode',
]);

export function isClientManagedStdio(server) {
    if (server.orphan || server.unit || isLocalHttp(server))
        return false;
    if (server.transport !== 'stdio')
        return false;
    return (server.sources || []).some(source => CLIENT_SOURCES.has(source));
}

export function classify(server) {
    if (server.disabled)
        return {status: 'disabled', reason: 'desligado na config', notify: false};

    if (server.orphan) {
        const n = (server.pids || []).length;
        return {
            status: n ? 'running' : 'stopped',
            reason: n ? `órfão · ${n} processo(s)` : 'órfão parado',
            notify: false,
        };
    }

    if (server.transport === 'http' || server.transport === 'sse') {
        if (!server.httpLocal)
            return {status: 'remote', reason: `remoto · ${server.url}`, notify: false};

        const tcp = Boolean(server.httpUp);
        const mcp = Boolean(server.mcpUp);
        const unit = Boolean(server.unitActive);
        const pids = (server.pids || []).length;
        const port = server.httpPort || '?';

        if (mcp)
            return {status: 'running', reason: 'MCP ok', notify: true};
        if (tcp && !mcp)
            return {status: 'degraded', reason: 'porta aberta, handshake MCP falhou', notify: true};
        if (unit && !tcp)
            return {status: 'degraded', reason: `serviço activo, porta ${port} recusada`, notify: true};
        if (pids && !tcp)
            return {status: 'degraded', reason: `processo no ar, porta ${port} recusada`, notify: true};
        if (server.unit && !unit)
            return {status: 'stopped', reason: 'serviço inactivo', notify: true};
        return {status: 'stopped', reason: 'HTTP parado', notify: true};
    }

    if ((server.pids || []).length > 0) {
        const n = server.pids.length;
        const reason = isClientManagedStdio(server)
            ? (n === 1 ? 'stdio do cliente' : `stdio do cliente · ${n} processos`)
            : (n === 1 ? `pid ${server.pids[0]}` : `${n} processos`);
        return {status: 'running', reason, notify: false};
    }

    if (isClientManagedStdio(server))
        return {status: 'stopped', reason: 'sem processo (o cliente é quem sobe)', notify: false};

    return {status: 'stopped', reason: 'parado', notify: false};
}

export function newSoupSession() {
    return new Soup.Session({timeout: 4});
}

function sendAndRead(session, message, cancellable) {
    return new Promise((resolve, reject) => {
        session.send_and_read_async(
            message,
            GLib.PRIORITY_DEFAULT,
            cancellable,
            (_sess, res) => {
                try {
                    resolve(session.send_and_read_finish(res));
                } catch (error) {
                    reject(error);
                }
            }
        );
    });
}

export async function mcpHandshake(session, url, cancellable) {
    if (!url || !session)
        return {ok: false, detail: 'URL inválida'};
    try {
        const message = Soup.Message.new('POST', url);
        if (!message)
            return {ok: false, detail: 'URL inválida'};
        message.request_headers.append('Accept', 'application/json, text/event-stream');
        const payload = JSON.stringify({
            jsonrpc: '2.0',
            id: 1,
            method: 'initialize',
            params: {
                protocolVersion: '2024-11-05',
                capabilities: {},
                clientInfo: {name: 'mcp-indicator', version: '4'},
            },
        });
        message.set_request_body_from_bytes(
            'application/json',
            GLib.Bytes.new(new TextEncoder().encode(payload))
        );
        const response = await sendAndRead(session, message, cancellable);
        const status = message.get_status();
        if (!status)
            return {ok: false, detail: 'sem resposta HTTP'};
        const text = new TextDecoder('utf-8').decode(response.get_data());
        const first = text.trim().split('\n')[0].replace(/^data:\s*/, '');
        let mcp = false;
        try {
            const body = JSON.parse(first);
            mcp = body.jsonrpc === '2.0' || body.result != null || body.error != null;
        } catch {
            mcp = false;
        }
        if (mcp || (status >= 200 && status < 500))
            return {ok: true, detail: `HTTP ${status}`};
        return {ok: false, detail: `HTTP ${status}`};
    } catch (error) {
        return {ok: false, detail: error.message || 'handshake falhou'};
    }
}
