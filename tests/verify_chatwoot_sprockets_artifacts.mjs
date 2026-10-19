// Verifies the Sprockets artifact actually selected by the served manifest.
// Runs in normal production builds, never against a local product runtime.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {createHash} from 'node:crypto';

// Exact tracked static files from the already-pinned upstream source commit.
// Generated Sprockets output is replaced; these raw images must remain byte-identical.
const STATIC_UPSTREAM_COMMIT = '9f920b549c14491a4e587687a3eed5d21c6ccc7d';
const STATIC_PUBLIC_ASSETS = [
  {
    "path": "administrate/bot/avatar.png",
    "sha256": "b69b2db700c77518a77947c1a6e4ef98bf0f988411359b5d89c7e351e88cbedc",
    "size": 2165
  },
  {
    "path": "administrate/user/avatar.png",
    "sha256": "8cb02f4d480234c60633bafddbc0e1eb7dbe812d3383aa6c409276cb73b9b3cc",
    "size": 27270
  },
  {
    "path": "images/auth/auth--bg.svg",
    "sha256": "08712d24009f9431107458ffe22e9be4d1d7578ee624b7df92188c68eb4cdadc",
    "size": 77381
  },
  {
    "path": "images/auth/bottom-right.svg",
    "sha256": "a1e61924090b0ff382c047e10f048a99da4c1ceca0b24bee9a1e4860779c65e6",
    "size": 262
  },
  {
    "path": "images/auth/top-left.svg",
    "sha256": "ff0b13aa56f6a8c0997cab1897a72b527ff8377b689cc66cca46919ccaedca60",
    "size": 246
  },
  {
    "path": "images/chatwoot_bot.png",
    "sha256": "b69b2db700c77518a77947c1a6e4ef98bf0f988411359b5d89c7e351e88cbedc",
    "size": 2165
  },
  {
    "path": "images/dashboard/captain/assistant-dark.svg",
    "sha256": "f2394a218f21bd0573552f7e53668c6862d5e1b2ecc96c2a44582659ae23a20b",
    "size": 13075
  },
  {
    "path": "images/dashboard/captain/assistant-light.svg",
    "sha256": "967f99aba016b019c6a11366e8cccb136ee3b0967b6452c4cac87ee232981b4e",
    "size": 13144
  },
  {
    "path": "images/dashboard/captain/assistant-popover-dark.svg",
    "sha256": "f72b2ccf71b77c45a842c353ce377a8bbdffcbdd11c486ed5de15adf2b6099f9",
    "size": 29743
  },
  {
    "path": "images/dashboard/captain/assistant-popover-light.svg",
    "sha256": "4e14e1c1e2593dc78c178ceba0b08a035fbb6bc3ecc04b1ce0a665d1c43ae857",
    "size": 29818
  },
  {
    "path": "images/dashboard/captain/document-dark.svg",
    "sha256": "2a050c66e464cad1d746bba8affb344658cec89375c944689899e6dcf6ac418a",
    "size": 5857
  },
  {
    "path": "images/dashboard/captain/document-light.svg",
    "sha256": "07d0f80bda088262f20f6dcfd0385045abfc4b343907a0e97ecc8e7a576bf279",
    "size": 5929
  },
  {
    "path": "images/dashboard/captain/document-popover-dark.svg",
    "sha256": "e5df11acd9cb82d1954dd5dfa7bafd4d0eca112fd41c9246e6e0ef8adb951e05",
    "size": 31553
  },
  {
    "path": "images/dashboard/captain/document-popover-light.svg",
    "sha256": "57ba97aa1b535b07bbd07105fe1125d37986afd53a187c1e1f9717d0fa2238c8",
    "size": 31649
  },
  {
    "path": "images/dashboard/captain/faqs-dark.svg",
    "sha256": "ef804c5c95f86abf5a18eda8c84f689d35d37bd4c0daa07e114f983fef82b0aa",
    "size": 7337
  },
  {
    "path": "images/dashboard/captain/faqs-light.svg",
    "sha256": "b697449317606b3954dd576f8f138b8188dbcc39c8ec25280467aa4437eaf134",
    "size": 7383
  },
  {
    "path": "images/dashboard/captain/faqs-popover-dark.svg",
    "sha256": "a4e5694f06dc0b59392f9c191533e96c7dc61f73c3b2d5b4be173e9c047dc3f5",
    "size": 32979
  },
  {
    "path": "images/dashboard/captain/faqs-popover-light.svg",
    "sha256": "575121e928b1dbe83070c1357c8430da35cfc6ce2a82d90b09871e7649be6d39",
    "size": 33061
  },
  {
    "path": "images/dashboard/captain/logo.svg",
    "sha256": "3adeb56a408139b1f7b0e587997b77334a40fbff2cfba1cf1dcf033ca3f371cc",
    "size": 2706
  },
  {
    "path": "images/dashboard/channels/api.png",
    "sha256": "23f93112fdefcb08b1b3a771caa52d58ac28a044d020840e4cd8f36cfa1c782f",
    "size": 42199
  },
  {
    "path": "images/dashboard/channels/email.png",
    "sha256": "a9a689be0426dcd209f4b21e228b4d46f7ef5e508d16277e02983f0b599e84c7",
    "size": 5659
  },
  {
    "path": "images/dashboard/channels/facebook.png",
    "sha256": "b5a4269f77c2f9be99d03305335485ae18731aa67de2b2bb412193b6218db9fe",
    "size": 12771
  },
  {
    "path": "images/dashboard/channels/google.png",
    "sha256": "ae678061accbd13835c7e5313da22cdf89e77ed384bd5abc124389028b814777",
    "size": 14794
  },
  {
    "path": "images/dashboard/channels/instagram.png",
    "sha256": "99ff567d984e38805779dd4562c9a52410af37ab99e9594dedd2cbc932dd273b",
    "size": 1335709
  },
  {
    "path": "images/dashboard/channels/line.png",
    "sha256": "cade393bbc9319a5ab98c705817e98310e41b3f40d0b2eb37856ada74889a057",
    "size": 15331
  },
  {
    "path": "images/dashboard/channels/microsoft.png",
    "sha256": "c9629625f54ecddb2a8f6ea57e22946281f6330b35ae9d16d926cadf6f598b49",
    "size": 414
  },
  {
    "path": "images/dashboard/channels/sms.png",
    "sha256": "bc6d54635ab609032657eebcb6288809bb2fb92680b065a9d476c37d8e8bc782",
    "size": 14570
  },
  {
    "path": "images/dashboard/channels/telegram.png",
    "sha256": "bc79d54315dada946eeb3f8c22d304af3a9597698c98bcec512d4c097048f6f4",
    "size": 51108
  },
  {
    "path": "images/dashboard/channels/tiktok.png",
    "sha256": "e02607728e6666803bf3ef96575fa83727a545e02d36c12b22be4a1b266f4bda",
    "size": 24164
  },
  {
    "path": "images/dashboard/channels/twilio.png",
    "sha256": "e662803e4dd1addac9ff2658ab0b3280f08eee2f6fb41ea97d0272a2604358e3",
    "size": 12215
  },
  {
    "path": "images/dashboard/channels/twitter.png",
    "sha256": "1be5d05ce6faad469f7f9c5a5879f2d9f8d267b60eb394e92c19217268bcea8f",
    "size": 4298
  },
  {
    "path": "images/dashboard/channels/voice.png",
    "sha256": "dc519f22245e1fb120ec36448040684e4675860bcd8cf2664112144ad2eaa254",
    "size": 1352277
  },
  {
    "path": "images/dashboard/channels/website.png",
    "sha256": "b586640a6ebbe1867ae031be9e0da9e283354c577e07b86df1f67ad33e8cc511",
    "size": 6037
  },
  {
    "path": "images/dashboard/channels/whatsapp.png",
    "sha256": "081aabb2c2bcc175aa0e8e2dd8fef1cf2a4afdd6393047af4c5abcce1608bf09",
    "size": 13525
  },
  {
    "path": "images/dashboard/editor/cmd-editor.png",
    "sha256": "f9446425ec82ae79327908a08ee08da0fca77f63543003cbf1973cb0d8bab2dc",
    "size": 149362
  },
  {
    "path": "images/dashboard/editor/enter-editor.png",
    "sha256": "75085a49bb6346ef58f7c2ee46c05034edfba3cac31688b53d33322a14efeb8a",
    "size": 147829
  },
  {
    "path": "images/dashboard/profile/hot-key-ctrl-enter-dark.svg",
    "sha256": "76cdb8e7d0a7b1642fa93c6f0b9d783c0ed24346c534a9d474c8e8c3af1c4a9a",
    "size": 11247
  },
  {
    "path": "images/dashboard/profile/hot-key-ctrl-enter.svg",
    "sha256": "0c2da9504ec8221005360e13a26c5e0db68ab2268c906fac08c5c19267f3027d",
    "size": 11233
  },
  {
    "path": "images/dashboard/profile/hot-key-enter-dark.svg",
    "sha256": "8add5619c43775a5616daf8b7e5c6788771712ac8ca590b698f01a2c0226540c",
    "size": 7465
  },
  {
    "path": "images/dashboard/profile/hot-key-enter.svg",
    "sha256": "a055a3e930aad122c642b16f527c9ec55b222763650eb09f9605afc6ab5b156f",
    "size": 7451
  },
  {
    "path": "images/dashboard/year-in-review/double-quotes.png",
    "sha256": "25d538fc80ce2f0be62f9225dba44cdbd29193dc6795e4e7762126dc493d38a5",
    "size": 723
  },
  {
    "path": "images/dashboard/year-in-review/fifth-frame-signature.png",
    "sha256": "a3784b00583abdfac1c610373ae6e41629e50ef6479f97de932d65e22013c057",
    "size": 37751
  },
  {
    "path": "images/dashboard/year-in-review/first-frame-bg.png",
    "sha256": "6889d83f83a0835f71bf45d4bc04c47fc91600b20d34fe18fbe28c8fc1975b3f",
    "size": 17373
  },
  {
    "path": "images/dashboard/year-in-review/first-frame-candles.png",
    "sha256": "407d8e9e1795379fff2675015ffe3b7e789e8471eb13e23af07ea3e6472c3fae",
    "size": 138090
  },
  {
    "path": "images/dashboard/year-in-review/fourth-frame-clock.png",
    "sha256": "84a1783fd3e1bf647d2587bb96c4c9e0459845651105d7a127a1fab846f183bd",
    "size": 20993
  },
  {
    "path": "images/dashboard/year-in-review/second-frame-cloud-icon.png",
    "sha256": "c2ff75c39d84edb2dbbe39ed69b057d55cdbb4d507ae32454f432b2dbe0af9cd",
    "size": 50817
  },
  {
    "path": "images/dashboard/year-in-review/third-frame-coffee.png",
    "sha256": "7dd5eca8ba17cc1219edec73687efbf6006bb86fec2b2cd4bb5fcbb1468b5419",
    "size": 135450
  },
  {
    "path": "images/dashboard/year-in-review/year-in-review-sidebar.png",
    "sha256": "f8026cc26256d20d5877cc9dc18d0e670bf38f02690e1134efbee7d9c2ab988a",
    "size": 114977
  },
  {
    "path": "images/hc/grid.svg",
    "sha256": "8b5c4039b814334e9f55681467879804d3e481b3cf4f1c4e575db8d8a0674e6a",
    "size": 173
  },
  {
    "path": "images/hc/grid_dark.svg",
    "sha256": "5dc9872cbfa442d5631042fe82df949636c3a0e1a134e3c9b43132c486cdac23",
    "size": 173
  },
  {
    "path": "images/hc/hexagon-dark.svg",
    "sha256": "cb3704d1638a983204eab8d37c2fb93a5d31e358396ee26bb53cfb8e1bb18273",
    "size": 2404
  },
  {
    "path": "images/hc/hexagon-light.svg",
    "sha256": "c572f5f09bc2cde498f2f21b6863cd9ea222798a237a98082f7ea479658be88f",
    "size": 645
  },
  {
    "path": "images/tracking-pixel.png",
    "sha256": "90a2134105ce90eb548541bc22129b7d2766d7a83877d56622c345d73fa6863e",
    "size": 123
  },
  {
    "path": "images/typing.gif",
    "sha256": "33808ce95c0e52200d33f3a847209de12650e44bd8afbc22e2f1df723658832b",
    "size": 19296
  }
];

