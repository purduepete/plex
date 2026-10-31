import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { spawnSync } from 'node:child_process';

const source = readFileSync(new URL('./Start-PlexWebUI.ps1', import.meta.url), 'utf8');
const html = source.match(/\$htmlPage = @'\r?\n([\s\S]*?)\r?\n'@/)[1];
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

test('applies the theme before requesting the font stylesheet', () => {
    const theme = html.indexOf('<script>');
    const font = html.indexOf('https://fonts.googleapis.com/css2');
    assert.ok(theme >= 0 && font > theme);
});

test('first-load gate reveals once, with immediate failures and no refresh replay', () => {
    assert.match(html, /<body data-first-load="loading">/);
    assert.match(html, /body\[data-first-load="loading"\] \.card \{ visibility:hidden; opacity:0; \}/);
    const finish = html.match(/ {2}function finishPageLoading\(failed\) \{[\s\S]*?\n {2}\}/)[0];
    for (const failed of [false, true]) {
        let removed = 0;
        const body = { dataset: { firstLoad: 'loading' } };
        const context = vm.createContext({
            document: { body },
            clearTimeout() {},
            pageRingTimer: 1,
            pageLoadingEl: {
                remove() {
                    removed++;
                },
            },
        });
        vm.runInContext(`${finish}\nfinishPageLoading(${failed});finishPageLoading(false);`, context);
        assert.equal(body.dataset.firstLoad, failed ? 'error' : 'ready');
        assert.equal(removed, 1);
    }
});

test('API errors reject before control handlers render success', async () => {
    const playback = html.match(/<script>([\s\S]*?)<\/script>/g).at(-1);
    const helper = playback.match(/ {2}function readApiResponse\(response\) \{[\s\S]*?\n {2}\}/)[0];
    const readResponse = vm.runInNewContext(`${helper}\nreadApiResponse`);
    const status = { found: true, volume: 42 };
    assert.equal(await readResponse({ ok: true, json: async () => status }), status);
    await assert.rejects(
        readResponse({ ok: false, status: 500, json: async () => ({ message: 'Player unreachable' }) }),
        /Player unreachable/
    );
    await assert.rejects(readResponse({ ok: false, status: 502, json: async () => ({}) }), /HTTP 502/);
    await assert.rejects(
        readResponse({
            ok: false,
            json: async () => {
                throw Error('Invalid JSON');
            },
        }),
        /Invalid JSON/
    );
    assert.doesNotMatch(playback, /\.then\(function \(r\) \{ return r.json\(\); \}\)/);
});

test('control handlers reject failures and preserve saved volume', () => {
    const result = spawnSync(
        'pwsh',
        [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            String.raw`
        $ErrorActionPreference = 'Stop'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PWD 'Start-PlexWebUI.ps1'), [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw ($errors | Out-String) }
        $confirm = $ast.Find({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Confirm-PlexControl'
        }, $true)
        . ([scriptblock]::Create($confirm.Extent.Text))
        function Invoke-PlexSkip { return $script:accepted }
        function Invoke-PlexPlaybackCommand { return $script:accepted }
        function Invoke-PlexSeek { return $script:accepted }
        function Invoke-PlexSetVolume { return $script:accepted }
        function Start-Sleep {}
        function Save-VolumeState { $script:saved = $true }
        function Test-VolumeSupported { return $true }
        function Get-StatusObject { return @{ found = $true } }
        function Write-JsonResponse {}
        $controlTracks = @([pscustomobject]@{
            MachineIdentifier = 'phone'; State = 'playing'; MediaType = 'music'; Device = 'iPhone'; Player = 'Plexamp'
        })
        $request = [pscustomobject]@{ QueryString = @{ value = '80'; offset = '10000' } }
        $routes = $ast.Find({ param($n)
            $n -is [System.Management.Automation.Language.SwitchStatementAst] -and
            $n.Condition.Extent.Text -eq '$request.Url.AbsolutePath'
        }, $true)
        foreach ($path in @('/api/next', '/api/previous', '/api/playpause', '/api/seek', '/api/volume')) {
            $route = $routes.Clauses | Where-Object { $_.Item1.Value -eq $path }
            $script:accepted = $false
            $script:saved = $false
            $script:VolumeState = @{ phone = 25 }
            $failed = $false
            try { & ([scriptblock]::Create($route.Item2.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))) }
            catch {
                if ($_.Exception.Message -notlike 'Plex could not send*') { throw }
                $failed = $true
            }
            if (-not $failed) { throw "$path did not reject failed command" }
            if ($script:saved -or $script:VolumeState.phone -ne 25) { throw 'Failed volume was saved' }
            $script:accepted = $true
            & ([scriptblock]::Create($route.Item2.Extent.Text.Trim().TrimStart('{').TrimEnd('}')))
            if ($path -eq '/api/volume' -and (-not $script:saved -or $script:VolumeState.phone -ne 80)) {
                throw 'Accepted volume was not saved'
            }
        }
        'All control failure/success checks passed'
    `,
        ],
        { encoding: 'utf8' }
    );
    assert.equal(result.status, 0, result.stdout + result.stderr);
});

