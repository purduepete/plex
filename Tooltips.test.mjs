import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import vm from 'node:vm';

const source = readFileSync(new URL('./Start-PlexWebUI.ps1', import.meta.url), 'utf8');
const html = source.match(/\$htmlPage = @'\r?\n([\s\S]*?)\r?\n'@/)[1];
const helper = source.slice(source.indexOf('(function appTooltips()'), source.indexOf('// End shared tooltips.'));
const settingOff = 'var SHOW_TOOLTIPS = false;';

function fixture(showTooltips = true) {
    const listeners = {},
        timers = new Map();
    let observe,
        sequence = 0;
    function element(text = 'Hint') {
        const attrs = new Map();
        return {
            dataset: { tip: text },
            isConnected: true,
            style: {},
            hidden: true,
            textContent: '',
            getAttribute: (key) => attrs.get(key) ?? null,
            setAttribute: (key, value) => attrs.set(key, value),
            removeAttribute: (key) => attrs.delete(key),
            contains(node) {
                return node === this;
            },
            closest() {
                return this.dataset.tip === undefined ? null : this;
            },
            getBoundingClientRect() {
                return this.rect ?? { left: 380, top: 20, bottom: 40, width: 10, height: 20 };
            },
        };
    }
    let tip;
    const addEventListener = (name, fn) => (listeners[name] ??= []).push(fn);
    vm.runInNewContext(showTooltips ? helper.replace(settingOff, 'var SHOW_TOOLTIPS = true;') : helper, {
        document: {
            createElement: () => (tip = element()),
            body: { appendChild() {} },
            documentElement: { clientWidth: 390 },
            addEventListener,
        },
        window: { innerHeight: 100, addEventListener },
        MutationObserver: class {
            constructor(fn) {
                observe = fn;
            }
            observe() {}
        },
        clearTimeout: (id) => timers.delete(id),
        setTimeout: (fn) => {
            timers.set(++sequence, fn);
            return sequence;
        },
    });
    tip.rect = { width: 200, height: 70 };
    return {
        tip,
        element,
        observe: () => observe(),
        event(name, target, extra = {}) {
            for (const fn of listeners[name] ?? []) fn({ target, ...extra });
        },
        flush() {
            for (const fn of timers.values()) fn();
            timers.clear();
        },
    };
}

test('SHOW_TOOLTIPS defaults to false and keeps hints closed with their descriptions', () => {
    assert.ok(helper.includes(settingOff));
    const f = fixture(false),
        target = f.element('Refresh');
    f.event('pointerover', target, { pointerType: 'mouse' });
    assert.equal(f.tip.hidden, true);
    f.event('focusin', target);
    assert.equal(f.tip.hidden, true);
    assert.equal(f.tip.textContent, 'Refresh');
    assert.equal(target.getAttribute('aria-describedby'), 'app-tooltip');
});

test('canonical PowerShell HTML has themed hints, named controls and valid emitted scripts', () => {
    const result = spawnSync(
        'pwsh',
        [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            String.raw`
        $ErrorActionPreference='Stop'
        $tokens=$null; $errors=$null
        $ast=[System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PWD 'Start-PlexWebUI.ps1'),[ref]$tokens,[ref]$errors)
        if($errors.Count){throw ($errors | Out-String)}
        $value=$ast.Find({param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$htmlPage'
        },$true)
        & ([scriptblock]::Create($value.Right.Extent.Text))
    `,
        ],
        { cwd: new URL('.', import.meta.url), encoding: 'utf8' }
    );
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.equal(result.stdout.trim(), html.trim());
    assert.doesNotMatch(source, /\btitle\s*=\s*['"\\]|\.title\s*=|setAttribute\(\s*['"]title['"]/);
    for (const [, script] of result.stdout.matchAll(/<script>([\s\S]*?)<\/script>/g)) new vm.Script(script);
    assert.match(html, /aria-label="Refresh" data-tip="Refresh"/);
    assert.match(html, /aria-label="Volume" data-tip="Volume"/);
    assert.match(
        html,
        /\.app-tooltip \{[^}]*border:1px solid var\(--track\); border-radius:0; background:var\(--panel\); color:var\(--text\)/
    );
});

