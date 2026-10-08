// 上流 EE ビューが CE overlay ビューを shadow する欠陥を build で止める guard
// (scripts/verify-chatwoot-ee-view-twins.sh)の単体テストと、Dockerfile・.dockerignore・
// gate への配線契約。gate は control snapshot のこのファイルを実行するので、root は
// TOYBACO_CONTROL_ROOT(無ければこのファイルの親)とし、snapshot にあるファイルだけを読む。
//
//   node --test tests/chatwoot-ee-view-twins.test.mjs

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const controlRoot = process.env.TOYBACO_CONTROL_ROOT;
assert.notEqual(controlRoot, '', 'TOYBACO_CONTROL_ROOT must not be empty');
const root = resolve(controlRoot ?? join(dirname(fileURLToPath(import.meta.url)), '..'));
const guardPath = join(root, 'scripts/verify-chatwoot-ee-view-twins.sh');

const SHADOWED = 'devise/mailer/x.html.erb';
const CE_CONTENT = '<%# toybaco CE x %>\n';

// 正例の fixture: 上流 EE に x と y、CE overlay に x と z、双子に CE と同一の x。
function makeFixture(t, mutate) {
  const base = mkdtempSync(join(tmpdir(), 'toybaco-ee-view-twins-'));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const ee = join(base, 'enterprise-app-views');
  const overlay = join(base, 'toybaco-overlay');
  const paths = {
    base,
    ee,
    overlay,
    eeView: relative => join(ee, relative),
    ceView: relative => join(overlay, 'app/views', relative),
    twin: relative => join(overlay, 'enterprise/app/views', relative),
  };
  const write = (path, content) => {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, content);
  };
  write(paths.eeView(SHADOWED), '<%# upstream EE x: saml_enabled? %>\n');
  write(paths.eeView('fields/y.html.erb'), '<%# upstream EE y %>\n');
  write(paths.ceView(SHADOWED), CE_CONTENT);
  write(paths.ceView('other/z.html.erb'), '<%# toybaco CE z %>\n');
  write(paths.twin(SHADOWED), CE_CONTENT);
  mutate?.({ ...paths, write });
  return paths;
}

function runGuard(...args) {
  const result = spawnSync('sh', [guardPath, ...args], { encoding: 'utf8' });
  assert.equal(result.error, undefined, 'guard must start');
  return result;
}

function assertViolations(result, expected) {
  assert.equal(result.status, 1, `exit 1 expected; stderr=${result.stderr}`);
  assert.equal(result.stdout, '', 'no PASS line on failure');
  const lines = result.stderr.trim().split('\n');
  assert.deepEqual(lines.slice(0, -1).sort(), [...expected].sort(), 'every violation is listed');
  assert.equal(lines.at(-1), `TOYBACO_EE_VIEW_TWINS=FAIL violations=${expected.length}`);
}

test('正例: shadow される EE ビューに byte 同一の双子があれば PASS', t => {
  const { ee, overlay } = makeFixture(t);
  const result = runGuard(ee, overlay);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, '');
  assert.equal(result.stdout, 'TOYBACO_EE_VIEW_TWINS=PASS shadows=1 twins=1\n');
});

test('正例: CE overlay と重ならない EE ビューだけなら双子は不要', t => {
  const { ee, overlay } = makeFixture(t, ({ ceView, twin }) => {
    unlinkSync(ceView(SHADOWED));
    unlinkSync(twin(SHADOWED));
  });
  const result = runGuard(ee, overlay);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'TOYBACO_EE_VIEW_TWINS=PASS shadows=0 twins=0\n');
});

test('負例: 双子が無い shadow は EE_VIEW_SHADOW_WITHOUT_TWIN', t => {
  const { ee, overlay } = makeFixture(t, ({ twin }) => unlinkSync(twin(SHADOWED)));
  assertViolations(runGuard(ee, overlay), [`EE_VIEW_SHADOW_WITHOUT_TWIN ${SHADOWED}`]);
});

test('負例: CE overlay と内容が違う双子は EE_VIEW_TWIN_DIFFERS', t => {
  const { ee, overlay } = makeFixture(t, ({ twin, write }) => write(twin(SHADOWED), `${CE_CONTENT} `));
  assertViolations(runGuard(ee, overlay), [`EE_VIEW_TWIN_DIFFERS ${SHADOWED}`]);
});

