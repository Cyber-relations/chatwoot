#!/usr/bin/env node
// Pure, fail-closed classification policy. This does not replace Trivy scanning.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const IMAGE = '951034765053.dkr.ecr.ap-northeast-1.amazonaws.com/toybaco/chatwoot';
export const CVE = 'CVE-2026-67991';
export const GEM_PURL = 'pkg:gem/ruby_llm@1.15.0';
export const FIX = '9d75b033d7d00c4e1baa9b0afb4828faa8bd6602';
export const VEX_TYPE = 'https://openvex.dev/ns/v0.2.0';
export const PROOF_TYPE = 'https://toybaco.jp/attestations/chatwoot-ruby-llm-backport/v1';
export const TRIVY = 'docker.io/aquasec/trivy:0.67.2@sha256:ac2f9d0197456a8ce460884b113e49d65b667f506c31d014c9955869a7a5d682';
const GEM_ROOT = '/gems/ruby/3.4.0/gems/ruby_llm-1.15.0';
const SPEC_PATH = '/gems/ruby/3.4.0/specifications/ruby_llm-1.15.0.gemspec';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const canonical = value => JSON.stringify(sort(value));
function sort(value) {
  if (Array.isArray(value)) return value.map(sort);
  return value && typeof value === 'object'
    ? Object.fromEntries(Object.keys(value).sort().map(key => [key, sort(value[key])])) : value;
}
const equal = (a, b, label) => assert.equal(canonical(a), canonical(b), label);
const hash = value => { assert.match(value, /^[0-9a-f]{64}$/); return value; };
const digest = value => { assert.match(value, /^sha256:[0-9a-f]{64}$/); return value; };
const one = (values, label) => { assert.equal(values.length, 1, label); return values[0]; };
const array = value => { assert.ok(Array.isArray(value)); return value; };
const timestamp = value => { const ms = Date.parse(value); assert.ok(Number.isFinite(ms)); return ms; };
function purl(pkg) {
  return one(array(pkg.externalRefs).filter(ref => ref.referenceType === 'purl' &&
    ref.referenceCategory === 'PACKAGE-MANAGER'), 'one package purl required').referenceLocator;
}

export function validateProof(proof, config, configSha, context) {
  assert.equal(config.schema_version, 1);
  assert.equal(config.advisory, CVE);
  assert.equal(config.gem.name, 'ruby_llm');
  assert.equal(config.gem.version, '1.15.0');
  assert.equal(config.upstream.fix_commit, FIX);
  equal(config.files.map(f => [f.path, f.method, f.source_line]), [
    ['lib/ruby_llm/agent.rb', 'RubyLLM::Agent.prompt_agent_path', 324],
    ['lib/ruby_llm/tool.rb', 'RubyLLM::Tool#name', 68],
  ], 'exact upstream call sites');
  assert.equal(proof.schema_version, 1);
  assert.equal(proof.result, 'PASS');
  assert.equal(proof.advisory, CVE);
  assert.equal(proof.public_revision, context.source_commit);
  assert.equal(proof.patch_config_sha256, hash(configSha));
  assert.equal(proof.upstream_fix_commit, FIX);
  equal(proof.gem, { name: 'ruby_llm', version: '1.15.0', installed_spec_count: 1,
    gem_root: GEM_ROOT, spec_path: SPEC_PATH }, 'unique exact installed gem');
  equal(proof.ruby, { version: '3.4.4', platform: 'x86_64-linux-musl' }, 'actual target interpreter');
  equal(proof.files, config.files.map(f => ({ path: f.path, sha256: hash(f.patched_sha256),
    method: f.method, source_path: GEM_ROOT + '/' + f.path, source_line: f.source_line })),
    'loaded methods and complete source file hashes');
  equal(proof.unchanged_files, config.unchanged_files, 'entrypoint/version/license unchanged');
  equal(proof.ruby_source_inventory, { ...config.ruby_source_inventory.patched,
    vulnerable_acronym_occurrences: 0, fixed_boundary_occurrences: 2 }, 'complete installed Ruby inventory');
  assert.equal(proof.ruby_source_inventory.count, 130);
  equal(proof.agents, { loaded: true, version: '0.12.0',
    spec_path: '/gems/ruby/3.4.0/specifications/ai-agents-0.12.0.gemspec' }, 'Agents retained');
  const t = proof.tests;
  assert.equal(t.passed, true);
  assert.equal(t.ordinary_cases, 20020);
  assert.equal(t.ordinary_method_comparisons, 40040);
  assert.equal(t.official_examples, 4);
  assert.equal(t.tool_suffix_examples, 4);
  assert.equal(t.agents_constructor, true);
  equal(t.negative_controls, { wrong_source_hash: true, wrong_catalog_hash: true });
  assert.equal(t.adversarial.length, 100000);
  assert.equal(t.adversarial.timeout_seconds, 2);
  for (const key of ['tool_seconds', 'agent_seconds']) {
    assert.ok(Number.isFinite(t.adversarial[key]) && t.adversarial[key] >= 0 && t.adversarial[key] < 2);
  }
}

