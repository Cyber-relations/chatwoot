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
const { IMAGE, CVES, FIXES, GEM_PURL, TRIVY, VEX_TYPE, PROOF_TYPE, ADVISORIES, RAILS_ADVISORIES, RAILS_FIXES, RAILS_GEMS,
  RAILS_FIXED_RANGE, railsPurl, evaluate, validateVex, verifyAttestations } = policy;
const configBytes = readFileSync(join(root, 'config/chatwoot-ruby-llm-backport.json'));
const config = JSON.parse(configBytes);
const railsConfigBytes = readFileSync(join(root, 'config/chatwoot-rails-backport.json'));
const railsConfig = JSON.parse(railsConfigBytes);
const ALL_FIXES = { ...FIXES, ...RAILS_FIXES };
const railsRoot = gem => '/gems/ruby/3.4.0/gems/' + gem + '-7.2.3.2';
const railsSpec = gem => '/gems/ruby/3.4.0/specifications/' + gem + '-7.2.3.2.gemspec';
const RAILS_GEM_OF = Object.fromEntries(railsConfig.advisories.map(a => [a.id, a.gem]));
// The marker counts and test sections tests/verify_chatwoot_rails_backport.rb prints on the patched installed gems.
const RAILS_MARKERS = {
  activesupport: { vulnerable_const_regexp_occurrences: 0, fixed_literal_constant_match_occurrences: 1 },
  actionpack: { vulnerable_each_key_delegation_occurrences: 0, fixed_each_key_returns_self_occurrences: 1 },
  activestorage: { fixed_securable_mini_magick_occurrences: 2, fixed_policy_application_occurrences: 2,
    vulnerable_tempfile_extension_occurrences: 0, fixed_tempfile_extension_occurrences: 1 },
};
const railsTests = () => ({
  'GHSA-8474-xrp6-wh69': { official_examples: 3, vulnerable_examples_rejected: 2, ordinary_cases: 140091, ordinary_constants: 8,
    adversarial_regexp_names: 5 },
  'GHSA-wm3x-v3qw-4jh3': { official_examples: 3, vulnerable_examples_rejected: 1, ordinary_examples: 4, ordinary_cases: 1000 },
  'GHSA-f3w6-w445-fwh9': { official_examples: 5, denied_coders: 31, variant_processor: 'vips', previewers: 0,
    mini_magick_version: '4.12.0', mini_magick_unsecurable: true, policy_applied: false, imagemagick_processes: 0 },
  'GHSA-v924-7rp8-4mxh': { official_examples: 6, vulnerable_examples_rejected: 4, ordinary_open: 30, ordinary_extensions_kept: 25,
    analyzed: 3, variants: 3, custom_tmpdir: true },
  passed: true,
  negative_controls: { wrong_source_hash: true, wrong_catalog_hash: true, database_refused: true, imagemagick_spawn_refused: true },
});
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
  // The shape the in-image proof (tests/verify_chatwoot_ruby_llm_backport.rb) prints, with fixture timings.
  const proof = { schema_version: 2, result: 'PASS', advisories: [...CVES], public_revision: context.source_commit,
    patch_config_sha256: hash(configBytes), upstream_fix_commits: { ...FIXES },
    gem: { name: 'ruby_llm', version: '1.15.0', installed_spec_count: 1, gem_root: gemRoot, spec_path: specPath },
    ruby: { version: '3.4.4', platform: 'x86_64-linux-musl' },
    files: config.advisories.flatMap(a => a.files.map(f => ({ advisory: a.id, path: f.path, sha256: f.patched_sha256,
      method: f.method, source_path: gemRoot + '/' + f.path, source_line: f.source_line }))),
    unchanged_files: clone(config.unchanged_files),
    ruby_source_inventory: { ...config.ruby_source_inventory.patched,
      vulnerable_acronym_occurrences: 0, fixed_boundary_occurrences: 2,
      vulnerable_think_tag_occurrences: 0, fixed_think_passthrough_occurrences: 1,
      vulnerable_voxtral_occurrences: 0, fixed_voxtral_occurrences: 1 },
    agents: { loaded: true, version: '0.12.0', spec_path: '/gems/ruby/3.4.0/specifications/ai-agents-0.12.0.gemspec' },
    tests: { passed: true, agents_constructor: true,
      negative_controls: { wrong_source_hash: true, wrong_catalog_hash: true },
      'CVE-2026-67987': { ordinary_cases: 5000, stream_cases: 2000, official_examples: 4, unchanged_shapes: 3,
        adversarial: { unclosed_tags: 50000, timeout_seconds: 2, scanner_seconds: 0.001, accumulator_seconds: 0.001 } },
      'CVE-2026-67989': { ordinary_cases: 20072, model_catalog_ids: 72, official_examples: 8,
        adversarial: { voxtral_repeats: 50000, timeout_seconds: 2, capabilities_seconds: 0.01 } },
      'CVE-2026-67991': { ordinary_cases: 20020, ordinary_method_comparisons: 40040,
        official_examples: 4, tool_suffix_examples: 4,
        adversarial: { length: 100000, timeout_seconds: 2, tool_seconds: 0.08, agent_seconds: 0.04 } } } };
  // The shape the in-image Rails proof (tests/verify_chatwoot_rails_backport.rb) prints.
  const railsProof = { schema_version: 1, result: 'PASS', advisories: [...RAILS_ADVISORIES], public_revision: context.source_commit,
    patch_config_sha256: hash(railsConfigBytes), upstream_fix_commits: { ...RAILS_FIXES },
    gems: RAILS_GEMS.map(gem => ({ name: gem, version: '7.2.3.2', installed_spec_count: 1, gem_root: railsRoot(gem),
      spec_path: railsSpec(gem) })),
    ruby: { version: '3.4.4', platform: 'x86_64-linux-musl' },
    files: railsConfig.advisories.flatMap(a => a.files.map(f => ({ advisory: a.id, gem: a.gem, path: f.path,
      sha256: f.patched_sha256, method: f.method, source_path: railsRoot(a.gem) + '/' + f.path, source_line: f.source_line }))),
    unchanged_files: clone(railsConfig.unchanged_files),
    source_inventory: Object.fromEntries(RAILS_GEMS.map(gem => [gem, { ...railsConfig.source_inventory[gem].patched,
      ...RAILS_MARKERS[gem] }])),
    tests: railsTests() };
  const sbom = { spdxVersion: 'SPDX-2.3', SPDXID: 'SPDXRef-DOCUMENT',
    packages: [
      { SPDXID: 'SPDXRef-image', name: IMAGE, versionInfo: imageDigest, primaryPackagePurpose: 'CONTAINER',
        checksums: [{ algorithm: 'SHA256', checksumValue: hex }],
        externalRefs: ref('pkg:oci/' + IMAGE + '@sha256%3A' + hex + '?arch=amd64') },
      { SPDXID: 'SPDXRef-ruby', name: 'ruby_llm', versionInfo: '1.15.0', externalRefs: ref(GEM_PURL) },
      { SPDXID: 'SPDXRef-alpine', name: 'alpine-baselayout', versionInfo: '3.7.0-r0',
        externalRefs: ref('pkg:apk/alpine/alpine-baselayout@3.7.0-r0?arch=x86_64&distro=alpine-3.22.0') },
      ...RAILS_GEMS.map(gem => ({ SPDXID: 'SPDXRef-' + gem, name: gem, versionInfo: '7.2.3.2', externalRefs: ref(railsPurl(gem)) })),
    ], relationships: [
      { spdxElementId: 'SPDXRef-DOCUMENT', relationshipType: 'DESCRIBES', relatedSpdxElement: 'SPDXRef-image' },
      { spdxElementId: 'SPDXRef-image', relationshipType: 'CONTAINS', relatedSpdxElement: 'SPDXRef-ruby' },
      ...RAILS_GEMS.map(gem => ({ spdxElementId: 'SPDXRef-image', relationshipType: 'CONTAINS', relatedSpdxElement: 'SPDXRef-' + gem })),
    ] };
  const finding = id => ({ VulnerabilityID: id, Severity: 'HIGH', PkgName: 'ruby_llm', InstalledVersion: '1.15.0',
    FixedVersion: '>= 2.0.0.rc1', PkgPath: specPath.slice(1), PkgIdentifier: { PURL: GEM_PURL, UID: 'gem-id' } });
  // As pinned Trivy 0.67.2 reported them on the 2026-11-04 DB (advisory watch issue #611): GHSA ids, one CRITICAL.
  const railsFinding = id => ({ VulnerabilityID: id, Severity: id === 'GHSA-f3w6-w445-fwh9' ? 'CRITICAL' : 'HIGH',
    PkgName: RAILS_GEM_OF[id], InstalledVersion: '7.2.3.2', FixedVersion: RAILS_FIXED_RANGE,
    PkgPath: railsSpec(RAILS_GEM_OF[id]).slice(1), PkgIdentifier: { PURL: railsPurl(RAILS_GEM_OF[id]), UID: RAILS_GEM_OF[id] + '-id' } });
  const raw = { SchemaVersion: 2, ArtifactType: 'spdx', Metadata: { OS: { Family: 'alpine', Name: '3.22.0' } },
    Results: [
      { Target: 'alpine', Type: 'alpine', Class: 'os-pkgs', Packages: [{ Name: 'openjpeg', Version: '2.5.4-r1' }] },
      { Target: 'Ruby', Type: 'gemspec', Class: 'lang-pkgs',
        Packages: [{ Name: 'ruby_llm', Version: '1.15.0', Identifier: { PURL: GEM_PURL, UID: 'gem-id' } },
          ...RAILS_GEMS.map(gem => ({ Name: gem, Version: '7.2.3.2', Identifier: { PURL: railsPurl(gem), UID: gem + '-id' } }))],
        Vulnerabilities: [...CVES.map(finding), ...RAILS_ADVISORIES.map(railsFinding)] },
    ] };
  const before = { database_sha256: 'd'.repeat(64), metadata_sha256: 'e'.repeat(64),
    metadata: { Version: 2, DownloadedAt: '2026-09-17T07:00:05Z',
      UpdatedAt: '2026-09-17T06:10:00Z', NextUpdate: '2026-09-17T12:10:00Z' } };
  return { config: clone(config), configSha: hash(configBytes), railsConfig: clone(railsConfig),
    railsConfigSha: hash(railsConfigBytes), context, proof, railsProof, sbom, raw, rawExit: 1,
    before, after: clone(before), imageInspect: [{ Os: 'linux', Architecture: 'amd64',
      RepoDigests: [IMAGE + '@' + imageDigest], Config: { Labels: {
        'jp.toybaco.gate.control-sha256': context.control_sha256,
        'org.opencontainers.image.revision': '9f920b549c14491a4e587687a3eed5d21c6ccc7d' } } }],
    hashes: { sbom: '1'.repeat(64), raw_report: '2'.repeat(64), installed_proof: '3'.repeat(64),
      installed_rails_proof: '6'.repeat(64), image_inspect: '4'.repeat(64), evaluator: '5'.repeat(64) } };
}
const valid = fixture(), originalRaw = clone(valid.raw), result = evaluate(valid);
assert.deepEqual(valid.raw, originalRaw, 'classification must not mutate the raw scanner report');
assert.deepEqual(result.classification.raw_report, originalRaw);
assert.equal(result.classification.scanner_vex_filtering, false);
assert.equal(result.classification.evaluation_kind, 'independent_source_backport_classification');
assert.deepEqual(result.classification.counts, { raw_critical: 1, raw_high: 6, source_verified_fixed: 7,
  unresolved_critical: 0, unresolved_high: 0 });