test('負例: 上流に EE ビューが無い双子は EE_VIEW_TWIN_STALE', t => {
  const { ee, overlay } = makeFixture(t, ({ ceView, twin, write }) => {
    write(ceView('gone/w.html.erb'), CE_CONTENT);
    write(twin('gone/w.html.erb'), CE_CONTENT);
  });
  assertViolations(runGuard(ee, overlay), ['EE_VIEW_TWIN_STALE gone/w.html.erb']);
});

test('負例: CE overlay が無い双子は EE_VIEW_TWIN_WITHOUT_CE', t => {
  const { ee, overlay } = makeFixture(t, ({ twin, write }) => write(twin('fields/y.html.erb'), CE_CONTENT));
  assertViolations(runGuard(ee, overlay), ['EE_VIEW_TWIN_WITHOUT_CE fields/y.html.erb']);
});

test('負例: 上流にも CE overlay にも無い双子は STALE と WITHOUT_CE を両方報告', t => {
  const { ee, overlay } = makeFixture(t, ({ twin, write }) => write(twin('orphan/o.html.erb'), CE_CONTENT));
  assertViolations(runGuard(ee, overlay), [
    'EE_VIEW_TWIN_STALE orphan/o.html.erb',
    'EE_VIEW_TWIN_WITHOUT_CE orphan/o.html.erb',
  ]);
});

test('負例: 内容が同じでも symlink の双子は EE_VIEW_GUARD_IRREGULAR', t => {
  const paths = makeFixture(t, ({ ceView, twin }) => {
    unlinkSync(twin(SHADOWED));
    symlinkSync(ceView(SHADOWED), twin(SHADOWED));
  });
  assertViolations(runGuard(paths.ee, paths.overlay), [`EE_VIEW_GUARD_IRREGULAR ${paths.twin(SHADOWED)}`]);
});

test('負例: 双子パスを(空の)実ディレクトリが占めていても EE_VIEW_GUARD_IRREGULAR', t => {
  const paths = makeFixture(t, ({ twin }) => {
    unlinkSync(twin(SHADOWED));
    mkdirSync(twin(SHADOWED), { recursive: true });
  });
  assertViolations(runGuard(paths.ee, paths.overlay), [`EE_VIEW_GUARD_IRREGULAR ${paths.twin(SHADOWED)}`]);
});

test('負例: 双子パスのディレクトリに中身があっても IRREGULAR と中身の STALE/WITHOUT_CE を全件報告', t => {
  const paths = makeFixture(t, ({ twin, write }) => {
    unlinkSync(twin(SHADOWED));
    write(join(twin(SHADOWED), 'inner.html.erb'), CE_CONTENT);
  });
  assertViolations(runGuard(paths.ee, paths.overlay), [
    `EE_VIEW_GUARD_IRREGULAR ${paths.twin(SHADOWED)}`,
    `EE_VIEW_TWIN_STALE ${SHADOWED}/inner.html.erb`,
    `EE_VIEW_TWIN_WITHOUT_CE ${SHADOWED}/inner.html.erb`,
  ]);
});

test('負例: 上流 EE 側の symlink も EE_VIEW_GUARD_IRREGULAR', t => {
  const paths = makeFixture(t, ({ eeView }) => symlinkSync(eeView('fields/y.html.erb'), eeView('fields/link.html.erb')));
  assertViolations(runGuard(paths.ee, paths.overlay), [`EE_VIEW_GUARD_IRREGULAR ${paths.eeView('fields/link.html.erb')}`]);
});

test('負例: 双子ディレクトリ自体が symlink なら EE_VIEW_GUARD_IRREGULAR', t => {
  const paths = makeFixture(t, ({ base, overlay }) => {
    const elsewhere = join(base, 'elsewhere');
    mkdirSync(join(elsewhere, 'devise/mailer'), { recursive: true });
    writeFileSync(join(elsewhere, SHADOWED), CE_CONTENT);
    rmSync(join(overlay, 'enterprise/app/views'), { recursive: true });
    symlinkSync(elsewhere, join(overlay, 'enterprise/app/views'));
  });
  const result = runGuard(paths.ee, paths.overlay);
  assert.equal(result.status, 1, result.stderr);
  assert.ok(result.stderr.split('\n').includes(`EE_VIEW_GUARD_IRREGULAR ${join(paths.overlay, 'enterprise/app/views')}`),
    result.stderr);
});

