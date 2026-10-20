import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('./Start-PlexWebUI.ps1', import.meta.url), 'utf8');
const html = source.match(/\$htmlPage = @'\r?\n([\s\S]*?)\r?\n'@/)[1];
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function launch(stored, dark = false, blocked = false) {
    let osChanged, ready;
    const storage = new Map(stored === undefined ? [] : [['plex-theme', stored]]);
    const classes = new Set();
    const root = { dataset: {}, style: {}, classList: {
        toggle(name, on) { on ? classes.add(name) : classes.delete(name); },
    } };
    const meta = {};
    const events = {};
    let active;
    function element(id, text = '') {
        return { id, textContent: text, hidden: true, attributes: {}, handlers: {},
            setAttribute(name, value) { this.attributes[name] = value; },
            addEventListener(type, fn) { this.handlers[type] = fn; },
            click() { this.handlers.click(); },
            focus() { active = this; } };
    }
    const control = element('theme');
    const label = element('themeValue');
    const options = ['system', 'light', 'midnight'].map(value => Object.assign(
        element(value, value[0].toUpperCase() + value.slice(1)), { dataset: { themePreference: value } }));
    const menu = Object.assign(element('themeMenu'), { querySelectorAll: () => options });
    const picker = { contains: target => [control, menu, label, ...options].includes(target) };
    const elements = { theme: control, themeValue: label, themeMenu: menu, themePicker: picker };
    const media = { matches: dark, addEventListener(_type, fn) { osChanged = fn; } };
    vm.runInNewContext(script, {
        document: { documentElement: root, querySelector: () => meta,
            get activeElement() { return active; },
            getElementById: id => elements[id],
            addEventListener(type, fn) { if (type === 'DOMContentLoaded') ready = fn; else events[type] = fn; } },
        matchMedia: () => media,
        localStorage: {
            getItem(key) { if (blocked) throw Error('blocked'); return storage.get(key) ?? null; },
            setItem(key, value) { if (blocked) throw Error('blocked'); storage.set(key, value); },
        },
    });
    ready();
    return { root, meta, control, storage, classes, label, menu, options,
        get active() { return active; },
        open() { control.handlers.click(); },
        key(key) { menu.handlers.keydown({ key, preventDefault() {} }); },
        outside() { events.pointerdown({ target: {} }); },
        choose(value) { options.find(option => option.dataset.themePreference === value).handlers.click(); },
        os(value) { media.matches = value; osChanged(); } };
}

test('Plex defaults to midnight before controls mount', () => {
    for (const stored of [undefined, 'invalid']) {
        const app = launch(stored);
        assert.equal(app.root.dataset.theme, 'midnight');
        assert.equal(app.meta.content, '#020617');
        assert.equal(app.label.textContent, 'Midnight');
        assert(app.classes.has('theme-midnight'));
    }
});

test('system tracks OS and fixed choices persist without following OS', () => {
    const app = launch('system');
    assert.equal(app.meta.content, '#ffffff');
    app.os(true);
    assert.equal(app.meta.content, '#020617');
    app.choose('light');
    app.os(true);
    assert.equal(app.meta.content, '#ffffff');
    assert.equal(app.root.style.colorScheme, 'light');
    app.choose('midnight');
    app.os(false);
    assert.equal(app.meta.content, '#020617');
    app.choose('system');
    assert.equal(app.storage.get('plex-theme'), 'system');
    assert.equal(app.meta.content, '#ffffff');
});

test('storage denial leaves theme controls functional', () => {
    const app = launch(undefined, false, true);
    app.choose('system');
    app.os(true);
    assert.equal(app.meta.content, '#020617');
    app.choose('light');
    assert.equal(app.root.style.backgroundColor, '#ffffff');
});

test('HTML scripts compile and UI retains gold, square controls and rounded tracks', () => {
    for (const match of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) new vm.Script(match[1]);
    assert(html.includes('Roboto+Flex:opsz,wght@8..144,100..1000'));
    assert(html.includes("'Helvetica Neue',Arial,'Noto Sans',sans-serif"));
    assert(html.includes('--accent:#f5c518'));
    assert(html.includes('background:var(--panel); border-radius:0'));
    assert(html.includes('width:18px; height:18px; border-radius:50%'));
    assert.doesNotMatch(html, /<(?:select|datalist)\b/i);
    assert(html.includes("target.closest('#themePicker')"));
    for (const value of ['system', 'light', 'midnight']) assert(html.includes(`data-theme-preference="${value}"`));
});

test('custom menu supports navigation, selection and dismissal with focus return', () => {
    const app = launch('midnight');
    app.open();
    assert.equal(app.menu.hidden, false);
    assert.equal(app.active, app.options[2]);
    app.key('Home');
    assert.equal(app.active, app.options[0]);
    app.key('ArrowUp');
    assert.equal(app.active, app.options[2]);
    app.key('ArrowDown');
    assert.equal(app.active, app.options[0]);
    app.key('End');
    assert.equal(app.active, app.options[2]);
    app.key(' ');
    assert.equal(app.menu.hidden, true);
    app.open();
    app.key('Escape');
    assert.equal(app.menu.hidden, true);
    assert.equal(app.active, app.control);
    app.open();
    app.choose('light');
    assert.equal(app.options[1].attributes['aria-checked'], 'true');
    assert.equal(app.storage.get('plex-theme'), 'light');
    assert.equal(app.menu.hidden, true);
    app.open();
    app.key('Tab');
    assert.equal(app.menu.hidden, true);
    app.open();
    app.outside();
    assert.equal(app.menu.hidden, true);
});
