#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs, { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { syncBuiltinESMExports } from 'node:module';
const root = resolve(process.argv[2] || '.');
const policy = await import(pathToFileURL(join(root, 'scripts/verify-chatwoot-ruby-llm-classification.mjs')));
const { IMAGE, CVE, GEM_PURL, FIX, TRIVY, VEX_TYPE, PROOF_TYPE, evaluate, validateVex, verifyAttestations } = policy;
const configBytes = readFileSync(join(root, 'config/chatwoot-ruby-llm-backport.json'));
const config = JSON.parse(configBytes);
const hash = value => createHash('sha256').update(value).digest('hex');
const clone = value => structuredClone(value);
const hex = 'a'.repeat(64), imageDigest = 'sha256:' + hex;
const gemRoot = '/gems/ruby/3.4.0/gems/ruby_llm-1.15.0';
const specPath = '/gems/ruby/3.4.0/specifications/ruby_llm-1.15.0.gemspec';
const ref = value => [{ referenceCategory: 'PACKAGE-MANAGER', referenceType: 'purl', referenceLocator: value }];
function fixture() {
  const context = { schema_version: 1, image: IMAGE, image_digest: imageDigest, source_commit: 'b'.repeat(40),
    source_ref: 'refs/heads/main', control_sha256: 'c'.repeat(64), trivy_image: TRIVY,
    db_download_started_at: '2026-09-17T07:00:00Z', issued_at: '2026-09-17T07:01:00Z' };
  const proof = { schema_version: 1, result: 'PASS', advisory: CVE, public_revision: context.source_commit,
    patch_config_sha256: hash(configBytes), upstream_fix_commit: FIX,
    gem: { name: 'ruby_llm', version: '1.15.0', installed_spec_count: 1, gem_root: gemRoot, spec_path: specPath },
    ruby: { version: '3.4.4', platform: 'x86_64-linux-musl' },
    files: config.files.map(f => ({ path: f.path, sha256: f.patched_sha256, method: f.method,
      source_path: gemRoot + '/' + f.path, source_line: f.source_line })),
    unchanged_files: clone(config.unchanged_files),
    ruby_source_inventory: { ...config.ruby_source_inventory.patched,
      vulnerable_acronym_occurrences: 0, fixed_boundary_occurrences: 2 },
    agents: { loaded: true, version: '0.12.0', spec_path: '/gems/ruby/3.4.0/specifications/ai-agents-0.12.0.gemspec' },
    tests: { passed: true, ordinary_cases: 20020, ordinary_method_comparisons: 40040,
      official_examples: 4, tool_suffix_examples: 4, agents_constructor: true,
      negative_controls: { wrong_source_hash: true, wrong_catalog_hash: true },
      adversarial: { length: 100000, timeout_seconds: 2, tool_seconds: 0.08, agent_seconds: 0.04 } } };
  const sbom = { spdxVersion: 'SPDX-2.3', SPDXID: 'SPDXRef-DOCUMENT',
    packages: [
      { SPDXID: 'SPDXRef-image', name: IMAGE, versionInfo: imageDigest, primaryPackagePurpose: 'CONTAINER',
        checksums: [{ algorithm: 'SHA256', checksumValue: hex }],
        externalRefs: ref('pkg:oci/' + IMAGE + '@sha256%3A' + hex + '?arch=amd64') },
      { SPDXID: 'SPDXRef-ruby', name: 'ruby_llm', versionInfo: '1.15.0', externalRefs: ref(GEM_PURL) },
      { SPDXID: 'SPDXRef-alpine', name: 'alpine-baselayout', versionInfo: '3.6.8-r1',
        externalRefs: ref('pkg:apk/alpine/alpine-baselayout@3.6.8-r1?arch=x86_64&distro=alpine-3.21.3') },
    ], relationships: [
      { spdxElementId: 'SPDXRef-DOCUMENT', relationshipType: 'DESCRIBES', relatedSpdxElement: 'SPDXRef-image' },
      { spdxElementId: 'SPDXRef-image', relationshipType: 'CONTAINS', relatedSpdxElement: 'SPDXRef-ruby' },
    ] };
  const finding = { VulnerabilityID: CVE, Severity: 'HIGH', PkgName: 'ruby_llm', InstalledVersion: '1.15.0',
    FixedVersion: '>= 2.0.0.rc1', PkgPath: specPath.slice(1), PkgIdentifier: { PURL: GEM_PURL, UID: 'gem-id' } };
  const raw = { SchemaVersion: 2, ArtifactType: 'spdx', Metadata: { OS: { Family: 'alpine', Name: '3.21.3' } },
    Results: [
      { Target: 'alpine', Type: 'alpine', Class: 'os-pkgs', Packages: [{ Name: 'openjpeg', Version: '2.5.4-r0' }] },
      { Target: 'Ruby', Type: 'gemspec', Class: 'lang-pkgs',
        Packages: [{ Name: 'ruby_llm', Version: '1.15.0', Identifier: { PURL: GEM_PURL, UID: 'gem-id' } }],
        Vulnerabilities: [finding] },
    ] };
  const before = { database_sha256: 'd'.repeat(64), metadata_sha256: 'e'.repeat(64),
    metadata: { Version: 2, DownloadedAt: '2026-09-17T07:00:05Z',
      UpdatedAt: '2026-09-17T06:10:00Z', NextUpdate: '2026-09-17T12:10:00Z' } };
  return { config: clone(config), configSha: hash(configBytes), context, proof, sbom, raw, rawExit: 1,
    before, after: clone(before), imageInspect: [{ Os: 'linux', Architecture: 'amd64',
      RepoDigests: [IMAGE + '@' + imageDigest], Config: { Labels: {
        'jp.toybaco.gate.control-sha256': context.control_sha256,
        'org.opencontainers.image.revision': '9f920b549c14491a4e587687a3eed5d21c6ccc7d' } } }],
    hashes: { sbom: '1'.repeat(64), raw_report: '2'.repeat(64), installed_proof: '3'.repeat(64),
      image_inspect: '4'.repeat(64), evaluator: '5'.repeat(64) } };
}
const valid = fixture(), originalRaw = clone(valid.raw), result = evaluate(valid);
assert.deepEqual(valid.raw, originalRaw, 'classification must not mutate the raw scanner report');
assert.deepEqual(result.classification.raw_report, originalRaw);
assert.equal(result.classification.scanner_vex_filtering, false);
assert.equal(result.classification.evaluation_kind, 'independent_source_backport_classification');
assert.deepEqual(result.classification.counts, { raw_critical: 0, raw_high: 1, source_verified_fixed: 1,
  unresolved_critical: 0, unresolved_high: 0 });
