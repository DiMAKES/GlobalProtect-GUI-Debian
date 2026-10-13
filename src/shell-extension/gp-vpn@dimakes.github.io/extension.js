// Кнопка VPN GlobalProtect в системном меню на экране входа (GDM) и экране блокировки:
// окна приложений там не показываются, поэтому вход и вопросы клиента — в окнах самой оболочки.
// Работает через общий помощник gp-vpn (/usr/lib/gp-vpn/gpvpn.py): status / run / session.
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as ModalDialog from 'resource:///org/gnome/shell/ui/modalDialog.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {QuickMenuToggle, SystemIndicator} from 'resource:///org/gnome/shell/ui/quickSettings.js';

Gio._promisify(Gio.Subprocess.prototype, 'communicate_utf8_async');
Gio._promisify(Gio.DataInputStream.prototype, 'read_line_async', 'read_line_finish_utf8');

const HELPER = ['/usr/bin/python3', GLib.getenv('GP_VPN_HELPER') || '/usr/lib/gp-vpn/gpvpn.py'];
const AUTO = 'Автовыбор';
const TITLES = {
    on: 'Подключено', internal: 'Внутренняя сеть', connecting: 'Подключение…',
    disconnecting: 'Отключение…', off: 'Не подключено',
};
const ICONS = {
    on: 'network-vpn-symbolic', internal: 'network-vpn-symbolic', connecting: 'network-vpn-acquiring-symbolic',
    disconnecting: 'network-vpn-acquiring-symbolic', off: 'network-vpn-disconnected-symbolic',
};

async function helper(...args) {
    const proc = Gio.Subprocess.new([...HELPER, ...args], Gio.SubprocessFlags.STDOUT_PIPE);
    const [out] = await proc.communicate_utf8_async(null, null);
    return JSON.parse(out);
}

// Диалог с CLI через «gpvpn.py session»: логин, пароль и гейт помощник подставляет сам,
// остальные запросы приходят в onPrompt
class Session {
    constructor(args, creds, onPrompt, onDone) {
        this.cancelling = false;
        this._onPrompt = onPrompt;
        this._onDone = onDone;
        this._proc = Gio.Subprocess.new([...HELPER, 'session', ...args],
            Gio.SubprocessFlags.STDIN_PIPE | Gio.SubprocessFlags.STDOUT_PIPE);
        this._in = this._proc.get_stdin_pipe();
        this._out = new Gio.DataInputStream({base_stream: this._proc.get_stdout_pipe(), close_base_stream: true});
        this._write(creds);
        this._read().catch(e => this._finish({rc: 1, error: String(e), cancelled: this.cancelling}));
    }

    _write(obj) {
        try {
            this._in.write_all(new TextEncoder().encode(`${JSON.stringify(obj)}\n`), null);
        } catch (e) {
            logError(e);
        }
    }

    async _read() {
        for (;;) {
            // eslint-disable-next-line no-await-in-loop
            const [line] = await this._out.read_line_async(GLib.PRIORITY_DEFAULT, null);
            if (line === null) {
                this._finish({rc: 1, error: '', cancelled: this.cancelling});
                return;
            }
            const e = JSON.parse(line);
            if (e.event === 'prompt') {
                this._onPrompt(this, e);
            } else {
                this._finish(e);
                return;
            }
        }
    }

    _finish(e) {
        if (this._done)
            return;
        this._done = true;
        this._onDone(this, e);
    }

    send(answer) {
        this._write({answer});
    }

    cancel() {
        this.cancelling = true;
        this._write({cancel: true});
    }
}

function entry(box, caption, value = '', secret = false) {
    box.add_child(new St.Label({text: caption, style_class: 'gp-vpn-caption'}));
    const e = new St.Entry({text: value, can_focus: true, x_expand: true});
    if (secret)
        e.clutter_text.set_password_char('●');
    box.add_child(e);
    return e;
}