// Existing reviewed localization overrides are copied only by the final overlay stage.
const STATIC_PUBLIC_FINAL_OVERRIDES = [
  {
    "path": "images/dashboard/profile/hot-key-ctrl-enter-dark.svg",
    "sha256": "492c9a0fca1f71b773ead9d90b8a14dfece4d0721c9f20c76c86051ff4f0c1c4",
    "size": 11483
  },
  {
    "path": "images/dashboard/profile/hot-key-ctrl-enter.svg",
    "sha256": "48fd4784ddb0a6019ea2f735709fd370b37076fc942801bd936df2248ceb57a6",
    "size": 11469
  },
  {
    "path": "images/dashboard/profile/hot-key-enter-dark.svg",
    "sha256": "17b3f666561c6f1340743810f7a0ca75fcaaebdbd491402ed65f53843888c374",
    "size": 7696
  },
  {
    "path": "images/dashboard/profile/hot-key-enter.svg",
    "sha256": "54f1dbcfeda04b79463cf48c4faac37d1daeb8c102c1128370bcc24e01e93ce1",
    "size": 7682
  }
];

function readStaticAsset(directory, entry) {
  const root = path.resolve(directory);
  assert(/^(administrate|images)\/[A-Za-z0-9_./-]+$/.test(entry.path));
  assert(!entry.path.split('/').includes('..'));
  const segments = entry.path.split('/');
  for (let i = 1; i < segments.length; i++) {
    const stat = fs.lstatSync(path.join(root, ...segments.slice(0, i)));
    assert(stat.isDirectory() && !stat.isSymbolicLink());
  }
  const file = path.join(root, entry.path);
  const stat = fs.lstatSync(file);
  assert(stat.isFile() && !stat.isSymbolicLink() && stat.size === entry.size);
  const bytes = fs.readFileSync(file);
  assert.equal(createHash('sha256').update(bytes).digest('hex'), entry.sha256,
    'tracked static public asset digest changed');
  return bytes;
}

