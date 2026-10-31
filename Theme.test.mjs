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
    assert(header.includes('id="themeLabel" class="theme-menu-label"'));
    assert(header.includes('aria-label="Theme: Midnight"'));
    assert(header.includes('M12 3a9 9 0 1 0 0 18h1a2 2 0 0 0 0-4'));
    assert.match(html, /\.theme-setting \{[^}]*align-items:center; justify-content:space-between;/);
    assert.match(html, /\.theme-trigger \{[^}]*width:32px; height:32px;[^}]*background:transparent;/);
    assert.match(html, /@media \(hover:hover\) \{ \.reload-btn:not\(\.spinning\):hover \{ color:var\(--text\); \} \}/);
    assert.match(html, /\.reload-btn svg \{[^}]*will-change:transform;/);
    assert.match(html, /\.theme-trigger:hover \{ color:var\(--text\); \}/);
    assert.match(html, /\.theme-trigger\[aria-expanded=true\] \{ background:var\(--btn\);/);
    assert.match(html, /\.theme-selection \{[^}]*background:var\(--accent\);[^}]*transition:transform \.25s ease-out;/);
    assert.match(html, /\.theme-segments \[aria-pressed=true\] \{ color:#0f172a; \}/);
    const order = ['light', 'midnight', 'system'].map((value) => header.indexOf(`data-theme-preference="${value}"`));
    assert.deepEqual(
        order,
        [...order].sort((a, b) => a - b)
    );
    assert.doesNotMatch(html, /\.reload-btn \{[^}]*position:absolute/);
});

test('pointer presses leave no outline and transport color clears after 2 seconds', () => {
    assert.match(html, /html\.pointer-input :focus-visible \{ outline:none; \}/);
    assert.match(html, /classList\.add\('pointer-input'\)/);
    assert.match(html, /classList\.remove\('pointer-input'\)/);
    for (const id of ['prevBtn', 'playPauseBtn', 'nextBtn']) {
        assert.match(html, new RegExp(`class="nav[^"]*transport" id="${id}"`));
    }
    assert.match(
        html,
        /button\.nav:not\(\.transport\):hover, button\.nav\.transport\.pressed \{ background:var\(--btn-hover\); \}/
    );
    assert.match(html, /btn\.classList\.remove\('pressed'\); \}, 2000\)/);
    assert.match(html, /rate\(idx === Math\.round\(currentRating\) \? 0 : idx\)/);
    assert.match(html, /value === 0 \? 'Rating cleared'/);
    assert.match(source, /if \(\$stars -gt 0 -and \$stars -lt 3\)/);
    const lib = readFileSync(new URL('./PlexTrackLib.ps1', import.meta.url), 'utf8');
    assert.match(lib, /\$plexRating = if \(\$Stars -le 0\) \{ -1 \} else \{ \$Stars \* 2 \}/);
    assert.match(html, /querySelectorAll\('button\.transport, button\.vol-btn'\)/);
    assert.match(html, /\.vol-btn\.pressed \{ background:var\(--btn-hover\); \}/);
    assert.doesNotMatch(html, /\.vol-btn:hover/);
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
            style: {
                setProperty(name, value) {
                    this[name] = value;
                },
            },
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
    const options = ['light', 'midnight', 'system'].map((value) =>
        Object.assign(element(value, value[0].toUpperCase() + value.slice(1)), { dataset: { themePreference: value } })
    );
    const menu = Object.assign(element('themeMenu'), { querySelectorAll: () => options });
    const group = element('themeSegments');
    const picker = { contains: (target) => [control, menu, label, group, ...options].includes(target) };
    const elements = { theme: control, themeValue: label, themeMenu: menu, themeSegments: group, themePicker: picker };
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
        group,
        options,
        events,
        get active() {
            return active;
        },
        open() {
            control.handlers.click();
        },
        key(key) {
            menu.handlers.keydown({ key, preventDefault() {} });
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

test('pill popover stays open on selection and closes from the icon, Escape or an outside press', () => {
    const app = launch('midnight');
    assert.equal(app.control.attributes['aria-label'], 'Theme: Midnight');
    assert.equal(app.group.style['--theme-index'], 1);
    app.open();
    assert.equal(app.menu.hidden, false);
    assert.equal(app.control.attributes['aria-expanded'], 'true');
    assert.equal(app.active, app.options[1]);
    app.key('Home');
    assert.equal(app.active, app.options[0]);
    app.key('ArrowLeft');
    assert.equal(app.active, app.options[2]);
    app.key('ArrowRight');
    assert.equal(app.active, app.options[0]);
    app.key('End');
    assert.equal(app.active, app.options[2]);
    app.choose('light');
    assert.equal(app.menu.hidden, false);
    assert.equal(app.active, app.options[0]);
    assert.equal(app.options[0].attributes['aria-pressed'], 'true');
    assert.equal(app.options[1].attributes['aria-pressed'], 'false');
    assert.equal(app.options[0].tabIndex, 0);
    assert.equal(app.group.style['--theme-index'], 0);
    assert.equal(app.control.attributes['aria-label'], 'Theme: Light');
    assert.equal(app.storage.get('plex-theme'), 'light');
    app.choose('system');
    assert.equal(app.menu.hidden, false);
    app.key('Tab');
    assert.equal(app.menu.hidden, false);
    assert.equal(app.events.focusin, undefined);
    app.events.pointerdown({ target: app.options[1] });
    assert.equal(app.menu.hidden, false);
    app.events.pointerdown({ target: {} });
    assert.equal(app.menu.hidden, true);
    assert.equal(app.control.attributes['aria-expanded'], 'false');
    app.open();
    app.open();
    assert.equal(app.menu.hidden, true);
    assert.equal(app.control.attributes['aria-expanded'], 'false');
    assert.equal(app.active, app.control);
    app.open();
    app.key('Escape');
    assert.equal(app.menu.hidden, true);
    assert.equal(app.active, app.control);
});