test('theme and refresh share a compact, vertically centered header', () => {
    const header = html.slice(html.indexOf('<div class="theme-setting">'), html.indexOf('<div class="art-wrap">'));
    assert(header.includes('id="themePicker"'));
    assert(header.includes('id="reloadBtn"'));
    assert(header.includes('id="themeLabel" hidden'));
    assert.match(html, /\.theme-setting \{[^}]*align-items:center; justify-content:space-between;/);
    assert.match(html, /\.theme-trigger \{[^}]*height:32px;[^}]*background:transparent;/);
    assert.doesNotMatch(html, /\.reload-btn \{[^}]*position:absolute/);
});

function launch(stored, dark = false, blocked = false) {
    let osChanged, ready;
    const storage = new Map(stored === undefined ? [] : [['plex-theme', stored]]);
    const classes = new Set();
    const root = {
        dataset: {},
        style: {},
        classList: {
            toggle(name, on) {
                on ? classes.add(name) : classes.delete(name);
            },
        },
    };
    const meta = {};
    const events = {};
    let active;
    function element(id, text = '') {
        return {
            id,
            textContent: text,
            hidden: true,
            attributes: {},
            handlers: {},
            setAttribute(name, value) {
                this.attributes[name] = value;
            },
            addEventListener(type, fn) {
                this.handlers[type] = fn;
            },
            click() {
                this.handlers.click();
            },
            focus() {
                active = this;
            },
        };
    }
    const control = element('theme');
    const label = element('themeValue');
    const options = ['system', 'light', 'midnight'].map((value) =>
        Object.assign(element(value, value[0].toUpperCase() + value.slice(1)), { dataset: { themePreference: value } })
    );
    const menu = Object.assign(element('themeMenu'), { querySelectorAll: () => options });
    const picker = { contains: (target) => [control, menu, label, ...options].includes(target) };
    const elements = { theme: control, themeValue: label, themeMenu: menu, themePicker: picker };
    const media = {
        matches: dark,
        addEventListener(_type, fn) {
            osChanged = fn;
        },
    };
    vm.runInNewContext(script, {
        document: {
            documentElement: root,
            querySelector: () => meta,
            get activeElement() {
                return active;
            },
            getElementById: (id) => elements[id],
            addEventListener(type, fn) {
                if (type === 'DOMContentLoaded') ready = fn;
                else events[type] = fn;
            },
        },
        matchMedia: () => media,
        localStorage: {
            getItem(key) {
                if (blocked) throw Error('blocked');
                return storage.get(key) ?? null;
            },
            setItem(key, value) {
                if (blocked) throw Error('blocked');
                storage.set(key, value);
            },
        },
    });
    ready();
    return {
        root,
        meta,
        control,
        storage,
        classes,
        label,
        menu,
        options,
        get active() {
            return active;
        },
        open() {
            control.handlers.click();
        },
        key(key) {
            menu.handlers.keydown({ key, preventDefault() {} });
        },
        outside() {
            events.pointerdown({ target: {} });
        },
        choose(value) {
            options.find((option) => option.dataset.themePreference === value).handlers.click();
        },
        os(value) {
            media.matches = value;
            osChanged();
        },
    };
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