function verifyStaticAssets(directory, finalOverlay = false) {
  assert.equal(STATIC_PUBLIC_ASSETS.length, 54);
  assert.equal(new Set(STATIC_PUBLIC_ASSETS.map(entry => entry.path)).size, 54);
  assert.equal(STATIC_PUBLIC_FINAL_OVERRIDES.length, 4);
  const overrides = new Map(STATIC_PUBLIC_FINAL_OVERRIDES.map(entry => [entry.path, entry]));
  assert.equal(overrides.size, 4);
  assert([...overrides.keys()].every(name => STATIC_PUBLIC_ASSETS.some(entry => entry.path === name)));
  for (const entry of STATIC_PUBLIC_ASSETS) {
    readStaticAsset(directory, finalOverlay ? (overrides.get(entry.path) || entry) : entry);
  }
  assert.throws(() => readStaticAsset(directory, {...STATIC_PUBLIC_ASSETS[0], sha256: '0'.repeat(64)}),
    /tracked static public asset digest changed/);
  assert.throws(() => readStaticAsset(directory, {...STATIC_PUBLIC_ASSETS[0],
    path: 'images/toybaco-csp-missing-static-negative.png'}), {code: 'ENOENT'});
}

function clearGeneratedAssetsPreservingTrackedStatic(directory) {
  const root = path.resolve(directory);
  assert(fs.lstatSync(root).isDirectory() && !fs.lstatSync(root).isSymbolicLink());
  // Read and verify everything before changing the build-only directory.
  const retained = STATIC_PUBLIC_ASSETS.map(entry => ({entry, bytes: readStaticAsset(root, entry)}));
  fs.rmSync(root, {recursive: true});
  fs.mkdirSync(root, {recursive: true});
  for (const {entry, bytes} of retained) {
    const target = path.join(root, entry.path);
    fs.mkdirSync(path.dirname(target), {recursive: true});
    fs.writeFileSync(target, bytes, {flag: 'wx', mode: 0o644});
  }
  verifyStaticAssets(root);
}