assert.deepEqual(result.vex.statements.map(s => [s.vulnerability.name, s.status]), ADVISORIES.map(id => [id, 'fixed']));
assert.deepEqual(result.classification.evaluated_findings.map(f => [f.finding.VulnerabilityID, f.upstream_fix_commit]),
  ADVISORIES.map(id => [id, ALL_FIXES[id]]));
// The ruby_llm statements are unchanged; each Rails statement names its own gem and the Rails proof.
assert.deepEqual(result.vex.statements.map(s => s.products[0].subcomponents),
  [...CVES.map(() => [{ '@id': GEM_PURL }]), ...RAILS_ADVISORIES.map(id => [{ '@id': railsPurl(RAILS_GEM_OF[id]) }])]);
assert.ok(result.vex.statements.slice(0, 3).every(s => s.status_notes.includes(valid.hashes.installed_proof)));
assert.ok(result.vex.statements.slice(3).every(s => s.status_notes.includes(valid.hashes.installed_rails_proof)));
assert.deepEqual(result.classification.installed_rails_source_proof, valid.railsProof);
assert.deepEqual(Object.keys(result.classification.bindings.rails_gems), RAILS_GEMS);
// The scanner's finding order is not reviewed evidence; the classification is the same in any order.
const reordered = fixture(); reordered.raw.Results[1].Vulnerabilities.reverse();
assert.deepEqual(evaluate(reordered).classification.counts, result.classification.counts);
// Exact root purl shape observed from the pinned registry-digest Syft publisher.
const observedEmptyArch = fixture();
const emptyArchPurl = 'pkg:oci/' + IMAGE.replaceAll('/', '%2F') + '@sha256%3A' + hex + '?arch=';
observedEmptyArch.sbom.packages[0].externalRefs = ref(emptyArchPurl);
const emptyArchResult = evaluate(observedEmptyArch);
assert.equal(emptyArchResult.classification.bindings.root_purl, emptyArchPurl);
assert.ok(emptyArchResult.vex.statements.every(s => s.products[0]['@id'] === emptyArchPurl));
assert.deepEqual(emptyArchResult.classification.counts, result.classification.counts);
// The raw additions observed in publishers 43236553283 and 43378184002; these literals are independent of the evaluator's alias map.
const observedAliases = [
  ['CVE-2026-126080', 'GHSA-8474-xrp6-wh69', 'activesupport', '210ac22d446c8e2625b091e79256806b836eee20', 'HIGH'],
  ['CVE-2026-126186', 'GHSA-v924-7rp8-4mxh', 'activestorage', '8106938fb0a595f11006dd1497cd409e27d7d636', 'HIGH'],
  ['CVE-2026-126081', 'GHSA-wm3x-v3qw-4jh3', 'actionpack', '2fc8838300133931e19eed3ea6cee76a7e83f19c', 'HIGH'],
  ['CVE-2026-122006', 'GHSA-f3w6-w445-fwh9', 'activestorage', 'ea8c40121ce53a3d0255cd4eb6d13bfe3bc01776', 'CRITICAL'],
];
export function addObservedRailsAliases(report, aliases = observedAliases) {
  for (const [id, , gem, , severity] of aliases) report.Results[1].Vulnerabilities.push({
    VulnerabilityID: id, Severity: severity, PkgName: gem, InstalledVersion: '7.2.3.2', FixedVersion: '8.1.4.1, 8.0.5.2',
    PkgPath: railsSpec(gem).slice(1), PkgIdentifier: { PURL: railsPurl(gem), UID: gem + '-id' },
  });
}
for (let mask = 0; mask < 2 ** observedAliases.length; mask++) {
  const aliases = observedAliases.filter((_alias, index) => mask & (1 << index));
  const input = fixture(); addObservedRailsAliases(input.raw, aliases);
  input.raw.Results[1].Vulnerabilities.reverse();
  const original = clone(input.raw), output = evaluate(input), count = 7 + aliases.length;
  const criticalCount = 1 + aliases.filter(alias => alias[4] === 'CRITICAL').length;
  assert.deepEqual(output.classification.counts, { raw_critical: criticalCount, raw_high: count - criticalCount, source_verified_fixed: count,
    unresolved_critical: 0, unresolved_high: 0 });
  assert.deepEqual(input.raw, original); assert.deepEqual(output.classification.raw_report, original);
  assert.equal(output.classification.policy, 'toybaco-chatwoot-source-backport-v4');
  assert.equal(output.vex.statements.length, count, 'every raw ID gets its own digest-bound VEX statement');
  for (const [id, canonical, gem, fix] of aliases) {
    const row = output.classification.evaluated_findings.find(row => row.finding.VulnerabilityID === id);
    assert.equal(row.canonical_advisory, canonical); assert.equal(row.upstream_fix_commit, fix);
    const statement = output.vex.statements.find(statement => statement.vulnerability.name === id);
    assert.equal(statement.status, 'fixed');
    assert.deepEqual(statement.products[0].subcomponents, [{ '@id': railsPurl(gem) }]);
    assert.ok(statement.status_notes.includes(canonical)); assert.ok(statement.status_notes.includes(fix));
    assert.ok(statement.status_notes.includes(input.hashes.installed_rails_proof));
  }
  const ids = output.classification.evaluated_findings.map(row => row.finding.VulnerabilityID);
  const verify = vex => validateVex(vex, output.classification.bindings, input.context,
    input.hashes.installed_proof, input.hashes.installed_rails_proof, ids);
  verify(output.vex);
  const missing = clone(output.vex); missing.statements.pop(); assert.throws(() => verify(missing));
  const wrong = clone(output.vex); wrong.statements.at(-1).status_notes = 'unverified alias'; assert.throws(() => verify(wrong));
}
for (const alias of observedAliases) {
  const [id, canonical] = alias;
  for (const [label, mutate] of [
    ['duplicate alias', (x, row) => x.raw.Results[1].Vulnerabilities.push(clone(row))],
    ['unknown alias', (_x, row) => { row.VulnerabilityID = 'CVE-2026-999999'; }],
    ['wrong package', (_x, row) => { row.PkgName = 'actionview'; }],
    ['wrong version', (_x, row) => { row.InstalledVersion = '7.2.3.1'; }],
    ['wrong fixed range', (_x, row) => { row.FixedVersion = '>= 7.2.3.3'; }],
    ['wrong severity', (_x, row) => { row.Severity = row.Severity === 'CRITICAL' ? 'HIGH' : 'CRITICAL'; }],
    ['wrong purl', (_x, row) => { row.PkgIdentifier.PURL = 'pkg:gem/actionview@7.2.3.2'; }],
    ['wrong instance', (_x, row) => { row.PkgIdentifier.UID = 'other'; }],
    ['wrong path', (_x, row) => { row.PkgPath = '/other/spec.gemspec'; }],
    ['alias replaces canonical', x => { x.raw.Results[1].Vulnerabilities = x.raw.Results[1].Vulnerabilities.filter(row => row.VulnerabilityID !== canonical); }],
    ['alias without source proof', x => { x.railsProof.files.find(file => file.advisory === canonical).sha256 = '0'.repeat(64); }],
    ['alias hides unknown finding', x => { x.raw.Results[0].Vulnerabilities = [{ VulnerabilityID: 'CVE-2099-1', Severity: 'HIGH' }]; }],
  ]) {
    const input = fixture(); addObservedRailsAliases(input.raw);
    const row = input.raw.Results[1].Vulnerabilities.find(row => row.VulnerabilityID === id);
    mutate(input, row); assert.throws(() => evaluate(input), id + ': ' + label);
  }
}
console.log('Chatwoot Rails aliases: PASS (four observed aliases, all 16 subsets, 7..11 raw findings, VEX coverage, 48 negative cases)');
// One failed scan can have several new IDs; report all of them, including an unrelated dependency finding.
const unreviewed = fixture(); addObservedRailsAliases(unreviewed.raw);
unreviewed.raw.Results[1].Vulnerabilities.push(
  { VulnerabilityID: 'CVE-2026-126366', Severity: 'HIGH', PkgName: 'msgpack', InstalledVersion: '1.8.3' },
  { VulnerabilityID: 'CVE-2099-1', Severity: 'CRITICAL' });
