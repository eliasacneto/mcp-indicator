import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import {Extension, gettext as _} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import {displayName, parseHttpUrl, scan} from './detector.js';
import {
    attachUnits,
    canDaemonStart,
    configArgv,
    fetchLogs,
    isLocalHttp,
    liveArgv,
    probeTcp,
    releaseHeld,
    restartServer,
    startServer,
    stopServer,
    waitForTcp,
} from './control.js';
import {classify, mcpHandshake, newSoupSession} from './health.js';

const McpIndicator = GObject.registerClass(
class McpIndicator extends PanelMenu.Button {
    _init(extension) {
        super._init(0.5, _('MCP locais'), false);

        this._extension = extension;
        this._settings = extension.getSettings();
        this._refreshTimeoutId = 0;
        this._refreshInFlight = false;
        this._cancellable = new Gio.Cancellable();
        this._snapshot = {servers: [], orphans: [], errors: []};
        this._savedArgv = new Map();
        this._healthById = new Map();
        this._actionInFlight = false;
        this._soup = newSoupSession();
        this._source = null;

        this.style_class = `${this.style_class} mcp-indicator-icon`;

        this._box = new St.BoxLayout({
            vertical: false,
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'panel-status-menu-box',
        });

        this._icon = new St.Icon({
            icon_name: 'network-server-symbolic',
            style_class: 'system-status-icon',
            icon_size: 16,
        });

        this._box.add_child(this._icon);
        this.add_child(this._box);

        this._headerItem = new PopupMenu.PopupMenuItem(_('Carregando MCP…'), {
            reactive: false,
            can_focus: false,
        });
        this._headerItem.label.add_style_class_name('mcp-indicator-header');
        this.menu.addMenuItem(this._headerItem);

        this._metaItem = new PopupMenu.PopupMenuItem('', {
            reactive: false,
            can_focus: false,
        });
        this._metaItem.label.add_style_class_name('mcp-indicator-meta');
        this.menu.addMenuItem(this._metaItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._listSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._listSection);

        this._logSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._logSection);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        const refreshItem = new PopupMenu.PopupMenuItem(_('Atualizar agora'));
        refreshItem.connect('activate', () => this.refresh(true));
        this.menu.addMenuItem(refreshItem);

        const prefsItem = new PopupMenu.PopupMenuItem(_('Preferências'));
        prefsItem.connect('activate', () => this._extension.openPreferences());
        this.menu.addMenuItem(prefsItem);

        this._settingsChangedIds = [
            this._settings.connect('changed::refresh-interval', () => this._scheduleRefresh()),
            this._settings.connect('changed::show-stopped', () => this._renderMenu()),
            this._settings.connect('changed::show-orphans', () => this._renderMenu()),
            this._settings.connect('changed::extra-config-paths', () => this.refresh(true)),
        ];

        this.refresh(true);
        this._scheduleRefresh();
    }

    destroy() {
        this._clearRefreshTimer();
        for (const id of this._settingsChangedIds || [])
            this._settings.disconnect(id);
        this._settingsChangedIds = [];
        try {
            this._cancellable.cancel();
        } catch {
            /* ignore */
        }
        if (this._source) {
            this._source.destroy();
            this._source = null;
        }
        super.destroy();
    }

    _clearRefreshTimer() {
        if (this._refreshTimeoutId) {
            GLib.source_remove(this._refreshTimeoutId);
            this._refreshTimeoutId = 0;
        }
    }

    _scheduleRefresh() {
        this._clearRefreshTimer();
        const seconds = Math.max(3, this._settings.get_int('refresh-interval') || 5);
        this._refreshTimeoutId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            seconds,
            () => {
                this.refresh(false);
                return GLib.SOURCE_CONTINUE;
            }
        );
    }

    async refresh(manual = false) {
        if (this._refreshInFlight)
            return;
        if (this._actionInFlight && !manual)
            return;

        this._refreshInFlight = true;
        if (manual)
            this._metaItem.label.text = _('Atualizando…');

        try {
            this._cancellable.cancel();
            this._cancellable = new Gio.Cancellable();
            const extra = this._settings.get_strv('extra-config-paths') || [];
            const snapshot = scan(extra);
            attachUnits(snapshot.servers);
            attachUnits(snapshot.orphans);
            await this._probeHttp(snapshot.servers);
            this._snapshot = snapshot;
            this._rememberArgv(snapshot);
            this._trackHealth(snapshot);
            this._renderMenu();
        } catch (error) {
            console.error(`[MCP Indicator] refresh failed: ${error}`);
            this._metaItem.label.text = _('Erro ao atualizar');
        } finally {
            this._refreshInFlight = false;
        }
    }

    async _probeHttp(servers) {
        const probeRemote = this._settings.get_boolean('probe-remote');
        const jobs = [];
        for (const server of servers) {
            if (server.transport !== 'http' && server.transport !== 'sse')
                continue;
            const parsed = parseHttpUrl(server.url);
            if (!parsed)
                continue;
            server.httpLocal = parsed.local;
            server.httpHost = parsed.host;
            server.httpPort = parsed.port;
            server.httpUp = false;
            server.mcpUp = false;
            if (!parsed.local && !probeRemote)
                continue;
            jobs.push((async () => {
                const up = await probeTcp(parsed.host, parsed.port, this._cancellable);
                server.httpUp = up;
                if (!up)
                    return;
                const hand = await mcpHandshake(this._soup, server.url, this._cancellable);
                server.mcpUp = hand.ok;
                server.mcpDetail = hand.detail;
            })());
        }
        if (jobs.length)
            await Promise.all(jobs);
    }

    _trackHealth(snapshot) {
        const all = [...snapshot.servers, ...(snapshot.orphans || [])];
        for (const server of all) {
            const health = classify(server);
            const prev = this._healthById.get(server.id);
            this._healthById.set(server.id, health.status);
            if (!prev)
                continue;
            if (!this._settings.get_boolean('enable-notifications'))
                continue;
            if (!health.notify)
                continue;
            if (prev === 'running' && (health.status === 'stopped' || health.status === 'degraded'))
                this._notifyDown(server, health);
        }
    }

    _ensureSource() {
        if (this._source)
            return this._source;
        this._source = new MessageTray.Source({
            title: _('MCP Indicator'),
            iconName: 'network-server-symbolic',
        });
        this._source.connect('destroy', () => {
            this._source = null;
        });
        Main.messageTray.add(this._source);
        return this._source;
    }

    _notifyDown(server, health) {
        const source = this._ensureSource();
        const title = health.status === 'degraded'
            ? _('%s degradado').format(displayName(server.name))
            : _('%s caiu').format(displayName(server.name));
        const notification = new MessageTray.Notification({
            source,
            title,
            body: health.reason,
            gicon: new Gio.ThemedIcon({name: 'dialog-warning-symbolic'}),
            urgency: health.status === 'stopped'
                ? MessageTray.Urgency.CRITICAL
                : MessageTray.Urgency.NORMAL,
        });
        source.addNotification(notification);
    }

    _visibleItems() {
        const showStopped = this._settings.get_boolean('show-stopped');
        const showOrphans = this._settings.get_boolean('show-orphans');
        const items = [];

        for (const server of this._snapshot.servers) {
            const health = classify(server);
            if (health.status === 'disabled')
                continue;
            if (health.status === 'stopped' && !showStopped)
                continue;
            items.push({server, status: health.status, reason: health.reason, orphan: false});
        }

        if (showOrphans) {
            for (const server of this._snapshot.orphans) {
                const health = classify(server);
                items.push({server, status: health.status, reason: health.reason, orphan: true});
            }
        }

        const rank = {running: 0, degraded: 1, remote: 2, stopped: 3, disabled: 4};
        items.sort((a, b) => {
            const ra = rank[a.status] ?? 9;
            const rb = rank[b.status] ?? 9;
            if (ra !== rb)
                return ra - rb;
            return a.server.name.localeCompare(b.server.name, 'pt');
        });
        return items;
    }

    _renderMenu() {
        this._listSection.removeAll();
        const items = this._visibleItems();
        const running = items.filter(i => i.status === 'running').length;
        const degraded = items.filter(i => i.status === 'degraded').length;
        const stopped = items.filter(i => i.status === 'stopped').length;
        const remote = items.filter(i => i.status === 'remote').length;

        if (items.length === 0) {
            this._headerItem.label.text = _('Nenhum MCP encontrado');
            this._metaItem.label.text = _('Nada configurado nem em execução');
            const empty = new PopupMenu.PopupMenuItem(
                _('Configure MCP no Cursor, Claude, VS Code ou OpenCode'),
                {reactive: false}
            );
            this._listSection.addMenuItem(empty);
            return;
        }

        this._headerItem.label.text = running === 1
            ? _('1 MCP em execução')
            : _('%d MCP em execução').format(running);

        const now = GLib.DateTime.new_now_local().format('%H:%M:%S');
        const parts = [_('atualizado %s').format(now)];
        if (degraded)
            parts.push(_('%d degradado(s)').format(degraded));
        if (stopped)
            parts.push(_('%d parado(s)').format(stopped));
        if (remote)
            parts.push(_('%d remoto(s)').format(remote));
        this._metaItem.label.text = parts.join(' · ');

        for (const item of items)
            this._addServerRow(item);

        if (this._snapshot.errors?.length) {
            const err = new PopupMenu.PopupMenuItem(
                this._snapshot.errors[0],
                {reactive: false}
            );
            err.label.add_style_class_name('mcp-indicator-error');
            this._listSection.addMenuItem(err);
        }
    }

    _addServerRow(item) {
        const {server, status, reason, orphan} = item;
        const row = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});

        const box = new St.BoxLayout({
            vertical: false,
            x_expand: true,
            style_class: 'mcp-indicator-row',
        });

        const dotClass = status === 'running'
            ? 'mcp-indicator-dot-running'
            : status === 'degraded'
                ? 'mcp-indicator-dot-partial'
                : status === 'remote'
                    ? 'mcp-indicator-dot-remote'
                    : 'mcp-indicator-dot-stopped';
        const dot = new St.Widget({
            style_class: `mcp-indicator-dot ${dotClass}`,
            y_align: Clutter.ActorAlign.CENTER,
        });

        const textBox = new St.BoxLayout({
            vertical: true,
            x_expand: true,
        });

        const title = orphan
            ? `${displayName(server.name)} · ${_('órfão')}`
            : displayName(server.name);
        const name = new St.Label({
            text: title,
            style_class: 'mcp-indicator-row-name',
            x_expand: true,
        });

        const sourceText = server.sources.filter(s => s !== 'processo').join(', ')
            || server.transport;
        const desc = new St.Label({
            text: `${sourceText} · ${reason}`,
            style_class: 'mcp-indicator-row-desc',
            x_expand: true,
        });

        textBox.add_child(name);
        textBox.add_child(desc);
        box.add_child(dot);
        box.add_child(textBox);
        box.add_child(this._actionButtons(server, status));
        row.add_child(box);
        this._listSection.addMenuItem(row);
    }

    _iconButton(iconName, label, onClick) {
        const button = new St.Button({
            style_class: 'mcp-indicator-action',
            reactive: true,
            can_focus: true,
            track_hover: true,
            accessible_name: label,
            x_expand: false,
            y_align: Clutter.ActorAlign.CENTER,
        });
        button.set_child(new St.Icon({
            icon_name: iconName,
            style_class: 'popup-menu-icon',
            icon_size: 16,
        }));
        button.connect('clicked', () => {
            onClick();
            return Clutter.EVENT_STOP;
        });
        return button;
    }

    _actionButtons(server, status) {
        const actions = new St.BoxLayout({
            vertical: false,
            x_expand: false,
            x_align: Clutter.ActorAlign.END,
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'mcp-indicator-actions',
        });

        if (status === 'running' || status === 'degraded') {
            if (canDaemonStart(server)) {
                actions.add_child(this._iconButton(
                    'view-refresh-symbolic',
                    _('Reiniciar'),
                    () => this._restart(server)
                ));
            }
            actions.add_child(this._iconButton(
                'media-playback-stop-symbolic',
                _('Parar'),
                () => this._stop(server)
            ));
        } else if (status === 'stopped' && canDaemonStart(server)) {
            actions.add_child(this._iconButton(
                'media-playback-start-symbolic',
                _('Iniciar'),
                () => this._start(server)
            ));
        }

        if (server.unit) {
            actions.add_child(this._iconButton(
                'org.gnome.Logs-symbolic',
                _('Logs'),
                () => this._showLogs(server)
            ));
        }

        if (server.url) {
            actions.add_child(this._iconButton(
                'edit-copy-symbolic',
                _('Copiar URL'),
                () => {
                    St.Clipboard.get_default().set_text(
                        St.ClipboardType.CLIPBOARD,
                        server.url
                    );
                    this._metaItem.label.text = _('URL copiada');
                }
            ));
        }

        return actions;
    }

    _showLogs(server) {
        this._logSection.removeAll();
        const result = fetchLogs(server);
        const title = new PopupMenu.PopupMenuItem(
            _('Logs · %s').format(displayName(server.name)),
            {reactive: false}
        );
        title.label.add_style_class_name('mcp-indicator-header');
        this._logSection.addMenuItem(title);

        const lines = result.lines.length
            ? result.lines.slice(-18)
            : [result.text || _('sem linhas')];
        for (const line of lines) {
            const item = new PopupMenu.PopupMenuItem(String(line).slice(0, 140), {
                reactive: false,
                can_focus: false,
            });
            item.label.add_style_class_name('mcp-indicator-log');
            this._logSection.addMenuItem(item);
        }

        if (result.text) {
            St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD, result.text);
            this._metaItem.label.text = _('logs de %s (copiados)').format(displayName(server.name));
        } else {
            this._metaItem.label.text = _('sem logs para %s').format(displayName(server.name));
        }
    }

    _rememberArgv(snapshot) {
        for (const server of [...snapshot.servers, ...snapshot.orphans]) {
            const argv = liveArgv(server);
            if (argv)
                this._savedArgv.set(server.id, argv);
        }
    }

    _argvFor(server) {
        return this._savedArgv.get(server.id) || configArgv(server) || liveArgv(server);
    }

    async _afterAction(result, verb, server) {
        if (result && !result.ok) {
            this._metaItem.label.text = _('%s: %s').format(
                displayName(server.name),
                result.error || _('falhou')
            );
        } else if ((verb === 'start' || verb === 'restart') && isLocalHttp(server) && server.httpPort) {
            this._metaItem.label.text = _('A esperar HTTP de %s…').format(displayName(server.name));
            const up = await waitForTcp(
                server.httpHost || '127.0.0.1',
                server.httpPort,
                15000,
                null
            );
            this._metaItem.label.text = up
                ? _('%s no ar').format(displayName(server.name))
                : _('%s: serviço pedido, HTTP ainda não respondeu').format(displayName(server.name));
        }
        this._actionInFlight = false;
        this.refresh(true);
    }

    async _stop(server) {
        if (this._actionInFlight)
            return;
        this._actionInFlight = true;
        this._metaItem.label.text = _('A parar %s…').format(displayName(server.name));
        let result = {ok: true, error: ''};
        try {
            result = await stopServer(server);
        } catch (error) {
            console.error(`[MCP Indicator] stop failed: ${error}`);
            result = {ok: false, error: error.message};
        }
        await this._afterAction(result, 'stop', server);
    }

    async _start(server) {
        if (this._actionInFlight)
            return;
        if (!canDaemonStart(server)) {
            this._metaItem.label.text = _('stdio: o cliente é quem inicia %s').format(displayName(server.name));
            return;
        }
        this._actionInFlight = true;
        this._metaItem.label.text = _('A iniciar %s…').format(displayName(server.name));
        let result = {ok: true, error: ''};
        try {
            result = await startServer(server, this._argvFor(server));
        } catch (error) {
            console.error(`[MCP Indicator] start failed: ${error}`);
            result = {ok: false, error: error.message};
        }
        await this._afterAction(result, 'start', server);
    }

    async _restart(server) {
        if (this._actionInFlight)
            return;
        this._actionInFlight = true;
        this._metaItem.label.text = _('A reiniciar %s…').format(displayName(server.name));
        let result = {ok: true, error: ''};
        try {
            result = await restartServer(server, this._argvFor(server));
        } catch (error) {
            console.error(`[MCP Indicator] restart failed: ${error}`);
            result = {ok: false, error: error.message};
        }
        await this._afterAction(result, 'restart', server);
    }
});

export default class McpIndicatorExtension extends Extension {
    enable() {
        this._indicator = new McpIndicator(this);
        Main.panel.addToStatusArea(this.uuid, this._indicator, 1, 'right');
    }

    disable() {
        releaseHeld();
        this._indicator?.destroy();
        this._indicator = null;
    }
}
