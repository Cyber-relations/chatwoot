import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Script } from 'node:vm';
import { brotliDecompressSync, gunzipSync } from 'node:zlib';

// Verify the served artifacts, rather than only the SDK source copied into /app.
export function verifySdkArtifacts(directory) {
  const javascript = readFileSync(join(directory, 'sdk.js'));
  assert(javascript.length > 0 && javascript.length <= 5 * 1024 * 1024, 'SDK size is invalid');
  new Script(javascript.toString('utf8'), { filename: 'sdk.js' });
  assert.match(javascript.toString('utf8'),
    /secure\s*:\s*(?:window\.location\.protocol\s*===?\s*["']https:["']|["']https:["']\s*===?\s*window\.location\.protocol)/,
    'compiled SDK omits the HTTPS Secure-cookie option');
  const gzip = readFileSync(join(directory, 'sdk.js.gz'));
  const brotli = readFileSync(join(directory, 'sdk.js.br'));
  assert.deepEqual(gunzipSync(gzip, { maxOutputLength: 5 * 1024 * 1024 }), javascript,
    'gzip SDK differs from the served JavaScript');
  assert.deepEqual(brotliDecompressSync(brotli, { maxOutputLength: 5 * 1024 * 1024 }), javascript,
    'Brotli SDK differs from the served JavaScript');
  return {
    sdk_artifacts: 'PASS',
    bytes: javascript.length,
    sha256: createHash('sha256').update(javascript).digest('hex'),
    browser_cookie_acceptance: false,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  assert.equal(process.argv.length, 3, 'usage: node verify_chatwoot_sdk_artifacts.mjs SDK_DIRECTORY');
  console.log(JSON.stringify(verifySdkArtifacts(process.argv[2])));
}
