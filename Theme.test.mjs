import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('./Start-PlexWebUI.ps1', import.meta.url), 'utf8');
const html = source.match(/\$htmlPage = @'\r?\n([\s\S]*?)\r?\n'@/)[1];
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function launch(stored, dark = false, blocked = false) {
    let osChanged, ready, changed;
    const storage = new Map(stored === undefined ? [] : [['plex-theme', stored]]);
    const classes = new Set();
    const root = { dataset: {}, style: {}, classList: {
        toggle(name, on) { on ? classes.add(name) : classes.delete(name); },
    } };
    const meta = {};
    const control = { value: '', addEventListener(_type, fn) { changed = fn; } };
    const media = { matches: dark, addEventListener(_type, fn) { osChanged = fn; } };
    vm.runInNewContext(script, {
        document: { documentElement: root, querySelector: () => meta,
            getElementById: () => control, addEventListener(_type, fn) { ready = fn; } },
        matchMedia: () => media,
        localStorage: {
            getItem(key) { if (blocked) throw Error('blocked'); return storage.get(key) ?? null; },
            setItem(key, value) { if (blocked) throw Error('blocked'); storage.set(key, value); },
        },
    });
    ready();
    return { root, meta, control, storage, classes,
        choose(value) { control.value = value; changed(); },
        os(value) { media.matches = value; osChanged(); } };
}

test('Plex defaults to midnight before controls mount', () => {
    for (const stored of [undefined, 'invalid']) {
        const app = launch(stored);
        assert.equal(app.root.dataset.theme, 'midnight');
        assert.equal(app.meta.content, '#020617');
        assert.equal(app.control.value, 'midnight');
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
    for (const value of ['system', 'light', 'midnight']) assert(html.includes(`value="${value}"`));
});