test('dynamic unsupported volume hints remain focusable while controls are disabled', () => {
    const block = source.slice(source.indexOf('    var volSupported ='), source.indexOf('    if (!volSupported) {'));
    const slider = { dataset: {} },
        row = { dataset: {}, classList: { toggle() {} } },
        down = {},
        up = {};
    for (const supported of [false, true]) {
        vm.runInNewContext(block, {
            data: { volumeSupported: supported },
            volumeSliderEl: slider,
            volumeRowEl: row,
            volDownBtnEl: down,
            volUpBtnEl: up,
        });
        assert.equal(slider.disabled, !supported);
        assert.equal(down.disabled, !supported);
        assert.equal(up.disabled, !supported);
        assert.equal(row.tabIndex, supported ? -1 : 0);
        assert.equal(slider.dataset.tip, supported ? 'Volume' : '');
        assert.equal(row.dataset.tip, supported ? '' : 'Volume control not supported on this device');
        assert.equal('title' in slider, false);
    }
    const idle = source.slice(
        source.indexOf("      volumeRowEl.classList.add('unsupported');"),
        source.indexOf('      if (!isDraggingVolume) { volumeSliderEl.value = 50; }')
    );
    row.classList.add = () => {};
    vm.runInNewContext(idle, { volumeSliderEl: slider, volumeRowEl: row });
    assert.equal(slider.dataset.tip, '');
    assert.equal(row.dataset.tip, 'Volume unavailable while nothing is playing');
    assert.equal(row.tabIndex, 0);
});

test('delegated hover, keyboard focus, pointer transfer and dismissal preserve descriptions', () => {
    const f = fixture(),
        first = f.element(),
        second = f.element('Dynamic status');
    first.setAttribute('aria-describedby', 'existing other');
    f.event('pointerover', first, { pointerType: 'mouse' });
    assert.equal(f.tip.hidden, false);
    assert.equal(f.tip.getAttribute('role'), 'tooltip');
    assert.equal(first.getAttribute('aria-describedby'), 'existing other app-tooltip');
    f.event('pointerout', first, { relatedTarget: null });
    f.event('pointerover', f.tip, { pointerType: 'mouse' });
    f.flush();
    assert.equal(f.tip.hidden, false);
    f.event('pointerout', f.tip, { relatedTarget: first });
    f.flush();
    assert.equal(f.tip.hidden, false);
    f.event('focusin', second);
    assert.equal(first.getAttribute('aria-describedby'), 'existing other');
    assert.equal(f.tip.textContent, 'Dynamic status');
    for (const name of ['keydown', 'scroll', 'click', 'resize', 'pagehide', 'focusout']) {
        f.event('focusin', second);
        f.event(name, second, { key: 'Escape' });
        assert.equal(f.tip.hidden, true, name);
        assert.equal(second.getAttribute('aria-describedby'), null);
    }
    f.event('pointerover', second, { pointerType: 'touch' });
    assert.equal(f.tip.hidden, true);
    f.event('pointerover', second);
    f.event('pointerout', second);
    f.flush();
    assert.equal(f.tip.hidden, true);
});

test('viewport clamps, active hint updates and removed targets are cleaned up', () => {
    const f = fixture(),
        target = f.element('<literal text>');
    f.event('focusin', target);
    assert.equal(f.tip.textContent, '<literal text>');
    assert.equal(f.tip.style.left, '182px');
    assert.equal(f.tip.style.top, '8px');
    target.rect = { left: -20, top: 90, bottom: 100, width: 10 };
    f.tip.rect = { width: 200, height: 20 };
    f.event('focusin', target);
    assert.equal(f.tip.style.left, '8px');
    assert.equal(f.tip.style.top, '64px');
    target.dataset.tip = 'Updated status';
    f.observe();
    assert.equal(f.tip.textContent, 'Updated status');
    target.isConnected = false;
    f.observe();
    assert.equal(f.tip.hidden, true);
    assert.equal(target.getAttribute('aria-describedby'), null);
    target.isConnected = true;
    f.event('focusin', target);
    target.dataset.tip = '';
    f.observe();
    assert.equal(f.tip.hidden, true);
});