assert.equal(result.vex.statements[0].status, 'fixed');
// Exact root purl shape observed from the pinned registry-digest Syft publisher.
const observedEmptyArch = fixture();
const emptyArchPurl = 'pkg:oci/' + IMAGE.replaceAll('/', '%2F') + '@sha256%3A' + hex + '?arch=';
observedEmptyArch.sbom.packages[0].externalRefs = ref(emptyArchPurl);
const emptyArchResult = evaluate(observedEmptyArch);
assert.equal(emptyArchResult.classification.bindings.root_purl, emptyArchPurl);
assert.equal(emptyArchResult.vex.statements[0].products[0]['@id'], emptyArchPurl);
assert.deepEqual(emptyArchResult.classification.counts, result.classification.counts);
const negatives = [
  ['missing proof', x => { x.proof = null; }],
  ['wrong source commit', x => { x.proof.public_revision = '0'.repeat(40); }],
  ['wrong config digest', x => { x.proof.patch_config_sha256 = '0'.repeat(64); }],
  ['wrong full source hash', x => { x.proof.files[0].sha256 = '0'.repeat(64); }],
  ['moved loaded method', x => { x.proof.files[0].source_path = '/tmp/agent.rb'; }],
  ['wrong loaded method line', x => { x.proof.files[1].source_line++; }],
  ['wrong unchanged entrypoint hash', x => { x.proof.unchanged_files[0].sha256 = '0'.repeat(64); }],
  ['duplicate installed spec', x => { x.proof.gem.installed_spec_count = 2; }],
  ['wrong spec path', x => { x.proof.gem.spec_path = '/other/ruby_llm.gemspec'; }],
  ['wrong runtime', x => { x.proof.ruby.version = '2.6.10'; }],
  ['unverified Agents', x => { x.proof.agents.loaded = false; }],
  ['missing equivalence tests', x => { x.proof.tests.ordinary_method_comparisons = 0; }],
  ['timing regression', x => { x.proof.tests.adversarial.tool_seconds = 2; }],
  ['missing negative tests', x => { x.proof.tests.negative_controls.wrong_source_hash = false; }],
  ['unexpected Ruby code file', x => { x.proof.ruby_source_inventory.count++; }],
  ['remaining vulnerable expression', x => { x.proof.ruby_source_inventory.vulnerable_acronym_occurrences = 1; }],
  ['wrong image digest', x => { x.context.image_digest = 'sha256:' + 'f'.repeat(64); }],
  ['wrong image repo', x => { x.context.image = 'elsewhere/image'; }],
  ['wrong image control', x => { x.imageInspect[0].Config.Labels['jp.toybaco.gate.control-sha256'] = 'f'.repeat(64); }],
  ['no inspected image', x => { x.imageInspect = []; }],
  ['duplicate image inspection', x => { x.imageInspect.push(clone(x.imageInspect[0])); }],
  ['wrong platform', x => { x.imageInspect[0].Architecture = 'arm64'; }],
  ['non-main source', x => { x.context.source_ref = 'refs/heads/other'; }],
  ['mutable scanner', x => { x.context.trivy_image = 'aquasec/trivy:latest'; }],
  ['missing SBOM root', x => { x.sbom.relationships.shift(); }],
  ['duplicate SBOM root', x => { x.sbom.relationships.push(clone(x.sbom.relationships[0])); }],
  ['wrong manifest checksum', x => { x.sbom.packages[0].checksums[0].checksumValue = 'f'.repeat(64); }],
  ['missing OCI purl', x => { x.sbom.packages[0].externalRefs = []; }],
  ['versionless OCI purl', x => { x.sbom.packages[0].externalRefs[0].referenceLocator = 'pkg:oci/' + IMAGE; }],
  ['wrong OCI purl digest', x => { x.sbom.packages[0].externalRefs[0].referenceLocator = 'pkg:oci/' + IMAGE + '@sha256%3A' + 'f'.repeat(64) + '?arch=amd64'; }],
  ['wrong OCI purl repository', x => { x.sbom.packages[0].externalRefs[0].referenceLocator = 'pkg:oci/other@sha256%3A' + hex + '?arch=amd64'; }],
  ['extra OCI qualifier', x => { x.sbom.packages[0].externalRefs[0].referenceLocator += '&tag=latest'; }],
  ['explicit wrong OCI architecture', x => { x.sbom.packages[0].externalRefs[0].referenceLocator = emptyArchPurl + 'arm64'; }],
  ['invalid OCI architecture', x => { x.sbom.packages[0].externalRefs[0].referenceLocator = emptyArchPurl + 'unknown'; }],
  ['duplicate OCI architecture', x => { x.sbom.packages[0].externalRefs[0].referenceLocator = emptyArchPurl + '&arch=amd64'; }],
  ['missing OCI architecture', x => { x.sbom.packages[0].externalRefs[0].referenceLocator = emptyArchPurl.replace('?arch=', ''); }],
  ['missing OCI architecture key', x => { x.sbom.packages[0].externalRefs[0].referenceLocator = emptyArchPurl.replace('?arch=', '?other='); }],
  ['missing OCI architecture assignment', x => { x.sbom.packages[0].externalRefs[0].referenceLocator = emptyArchPurl.slice(0, -1); }],
  ['blank OCI architecture cannot bypass actual image CPU', x => { x.sbom.packages[0].externalRefs = ref(emptyArchPurl); x.imageInspect[0].Architecture = 'arm64'; }],
  ['blank OCI architecture cannot bypass actual image OS', x => { x.sbom.packages[0].externalRefs = ref(emptyArchPurl); x.imageInspect[0].Os = 'windows'; }],
  ['blank OCI architecture cannot bypass runtime CPU', x => { x.sbom.packages[0].externalRefs = ref(emptyArchPurl); x.proof.ruby.platform = 'aarch64-linux-musl'; }],
  ['wrong gem purl', x => { x.sbom.packages[1].externalRefs[0].referenceLocator = 'pkg:gem/ruby_llm@1.16.0'; }],
  ['versionless gem purl', x => { x.sbom.packages[1].externalRefs[0].referenceLocator = 'pkg:gem/ruby_llm'; }],
  ['duplicate gem inventory', x => { x.sbom.packages.push({ ...clone(x.sbom.packages[1]), SPDXID: 'SPDXRef-extra' }); }],
  ['missing dependency relationship', x => { x.sbom.relationships.pop(); }],
  ['wrong relationship direction', x => { const r = x.sbom.relationships[1]; [r.spdxElementId, r.relatedSpdxElement] = [r.relatedSpdxElement, r.spdxElementId]; }],
  ['unknown relationship', x => { x.sbom.relationships[1].relationshipType = 'OTHER'; }],
  ['database changed', x => { x.after.database_sha256 = 'f'.repeat(64); }],
  ['database metadata changed', x => { x.after.metadata_sha256 = 'f'.repeat(64); }],
  ['old copied DB', x => { x.before.metadata.DownloadedAt = '2026-09-16T07:00:00Z'; x.after = clone(x.before); }],
  ['stale DB', x => { x.before.metadata.UpdatedAt = '2026-09-10T07:00:00Z'; x.after = clone(x.before); }],
  ['wrong DB schema', x => { x.before.metadata.Version = 1; x.after = clone(x.before); }],
  ['empty raw report', x => { x.raw = {}; }],
  ['raw zero cannot claim backport', x => { x.raw.Results[1].Vulnerabilities = []; x.rawExit = 0; }],
  ['scanner error', x => { x.rawExit = 2; }],
  ['wrong scanner exit', x => { x.rawExit = 0; }],
  ['lost OS inventory', x => { x.raw.Results.shift(); }],
  ['lost language inventory', x => { x.raw.Results[1].Packages = []; }],
  ['additional unfixed HIGH', x => { x.raw.Results[0].Vulnerabilities = [{ VulnerabilityID: 'CVE-2099-1', Severity: 'HIGH', FixedVersion: '' }]; }],
  ['additional CRITICAL', x => { x.raw.Results[0].Vulnerabilities = [{ VulnerabilityID: 'CVE-2099-2', Severity: 'CRITICAL' }]; }],
  ['duplicate raw finding', x => { x.raw.Results[1].Vulnerabilities.push(clone(x.raw.Results[1].Vulnerabilities[0])); }],
  ['new CVE on same gem', x => { x.raw.Results[1].Vulnerabilities[0].VulnerabilityID = 'CVE-2099-3'; }],
  ['wrong affected version', x => { x.raw.Results[1].Vulnerabilities[0].InstalledVersion = '1.16.0'; }],
  ['wrong affected package path', x => { x.raw.Results[1].Vulnerabilities[0].PkgPath = '/other/ruby_llm.gemspec'; }],
  ['wrong affected purl', x => { x.raw.Results[1].Vulnerabilities[0].PkgIdentifier.PURL = 'pkg:gem/ruby_llm'; }],
  ['ambiguous affected UID', x => { x.raw.Results[1].Vulnerabilities[0].PkgIdentifier.UID = 'other'; }],
  ['duplicate raw package', x => { x.raw.Results[1].Packages.push(clone(x.raw.Results[1].Packages[0])); }],
  ['prefiltered finding', x => { x.raw.Results[1].ExperimentalModifiedFindings = [{ Status: 'fixed' }]; }],
];
for (const [label, mutate] of negatives) { const x = fixture(); mutate(x); assert.throws(() => evaluate(x), label); }
const vexNegatives = [
  ['extra statement', v => v.statements.push(clone(v.statements[0]))],
  ['extra product', v => v.statements[0].products.push(clone(v.statements[0].products[0]))],
  ['extra component', v => v.statements[0].products[0].subcomponents.push({ '@id': 'pkg:gem/rails' })],
  ['gem-only broad product', v => { v.statements[0].products[0]['@id'] = GEM_PURL; }],
  ['not affected claim', v => { v.statements[0].status = 'not_affected'; }],
  ['wrong proof hash', v => { v.statements[0].status_notes = 'trust me'; }],
  ['extra author field', v => { v.other = 'unreviewed'; }],
];
for (const [label, mutate] of vexNegatives) { const v = clone(result.vex); mutate(v);
  assert.throws(() => validateVex(v, result.classification.bindings, valid.context, valid.hashes.installed_proof), label); }