// Вход: портал, логин (пусто — сохранённый клиентом), пароль
const ConnectDialog = GObject.registerClass(
class ConnectDialog extends ModalDialog.ModalDialog {
    _init(portal, login, error, onConnect) {
        super._init({styleClass: 'gp-vpn-dialog'});
        const box = new St.BoxLayout({vertical: true, style_class: 'gp-vpn-content'});
        box.add_child(new St.Label({text: 'GlobalProtect', style_class: 'gp-vpn-title'}));
        this._portal = entry(box, 'Адрес портала', portal);
        this._login = entry(box, 'Логин', login);
        this._pw = entry(box, 'Пароль', '', true);
        if (error)
            box.add_child(new St.Label({text: error, style_class: 'gp-vpn-error'}));
        this.contentLayout.add_child(box);
        const go = () => {
            onConnect(this._portal.text.trim(), this._login.text.trim(), this._pw.text);
            this.close();
        };
        for (const e of [this._portal, this._login, this._pw])
            e.clutter_text.connect('activate', go);
        this.addButton({label: 'Отмена', action: () => this.close(), key: Clutter.KEY_Escape});
        this.addButton({label: 'Подключить', action: go, default: true});
        this.setInitialKeyFocus(portal ? this._pw : this._portal);
    }
});

// Вопрос клиента: код, выбор из списка, «да/нет»
const PromptDialog = GObject.registerClass(
class PromptDialog extends ModalDialog.ModalDialog {
    _init(prompt, onAnswer, onCancel) {
        super._init({styleClass: 'gp-vpn-dialog'});
        const box = new St.BoxLayout({vertical: true, style_class: 'gp-vpn-content'});
        box.add_child(new St.Label({text: 'GlobalProtect', style_class: 'gp-vpn-title'}));
        const text = new St.Label({text: prompt.text, style_class: 'gp-vpn-text'});
        text.clutter_text.line_wrap = true;
        box.add_child(text);
        this.contentLayout.add_child(box);
        const answer = v => {
            this.close();
            onAnswer(v);
        };
        this.addButton({label: 'Отменить', action: () => { this.close(); onCancel(); }, key: Clutter.KEY_Escape});
        if (prompt.kind === 'confirm') {
            this.addButton({label: 'Нет', action: () => answer('n')});
            this.addButton({label: 'Да', action: () => answer('y'), default: true});
        } else if (prompt.kind === 'choice') {
            for (const [n, label] of prompt.options) {
                const b = new St.Button({label, style_class: 'button gp-vpn-option', x_expand: true, can_focus: true});
                b.connect('clicked', () => answer(n));
                box.add_child(b);
            }
        } else {
            const e = new St.Entry({can_focus: true, x_expand: true});
            if (prompt.kind === 'secret')
                e.clutter_text.set_password_char('●');
            e.clutter_text.connect('activate', () => answer(e.text));
            box.add_child(e);
            this.addButton({label: 'Ответить', action: () => answer(e.text), default: true});
            this.setInitialKeyFocus(e);
        }
    }
});

const MessageDialog = GObject.registerClass(
class MessageDialog extends ModalDialog.ModalDialog {
    _init(title, body) {
        super._init({styleClass: 'gp-vpn-dialog'});
        const box = new St.BoxLayout({vertical: true, style_class: 'gp-vpn-content'});
        box.add_child(new St.Label({text: title, style_class: 'gp-vpn-title'}));
        const text = new St.Label({text: body, style_class: 'gp-vpn-error'});
        text.clutter_text.line_wrap = true;
        box.add_child(text);
        this.contentLayout.add_child(box);
        this.addButton({label: 'OK', action: () => this.close(), key: Clutter.KEY_Escape, default: true});
    }
});

const GPToggle = GObject.registerClass(
class GPToggle extends QuickMenuToggle {
    _init(ext) {
        super._init({title: 'GlobalProtect', subtitle: TITLES.off, iconName: ICONS.off, toggleMode: false});
        this._ext = ext;
        this.menu.setHeader(ICONS.off, 'GlobalProtect', TITLES.off);
        this._gateways = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._gateways);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this.menu.addAction('Подключиться…', () => ext.openConnect());
        this.connect('clicked', () => ext.toggle());
    }

    update(st, busy) {
        const state = busy || st.state || 'off';
        const d = st.details || {};
        const pref = (st.gateways || []).find(g => g[2]);
        let where = d['Gateway Description'] || d['Gateway Name'] || '';
        if (where && !pref)
            where = `${AUTO} → ${where}`;
        const subtitle = ['on', 'internal'].includes(state) && where ? where : TITLES[state];
        this.subtitle = subtitle;
        this.iconName = ICONS[state];
        this.checked = ['on', 'internal'].includes(state);
        this.menu.setHeader(ICONS[state], 'GlobalProtect', [TITLES[state], st.portal].filter(Boolean).join(' · '));
        this._gateways.removeAll();
        const gws = st.gateways || [];
        if (!gws.length)
            return;
        for (const [name, label] of [['', AUTO], ...gws.map(g => [g[0], g[0]])]) {
            const item = this._gateways.addAction(label, () => this._ext.setGateway(name || null));
            item.setOrnament((pref ? pref[0] === name : name === '') ? PopupMenu.Ornament.CHECK : PopupMenu.Ornament.NONE);
        }
    }
});