export function validateBinding(sbom, context, imageInspect) {
  assert.equal(context.schema_version, 1);
  assert.equal(context.image, IMAGE);
  digest(context.image_digest); hash(context.control_sha256);
  assert.match(context.source_commit, /^[0-9a-f]{40}$/);
  assert.equal(context.trivy_image, TRIVY);
  assert.equal(context.source_ref, 'refs/heads/main');
  const image = one(array(imageInspect), 'one docker image');
  assert.equal(image.Os, 'linux'); assert.equal(image.Architecture, 'amd64');
  assert.ok(array(image.RepoDigests).includes(IMAGE + '@' + context.image_digest));
  assert.equal(image.Config.Labels['jp.toybaco.gate.control-sha256'], context.control_sha256);
  assert.equal(image.Config.Labels['org.opencontainers.image.revision'], 'b354a9550e1fb59fa537a9c384232cb076213e72');
  assert.equal(sbom.spdxVersion, 'SPDX-2.3');
  assert.equal(sbom.SPDXID, 'SPDXRef-DOCUMENT');
  const packages = array(sbom.packages), relationships = array(sbom.relationships);
  const ids = packages.map(p => p.SPDXID);
  assert.equal(new Set(ids).size, ids.length, 'no duplicate SPDX identities');
  const rootId = one(relationships.filter(r => r.spdxElementId === sbom.SPDXID &&
    r.relationshipType === 'DESCRIBES'), 'unique described image').relatedSpdxElement;
  const root = one(packages.filter(p => p.SPDXID === rootId), 'described image exists');
  assert.equal(root.name, IMAGE); assert.equal(root.primaryPackagePurpose, 'CONTAINER');
  assert.equal(root.versionInfo, context.image_digest);
  equal(root.checksums, [{ algorithm: 'SHA256', checksumValue: context.image_digest.slice(7) }]);
  const rootPurl = purl(root);
  assert.ok(typeof rootPurl === 'string' && rootPurl.startsWith('pkg:oci/'));
  const match = /^pkg:oci\/(.+)@([^?#]+)\?([^#]+)$/.exec(rootPurl);
  assert.ok(match, 'versioned image purl with architecture');
  assert.equal(decodeURIComponent(match[1]), IMAGE);
  assert.equal(decodeURIComponent(match[2]), context.image_digest);
  // Pinned Syft can leave this metadata empty; actual image OS/CPU is verified above.
  assert.match(match[3], /^arch=(?:amd64)?$/, 'one architecture qualifier: unknown or amd64');
  const ruby = one(packages.filter(p => p.name === 'ruby_llm' ||
    (p.externalRefs || []).some(r => r.referenceType === 'purl' && /^pkg:gem\/ruby_llm(?:@|$)/.test(r.referenceLocator))),
    'unique ruby_llm SBOM occurrence');
  assert.equal(ruby.name, 'ruby_llm'); assert.equal(ruby.versionInfo, '1.15.0');
  assert.equal(purl(ruby), GEM_PURL);
  const graph = new Map();
  for (const r of relationships) {
    if (!['CONTAINS', 'DEPENDS_ON'].includes(r.relationshipType)) continue;
    if (!ids.includes(r.spdxElementId) || !ids.includes(r.relatedSpdxElement)) continue;
    if (!graph.has(r.spdxElementId)) graph.set(r.spdxElementId, []);
    graph.get(r.spdxElementId).push(r.relatedSpdxElement);
  }
  const reachable = new Set(), queue = [rootId];
  while (queue.length) {
    const id = queue.pop(); if (reachable.has(id)) continue;
    reachable.add(id); queue.push(...(graph.get(id) || []));
  }
  assert.ok(reachable.has(ruby.SPDXID), 'image-to-gem relationship is required');
  return { root_purl: rootPurl, root_spdx_id: rootId, gem_purl: GEM_PURL, gem_spdx_id: ruby.SPDXID };
}

export function validateDatabase(db, context) {
  hash(db.database_sha256); hash(db.metadata_sha256);
  assert.equal(db.metadata.Version, 2);
  const start = timestamp(context.db_download_started_at), now = timestamp(context.issued_at);
  const downloaded = timestamp(db.metadata.DownloadedAt), updated = timestamp(db.metadata.UpdatedAt);
  assert.ok(start <= now && now - start < 3600000, 'one fresh publication DB download');
  assert.ok(downloaded >= start - 120000 && downloaded <= now + 120000, 'DB downloaded in this run');
  assert.ok(updated <= now + 120000 && now - updated <= 48 * 3600000, 'DB update within 48 hours');
  assert.ok(timestamp(db.metadata.NextUpdate) > updated);
}

export function validateRawReport(report, exitStatus) {
  assert.equal(exitStatus, 1, 'raw scanner must have the one expected HIGH and exit 1');
  assert.equal(report.SchemaVersion, 2);
  assert.equal(report.Metadata.OS.Family, 'alpine');
  assert.equal(report.Metadata.OS.Name, '3.21.3');
  const results = array(report.Results);
  for (const cls of ['os-pkgs', 'lang-pkgs']) {
    assert.ok(results.some(r => r.Class === cls && Array.isArray(r.Packages) && r.Packages.length > 0),
      'complete OS and language inventory');
  }
  assert.equal(results.flatMap(r => r.ExperimentalModifiedFindings || []).length, 0, 'no prefiltered findings');
  const rows = results.flatMap(r => (r.Vulnerabilities || []).map(f => ({ result: r, finding: f })));
  const { result, finding } = one(rows, 'exactly one raw HIGH/CRITICAL finding');
  assert.equal(result.Class, 'lang-pkgs');
  assert.equal(finding.VulnerabilityID, CVE); assert.equal(finding.Severity, 'HIGH');
  assert.equal(finding.PkgName, 'ruby_llm'); assert.equal(finding.InstalledVersion, '1.15.0');
  assert.equal(finding.FixedVersion, '>= 2.0.0.rc1');
  assert.equal(finding.PkgIdentifier?.PURL, GEM_PURL);
  // Syft's no-file-metadata SPDX can omit PkgPath. If present it must be the verified installed spec.
  assert.ok(finding.PkgPath === undefined || finding.PkgPath === '' ||
    finding.PkgPath.replace(/^\//, '') === SPEC_PATH.slice(1), 'unexpected affected package path');
  const instances = results.flatMap(r => (r.Packages || []).filter(p => p.Name === 'ruby_llm'));
  const pkg = one(instances, 'one scanned ruby_llm instance');
  assert.equal(pkg.Version, '1.15.0'); assert.equal(pkg.Identifier?.PURL, GEM_PURL);
  assert.ok(pkg.Identifier.UID && pkg.Identifier.UID === finding.PkgIdentifier.UID, 'finding refers to inventoried gem');
  if (pkg.FilePath) assert.equal(pkg.FilePath.replace(/^\//, ''), SPEC_PATH.slice(1));
  return { target: result.Target, type: result.Type, finding };
}

export function makeVex(binding, context, preparedSha) {
  return { '@context': VEX_TYPE,
    '@id': 'https://toybaco.jp/security/vex/' + context.image_digest.slice(7) + '/' + CVE,
    author: 'https://github.com/Cyber-relations', role: 'Product Security',
    timestamp: context.issued_at, version: 1, statements: [{
      vulnerability: { name: CVE },
      products: [{ '@id': binding.root_purl,
        hashes: { 'sha-256': context.image_digest.slice(7) },
        subcomponents: [{ '@id': GEM_PURL }] }],
      status: 'fixed',
      status_notes: 'Official algorithm backport ' + FIX + '; exact-image proof SHA256 ' + hash(preparedSha) +
        '. ruby_llm remains 1.15.0; raw scanner still reports the version-based finding.',
    }] };
}
export function validateVex(vex, binding, context, preparedSha) {
  equal(vex, makeVex(binding, context, preparedSha), 'only generated exact-artifact fixed VEX accepted');
}

function regular(path, limit = 16777216) {
  const stat = lstatSync(path); assert.ok(stat.isFile() && !stat.isSymbolicLink());
  assert.ok(stat.size > 0 && stat.size <= limit);
  return readFileSync(path);
}
function json(path) { return JSON.parse(regular(path)); }
function writeExclusive(path, value) {
  const bytes = JSON.stringify(value, null, 2) + '\n';
  assert.ok(Buffer.byteLength(bytes) <= 16777216);
  writeFileSync(path, bytes, { flag: 'wx', mode: 0o600 });
}
export function snapshotDatabase(directory) {
  return { database_sha256: sha(regular(join(directory, 'db', 'trivy.db'), 1073741824)),
    metadata_sha256: sha(regular(join(directory, 'db', 'metadata.json'))),
    metadata: json(join(directory, 'db', 'metadata.json')) };
}

export function evaluate(input) {
  const { config, configSha, context, imageInspect, proof, sbom, raw, rawExit, before, after, hashes } = input;
  validateProof(proof, config, configSha, context);
  const binding = validateBinding(sbom, context, imageInspect);
  validateDatabase(before, context);
  equal(before, after, 'frozen database unchanged through raw scan');
  const finding = validateRawReport(raw, rawExit);
  for (const value of Object.values(hashes)) hash(value);
  const vex = makeVex(binding, context, hashes.installed_proof);
  const classification = {
    schema_version: 1, result: 'PASS',
    policy: 'toybaco-ruby-llm-1.15.0-source-backport-v1',
    evaluator: 'scripts/verify-chatwoot-ruby-llm-classification.mjs',
    evaluation_kind: 'independent_source_backport_classification',
    scanner_vex_filtering: false,
    image: { name: IMAGE, digest: context.image_digest },
    source: { commit: context.source_commit, ref: context.source_ref, control_sha256: context.control_sha256 },
    timestamp: context.issued_at,
    counts: { raw_critical: 0, raw_high: 1, source_verified_fixed: 1, unresolved_critical: 0, unresolved_high: 0 },
    bindings: { ...binding, ...hashes, patch_config: configSha },
    scanner: { image: TRIVY, exit_status: rawExit, arguments: [
      '--config', '/dev/null', 'sbom', '--scanners', 'vuln', '--pkg-types', 'os,library',
      '--distro', 'alpine/3.21.3', '--severity', 'CRITICAL,HIGH', '--ignore-unfixed=false',
      '--exit-code', '1', '--list-all-pkgs', '--skip-db-update', '--skip-java-db-update', '--offline-scan',
    ], database: before },
    installed_source_proof: proof,
    evaluated_findings: [{ status: 'fixed', basis: 'verified_official_algorithm_backport',
      upstream_fix_commit: FIX, ...finding }],
    unresolved_findings: [],
    raw_report: raw,
    openvex: vex,
  };
  return { vex, classification };
}

export function verifyAttestations(rows, predicateType, expected, context) {
  assert.ok(array(rows).length > 0, 'verified attestation is missing');
  for (const row of rows) {
    const result = row.verificationResult;
    assert.ok(result && result.signature?.certificate && array(result.verifiedTimestamps).length > 0);
    const statement = result.statement;
    assert.equal(statement._type, 'https://in-toto.io/Statement/v1');
    assert.equal(statement.predicateType, predicateType);
    equal(statement.subject, [{ name: IMAGE, digest: { sha256: context.image_digest.slice(7) } }]);
    equal(statement.predicate, expected, 'verified predicate must contain the exact reviewed evidence');
  }
}

function main() {
  const [mode, directory, configPath] = process.argv.slice(2);
  assert.ok(directory && configPath);
  const dir = resolve(directory), configBytes = regular(resolve(configPath)), config = JSON.parse(configBytes);
  if (mode === 'snapshot-before' || mode === 'snapshot-after') {
    writeExclusive(join(dir, mode === 'snapshot-before' ? 'db-before.json' : 'db-after.json'), snapshotDatabase(dir));
    return;
  }
  const read = name => json(join(dir, name));
  const context = read('context.json');
  const recompute = () => {
    const names = { sbom: 'sbom.spdx.json', raw_report: 'raw-report.json',
      installed_proof: 'installed-proof.json', image_inspect: 'image-inspect.json',
      evaluator: null };
    const hashes = Object.fromEntries(Object.entries(names).map(([key, name]) => [
      key, sha(regular(name ? join(dir, name) : process.argv[1])),
    ]));
    const before = read('db-before.json'), after = read('db-after.json');
    equal(snapshotDatabase(dir), after, 'current frozen DB equals final snapshot');
    return evaluate({ config, configSha: sha(configBytes), context,
      imageInspect: read('image-inspect.json'), proof: read('installed-proof.json'),
      sbom: read('sbom.spdx.json'), raw: read('raw-report.json'),
      rawExit: Number(regular(join(dir, 'raw-exit.txt')).toString().trim()),
      before, after, hashes });
  };
  if (mode === 'evaluate') {
    const result = recompute();
    writeExclusive(join(dir, 'openvex.json'), result.vex);
    writeExclusive(join(dir, 'source-backport-classification.json'), result.classification);
    console.log('TOYBACO_CHATWOOT_BACKPORT_CLASSIFICATION=PASS RAW_CRITICAL=0 RAW_HIGH=1 SOURCE_VERIFIED_FIXED=1 UNRESOLVED_CRITICAL=0 UNRESOLVED_HIGH=0');
    return;
  }
  if (mode === 'verify-attestations') {
    const classification = read('source-backport-classification.json'), vex = read('openvex.json');
    const expected = recompute();
    equal(classification, expected.classification, 'classification inputs or evidence changed');
    equal(vex, expected.vex, 'VEX inputs or evidence changed');
    validateVex(vex, classification.bindings, context, classification.bindings.installed_proof);
    equal(classification.openvex, vex);
    verifyAttestations(read('verified-openvex.json'), VEX_TYPE, vex, context);
    verifyAttestations(read('verified-source-backport.json'), PROOF_TYPE, classification, context);
    console.log('TOYBACO_CHATWOOT_BACKPORT_ATTESTATIONS=VERIFIED');
    return;
  }
  throw new Error('unknown classification mode');
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try { main(); } catch (error) { console.error('Chatwoot exact-artifact classification: FAIL: ' + error.message); process.exitCode = 1; }
}