function attestation(predicateType, predicate) {
  return [{ verificationResult: { signature: { certificate: {} }, verifiedTimestamps: [{ type: 'tlog' }],
    statement: { _type: 'https://in-toto.io/Statement/v1', subject: [{ name: IMAGE, digest: { sha256: hex } }],
      predicateType, predicate } } }];
}
for (const [type, document] of [[VEX_TYPE, result.vex], [PROOF_TYPE, result.classification]]) {
  verifyAttestations(attestation(type, document), type, document, valid.context);
  for (const mutate of [
    rows => { rows[0].verificationResult.statement.subject[0].digest.sha256 = 'f'.repeat(64); },
    rows => { rows[0].verificationResult.statement.subject.push({ name: 'other', digest: { sha256: hex } }); },
    rows => { rows[0].verificationResult.statement.predicate = {}; },
    rows => { rows[0].verificationResult.statement.predicateType = 'wrong'; },
    rows => { rows[0].verificationResult.verifiedTimestamps = []; },
  ]) { const rows = attestation(type, clone(document)); mutate(rows);
    assert.throws(() => verifyAttestations(rows, type, document, valid.context)); }
}
assert.throws(() => verifyAttestations([], VEX_TYPE, result.vex, valid.context));
console.log('Chatwoot source-backport classifier: PASS (2 positives; ' +
  negatives.length + ' evidence negatives; ' + vexNegatives.length + ' VEX negatives; 11 attestation negatives; no external calls)');