test('負例: 複数の違反は全件列挙してから exit 1', t => {
  const { ee, overlay } = makeFixture(t, ({ ceView, twin, write }) => {
    unlinkSync(twin(SHADOWED));
    write(ceView('gone/w.html.erb'), CE_CONTENT);
    write(twin('gone/w.html.erb'), CE_CONTENT);
    write(twin('fields/y.html.erb'), CE_CONTENT);
  });
  assertViolations(runGuard(ee, overlay), [
    `EE_VIEW_SHADOW_WITHOUT_TWIN ${SHADOWED}`,
    'EE_VIEW_TWIN_STALE gone/w.html.erb',
    'EE_VIEW_TWIN_WITHOUT_CE fields/y.html.erb',
  ]);
});

test('負例: root の不在・非ディレクトリ・symlink と引数の数違いは exit 2', t => {
  const paths = makeFixture(t);
  const missing = join(paths.base, 'missing');
  const plainFile = paths.ceView(SHADOWED);
  const linkedRoot = join(paths.base, 'linked-ee');
  symlinkSync(paths.ee, linkedRoot);
  for (const [args, message] of [
    [[missing, paths.overlay], `EE_VIEW_GUARD_MISSING_ROOT ${missing}`],
    [[paths.ee, missing], `EE_VIEW_GUARD_MISSING_ROOT ${missing}`],
    [[plainFile, paths.overlay], `EE_VIEW_GUARD_MISSING_ROOT ${plainFile}`],
    [[linkedRoot, paths.overlay], `EE_VIEW_GUARD_MISSING_ROOT ${linkedRoot}`],
  ]) {
    const result = runGuard(...args);
    assert.equal(result.status, 2, `${args.join(' ')}: ${result.stderr}`);
    assert.equal(result.stdout, '');
    assert.equal(result.stderr, `${message}\n`);
  }
  for (const args of [[], [paths.ee], [paths.ee, paths.overlay, paths.overlay]]) {
    const result = runGuard(...args);
    assert.equal(result.status, 2, result.stderr);
    assert.match(result.stderr, /^EE_VIEW_GUARD_USAGE /);
  }
});

// ---- 配線契約(リポジトリ実体) ----

const OVERLAY_STAGE = 'FROM ${CHATWOOT_IMAGE} AS overlay-normalizer';
const OVERLAY_COPY = 'COPY overlay/app/ /toybaco-overlay/';
const GUARD_COPY = 'COPY scripts/verify-chatwoot-ee-view-twins.sh /opt/toybaco/verify-ee-view-twins.sh';
const GUARD_RUN = 'RUN sh /opt/toybaco/verify-ee-view-twins.sh /app/enterprise/app/views /toybaco-overlay';
const OVERLAY_TOUCH = 'RUN find /toybaco-overlay -exec touch -t 200001010000.00 {} +';
const IGNORE_INCLUDE = '!scripts/verify-chatwoot-ee-view-twins.sh';
const CONTROL_FILES = ['scripts/verify-chatwoot-ee-view-twins.sh', 'tests/chatwoot-ee-view-twins.test.mjs'];
const QUALITY_RUN =
  '  TOYBACO_CONTROL_ROOT="$CONTROL_ROOT" node --test "$CONTROL_ROOT/tests/chatwoot-ee-view-twins.test.mjs"';
const QUALITY_NEIGHBOR = '  node "$CONTROL_ROOT/tests/chatwoot-post-entry.test.mjs"';

function exactLineIndexes(lines, expected) {
  return lines.flatMap((line, index) => (line === expected ? [index] : []));
}

function singleLine(lines, expected, label) {
  const indexes = exactLineIndexes(lines, expected);
  assert.equal(indexes.length, 1, `${label}: exact 1 line expected: ${expected}`);
  return indexes[0];
}

// bash 関数 name() { ... } の本体(列 0 の閉じ括弧まで)。
function functionBody(source, name) {
  const lines = source.split('\n');
  const start = singleLine(lines, `${name}() {`, 'gate function');
  const end = lines.findIndex((line, index) => index > start && line === '}');
  assert.ok(end > start, `gate function ${name} must close`);
  return lines.slice(start + 1, end);
}