assert.throws(() => evaluate(unreviewed), error => {
  assert.match(error.message, /unreviewed advisory IDs/);
  assert.deepEqual(error.actual, ['CVE-2026-126366', 'CVE-2099-1']);
  return true;
});
const negatives = [
  ['missing proof', x => { x.proof = null; }],
  ['wrong source commit', x => { x.proof.public_revision = '0'.repeat(40); }],
  ['wrong config digest', x => { x.proof.patch_config_sha256 = '0'.repeat(64); }],
  ['wrong full source hash', x => { x.proof.files[0].sha256 = '0'.repeat(64); }],
  ['CVE-2026-67987 patched hash reverted to the official source', x => { x.proof.files[0].sha256 = x.config.advisories[0].files[0].original_sha256; }],
  ['CVE-2026-67989 patched hash reverted to the official source', x => { x.proof.files[2].sha256 = x.config.advisories[1].files[0].original_sha256; }],
  ['reviewed CVE-2026-67987 hash reverted to the official source', x => {
    const file = x.config.advisories[0].files[0];
    file.patched_sha256 = file.original_sha256; x.proof.files[0].sha256 = file.original_sha256;
  }],
  ['patched accumulator altered', x => { x.proof.files[1].sha256 = '0'.repeat(64); }],
  ['moved think-tag method', x => { x.proof.files[0].source_line++; }],
  ['moved Mistral capability method', x => { x.proof.files[2].source_path = '/tmp/capabilities.rb'; }],
  ['proof without one advisory', x => { x.proof.advisories.pop(); }],
  ['proof missing a patched file', x => { x.proof.files.splice(1, 1); }],
  ['proof with a misattributed file', x => { x.proof.files[2].advisory = 'CVE-2026-67987'; }],
  ['wrong upstream fix', x => { x.proof.upstream_fix_commits['CVE-2026-67989'] = '0'.repeat(40); }],
  ['config without one advisory', x => { x.config.advisories.splice(1, 1); }],
  ['config with a fourth advisory', x => { x.config.advisories.push({ ...clone(x.config.advisories[0]), id: 'CVE-2099-4' }); }],
  ['config with a moved call site', x => { x.config.advisories[1].files[0].source_line = 97; }],
  ['remaining think-tag scanner', x => { x.proof.ruby_source_inventory.vulnerable_think_tag_occurrences = 1; }],
  ['remaining voxtral regex', x => { x.proof.ruby_source_inventory.vulnerable_voxtral_occurrences = 1; }],
  ['missing voxtral walk', x => { x.proof.ruby_source_inventory.fixed_voxtral_occurrences = 0; }],
  ['missing think-tag pass-through', x => { x.proof.ruby_source_inventory.fixed_think_passthrough_occurrences = 0; }],
  ['missing think-tag equivalence', x => { x.proof.tests['CVE-2026-67987'].ordinary_cases = 0; }],
  ['think-tag timing regression', x => { x.proof.tests['CVE-2026-67987'].adversarial.scanner_seconds = 2; }],
  ['Mistral timing regression', x => { x.proof.tests['CVE-2026-67989'].adversarial.capabilities_seconds = 2; }],
  ['missing Mistral catalog equivalence', x => { x.proof.tests['CVE-2026-67989'].model_catalog_ids = 0; }],
  ['missing advisory test section', x => { delete x.proof.tests['CVE-2026-67989']; }],
  ['moved loaded method', x => { x.proof.files[0].source_path = '/tmp/agent.rb'; }],
  ['wrong loaded method line', x => { x.proof.files[4].source_line++; }],
  ['wrong unchanged entrypoint hash', x => { x.proof.unchanged_files[0].sha256 = '0'.repeat(64); }],
  ['duplicate installed spec', x => { x.proof.gem.installed_spec_count = 2; }],
  ['wrong spec path', x => { x.proof.gem.spec_path = '/other/ruby_llm.gemspec'; }],
  ['wrong runtime', x => { x.proof.ruby.version = '2.6.10'; }],
  ['unverified Agents', x => { x.proof.agents.loaded = false; }],
  ['missing equivalence tests', x => { x.proof.tests['CVE-2026-67991'].ordinary_method_comparisons = 0; }],
  ['timing regression', x => { x.proof.tests['CVE-2026-67991'].adversarial.tool_seconds = 2; }],
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
  ['raw HIGH 2: CVE-2026-67987 missing', x => { x.raw.Results[1].Vulnerabilities.splice(0, 1); }],
  ['raw HIGH 2: CVE-2026-67989 missing', x => { x.raw.Results[1].Vulnerabilities.splice(1, 1); }],
  ['raw HIGH 2: CVE-2026-67991 missing', x => { x.raw.Results[1].Vulnerabilities.splice(2, 1); }],
  ['raw HIGH 4: fourth ruby_llm finding', x => { x.raw.Results[1].Vulnerabilities.push({ ...clone(x.raw.Results[1].Vulnerabilities[0]), VulnerabilityID: 'CVE-2099-4' }); }],
  ['finding on another package', x => { x.raw.Results[1].Vulnerabilities[1].PkgName = 'ruby_llm-schema'; }],
  ['finding on another version', x => { x.raw.Results[1].Vulnerabilities[0].InstalledVersion = '1.14.0'; }],
  ['finding with another fixed range', x => { x.raw.Results[1].Vulnerabilities[2].FixedVersion = '>= 1.15.1'; }],
  ['finding with another severity', x => { x.raw.Results[1].Vulnerabilities[1].Severity = 'CRITICAL'; }],
  ['finding in the OS result', x => { x.raw.Results[0].Vulnerabilities = x.raw.Results[1].Vulnerabilities.splice(0, 1); }],
  ['scanner error', x => { x.rawExit = 2; }],
  ['wrong scanner exit', x => { x.rawExit = 0; }],
  ['lost OS inventory', x => { x.raw.Results.shift(); }],
  // The scanned distro is the shipped runtime's pinned Alpine 3.22 release, never the retired 3.21 base or another point release.
  ['raw scan of the retired Alpine 3.21 distro', x => { x.raw.Metadata.OS.Name = '3.21.3'; }],
  ['raw scan of another Alpine 3.22 point release', x => { x.raw.Metadata.OS.Name = '3.22.6'; }],
  ['lost language inventory', x => { x.raw.Results[1].Packages = []; }],
  ['additional unfixed HIGH', x => { x.raw.Results[0].Vulnerabilities = [{ VulnerabilityID: 'CVE-2099-1', Severity: 'HIGH', FixedVersion: '' }]; }],
  ['additional CRITICAL', x => { x.raw.Results[0].Vulnerabilities = [{ VulnerabilityID: 'CVE-2099-2', Severity: 'CRITICAL' }]; }],
  ['duplicate raw finding', x => { x.raw.Results[1].Vulnerabilities.push(clone(x.raw.Results[1].Vulnerabilities[0])); }],
  ['duplicate replaces a reviewed finding', x => { x.raw.Results[1].Vulnerabilities[1] = clone(x.raw.Results[1].Vulnerabilities[0]); }],
  ['new CVE on same gem', x => { x.raw.Results[1].Vulnerabilities[0].VulnerabilityID = 'CVE-2099-3'; }],
  ['wrong affected version', x => { x.raw.Results[1].Vulnerabilities[0].InstalledVersion = '1.16.0'; }],
  ['wrong affected package path', x => { x.raw.Results[1].Vulnerabilities[0].PkgPath = '/other/ruby_llm.gemspec'; }],
  ['wrong affected purl', x => { x.raw.Results[1].Vulnerabilities[0].PkgIdentifier.PURL = 'pkg:gem/ruby_llm'; }],
  ['ambiguous affected UID', x => { x.raw.Results[1].Vulnerabilities[0].PkgIdentifier.UID = 'other'; }],
  ['duplicate raw package', x => { x.raw.Results[1].Packages.push(clone(x.raw.Results[1].Packages[0])); }],
  ['prefiltered finding', x => { x.raw.Results[1].ExperimentalModifiedFindings = [{ Status: 'fixed' }]; }],
  // Rails 7.2.3.2 (config/chatwoot-rails-backport.json): the proof, the catalog, the SBOM and the raw findings.
  ['missing Rails proof', x => { x.railsProof = null; }],
  ['Rails proof from another source commit', x => { x.railsProof.public_revision = '0'.repeat(40); }],
  ['wrong Rails config digest', x => { x.railsProof.patch_config_sha256 = '0'.repeat(64); }],
  ['Rails config digest from the ruby_llm catalog', x => { x.railsProof.patch_config_sha256 = x.configSha; }],
  ...RAILS_ADVISORIES.map(id => [`${id} patched hash reverted to the official source`, x => {
    const index = x.railsProof.files.findIndex(f => f.advisory === id && x.railsConfig.advisories.find(a => a.id === id)
      .files.find(c => c.path === f.path).original_sha256 !== null);
    const file = x.railsConfig.advisories.find(a => a.id === id).files.find(c => c.path === x.railsProof.files[index].path);
    x.railsProof.files[index].sha256 = file.original_sha256;
  }]),
  ['reviewed Rails hash reverted to the official source', x => {
    const file = x.railsConfig.advisories[0].files[0];
    file.patched_sha256 = file.original_sha256; x.railsProof.files[0].sha256 = file.original_sha256;
  }],
  ['shipped ImageMagick policy missing from the proof', x => { x.railsProof.files.splice(5, 1); }],
  ['shipped ImageMagick policy declared as an existing file', x => {
    x.railsConfig.advisories[2].files[3].original_sha256 = 'f'.repeat(64);
  }],
  ['Rails file hash changed', x => { x.railsProof.files[6].sha256 = '0'.repeat(64); }],
  ['moved safe_constantize method', x => { x.railsProof.files[0].source_line++; }],
  ['moved each_key method', x => { x.railsProof.files[1].source_path = '/tmp/strong_parameters.rb'; }],
  ['policy outside the gem', x => { x.railsProof.files[5].source_path = '/etc/ImageMagick-7/policy.xml'; }],
  ['Rails proof without one advisory', x => { x.railsProof.advisories.pop(); }],
  ['Rails proof missing a patched file', x => { x.railsProof.files.splice(2, 1); }],
  ['Rails proof with a misattributed file', x => { x.railsProof.files[6].advisory = 'GHSA-f3w6-w445-fwh9'; }],
  ['Rails file in another gem', x => { x.railsProof.files[1].gem = 'actionview'; }],
  ['wrong Rails upstream fix', x => { x.railsProof.upstream_fix_commits['GHSA-v924-7rp8-4mxh'] = RAILS_FIXES['GHSA-f3w6-w445-fwh9']; }],
  ['Rails config without one advisory', x => { x.railsConfig.advisories.splice(1, 1); }],
  ['Rails config with a fifth advisory', x => { x.railsConfig.advisories.push({ ...clone(x.railsConfig.advisories[3]), id: 'GHSA-3f4q-8x5m-76v8' }); }],
  ['Rails config with reordered advisories', x => { x.railsConfig.advisories.reverse(); }],
  ['Rails config with another severity', x => { x.railsConfig.advisories[2].severity = 'HIGH'; }],
  ['Rails config with another gem', x => { x.railsConfig.advisories[0].gem = 'activestorage'; }],
  ['Rails config with another version', x => { x.railsConfig.rails_version = '7.2.3.1'; }],
  ['Rails config with a moved call site', x => { x.railsConfig.advisories[3].files[0].source_line = 358; }],
  ['duplicate installed Rails spec', x => { x.railsProof.gems[0].installed_spec_count = 2; }],
  ['other installed Rails version', x => { x.railsProof.gems[2].version = '7.2.3.1'; }],
  ['wrong Rails spec path', x => { x.railsProof.gems[1].spec_path = '/usr/local/bundle/specifications/actionpack-7.2.3.2.gemspec'; }],
  ['Rails proof on another runtime', x => { x.railsProof.ruby.platform = 'aarch64-linux-musl'; }],
  ['changed Rails entrypoint hash', x => { x.railsProof.unchanged_files[0].sha256 = '0'.repeat(64); }],
  ['changed Rails source inventory hash', x => { x.railsProof.source_inventory.actionpack.sha256 = '0'.repeat(64); }],
  ['unexpected Rails source file', x => { x.railsProof.source_inventory.activestorage.count++; }],
  ['remaining safe_constantize regexp', x => { x.railsProof.source_inventory.activesupport.vulnerable_const_regexp_occurrences = 1; }],
  ['remaining each_key delegation', x => { x.railsProof.source_inventory.actionpack.vulnerable_each_key_delegation_occurrences = 1; }],
  ['missing tempfile extension fix', x => { x.railsProof.source_inventory.activestorage.fixed_tempfile_extension_occurrences = 0; }],
  ['missing ImageMagick guard', x => { x.railsProof.source_inventory.activestorage.fixed_securable_mini_magick_occurrences = 1; }],
  ['missing Rails advisory test section', x => { delete x.railsProof.tests['GHSA-v924-7rp8-4mxh']; }],
  ['fewer official safe_constantize examples', x => { x.railsProof.tests['GHSA-8474-xrp6-wh69'].official_examples = 2; }],
  ['official examples do not reject the vulnerable each_key', x => { x.railsProof.tests['GHSA-wm3x-v3qw-4jh3'].vulnerable_examples_rejected = 0; }],
  ['fewer ordinary safe_constantize cases', x => { x.railsProof.tests['GHSA-8474-xrp6-wh69'].ordinary_cases = 7; }],
  ['ImageMagick policy claimed applied', x => { x.railsProof.tests['GHSA-f3w6-w445-fwh9'].policy_applied = true; }],
  ['securable mini_magick without review', x => { x.railsProof.tests['GHSA-f3w6-w445-fwh9'].mini_magick_version = '5.1.2'; }],
  ['ImageMagick variant processor', x => { x.railsProof.tests['GHSA-f3w6-w445-fwh9'].variant_processor = 'mini_magick'; }],
  ['ImageMagick process during the proof', x => { x.railsProof.tests['GHSA-f3w6-w445-fwh9'].imagemagick_processes = 1; }],
  ['ordinary Blob#open cases dropped', x => { x.railsProof.tests['GHSA-v924-7rp8-4mxh'].ordinary_open = 29; }],
  ['missing vips variants', x => { x.railsProof.tests['GHSA-v924-7rp8-4mxh'].variants = 0; }],
  ['extra Rails test claim', x => { x.railsProof.tests['GHSA-v924-7rp8-4mxh'].preview = true; }],
  ['missing Rails negative control', x => { x.railsProof.tests.negative_controls.database_refused = false; }],
  ['Rails proof not passed', x => { x.railsProof.tests.passed = false; }],
  ['missing activestorage SBOM package', x => { x.sbom.packages.splice(5, 1); x.sbom.relationships.splice(4, 1); }],
  ['duplicate actionpack SBOM package', x => { x.sbom.packages.push({ ...clone(x.sbom.packages[4]), SPDXID: 'SPDXRef-extra-actionpack' }); }],
  ['wrong activesupport SBOM version', x => { x.sbom.packages[3].versionInfo = '7.2.3.1'; }],
  ['wrong activesupport SBOM purl', x => { x.sbom.packages[3].externalRefs[0].referenceLocator = 'pkg:gem/activesupport@8.0.5.2'; }],
  ['activestorage outside the image', x => { x.sbom.relationships.pop(); }],
  ...RAILS_ADVISORIES.map((id, index) => [`raw ${id} missing`, x => { x.raw.Results[1].Vulnerabilities.splice(3 + index, 1); }]),
  ['extra Rails finding on a reviewed gem', x => { x.raw.Results[1].Vulnerabilities.push({ ...clone(x.raw.Results[1].Vulnerabilities[3]), VulnerabilityID: 'GHSA-xxxx-xxxx-xxxx' }); }],
  ['extra HIGH on another Rails gem', x => { x.raw.Results[1].Vulnerabilities.push({ ...clone(x.raw.Results[1].Vulnerabilities[3]), VulnerabilityID: 'GHSA-9999-9999-9999', PkgName: 'actionview' }); }],
  ['duplicate Rails finding', x => { x.raw.Results[1].Vulnerabilities.push(clone(x.raw.Results[1].Vulnerabilities[5])); }],
  ['Rails finding on another version', x => { x.raw.Results[1].Vulnerabilities[3].InstalledVersion = '7.2.3.1'; }],
  ['Rails finding on another package', x => { x.raw.Results[1].Vulnerabilities[4].PkgName = 'actionview'; }],
  ['Rails finding with another fixed range', x => { x.raw.Results[1].Vulnerabilities[6].FixedVersion = '>= 7.2.3.3'; }],
  ['Rails CRITICAL reported as HIGH', x => { x.raw.Results[1].Vulnerabilities[5].Severity = 'HIGH'; }],
  ['Rails HIGH reported as CRITICAL', x => { x.raw.Results[1].Vulnerabilities[6].Severity = 'CRITICAL'; }],
  ['Rails finding with another purl', x => { x.raw.Results[1].Vulnerabilities[3].PkgIdentifier.PURL = 'pkg:gem/activesupport'; }],
  ['Rails finding on an uninventoried instance', x => { x.raw.Results[1].Vulnerabilities[4].PkgIdentifier.UID = 'other'; }],
  ['Rails finding on another path', x => { x.raw.Results[1].Vulnerabilities[5].PkgPath = 'usr/local/bundle/specifications/activestorage-7.2.3.2.gemspec'; }],
  ['duplicate scanned activestorage', x => { x.raw.Results[1].Packages.push(clone(x.raw.Results[1].Packages[3])); }],
  ['missing scanned actionpack', x => { x.raw.Results[1].Packages.splice(2, 1); }],
];
for (const [label, mutate] of negatives) { const x = fixture(); mutate(x); assert.throws(() => evaluate(x), label); }
const vexNegatives = [
  ['extra statement', v => v.statements.push(clone(v.statements[0]))],
  ['VEX with two statements', v => v.statements.pop()],
  ['statement for another advisory', v => { v.statements[1].vulnerability.name = 'CVE-2099-5'; }],
  ['statement with another fix', v => { v.statements[0].status_notes = v.statements[0].status_notes.replace(FIXES['CVE-2026-67987'], FIXES['CVE-2026-67991']); }],
  ['extra product', v => v.statements[0].products.push(clone(v.statements[0].products[0]))],
  ['extra component', v => v.statements[0].products[0].subcomponents.push({ '@id': 'pkg:gem/rails' })],
  ['gem-only broad product', v => { v.statements[0].products[0]['@id'] = GEM_PURL; }],
  ['not affected claim', v => { v.statements[0].status = 'not_affected'; }],
  ['wrong proof hash', v => { v.statements[0].status_notes = 'trust me'; }],
  ['extra author field', v => { v.other = 'unreviewed'; }],
];
vexNegatives.push(
  ['Rails statement with the ruby_llm subcomponent', v => { v.statements[3].products[0].subcomponents = [{ '@id': GEM_PURL }]; }],
  ['Rails statement with another gem', v => { v.statements[4].products[0].subcomponents = [{ '@id': railsPurl('actionview') }]; }],
  ['Rails statement citing the ruby_llm proof', v => {
    v.statements[6].status_notes = v.statements[6].status_notes.replace(valid.hashes.installed_rails_proof, valid.hashes.installed_proof);
  }],
  ['missing Rails statement', v => { v.statements.splice(5, 1); }],
);
for (const [label, mutate] of vexNegatives) { const v = clone(result.vex); mutate(v);
  assert.throws(() => validateVex(v, result.classification.bindings, valid.context, valid.hashes.installed_proof,
    valid.hashes.installed_rails_proof), label); }
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