const GPIndicator = GObject.registerClass(
class GPIndicator extends SystemIndicator {
    _init(ext) {
        super._init();
        this._icon = this._addIndicator();
        this.toggle = new GPToggle(ext);
        this.quickSettingsItems.push(this.toggle);
    }

    update(st, busy) {
        const state = busy || st.state || 'off';
        this._icon.icon_name = ICONS[state];
        this._icon.visible = state !== 'off';
        this.toggle.update(st, busy);
    }
});

export default class GPVpnExtension extends Extension {
    enable() {
        this._st = {state: null, details: {}, gateways: [], portal: ''};
        this._busy = null;
        this._login = '';
        this._pw = null;
        this._indicator = new GPIndicator(this);
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
        this._poll();
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 5, () => {
            this._poll();
            return GLib.SOURCE_CONTINUE;
        });
    }

    disable() {
        GLib.source_remove(this._timer);
        this._session?.cancel();
        this._dialog?.close();
        this._indicator.quickSettingsItems.forEach(i => i.destroy());
        this._indicator.destroy();
        this._indicator = this._session = this._dialog = this._pw = null;
    }

    async _poll() {
        if (this._polling || this._session)
            return;
        this._polling = true;
        try {
            const st = await helper('status');
            if (st.state && this._indicator && !this._session)
                this._st = st;
        } catch (e) {
            logError(e);
        }
        this._polling = false;
        this._indicator?.update(this._st, this._busy);
    }

    _open(dialog) {
        this._dialog?.close();
        this._dialog = dialog;
        dialog.open();
    }

    toggle() {
        if (this._session)
            return;
        if (['on', 'internal', 'connecting'].includes(this._st.state))
            this._run(['disconnect'], 'disconnecting', {});
        else
            this.openConnect();
    }

    openConnect(error = '') {
        Main.panel.closeQuickSettings?.();
        this._open(new ConnectDialog(this._st.portal, this._login, error, (portal, login, pw) => {
            portal = portal.replace(/^.*:\/\//, '').split('/')[0];
            if (!portal)
                return this.openConnect('Введите адрес портала.');
            this._login = login;
            this._pw = pw || this._pw;
            const args = ['connect', '--portal', portal, ...(login ? ['--username', login] : [])];
            return this._run(args, 'connecting', {login, password: this._pw});
        }));
    }

    async setGateway(name) {
        if (this._session)
            return;
        const res = await helper('run', 'set-preferred-gateway', ...(name ? ['--name', name] : []));
        if (res.rc && res.error)
            this._open(new MessageDialog('Не удалось выбрать гейт', res.error));
        else if (['on', 'internal'].includes(this._st.state))
            this._run(['rediscover-network'], 'connecting', {login: this._login, password: this._pw, gateway: name});
        else
            this._poll();
    }

    _run(args, busy, creds) {
        this._busy = busy;
        this._indicator.update(this._st, busy);
        this._session = new Session(args, creds,
            (s, prompt) => this._open(new PromptDialog(prompt, v => s.send(v), () => s.cancel())),
            (s, e) => {
                this._session = null;
                this._busy = null;
                if (!(e.cancelled || s.cancelling) && (e.rc || e.error)) {
                    if (busy === 'connecting') {
                        this._pw = null;
                        this.openConnect(e.error || 'Не удалось подключиться.');
                    } else {
                        this._open(new MessageDialog('GlobalProtect', e.error || 'Команда не выполнена.'));
                    }
                }
                this._poll();
            });
    }
}
