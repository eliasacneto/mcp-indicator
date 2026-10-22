import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import GObject from 'gi://GObject';
import Gtk from 'gi://Gtk';

import {
    ExtensionPreferences,
    gettext as _,
} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

import {DEFAULT_CONFIGS, expandUser} from './detector.js';

const PathRow = GObject.registerClass(
class PathRow extends Adw.ActionRow {
    _init(path, onDelete) {
        super._init({
            title: path,
        });
        const button = new Gtk.Button({
            icon_name: 'user-trash-symbolic',
            valign: Gtk.Align.CENTER,
            css_classes: ['flat'],
            tooltip_text: _('Remover'),
        });
        button.connect('clicked', () => onDelete(path));
        this.add_suffix(button);
        this.set_activatable_widget(button);
    }
});

export default class McpIndicatorPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();
        window.set_default_size(560, 620);

        const page = new Adw.PreferencesPage({
            title: _('MCP'),
            icon_name: 'network-server-symbolic',
        });
        window.add(page);

        const general = new Adw.PreferencesGroup({
            title: _('Geral'),
            description: _('Como o indicador consulta os servidores MCP locais.'),
        });
        page.add(general);

        const interval = new Adw.SpinRow({
            title: _('Intervalo de atualização'),
            subtitle: _('Segundos entre cada varredura de configs e processos'),
            adjustment: new Gtk.Adjustment({
                lower: 3,
                upper: 60,
                step_increment: 1,
                page_increment: 5,
            }),
        });
        settings.bind(
            'refresh-interval',
            interval,
            'value',
            Gio.SettingsBindFlags.DEFAULT
        );
        general.add(interval);

        const showStopped = new Adw.SwitchRow({
            title: _('Mostrar MCP parados'),
            subtitle: _('Listar também os que estão na config e não estão em execução'),
        });
        settings.bind('show-stopped', showStopped, 'active', Gio.SettingsBindFlags.DEFAULT);
        general.add(showStopped);

        const showOrphans = new Adw.SwitchRow({
            title: _('Mostrar processos órfãos'),
            subtitle: _('Processos que parecem MCP mas não estão nos arquivos de config'),
        });
        settings.bind('show-orphans', showOrphans, 'active', Gio.SettingsBindFlags.DEFAULT);
        general.add(showOrphans);

        const probeRemote = new Adw.SwitchRow({
            title: _('Sondar HTTP remoto'),
            subtitle: _('Por omissão só testa localhost. Remotos (GitHub, etc.) ficam como “remoto”.'),
        });
        settings.bind('probe-remote', probeRemote, 'active', Gio.SettingsBindFlags.DEFAULT);
        general.add(probeRemote);

        const notifyDown = new Adw.SwitchRow({
            title: _('Notificar queda'),
            subtitle: _('Aviso quando um MCP HTTP/systemd local deixa de responder. stdio do cliente não dispara.'),
        });
        settings.bind('enable-notifications', notifyDown, 'active', Gio.SettingsBindFlags.DEFAULT);
        general.add(notifyDown);

        const sources = new Adw.PreferencesGroup({
            title: _('Fontes já consultadas'),
            description: _('Arquivos padrão no diretório home. Só entram os que existirem.'),
        });
        page.add(sources);
        const list = DEFAULT_CONFIGS.map(item => `~/${item.rel}  (${item.source})`).join('\n');
        const sourcesRow = new Adw.ActionRow({
            title: _('Configs padrão'),
            subtitle: list,
        });
        sources.add(sourcesRow);

        const extraGroup = new Adw.PreferencesGroup({
            title: _('Arquivos extra'),
            description: _('Caminho absoluto ou começando com ~/ para um JSON de MCP adicional.'),
        });
        page.add(extraGroup);

        const extraBox = new Gtk.Box({
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 0,
        });
        extraGroup.add(extraBox);

        const rebuild = () => {
            while (extraBox.get_first_child())
                extraBox.remove(extraBox.get_first_child());
            const paths = settings.get_strv('extra-config-paths') || [];
            if (paths.length === 0) {
                extraBox.append(new Adw.ActionRow({
                    title: _('Nenhum arquivo extra'),
                }));
                return;
            }
            for (const path of paths) {
                extraBox.append(new PathRow(path, removed => {
                    const next = (settings.get_strv('extra-config-paths') || [])
                        .filter(p => p !== removed);
                    settings.set_strv('extra-config-paths', next);
                    rebuild();
                }));
            }
        };
        rebuild();
        settings.connect('changed::extra-config-paths', rebuild);

        const addGroup = new Adw.PreferencesGroup({
            title: _('Adicionar arquivo'),
        });
        page.add(addGroup);

        const pathRow = new Adw.EntryRow({
            title: _('Caminho do JSON'),
        });
        pathRow.set_text('~/');
        addGroup.add(pathRow);

        const addButton = new Gtk.Button({
            label: _('Adicionar'),
            halign: Gtk.Align.END,
            margin_top: 8,
            css_classes: ['suggested-action'],
        });
        addButton.connect('clicked', () => {
            const raw = pathRow.get_text().trim();
            const path = expandUser(raw);
            if (!raw || raw === '~/') {
                window.add_toast(new Adw.Toast({
                    title: _('Informe um caminho'),
                    timeout: 3,
                }));
                return;
            }
            const current = settings.get_strv('extra-config-paths') || [];
            if (current.includes(path) || current.includes(raw)) {
                window.add_toast(new Adw.Toast({
                    title: _('Esse caminho já está na lista'),
                    timeout: 3,
                }));
                return;
            }
            current.push(path);
            settings.set_strv('extra-config-paths', current);
            pathRow.set_text('~/');
            rebuild();
        });
        addGroup.add(addButton);
    }
}