function readCompiled(directory) {
  const root = path.resolve(directory);
  const manifests = fs.readdirSync(root).filter(name => /^\.sprockets-manifest-[a-f0-9]+\.json$/.test(name));
  assert.equal(manifests.length, 1, 'exactly one served Sprockets manifest is required');
  const manifest = JSON.parse(fs.readFileSync(path.join(root, manifests[0]), 'utf8'));
  const logical = manifest.assets?.['secretField.js'];
  assert.equal(typeof logical, 'string', 'compiled administrative asset is missing');
  assert.match(logical, /^secretField-[a-f0-9]+\.js$/);
  assert(manifest.files?.[logical], 'compiled administrative asset is not in the manifest file table');
  const file = path.join(root, logical);
  const stat = fs.lstatSync(file);
  assert(stat.isFile() && !stat.isSymbolicLink() && stat.size > 0 && stat.size <= 5 * 1024 * 1024);
  const bytes = fs.readFileSync(file);
  return {code: bytes.toString('utf8'), artifact: logical, bytes: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex')};
}

function verifyAdminBehavior(asset) {
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
  vm.runInContext(asset, admin);
  vm.runInContext(asset, admin);
  assert.equal(handlers.length, 1, 'compiled administrative delegated events are absent or duplicated');
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
}

const [mode, directory, legacyPath] = process.argv.slice(2);
assert(['--capture-legacy', '--verify-build', '--verify-final'].includes(mode));
assert(directory && (mode === '--verify-final' ? !legacyPath : legacyPath));
const compiled = readCompiled(directory);
if (mode === '--capture-legacy') {
  // The immutable base image supplies this counterexample before old assets are removed.
  fs.writeFileSync(legacyPath, compiled.code, {flag: 'wx', mode: 0o600});
  clearGeneratedAssetsPreservingTrackedStatic(directory);
} else {
  verifyStaticAssets(directory, mode === '--verify-final');
  verifyAdminBehavior(compiled.code);
  if (mode === '--verify-build') {
    const legacy = fs.readFileSync(legacyPath, 'utf8');
    assert.notEqual(legacy, compiled.code, 'precompiled base asset was accidentally retained');
    assert.throws(() => verifyAdminBehavior(legacy), /compiled administrative delegated events are absent or duplicated/,
      'the actual legacy compiled artifact must fail the new DOM event contract');
  }
  console.log(JSON.stringify({sprockets_artifact: 'PASS', stage: mode === '--verify-final' ? 'final' : 'build',
    manifest_bound: true, administrative_actions: 3, duplicate_binding: 1,
    tracked_static_files: 54, reviewed_final_localization_overrides: mode === '--verify-final' ? 4 : 0,
    static_upstream: STATIC_UPSTREAM_COMMIT,
    legacy_artifact_rejected: mode === '--verify-build', artifact: compiled.artifact,
    bytes: compiled.bytes, sha256: compiled.sha256}));
  console.log(`TOYBACO_CSP_STATIC_ASSETS=PASS stage=${mode === '--verify-final' ? 'final' : 'build'} files=54 reviewed_overrides=${mode === '--verify-final' ? 4 : 0} missing_and_corruption_rejected=true`);
  console.log(mode === '--verify-final'
    ? 'TOYBACO_CSP_SPROCKETS_FINAL=PASS compiled_admin_actions=3 manifest_bound=true'
    : 'TOYBACO_CSP_SPROCKETS_BUILD=PASS compiled_admin_actions=3 legacy_asset_rejected=true');
}
