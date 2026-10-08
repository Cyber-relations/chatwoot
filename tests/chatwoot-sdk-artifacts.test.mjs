import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { brotliCompressSync, gzipSync } from 'node:zlib';
import { verifySdkArtifacts } from './verify_chatwoot_sdk_artifacts.mjs';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const directory = mkdtempSync(join(tmpdir(), 'toybaco-sdk-artifacts-'));
const current = Buffer.from('(()=>{const options={sameSite:"Lax",secure:window.location.protocol==="https:"};})();');
const legacy = Buffer.from('(()=>{const options={sameSite:"Lax"};})();');
let negativeControls = 0;
function save(bytes = current) {
  writeFileSync(join(directory, 'sdk.js'), bytes);
  writeFileSync(join(directory, 'sdk.js.gz'), gzipSync(bytes));
  writeFileSync(join(directory, 'sdk.js.br'), brotliCompressSync(bytes));
}
try {
  save();
  assert.equal(verifySdkArtifacts(directory).sdk_artifacts, 'PASS');
  save(legacy);
  assert.throws(() => verifySdkArtifacts(directory), /omits the HTTPS/);
  negativeControls++;
  for (const name of ['sdk.js.gz', 'sdk.js.br']) {
    save();
    writeFileSync(join(directory, name), name.endsWith('.gz') ? gzipSync(legacy) : brotliCompressSync(legacy));
    assert.throws(() => verifySdkArtifacts(directory), /differs from the served/);
    negativeControls++;
    save();
    rmSync(join(directory, name));
    assert.throws(() => verifySdkArtifacts(directory), /ENOENT/);
    negativeControls++;
  }
  save(Buffer.from('(()=>{secure:window.location.protocol==="https:"}'));
  assert.throws(() => verifySdkArtifacts(directory), SyntaxError);
  negativeControls++;
} finally {
  rmSync(directory, { recursive: true, force: true });
}

function verifyWiring(dockerfile, ignore, gate) {
  const verifier = 'node /opt/toybaco/tests/verify_chatwoot_sdk_artifacts.mjs /app/public/packs/js';
  assert.equal(dockerfile.split('COPY tests/verify_chatwoot_sdk_artifacts.mjs /opt/toybaco/tests/').length - 1, 2,
    'builder and final runtime need the artifact verifier');
  assert(ignore.split('\n').includes('!tests/verify_chatwoot_sdk_artifacts.mjs'));
  assert.equal(dockerfile.split(verifier).length - 1, 2, 'verify rebuilt and final SDK artifacts');
  const build = dockerfile.indexOf('bundle exec rake assets:precompile');
  const firstCheck = dockerfile.indexOf(verifier);
  const collect = dockerfile.indexOf('cp -a /app/public/packs/js/sdk.js /app/public/packs/js/sdk.js.gz /app/public/packs/js/sdk.js.br /toybaco-runtime-root/app/public/packs/js/');
  const finalCopy = dockerfile.indexOf('COPY --from=runtime-hardening /toybaco-runtime-root/ /');
  assert(build < firstCheck && firstCheck < collect && collect < finalCopy && finalCopy < dockerfile.lastIndexOf(verifier),
    'rebuilt SDK must be checked, carried into the runtime, and checked again');
  assert(dockerfile.indexOf('/app/TOYBACO_PUBLIC_REVISION') < dockerfile.lastIndexOf(verifier),
    'verify the final filesystem after overlay and public revision writes');
  assert(gate.includes("'tests/verify_chatwoot_sdk_artifacts.mjs'"));
  assert(gate.includes("'tests/chatwoot-sdk-artifacts.test.mjs'"));
  assert(gate.includes('node "$CONTROL_ROOT/tests/chatwoot-sdk-artifacts.test.mjs"'));
}
const inputs = ['Dockerfile', '.dockerignore', 'bin/toybaco-chatwoot-gate'].map(path => readFileSync(join(root, path), 'utf8'));
verifyWiring(...inputs);
for (const [index, text] of [
  [0, 'COPY tests/verify_chatwoot_sdk_artifacts.mjs /opt/toybaco/tests/'],
  [0, 'cp -a /app/public/packs/js/sdk.js /app/public/packs/js/sdk.js.gz /app/public/packs/js/sdk.js.br /toybaco-runtime-root/app/public/packs/js/'],
  [0, 'node /opt/toybaco/tests/verify_chatwoot_sdk_artifacts.mjs /app/public/packs/js'],
  [1, '!tests/verify_chatwoot_sdk_artifacts.mjs'],
  [2, "'tests/verify_chatwoot_sdk_artifacts.mjs'"],
  [2, 'node "$CONTROL_ROOT/tests/chatwoot-sdk-artifacts.test.mjs"'],
]) {
  const mutated = [...inputs];
  assert(mutated[index].includes(text));
  mutated[index] = mutated[index].replace(text, '# omitted');
  assert.throws(() => verifyWiring(...mutated), 'omitted SDK packaging contract must fail');
  negativeControls++;
}
const prematureCheck = [...inputs];
const finalRun = 'RUN node /opt/toybaco/tests/verify_chatwoot_sdk_artifacts.mjs /app/public/packs/js\n';
prematureCheck[0] = prematureCheck[0].replace(finalRun, '').replace('COPY --from=overlay-normalizer /toybaco-overlay/ /app/\n',
  finalRun + 'COPY --from=overlay-normalizer /toybaco-overlay/ /app/\n');
assert.throws(() => verifyWiring(...prematureCheck), 'SDK proof before the final overlay must fail');
negativeControls++;
console.log(JSON.stringify({ sdk_artifact_contract: 'PASS', negative_controls: negativeControls }));