export { fixture as classificationFixture };

// These disk tests run in the dedicated classifier check, not fixture-only imports.
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const directory = mkdtempSync(join(tmpdir(), 'toybaco-db-hash-'));
  const dbPath = join(directory, 'db', 'trivy.db'), metadataPath = join(directory, 'db', 'metadata.json');
  const metadataBytes = Buffer.from('{"Version":2}\n');
  mkdirSync(join(directory, 'db'));
  const reset = (bytes = Buffer.from('frozen database fixture')) => {
    rmSync(dbPath, { force: true, recursive: true });
    writeFileSync(dbPath, bytes);
    writeFileSync(metadataPath, metadataBytes);
  };
  const sparse = size => {
    const fd = fs.openSync(dbPath, 'r+');
    try { fs.ftruncateSync(fd, size); } finally { fs.closeSync(fd); }
  };
  const replaceFs = (overrides, run) => {
    const originals = Object.fromEntries(Object.keys(overrides).map(key => [key, fs[key]]));
    try {
      for (const [key, factory] of Object.entries(overrides)) fs[key] = factory(originals[key]);
      syncBuiltinESMExports();
      return run();
    } finally {
      Object.assign(fs, originals);
      syncBuiltinESMExports();
    }
  };
  const snapshot = () => policy.snapshotDatabase(directory);
  const duringRead = (mutate, expected) => {
    let changed = false;
    replaceFs({ readSync: original => (...args) => {
      const count = original(...args);
      if (!changed && count > 0) { changed = true; mutate(); }
      return count;
    } }, () => assert.throws(snapshot, expected));
    assert.equal(changed, true);
  };
  try {
    reset();
    assert.deepEqual(snapshot(), { database_sha256: hash(Buffer.from('frozen database fixture')),
      metadata_sha256: hash(metadataBytes), metadata: { Version: 2 } });

    // A real sparse file above the old 1 GiB boundary, with independently known bytes.
    reset(Buffer.alloc(0));
    const size = 1073741824 + 4097, head = Buffer.from('database-head'), tail = Buffer.from('database-tail');
    sparse(size);
    const fd = fs.openSync(dbPath, 'r+');
    try {
      fs.writeSync(fd, head, 0, head.length, 0);
      fs.writeSync(fd, tail, 0, tail.length, size - tail.length);
    } finally { fs.closeSync(fd); }
    const expected = createHash('sha256').update(head), zeros = Buffer.alloc(1048576);
    let zeroBytes = size - head.length - tail.length;
    while (zeroBytes > 0) { const length = Math.min(zeros.length, zeroBytes);
      expected.update(zeros.subarray(0, length)); zeroBytes -= length; }
    const expectedSha = expected.update(tail).digest('hex');
    let reads = 0;
    const large = replaceFs({
      readFileSync: original => (path, ...args) => {
        assert.notEqual(path, dbPath, 'database must not be read into a whole-file buffer');
        return original(path, ...args);
      },
      readSync: original => (...args) => {
        assert.ok(args[3] > 0 && args[3] <= 1048576, 'database reads must be bounded to 1 MiB');
        reads += 1; return original(...args);
      },
    }, snapshot);
    assert.equal(large.database_sha256, expectedSha);
    assert.ok(reads > 1024);

    reset();
    const before = snapshot();
    writeFileSync(dbPath, 'Frozen database fixture');
    assert.notEqual(snapshot().database_sha256, before.database_sha256, 'same-size content change must change the hash');

    reset(Buffer.alloc(0));
    assert.throws(snapshot, /trivy.db: size 0 outside supported range 1\.\.4294967296 bytes/);
    sparse(4294967297);
    assert.throws(snapshot, /trivy.db: size 4294967297 outside supported range 1\.\.4294967296 bytes/);
    reset();
    rmSync(dbPath); mkdirSync(dbPath);
    assert.throws(snapshot, /trivy.db: expected a regular non-symlink file/);
    reset();
    rmSync(dbPath); fs.symlinkSync(metadataPath, dbPath);
    assert.throws(snapshot, /trivy.db: expected a regular non-symlink file/);
    reset();
    const metadataFd = fs.openSync(metadataPath, 'r+');
    try { fs.ftruncateSync(metadataFd, 16777217); } finally { fs.closeSync(metadataFd); }
    assert.throws(snapshot, /"metadata.json": size 16777217 outside supported range 1\.\.16777216 bytes/);

    // Actual file changes around descriptor opening/reading must fail closed.
    reset();
    replaceFs({ openSync: original => (path, ...args) => {
      if (path === dbPath) { fs.renameSync(dbPath, dbPath + '.replaced');
        writeFileSync(dbPath, 'frozen database fixture'); }
      return original(path, ...args);
    } }, () => assert.throws(snapshot, /trivy.db: identity or metadata changed during hashing/));
    reset();
    replaceFs({ openSync: original => (path, ...args) => {
      if (path === dbPath) { rmSync(dbPath); fs.symlinkSync(metadataPath, dbPath); }
      return original(path, ...args);
    } }, () => assert.throws(snapshot, error => error.code === 'ELOOP'));
    reset(Buffer.alloc(2097152));
    duringRead(() => fs.truncateSync(dbPath, 0), /trivy.db: unexpected EOF during hashing/);
    reset(Buffer.alloc(2097152));
    duringRead(() => fs.appendFileSync(dbPath, 'extra'), /trivy.db: grew during hashing/);
    reset(Buffer.alloc(2097152));
    duringRead(() => {
      const mutationFd = fs.openSync(dbPath, 'r+');
      try { fs.writeSync(mutationFd, Buffer.from('changed'), 0, 7, 0); } finally { fs.closeSync(mutationFd); }
      fs.utimesSync(dbPath, new Date(0), new Date(0));
    }, /trivy.db: identity or metadata changed during hashing/);
    reset(Buffer.alloc(2097152));
    duringRead(() => { fs.renameSync(dbPath, dbPath + '.during-read'); writeFileSync(dbPath, Buffer.alloc(2097152)); },
      /trivy.db: identity or metadata changed during hashing/);
    reset(Buffer.alloc(2097152));
    duringRead(() => { rmSync(dbPath); fs.symlinkSync(metadataPath, dbPath); },
      /trivy.db: (identity or metadata changed during hashing|file type changed during hashing)/);

    reset();
    const partial = replaceFs({ readSync: original => (fd, buffer, offset, length, position) =>
      original(fd, buffer, offset, Math.min(length, 3), position) }, snapshot);
    assert.equal(partial.database_sha256, hash(Buffer.from('frozen database fixture')));
    console.log('Chatwoot database snapshots: PASS (small/over-1-GiB/partial-read hashes; bounded 1 MiB reads; ' +
      '4 GiB cap; 16 MiB metadata cap; same-size hash change; 12 invalid-file/size/race negatives)');
  } finally { rmSync(directory, { recursive: true, force: true }); }
}
