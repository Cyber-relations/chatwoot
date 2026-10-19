// Runs inside the normal production asset-build stage after frozen-lock install.
// Uses that stage's Vite config, Vue and Vue I18n, then denies dynamic code in V8.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const root = path.resolve(process.argv[2] || '/app');
const require = createRequire(path.join(root, 'package.json'));
const { JSDOM } = require('jsdom');
const viteRoot = path.dirname(require.resolve('vite/package.json'));
const { build, loadConfigFromFile } = await import(pathToFileURL(path.join(viteRoot, 'dist/node/index.js')));
const loaded = await loadConfigFromFile({ command: 'build', mode: 'production' }, path.join(root, 'vite.config.ts'));
assert(loaded, 'actual Vite config must load');
assert.equal(loaded.config.define.__INTLIFY_JIT_COMPILATION__, true);
assert.equal(loaded.config.define.__INTLIFY_DROP_MESSAGE_COMPILER__, false);
assert.equal(loaded.config.define.regeneratorRuntime, 'globalThis.regeneratorRuntime');
assert.equal(loaded.config.resolve.alias.vue, 'vue/dist/vue.runtime.esm-bundler.js');
const work = fs.mkdtempSync(path.join(root, '.toybaco-csp-build-'));
try {
  const entry = path.join(work, 'probe.js');
  fs.writeFileSync(entry, `
    import { createI18n } from 'vue-i18n';
    const i18n = createI18n({legacy: false, locale: 'en', fallbackLocale: 'en',
      missingWarn: false, fallbackWarn: false,
      messages: {en: {greeting: 'Hello {name}', apples: 'no apples | one apple | {count} apples'},
                 ja: {greeting: '\\u3053\\u3093\\u306b\\u3061\\u306f {name}'}}});
    const interpolate = i18n.global.t('greeting', {name: 'Ada'});
    const plural = i18n.global.t('apples', 2);
    i18n.global.locale.value = 'ja';
    const japanese = i18n.global.t('greeting', {name: 'Ada'});
    const fallback = i18n.global.t('apples', 2);
    i18n.global.mergeLocaleMessage('ja', {fromApi: 'Dynamic {value}'});
    const dynamic = i18n.global.t('fromApi', {value: 'message'});
    globalThis.__CSP_RESULTS__ = {interpolate, plural, japanese, fallback, dynamic};
  `);
  const bundle = async jit => {
    const output = await build({
      root, configFile: false, logLevel: 'error',
      // Library-mode probes retain process.env by default, unlike the browser
      // application build. Bind just its production literal; do not grant the
      // isolated V8 context a host process / environment object.
      define: {...loaded.config.define, 'process.env.NODE_ENV': JSON.stringify('production'),
        __INTLIFY_JIT_COMPILATION__: jit},
      resolve: loaded.config.resolve,
      build: {write: false, minify: 'esbuild', target: 'es2022',
        lib: {entry, formats: ['iife'], name: 'ToybacoCspBuildProbe'},
        rollupOptions: {output: {inlineDynamicImports: true}}},
    });
    const outputs = Array.isArray(output) ? output : [output];
    const chunks = outputs.flatMap(item => item.output).filter(item => item.type === 'chunk');
    assert.equal(chunks.length, 1);
    assert.doesNotMatch(chunks[0].code, /process\.env\.NODE_ENV/);
    return chunks[0].code;
  };
  const run = code => {
    const context = vm.createContext({console: {log() {}, warn() {}, error() {}}},
      {codeGeneration: {strings: false, wasm: false}});
    vm.runInContext(code, context, {timeout: 10000});
    return context.__CSP_RESULTS__;
  };
  assert.equal(run('globalThis.__CSP_RESULTS__ = typeof process'), 'undefined');
  // Negative controls execute the real pre-JIT compiler, not a mocked Function.
  assert.throws(() => run('new Function("return 1")()'), /Code generation from strings disallowed/);
  const nonJit = await bundle(false);
  assert.throws(() => run(nonJit), /Code generation from strings disallowed/);
  const result = run(await bundle(true));
  assert.deepEqual(JSON.parse(JSON.stringify(result)), {
    interpolate: 'Hello Ada', plural: '2 apples', japanese: '\u3053\u3093\u306b\u3061\u306f Ada',
    fallback: '2 apples', dynamic: 'Dynamic message',
  });
  const portal = fs.readFileSync(path.join(root, 'app/javascript/portal/portalHelpers.js'), 'utf8');
  assert.doesNotMatch(portal, /\btemplate\s*:/);
  for (const component of ['PublicArticleSearch', 'TableOfContents', 'SidebarThemeToggle']) {
    assert.match(portal, new RegExp(`h\\(${component}\\b`));
  }
  // Compile the actual helper and its three real SFCs with the application's
  // Vue plugin, then mount them in a DOM with V8 string compilation disabled.
  // The DOM adapter supplies browser APIs only; no component/render is mocked.
  const portalEntry = path.join(work, 'portal.js');
  fs.writeFileSync(portalEntry, `
    import { InitializationHelpers } from '../app/javascript/portal/portalHelpers.js';
    import MessageFormatter from '../app/javascript/shared/helpers/MessageFormatter.js';
    import DOMPurify from 'dompurify';
    import { nextTick } from 'vue';
    globalThis.__CSP_MOUNT_PORTAL__ = async () => {
      InitializationHelpers.initializeSearch();
      InitializationHelpers.initializeTableOfContents();
      InitializationHelpers.initializeSidebarThemeToggle();
      await nextTick();
    };
    globalThis.__CSP_PORTAL_TICK__ = nextTick;
    globalThis.__CSP_FORMAT_MESSAGE__ = message => DOMPurify.sanitize(new MessageFormatter(message).formattedMessage);
  `);
  const portalBundle = async (mutation = null) => {
    const plugins = loaded.config.plugins.flat(Infinity).filter(Boolean)
      .filter(plugin => ['vite:vue', 'yaml'].includes(plugin.name));
    assert(plugins.some(plugin => plugin.name === 'vite:vue'), 'actual Vue SFC compiler plugin must be used');
    const rootMutation = {
      name: 'toybaco-csp-old-root-negative', enforce: 'pre',
      transform(code, id) {
        if (mutation === 'old-dimension' && id === path.join(root, 'app/javascript/shared/helpers/MessageFormatter.js')) {
          for (const key of ['width', 'height']) {
            const exact = `const ${key} = safeImageDimension(url.searchParams.get('cw_image_${key}'));`;
            assert.equal(code.split(exact).length, 2, 'dimension negative must change the actual formatter');
            code = code.replace(exact, `const ${key} = url.searchParams.get('cw_image_${key}');`);
          }
          return code;
        }
        if (mutation !== 'old-template' || id !== path.join(root, 'app/javascript/portal/portalHelpers.js')) return null;
        const exact = 'render: () => h(PublicArticleSearch, { size, showKbd }),';
        assert.equal(code.split(exact).length, 2, 'old-template negative must change the actual search root');
        return code.replace(exact, `components: {PublicArticleSearch}, data: () => ({size, showKbd}), template: '<PublicArticleSearch :size="size" :show-kbd="showKbd" />',`);
      },
    };
    const define = {...loaded.config.define, 'process.env.NODE_ENV': JSON.stringify('production')};
    if (mutation === 'old-regenerator') delete define.regeneratorRuntime;
    const output = await build({
      root, configFile: false, logLevel: 'error', plugins: [...plugins, rootMutation],
      define,
      resolve: loaded.config.resolve, css: loaded.config.css,
      build: {write: false, minify: 'esbuild', target: 'es2022',
        lib: {entry: portalEntry, formats: ['iife'], name: 'ToybacoCspPortalProbe'},
        rollupOptions: {output: {inlineDynamicImports: true}}},
    });
    const outputs = Array.isArray(output) ? output : [output];
    const chunks = outputs.flatMap(item => item.output).filter(item => item.type === 'chunk');
    assert.equal(chunks.length, 1);
    return chunks[0].code;
  };
  const mountPortal = async code => {
    const dom = new JSDOM(`<!doctype html><html><body>
      <div id="search-wrap" data-size="small" data-kbd="true"></div>
      <div id="search-wrap-hero"></div>
      <article id="cw-article-content"><h1>Fixture article</h1></article>
      <div id="cw-hc-toc"></div><div id="sidebar-theme-toggle"></div>
      </body></html>`, {url: 'https://portal.example.test/hc/fixture/en/'});
    let networkCalls = 0;
    const noNetwork = () => {networkCalls++; throw new Error('portal mount must not use the network');};
    const heading = dom.window.document.querySelector('h1');
    // jsdom has no layout/innerText implementation. Supply only this static
    // heading's browser text; heading discovery and TOC render stay real.
    Object.defineProperty(heading, 'innerText', {value: heading.textContent});
    dom.window.portalConfig = {portalSlug: 'fixture', localeCode: 'en',
      searchTranslations: {searchPlaceholder: 'Search fixture', submit: 'Search'}};
    dom.window.fetch = noNetwork;
    dom.window.XMLHttpRequest = class {constructor() {noNetwork();}};
    const observed = [];
    const context = vm.createContext({
      window: dom.window, document: dom.window.document, navigator: dom.window.navigator,
      Element: dom.window.Element, HTMLElement: dom.window.HTMLElement,
      SVGElement: dom.window.SVGElement, Node: dom.window.Node,
      MutationObserver: dom.window.MutationObserver, DOMParser: dom.window.DOMParser,
      URL: dom.window.URL, URLSearchParams: dom.window.URLSearchParams,
      localStorage: dom.window.localStorage,
      setTimeout: dom.window.setTimeout.bind(dom.window), clearTimeout: dom.window.clearTimeout.bind(dom.window),
      XMLHttpRequest: dom.window.XMLHttpRequest, fetch: noNetwork,
      // Geometry is outside this compiler test; record actual TOC observation.
      IntersectionObserver: class {observe(element) {observed.push(element);} disconnect() {}},
      console: {log() {}, warn() {}, error() {}},
    }, {codeGeneration: {strings: false, wasm: false}});
    try {
      dom.window.Function = vm.runInContext('Function', context);
      dom.window.eval = vm.runInContext('eval', context);
      assert.equal(vm.runInContext('typeof process', context), 'undefined');
      assert.throws(() => vm.runInContext('new Function("return 1")()', context), /Code generation from strings disallowed/);
      assert.throws(() => vm.runInContext('window.Function("return 1")()', context), /Code generation from strings disallowed/);
      assert.throws(() => vm.runInContext('window.eval("1")', context), /Code generation from strings disallowed/);
      vm.runInContext(code, context, {timeout: 10000});
      assert.equal(typeof context.regeneratorRuntime?.wrap, 'function',
        'actual dependency runtime must register without a string compiler');
      assert.throws(() => vm.runInContext('new Function("return 1")()', context), /Code generation from strings disallowed/);
      await context.__CSP_MOUNT_PORTAL__();
      const document = dom.window.document;
      assert.equal(document.querySelectorAll('#search-wrap input, #search-wrap-hero input').length, 2,
        'actual portal search SFCs must mount');
      assert.equal(document.querySelector('#search-wrap input').placeholder, 'Search fixture');
      assert(document.querySelector('#search-wrap input').classList.contains('text-sm'));
      assert(document.querySelector('#search-wrap kbd').textContent.includes('K'));
      assert.equal(document.querySelector('#cw-hc-toc a').getAttribute('href'), '#fixture-article');
      assert.deepEqual(observed, [heading]);
      const trigger = document.querySelector('#sidebar-theme-toggle button');
      assert.equal(trigger.getAttribute('aria-expanded'), 'false');
      trigger.click();
      await context.__CSP_PORTAL_TICK__();
      assert.equal(trigger.getAttribute('aria-expanded'), 'true');
      const choices = [...document.querySelectorAll('#sidebar-theme-toggle button')];
      assert.equal(choices.length, 4);
      choices[3].click();
      await context.__CSP_PORTAL_TICK__();
      assert(document.documentElement.classList.contains('dark'));
      assert.equal(dom.window.localStorage.theme, 'dark');
      assert.equal(networkCalls, 0);
      // The real formatter and real default DOMPurify configuration used by
      // chat bubbles must preserve resize metadata but never turn it into CSS.
      const image = (parameter, value, source = 'https://images.example.test/fixture.png') => {
        const url = source + '?' + new URLSearchParams({[parameter]: value});
        const html = context.__CSP_FORMAT_MESSAGE__(`![fixture](${url})`);
        return new dom.window.DOMParser().parseFromString(html, 'text/html').querySelector('img');
      };
      for (const [parameter, value, expected, source] of [
        ['cw_image_height', '24px', 'height: 24px;'],
        ['cw_image_height', 'auto', 'height: auto;'],
        ['cw_image_width', '320px', 'width: 320px; max-width: 100%; height: auto;'],
        ['cw_image_width', '50%', 'width: 50%; max-width: 100%; height: auto;'],
        ['cw_image_width', '1.5rem', 'width: 1.5rem; max-width: 100%; height: auto;'],
        ['cw_image_width', '0', 'width: 0; max-width: 100%; height: auto;'],
        ['cw_image_width', '.5em', 'width: .5em; max-width: 100%; height: auto;'],
        ['cw_image_width', '240px', 'width: 240px; max-width: 100%; height: auto;', '/relative.png'],
      ]) {
        const element = image(parameter, value, source);
        assert(element, 'ordinary Markdown images must remain');
        assert.equal(element.getAttribute('style'), expected);
        assert(element.getAttribute('src').startsWith(source || 'https://images.example.test/fixture.png'));
      }
      for (const parameter of ['cw_image_width', 'cw_image_height']) {
        for (const value of ['24px;background:url(https://attacker.example.test/p)',
          '24px;position:fixed;inset:0', 'expression(alert(1))', 'url(javascript:alert(1))',
          'var(--attacker)', 'calc(100% - 1px)']) {
          const element = image(parameter, value);
          assert(element, 'invalid resize metadata must not delete the image/history');
          assert.equal(element.getAttribute('style'), null,
            'image styling must stay within resize properties');
        }
      }
      const hostile = context.__CSP_FORMAT_MESSAGE__('<script>fixture()</script> <img src=x onerror="fixture()">');
      assert(!new dom.window.DOMParser().parseFromString(hostile, 'text/html').querySelector('script,[onerror]'));
    } finally {
      for (const selector of ['#search-wrap', '#search-wrap-hero', '#cw-hc-toc', '#sidebar-theme-toggle']) {
        dom.window.document.querySelector(selector)?.__vue_app__?.unmount();
      }
      dom.window.close();
    }
  };
  await mountPortal(await portalBundle());
  await assert.rejects(() => portalBundle('old-regenerator').then(mountPortal), /Code generation from strings disallowed/);
  await assert.rejects(() => portalBundle('old-template').then(mountPortal), /actual portal search SFCs must mount/);
  await assert.rejects(() => portalBundle('old-dimension').then(mountPortal), /image styling must stay within resize properties/);
  console.log('TOYBACO_CSP_PORTAL=PASS actual_helper=true real_sfc_roots=3 mounted_search=2 toc=1 theme=1 network=0 negatives=1');
  console.log('TOYBACO_CSP_IMAGE_DIMENSIONS=PASS actual_formatter=true actual_dompurify=true positives=8 rejected_values=12 old_source_negative=1');
  console.log('TOYBACO_CSP_REGENERATOR=PASS actual_dependency=true global_registration=explicit no_vm_seed=true old_define_negative=1');
  console.log('TOYBACO_CSP_BUILD=PASS real_i18n=5 render_roots=3 no_string_codegen=true negatives=2');
  // Execute the actual administrative asset. Fixed buttons use DOM events;
  // no string handlers, host environment, clipboard, or customer values are used.
  const handlers = [];
  const copied = [];
  const masked = {dataset: {secretMasked: 'true'}, textContent: '••••'};
  const icon = {setAttribute() {}};
  const field = {dataset: {secretText: 'fixture-value'}, querySelector: () => masked};
  const toggler = {parentElement: field, querySelector: () => icon,
    hasAttribute: name => name === 'data-secret-toggler'};
  const copier = {parentElement: field, hasAttribute: name => name === 'data-secret-copier'};
  const support = {hasAttribute: name => name === 'data-toybaco-support-mail'};
  const admin = vm.createContext({window: {location: {href: ''}}, document: {
    addEventListener(name, fn) {if (name === 'click') handlers.push(fn);},
  }, navigator: {clipboard: {writeText(value) {copied.push(value);}}}},
  {codeGeneration: {strings: false, wasm: false}});
  const asset = fs.readFileSync(path.join(root, 'app/assets/javascripts/secretField.js'), 'utf8');
  vm.runInContext(asset, admin);
  vm.runInContext(asset, admin);
  assert.equal(handlers.length, 1, 'repeated partials must not toggle twice');
  let prevented = 0;
  const click = button => handlers[0]({target: {closest: () => button},
    preventDefault() {prevented++;}, stopPropagation() {}});
  click(toggler);
  assert.equal(masked.textContent, 'fixture-value');
  assert.equal(masked.dataset.secretMasked, 'false');
  click(toggler);
  assert.equal(masked.textContent, '•'.repeat('fixture-value'.length));
  assert.equal(masked.dataset.secretMasked, 'true');
  click(copier);
  assert.deepEqual(copied, ['fixture-value']);
  click(support);
  assert.equal(admin.window.location.href, 'mailto:support@toybaco.jp');
  click(null);
  assert.equal(prevented, 3, 'unrelated buttons must remain untouched');
  console.log('TOYBACO_CSP_ADMIN_EVENTS=PASS delegated_actions=3 duplicate_binding=1 unrelated=untouched');
} finally {
  fs.rmSync(work, {recursive: true, force: true});
}