function validateWiring(dockerfile, dockerignore, gate) {
  const lines = dockerfile.split('\n');
  const stage = singleLine(lines, OVERLAY_STAGE, 'Dockerfile');
  const overlayCopy = singleLine(lines, OVERLAY_COPY, 'Dockerfile');
  const guardCopy = singleLine(lines, GUARD_COPY, 'Dockerfile');
  const guardRun = singleLine(lines, GUARD_RUN, 'Dockerfile');
  const touch = singleLine(lines, OVERLAY_TOUCH, 'Dockerfile');
  assert.ok(stage < overlayCopy && overlayCopy < guardCopy && guardCopy < guardRun && guardRun < touch,
    'guard must run after the overlay copy and before the mtime normalization');
  assert.ok(!lines.slice(stage + 1, touch).some(line => /^\s*FROM\s/i.test(line)),
    'guard must run inside the overlay-normalizer stage');
  assert.equal(dockerfile.split('verify-chatwoot-ee-view-twins.sh').length - 1, 1, 'one guard copy');
  assert.equal(dockerfile.split('/opt/toybaco/verify-ee-view-twins.sh').length - 1, 2, 'one guard copy and run');

  singleLine(dockerignore.split('\n'), IGNORE_INCLUDE, '.dockerignore');

  const controlFiles = functionBody(gate, 'control_file_list');
  for (const file of CONTROL_FILES) {
    assert.equal(controlFiles.filter(line => line.trim() === `'${file}' \\`).length, 1,
      `gate control_file_list must carry ${file}`);
  }
  const quality = functionBody(gate, 'verify_base_and_frame_contract');
  singleLine(quality, QUALITY_RUN, 'gate quality stage');
  singleLine(quality, QUALITY_NEIGHBOR, 'gate quality stage');
  singleLine(gate.split('\n'), QUALITY_RUN, 'gate');
}

const wiringInputs = ['Dockerfile', '.dockerignore', 'bin/toybaco-chatwoot-gate'].map(path =>
  readFileSync(join(root, path), 'utf8'));

test('配線契約: Dockerfile・.dockerignore・gate が guard と単体テストを通す', () => {
  validateWiring(...wiringInputs);
});

test('配線契約の負例: 各配線行を外すか順序を崩すと契約が落ちる', () => {
  const omissions = [
    [0, GUARD_COPY],
    [0, GUARD_RUN],
    [0, OVERLAY_COPY],
    [1, IGNORE_INCLUDE],
    [2, `'${CONTROL_FILES[0]}'`],
    [2, `'${CONTROL_FILES[1]}'`],
    [2, QUALITY_RUN],
  ];
  const reorders = [
    // guard を overlay copy より前へ
    [0, `${OVERLAY_COPY}\n${GUARD_COPY}\n${GUARD_RUN}`, `${GUARD_COPY}\n${GUARD_RUN}\n${OVERLAY_COPY}`],
    // guard を mtime 正規化より後へ
    [0, `${GUARD_RUN}\n${OVERLAY_TOUCH}`, `${OVERLAY_TOUCH}\n${GUARD_RUN}`],
    // guard を別 stage へ
    [0, `${GUARD_COPY}\n${GUARD_RUN}`, `${GUARD_COPY}\nFROM \${CHATWOOT_IMAGE} AS elsewhere\n${GUARD_RUN}`],
    // guard を重複
    [0, GUARD_RUN, `${GUARD_RUN}\n${GUARD_RUN}`],
  ];
  let negatives = 0;
  for (const [index, text] of omissions) {
    const modified = [...wiringInputs];
    assert.ok(modified[index].includes(text), `fixture anchor missing: ${text}`);
    modified[index] = modified[index].replace(text, '# omitted');
    assert.throws(() => validateWiring(...modified), `omitted wiring must fail: ${text}`);
    negatives++;
  }
  for (const [index, from, to] of reorders) {
    const modified = [...wiringInputs];
    assert.ok(modified[index].includes(from), `fixture anchor missing: ${from}`);
    modified[index] = modified[index].replace(from, to);
    assert.throws(() => validateWiring(...modified), `reordered wiring must fail: ${to}`);
    negatives++;
  }
  // quality stage の実行行を、quality stage ではない別の関数へ移す
  const movedGate = wiringInputs[2].replace(`${QUALITY_RUN}\n`, '')
    .replace('build_test_image() {\n', `build_test_image() {\n${QUALITY_RUN}\n`);
  assert.notEqual(movedGate, wiringInputs[2]);
  assert.throws(() => validateWiring(wiringInputs[0], wiringInputs[1], movedGate), 'quality run outside the quality stage');
  negatives++;
  assert.ok(negatives >= 5);
  console.log(`EE view twin wiring: PASS (${negatives} negative controls)`);
});
