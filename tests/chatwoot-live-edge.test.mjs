import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'toybaco-edge-contract-'));
try {
  // Exercise the real gate, replacing only curl. No network or system change.
  fs.writeFileSync(path.join(temp, 'curl'), `#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2);
if (args.includes('--tls-max')) process.exit(process.env.TB_EDGE_TLS11 === '1' ? 0 : 35);
const http = args[args.length - 1].startsWith('http://');
const headers = args[args.indexOf('--dump-header') + 1];
const eol = process.env.TB_EDGE_EOL === 'lf' ? '\\n' : '\\r\\n';
const lines = http ? ['HTTP/1.1 301 Moved', 'Location: ' + (process.env.TB_EDGE_LOCATION || 'https://app.toybaco.jp/app/login')] :
  ['HTTP/2 200', 'Strict-Transport-Security: ' + (process.env.TB_EDGE_HSTS || 'max-age=15552000; includeSubDomains'),
   process.env.TB_EDGE_NOSNIFF || 'X-Content-Type-Options: nosniff'];
fs.writeFileSync(headers, lines.join(eol) + eol + eol);
if (http) process.stdout.write(process.env.TB_EDGE_HTTP || '301');
`, { mode: 0o700 });
  let cases = 0;
  for (const [name, env, pass] of [
    ['CRLF', {}, true],
    ['LF', { TB_EDGE_EOL: 'lf' }, true],
    ['header case and whitespace', { TB_EDGE_NOSNIFF: 'x-content-type-options:\tNOSNIFF' }, true],
    ['missing header', { TB_EDGE_NOSNIFF: 'X-Unrelated: nosniff' }, false],
    ['wrong value', { TB_EDGE_NOSNIFF: 'X-Content-Type-Options: sniff' }, false],
    ['suffix rejected', { TB_EDGE_NOSNIFF: 'X-Content-Type-Options: nosniffr' }, false],
    ['weak HSTS', { TB_EDGE_HSTS: 'max-age=60; includeSubDomains' }, false],
    ['missing subdomains', { TB_EDGE_HSTS: 'max-age=15552000' }, false],
    ['unapproved preload', { TB_EDGE_HSTS: 'max-age=15552000; includeSubDomains; preload' }, false],
    ['HTTP not redirected', { TB_EDGE_HTTP: '200' }, false],
    ['wrong redirect', { TB_EDGE_LOCATION: 'https://example.invalid/' }, false],
    ['TLS 1.1 accepted', { TB_EDGE_TLS11: '1' }, false],
  ]) {
    const result = spawnSync('bash', [path.join(root, 'bin/toybaco-chatwoot-live-edge-gate')], {
      encoding: 'utf8', env: { ...process.env, PATH: `${temp}:${process.env.PATH}`, ...env },
    });
    assert.equal(result.status === 0, pass, `${name}: ${result.stdout}${result.stderr}`);
    cases++;
  }
  console.log(`Live edge header contract: ${cases} cases PASS`);
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
