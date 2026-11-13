#!/usr/bin/env node
// Pure, fail-closed classification policy. This does not replace Trivy scanning. It classifies exactly two reviewed source
// backports: ruby_llm 1.15.0 (docs/chatwoot-ruby-llm-backport-policy.md) and Rails 7.2.3.2 (docs/chatwoot-rails-backport-policy.md).
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { constants, closeSync, fstatSync, lstatSync, openSync, readFileSync, readSync, writeFileSync } from 'node:fs';
import { basename, resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const IMAGE = '951034765053.dkr.ecr.ap-northeast-1.amazonaws.com/toybaco/chatwoot';
// The reviewed advisories in ruby_llm 1.15.0 and their upstream fixes, in the reviewed order.
export const FIXES = Object.freeze({
  'CVE-2026-67987': '5e88411f171721b381853fa77d254e266dcf6ad8',
  'CVE-2026-67989': 'dd3c84812598def03d4aff77b5447c41d8f5c34e',
  'CVE-2026-67991': '9d75b033d7d00c4e1baa9b0afb4828faa8bd6602',
});
export const CVES = Object.freeze(Object.keys(FIXES));
export const GEM_PURL = 'pkg:gem/ruby_llm@1.15.0';
export const VEX_TYPE = 'https://openvex.dev/ns/v0.2.0';
export const PROOF_TYPE = 'https://toybaco.jp/attestations/chatwoot-ruby-llm-backport/v1';
export const TRIVY = 'docker.io/aquasec/trivy:0.67.2@sha256:ac2f9d0197456a8ce460884b113e49d65b667f506c31d014c9955869a7a5d682';
// The shipped runtime's distro: alpine-release stays at the pinned Alpine 3.22 base image's own build
// (docs/chatwoot-runtime-os-policy.md), and the publisher passes the same value as Trivy --distro.
export const ALPINE_RELEASE = '3.22.0';
const GEM_ROOT = '/gems/ruby/3.4.0/gems/ruby_llm-1.15.0';
const SPEC_PATH = '/gems/ruby/3.4.0/specifications/ruby_llm-1.15.0.gemspec';
// The reviewed Rails advisories of 2026-11-04 in activesupport, actionpack and activestorage 7.2.3.2, their upstream fixes
// (rails/rails v8.0.5.1...v8.0.5.2) and the gem and severity the raw scanner reports for each, in the reviewed order.
export const RAILS_VERSION = '7.2.3.2';
export const RAILS_FIXED_RANGE = '~> 8.0.5, >= 8.0.5.2, >= 8.1.4.1';
export const RAILS_FIXES = Object.freeze({
  'GHSA-8474-xrp6-wh69': '210ac22d446c8e2625b091e79256806b836eee20',
  'GHSA-wm3x-v3qw-4jh3': '2fc8838300133931e19eed3ea6cee76a7e83f19c',
  'GHSA-f3w6-w445-fwh9': 'ea8c40121ce53a3d0255cd4eb6d13bfe3bc01776',
  'GHSA-v924-7rp8-4mxh': '8106938fb0a595f11006dd1497cd409e27d7d636',
});
export const RAILS_ADVISORIES = Object.freeze(Object.keys(RAILS_FIXES));
export const RAILS_GEMS = Object.freeze(['activesupport', 'actionpack', 'activestorage']);
const RAILS_GEM_OF = Object.freeze({ 'GHSA-8474-xrp6-wh69': 'activesupport', 'GHSA-wm3x-v3qw-4jh3': 'actionpack',
  'GHSA-f3w6-w445-fwh9': 'activestorage', 'GHSA-v924-7rp8-4mxh': 'activestorage' });
const RAILS_SEVERITY = Object.freeze({ 'GHSA-8474-xrp6-wh69': 'HIGH', 'GHSA-wm3x-v3qw-4jh3': 'HIGH',
  'GHSA-f3w6-w445-fwh9': 'CRITICAL', 'GHSA-v924-7rp8-4mxh': 'HIGH' });
export const railsPurl = gem => 'pkg:gem/' + gem + '@' + RAILS_VERSION;
const railsRoot = gem => '/gems/ruby/3.4.0/gems/' + gem + '-' + RAILS_VERSION;
const railsSpec = gem => '/gems/ruby/3.4.0/specifications/' + gem + '-' + RAILS_VERSION + '.gemspec';
// Every finding the raw scanner must report, once each: the three ruby_llm advisories, then the four Rails advisories.
const EXPECTED_FINDINGS = Object.freeze([
  ...Object.keys(FIXES).map(id => Object.freeze({ id, name: 'ruby_llm', version: '1.15.0', severity: 'HIGH',
    fixed: '>= 2.0.0.rc1', purl: GEM_PURL, spec: SPEC_PATH, fix: FIXES[id] })),
  ...RAILS_ADVISORIES.map(id => Object.freeze({ id, name: RAILS_GEM_OF[id], version: RAILS_VERSION, severity: RAILS_SEVERITY[id],
    fixed: RAILS_FIXED_RANGE, purl: railsPurl(RAILS_GEM_OF[id]), spec: railsSpec(RAILS_GEM_OF[id]), fix: RAILS_FIXES[id] })),
]);
export const ADVISORIES = Object.freeze(EXPECTED_FINDINGS.map(finding => finding.id));
// Rails' official advisories identify these two CVEs as aliases (reviewed 2026-11-12).
// Trivy's newer DB emits them in addition to the GHSAs, with this exact fixed-version spelling.
// They never substitute for a missing canonical finding or authorize another package/version.
export const RAILS_ALIASES = Object.freeze({
  'CVE-2026-126080': 'GHSA-8474-xrp6-wh69',
  'CVE-2026-126186': 'GHSA-v924-7rp8-4mxh',
});
const REVIEWED_FINDINGS = Object.freeze([
  ...EXPECTED_FINDINGS,
  ...Object.entries(RAILS_ALIASES).map(([id, canonical_id]) => Object.freeze({
    ...EXPECTED_FINDINGS.find(finding => finding.id === canonical_id),
    id, canonical_id, fixed: '8.1.4.1, 8.0.5.2',
  })),
]);
function reviewedFindings(ids) {
  assert.equal(new Set(ids).size, ids.length, 'each raw advisory ID occurs once');
  assert.ok(ids.every(id => REVIEWED_FINDINGS.some(finding => finding.id === id)), 'unreviewed advisory ID');
  assert.ok(ADVISORIES.every(id => ids.includes(id)), 'all seven canonical advisories remain required');
  return REVIEWED_FINDINGS.filter(finding => ids.includes(finding.id));
}
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

// Each advisory's patched 1.15.0 files and the loaded method that proves the patched source is the one in use.
const SITES = Object.freeze({
  'CVE-2026-67987': [
    ['lib/ruby_llm/providers/openai/chat.rb', 'RubyLLM::Providers::OpenAI::Chat.extract_content_and_thinking', 175],
    ['lib/ruby_llm/stream_accumulator.rb', 'RubyLLM::StreamAccumulator#handle_chunk_content', 120],
  ],
  'CVE-2026-67989': [
    ['lib/ruby_llm/providers/mistral/capabilities.rb', 'RubyLLM::Providers::Mistral::Capabilities.capabilities_for', 106],
  ],
  'CVE-2026-67991': [
    ['lib/ruby_llm/agent.rb', 'RubyLLM::Agent.prompt_agent_path', 324],
    ['lib/ruby_llm/tool.rb', 'RubyLLM::Tool#name', 68],
  ],
});
// Occurrences of each vulnerable/fixed expression across all installed lib/**/*.rb after the backport.
const PATCHED_MARKERS = Object.freeze({
  vulnerable_acronym_occurrences: 0, fixed_boundary_occurrences: 2,
  vulnerable_think_tag_occurrences: 0, fixed_think_passthrough_occurrences: 1,
  vulnerable_voxtral_occurrences: 0, fixed_voxtral_occurrences: 1,
});
const timed = (value, label) => assert.ok(Number.isFinite(value) && value >= 0 && value < 2, label);
// Each Rails advisory's patched or added 7.2.3.2 files and the loaded binding that proves the patched source is in use.
const RAILS_SITES = Object.freeze({
  'GHSA-8474-xrp6-wh69': [['lib/active_support/inflector/methods.rb', 'ActiveSupport::Inflector#safe_constantize', 315]],
  'GHSA-wm3x-v3qw-4jh3': [['lib/action_controller/metal/strong_parameters.rb', 'ActionController::Parameters#each_key', 425]],
  'GHSA-f3w6-w445-fwh9': [
    ['lib/active_storage/analyzer/image_analyzer/image_magick.rb', 'ActiveStorage::Analyzer::ImageAnalyzer::ImageMagick#read_image', 14],
    ['lib/active_storage/engine.rb', 'ActiveStorage::Engine initializer active_storage.configs', 86],
    ['lib/active_storage/image_magick.rb', 'ActiveStorage::ImageMagick.apply_policy', 30],
    ['lib/active_storage/image_magick/policy.xml', 'ActiveStorage::ImageMagick::POLICY_DIRECTORY', null],
  ],
  'GHSA-v924-7rp8-4mxh': [['app/models/active_storage/blob.rb', 'ActiveStorage::Blob#tempfile_extension', 359]],
});
const RAILS_ADDED_FILES = Object.freeze(['lib/active_storage/image_magick.rb', 'lib/active_storage/image_magick/policy.xml']);
// Every regular file of each installed gem after the backport, and the vulnerable/fixed expression counts over its *.rb.
const RAILS_PATCHED_INVENTORY = Object.freeze({
  activesupport: { count: 285, vulnerable_const_regexp_occurrences: 0, fixed_literal_constant_match_occurrences: 1 },
  actionpack: { count: 187, vulnerable_each_key_delegation_occurrences: 0, fixed_each_key_returns_self_occurrences: 1 },
  activestorage: { count: 102, fixed_securable_mini_magick_occurrences: 2, fixed_policy_application_occurrences: 2,
    vulnerable_tempfile_extension_occurrences: 0, fixed_tempfile_extension_occurrences: 1 },
});
// The counts tests/verify_chatwoot_rails_backport.rb prints for its official, vulnerable, ordinary and adversarial cases.
const RAILS_TESTS = Object.freeze({
  'GHSA-8474-xrp6-wh69': { official_examples: 3, vulnerable_examples_rejected: 2, ordinary_cases: 140091, ordinary_constants: 8,
    adversarial_regexp_names: 5 },
  'GHSA-wm3x-v3qw-4jh3': { official_examples: 3, vulnerable_examples_rejected: 1, ordinary_examples: 4, ordinary_cases: 1000 },
  'GHSA-f3w6-w445-fwh9': { official_examples: 5, denied_coders: 31, variant_processor: 'vips', previewers: 0,
    mini_magick_version: '4.12.0', mini_magick_unsecurable: true, policy_applied: false, imagemagick_processes: 0 },
  'GHSA-v924-7rp8-4mxh': { official_examples: 6, vulnerable_examples_rejected: 4, ordinary_open: 30, ordinary_extensions_kept: 25,
    analyzed: 3, variants: 3, custom_tmpdir: true },
  negative_controls: { wrong_source_hash: true, wrong_catalog_hash: true, database_refused: true, imagemagick_spawn_refused: true },
  passed: true,
});

export function validateProof(proof, config, configSha, context) {
  assert.equal(config.schema_version, 2);
  assert.equal(config.gem.name, 'ruby_llm');
  assert.equal(config.gem.version, '1.15.0');
  equal(config.advisories.map(a => a.id), CVES, 'exactly the three reviewed advisories');
  for (const advisory of config.advisories) {
    assert.equal(advisory.fix_commit, FIXES[advisory.id]);
    assert.equal(advisory.fix_url, 'https://github.com/crmne/ruby_llm/commit/' + FIXES[advisory.id]);
    equal(advisory.files.map(f => [f.path, f.method, f.source_line]), SITES[advisory.id], 'exact upstream call sites');
    // A backport must change every listed file: a patched hash equal to the official source is not a fix.
    for (const f of advisory.files) assert.notEqual(hash(f.patched_sha256), hash(f.original_sha256), 'patched file differs from official source');
  }
  assert.notEqual(config.ruby_source_inventory.patched.sha256, config.ruby_source_inventory.original.sha256,
    'patched inventory differs from the official gem');
  const files = config.advisories.flatMap(a => a.files.map(f => ({ advisory: a.id, ...f })));
  assert.equal(proof.schema_version, 2);
  assert.equal(proof.result, 'PASS');
  equal(proof.advisories, CVES, 'proof covers exactly the three advisories');
  assert.equal(proof.public_revision, context.source_commit);
  assert.equal(proof.patch_config_sha256, hash(configSha));
  equal(proof.upstream_fix_commits, FIXES, 'upstream fixes');
  equal(proof.gem, { name: 'ruby_llm', version: '1.15.0', installed_spec_count: 1,
    gem_root: GEM_ROOT, spec_path: SPEC_PATH }, 'unique exact installed gem');
  equal(proof.ruby, { version: '3.4.4', platform: 'x86_64-linux-musl' }, 'actual target interpreter');
  equal(proof.files, files.map(f => ({ advisory: f.advisory, path: f.path, sha256: hash(f.patched_sha256),
    method: f.method, source_path: GEM_ROOT + '/' + f.path, source_line: f.source_line })),
    'loaded methods and complete source file hashes');
  equal(proof.unchanged_files, config.unchanged_files, 'entrypoint/version/license unchanged');
  equal(proof.ruby_source_inventory, { ...config.ruby_source_inventory.patched, ...PATCHED_MARKERS },
    'complete installed Ruby inventory');
  assert.equal(proof.ruby_source_inventory.count, 130);
  equal(proof.agents, { loaded: true, version: '0.12.0',
    spec_path: '/gems/ruby/3.4.0/specifications/ai-agents-0.12.0.gemspec' }, 'Agents retained');
  const t = proof.tests;
  equal(Object.keys(t).sort(), [...CVES, 'agents_constructor', 'negative_controls', 'passed'].sort(), 'proof test sections');
  assert.equal(t.passed, true);
  assert.equal(t.agents_constructor, true);
  equal(t.negative_controls, { wrong_source_hash: true, wrong_catalog_hash: true });
  const acronym = t['CVE-2026-67991'];
  equal(Object.keys(acronym).sort(), ['adversarial', 'official_examples', 'ordinary_cases',
    'ordinary_method_comparisons', 'tool_suffix_examples'], 'CVE-2026-67991 proof shape');
  assert.equal(acronym.ordinary_cases, 20020);
  assert.equal(acronym.ordinary_method_comparisons, 40040);
  assert.equal(acronym.official_examples, 4);
  assert.equal(acronym.tool_suffix_examples, 4);
  equal(Object.keys(acronym.adversarial).sort(), ['agent_seconds', 'length', 'timeout_seconds', 'tool_seconds']);
  assert.equal(acronym.adversarial.length, 100000);
  assert.equal(acronym.adversarial.timeout_seconds, 2);
  for (const key of ['tool_seconds', 'agent_seconds']) timed(acronym.adversarial[key], 'CVE-2026-67991 ' + key);
  const think = t['CVE-2026-67987'];
  equal(Object.keys(think).sort(), ['adversarial', 'official_examples', 'ordinary_cases', 'stream_cases',
    'unchanged_shapes'], 'CVE-2026-67987 proof shape');
  assert.equal(think.ordinary_cases, 5000);
  assert.equal(think.stream_cases, 2000);
  assert.equal(think.official_examples, 4);
  assert.equal(think.unchanged_shapes, 3);
  equal(Object.keys(think.adversarial).sort(), ['accumulator_seconds', 'scanner_seconds', 'timeout_seconds', 'unclosed_tags']);
  assert.equal(think.adversarial.unclosed_tags, 50000);
  assert.equal(think.adversarial.timeout_seconds, 2);
  for (const key of ['scanner_seconds', 'accumulator_seconds']) timed(think.adversarial[key], 'CVE-2026-67987 ' + key);
  const voxtral = t['CVE-2026-67989'];
  equal(Object.keys(voxtral).sort(), ['adversarial', 'model_catalog_ids', 'official_examples', 'ordinary_cases'],
    'CVE-2026-67989 proof shape');
  assert.equal(voxtral.ordinary_cases, 20072);
  assert.equal(voxtral.model_catalog_ids, 72);
  assert.equal(voxtral.official_examples, 8);
  equal(Object.keys(voxtral.adversarial).sort(), ['capabilities_seconds', 'timeout_seconds', 'voxtral_repeats']);
  assert.equal(voxtral.adversarial.voxtral_repeats, 50000);
  assert.equal(voxtral.adversarial.timeout_seconds, 2);
  timed(voxtral.adversarial.capabilities_seconds, 'CVE-2026-67989 capabilities_seconds');
}

export function validateRailsProof(proof, config, configSha, context) {
  assert.equal(config.schema_version, 1);
  assert.equal(config.rails_version, RAILS_VERSION);
  equal(config.gems.map(gem => [gem.name, gem.version]), RAILS_GEMS.map(gem => [gem, RAILS_VERSION]), 'exactly the three Rails gems');
  equal(config.advisories.map(a => a.id), RAILS_ADVISORIES, 'exactly the four reviewed Rails advisories');
  for (const advisory of config.advisories) {
    assert.equal(advisory.gem, RAILS_GEM_OF[advisory.id]);
    assert.equal(advisory.severity, RAILS_SEVERITY[advisory.id]);
    assert.equal(advisory.fix_commit, RAILS_FIXES[advisory.id]);
    assert.equal(advisory.fix_url, 'https://github.com/rails/rails/commit/' + RAILS_FIXES[advisory.id]);
    hash(advisory.upstream_diff_sha256);
    equal(advisory.files.map(f => [f.path, f.method, f.source_line]), RAILS_SITES[advisory.id], 'exact upstream call sites');
    // A backport must change every listed file: a patched hash equal to the official source is not a fix.
    for (const f of advisory.files) {
      if (f.original_sha256 !== null) assert.notEqual(hash(f.patched_sha256), hash(f.original_sha256), 'patched file differs from official source');
    }
  }
  equal(config.advisories.flatMap(a => a.files.filter(f => f.original_sha256 === null).map(f => f.path)), RAILS_ADDED_FILES,
    'only the upstream files are added');
  for (const gem of RAILS_GEMS) {
    assert.notEqual(config.source_inventory[gem].patched.sha256, config.source_inventory[gem].original.sha256,
      'patched inventory differs from the official gem');
  }
  const files = config.advisories.flatMap(a => a.files.map(f => ({ advisory: a.id, gem: a.gem, ...f })));
  assert.equal(proof.schema_version, 1);
  assert.equal(proof.result, 'PASS');
  equal(proof.advisories, RAILS_ADVISORIES, 'proof covers exactly the four Rails advisories');
  assert.equal(proof.public_revision, context.source_commit);
  assert.equal(proof.patch_config_sha256, hash(configSha));
  equal(proof.upstream_fix_commits, RAILS_FIXES, 'upstream Rails fixes');
  equal(proof.gems, RAILS_GEMS.map(gem => ({ name: gem, version: RAILS_VERSION, installed_spec_count: 1,
    gem_root: railsRoot(gem), spec_path: railsSpec(gem) })), 'unique exact installed Rails gems');
  equal(proof.ruby, { version: '3.4.4', platform: 'x86_64-linux-musl' }, 'actual target interpreter');
  equal(proof.files, files.map(f => ({ advisory: f.advisory, gem: f.gem, path: f.path, sha256: hash(f.patched_sha256),
    method: f.method, source_path: railsRoot(f.gem) + '/' + f.path, source_line: f.source_line })),
  'loaded Rails bindings and complete source file hashes');
  equal(proof.unchanged_files, config.unchanged_files, 'Rails entrypoints, versions and licenses unchanged');
  equal(proof.source_inventory, Object.fromEntries(RAILS_GEMS.map(gem => [gem,
    { ...config.source_inventory[gem].patched, ...RAILS_PATCHED_INVENTORY[gem] }])), 'complete installed Rails inventories');
  equal(proof.tests, RAILS_TESTS, 'Rails official, ordinary and negative evidence');
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
  assert.equal(image.Config.Labels['org.opencontainers.image.revision'], '9f920b549c14491a4e587687a3eed5d21c6ccc7d');
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
  const rails = Object.fromEntries(RAILS_GEMS.map(gem => {
    const pkg = one(packages.filter(p => p.name === gem || (p.externalRefs || []).some(r => r.referenceType === 'purl' &&
      (r.referenceLocator === 'pkg:gem/' + gem || String(r.referenceLocator).startsWith('pkg:gem/' + gem + '@')))),
    'unique ' + gem + ' SBOM occurrence');
    assert.equal(pkg.name, gem); assert.equal(pkg.versionInfo, RAILS_VERSION);
    assert.equal(purl(pkg), railsPurl(gem));
    assert.ok(reachable.has(pkg.SPDXID), 'image-to-' + gem + ' relationship is required');
    return [gem, { purl: railsPurl(gem), spdx_id: pkg.SPDXID }];
  }));
  return { root_purl: rootPurl, root_spdx_id: rootId, gem_purl: GEM_PURL, gem_spdx_id: ruby.SPDXID, rails_gems: rails };
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
  assert.equal(exitStatus, 1, 'raw scanner must report the reviewed HIGH/CRITICAL findings and exit 1');
  assert.equal(report.SchemaVersion, 2);
  assert.equal(report.Metadata.OS.Family, 'alpine');
  assert.equal(report.Metadata.OS.Name, ALPINE_RELEASE);
  const results = array(report.Results);
  for (const cls of ['os-pkgs', 'lang-pkgs']) {
    assert.ok(results.some(r => r.Class === cls && Array.isArray(r.Packages) && r.Packages.length > 0),
      'complete OS and language inventory');
  }
  assert.equal(results.flatMap(r => r.ExperimentalModifiedFindings || []).length, 0, 'no prefiltered findings');
  const rows = results.flatMap(r => (r.Vulnerabilities || []).map(f => ({ result: r, finding: f })));
  const expectedFindings = reviewedFindings(rows.map(row => row.finding.VulnerabilityID));
  const scanned = {};
  for (const expected of EXPECTED_FINDINGS) {
    if (scanned[expected.name]) continue;
    const instances = results.flatMap(r => (r.Packages || []).filter(p => p.Name === expected.name));
    const pkg = one(instances, 'one scanned ' + expected.name + ' instance');
    assert.equal(pkg.Version, expected.version); assert.equal(pkg.Identifier?.PURL, expected.purl);
    if (pkg.FilePath) assert.equal(pkg.FilePath.replace(/^\//, ''), expected.spec.slice(1));
    scanned[expected.name] = pkg;
  }
  return expectedFindings.map(expected => {
    const { result, finding } = one(rows.filter(row => row.finding.VulnerabilityID === expected.id), 'one raw finding for ' + expected.id);
    const pkg = scanned[expected.name];
    assert.equal(result.Class, 'lang-pkgs');
    assert.equal(finding.Severity, expected.severity);
    assert.equal(finding.PkgName, expected.name); assert.equal(finding.InstalledVersion, expected.version);
    assert.equal(finding.FixedVersion, expected.fixed);
    assert.equal(finding.PkgIdentifier?.PURL, expected.purl);
    // Syft's no-file-metadata SPDX can omit PkgPath. If present it must be the verified installed spec.
    assert.ok(finding.PkgPath === undefined || finding.PkgPath === '' ||
      finding.PkgPath.replace(/^\//, '') === expected.spec.slice(1), 'unexpected affected package path');
    assert.ok(pkg.Identifier.UID && pkg.Identifier.UID === finding.PkgIdentifier.UID, 'finding refers to inventoried gem');
    return { target: result.Target, type: result.Type, finding, canonical_advisory: expected.canonical_id || expected.id };
  });
}

export function makeVex(binding, context, preparedSha, railsPreparedSha, findingIds = ADVISORIES) {
  const statement = (id, subcomponent, notes) => ({
    vulnerability: { name: id },
    products: [{ '@id': binding.root_purl,
      hashes: { 'sha-256': context.image_digest.slice(7) },
      subcomponents: [{ '@id': subcomponent }] }],
    status: 'fixed',
    status_notes: notes,
  });
  return { '@context': VEX_TYPE,
    '@id': 'https://toybaco.jp/security/vex/' + context.image_digest.slice(7) + '/chatwoot-source-backports',
    author: 'https://github.com/Cyber-relations', role: 'Product Security',
    timestamp: context.issued_at, version: 1, statements: reviewedFindings(findingIds).map(finding =>
      statement(finding.id, finding.purl, 'Official fix backport ' + finding.fix + '; exact-image proof SHA256 ' +
        hash(finding.name === 'ruby_llm' ? preparedSha : railsPreparedSha) + '. ' + finding.name + ' remains ' + finding.version +
        '; raw scanner still reports the version-based finding.' +
        (finding.canonical_id ? ' Reviewed alias of ' + finding.canonical_id + '.' : ''))) };
}
export function validateVex(vex, binding, context, preparedSha, railsPreparedSha, findingIds = ADVISORIES) {
  equal(vex, makeVex(binding, context, preparedSha, railsPreparedSha, findingIds), 'only generated exact-artifact fixed VEX accepted');
}

function regular(path) {
  const stat = lstatSync(path), label = JSON.stringify(basename(path));
  assert.ok(stat.isFile() && !stat.isSymbolicLink(), label + ': expected a regular non-symlink file');
  assert.ok(stat.size > 0 && stat.size <= 16777216,
    label + ': size ' + stat.size + ' outside supported range 1..16777216 bytes');
  return readFileSync(path);
}
function hashDatabase(path) {
  const before = lstatSync(path, { bigint: true });
  assert.ok(before.isFile() && !before.isSymbolicLink(), 'trivy.db: expected a regular non-symlink file');
  assert.ok(before.size > 0n && before.size <= 4294967296n,
    'trivy.db: size ' + before.size + ' outside supported range 1..4294967296 bytes');
  const identity = stat => [stat.dev, stat.ino, stat.size, stat.mtimeNs, stat.ctimeNs];
  const unchanged = stat => {
    assert.ok(stat.isFile() && !stat.isSymbolicLink(), 'trivy.db: file type changed during hashing');
    assert.deepEqual(identity(stat), identity(before), 'trivy.db: identity or metadata changed during hashing');
  };
  assert.ok(Number.isInteger(constants.O_NOFOLLOW) && constants.O_NOFOLLOW > 0,
    'trivy.db: platform must support O_NOFOLLOW');
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    unchanged(fstatSync(fd, { bigint: true }));
    const digest = createHash('sha256'), buffer = Buffer.allocUnsafe(1048576);
    let remaining = Number(before.size);
    while (remaining > 0) {
      const length = readSync(fd, buffer, 0, Math.min(buffer.length, remaining), null);
      assert.ok(length > 0, 'trivy.db: unexpected EOF during hashing');
      digest.update(buffer.subarray(0, length));
      remaining -= length;
    }
    assert.equal(readSync(fd, buffer, 0, 1, null), 0, 'trivy.db: grew during hashing');
    unchanged(fstatSync(fd, { bigint: true }));
    unchanged(lstatSync(path, { bigint: true }));
    return digest.digest('hex');
  } finally {
    closeSync(fd);
  }
}
function json(path) { return JSON.parse(regular(path)); }
function writeExclusive(path, value) {
  const bytes = JSON.stringify(value, null, 2) + '\n';
  assert.ok(Buffer.byteLength(bytes) <= 16777216);
  writeFileSync(path, bytes, { flag: 'wx', mode: 0o600 });
}
export function snapshotDatabase(directory) {
  return { database_sha256: hashDatabase(join(directory, 'db', 'trivy.db')),
    metadata_sha256: sha(regular(join(directory, 'db', 'metadata.json'))),
    metadata: json(join(directory, 'db', 'metadata.json')) };
}

export function evaluate(input) {
  const { config, configSha, railsConfig, railsConfigSha, context, imageInspect, proof, railsProof, sbom, raw, rawExit,
    before, after, hashes } = input;
  validateProof(proof, config, configSha, context);
  validateRailsProof(railsProof, railsConfig, railsConfigSha, context);
  const binding = validateBinding(sbom, context, imageInspect);
  validateDatabase(before, context);
  equal(before, after, 'frozen database unchanged through raw scan');
  const findings = validateRawReport(raw, rawExit);
  for (const value of Object.values(hashes)) hash(value);
  const vex = makeVex(binding, context, hashes.installed_proof, hashes.installed_rails_proof,
    findings.map(row => row.finding.VulnerabilityID));
  const severities = findings.map(row => row.finding.Severity);
  const classification = {
    schema_version: 2, result: 'PASS',
    policy: 'toybaco-chatwoot-source-backport-v4',
    evaluator: 'scripts/verify-chatwoot-ruby-llm-classification.mjs',
    evaluation_kind: 'independent_source_backport_classification',
    scanner_vex_filtering: false,
    image: { name: IMAGE, digest: context.image_digest },
    source: { commit: context.source_commit, ref: context.source_ref, control_sha256: context.control_sha256 },
    timestamp: context.issued_at,
    counts: { raw_critical: severities.filter(value => value === 'CRITICAL').length,
      raw_high: severities.filter(value => value === 'HIGH').length, source_verified_fixed: findings.length,
      unresolved_critical: 0, unresolved_high: 0 },
    bindings: { ...binding, ...hashes, patch_config: configSha, rails_patch_config: railsConfigSha },
    scanner: { image: TRIVY, exit_status: rawExit, arguments: [
      '--config', '/dev/null', 'sbom', '--scanners', 'vuln', '--pkg-types', 'os,library',
      '--distro', `alpine/${ALPINE_RELEASE}`, '--severity', 'CRITICAL,HIGH', '--ignore-unfixed=false',
      '--exit-code', '1', '--list-all-pkgs', '--skip-db-update', '--skip-java-db-update', '--offline-scan',
    ], database: before },
    installed_source_proof: proof,
    installed_rails_source_proof: railsProof,
    evaluated_findings: findings.map(finding => ({ status: 'fixed', basis: 'verified_official_fix_backport',
      upstream_fix_commit: EXPECTED_FINDINGS.find(expected => expected.id === finding.canonical_advisory).fix, ...finding })),
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
  const [mode, directory, configPath, railsConfigPath] = process.argv.slice(2);
  assert.ok(directory && configPath);
  const dir = resolve(directory), configBytes = regular(resolve(configPath)), config = JSON.parse(configBytes);
  if (mode === 'snapshot-before' || mode === 'snapshot-after') {
    writeExclusive(join(dir, mode === 'snapshot-before' ? 'db-before.json' : 'db-after.json'), snapshotDatabase(dir));
    return;
  }
  assert.ok(railsConfigPath, 'the Rails backport catalog is required');
  const railsConfigBytes = regular(resolve(railsConfigPath)), railsConfig = JSON.parse(railsConfigBytes);
  const read = name => json(join(dir, name));
  const context = read('context.json');
  const recompute = () => {
    const names = { sbom: 'sbom.spdx.json', raw_report: 'raw-report.json',
      installed_proof: 'installed-proof.json', installed_rails_proof: 'installed-rails-proof.json',
      image_inspect: 'image-inspect.json', evaluator: null };
    const hashes = Object.fromEntries(Object.entries(names).map(([key, name]) => [
      key, sha(regular(name ? join(dir, name) : process.argv[1])),
    ]));
    const before = read('db-before.json'), after = read('db-after.json');
    equal(snapshotDatabase(dir), after, 'current frozen DB equals final snapshot');
    return evaluate({ config, configSha: sha(configBytes), railsConfig, railsConfigSha: sha(railsConfigBytes), context,
      imageInspect: read('image-inspect.json'), proof: read('installed-proof.json'),
      railsProof: read('installed-rails-proof.json'),
      sbom: read('sbom.spdx.json'), raw: read('raw-report.json'),
      rawExit: Number(regular(join(dir, 'raw-exit.txt')).toString().trim()),
      before, after, hashes });
  };
  if (mode === 'evaluate') {
    const result = recompute();
    writeExclusive(join(dir, 'openvex.json'), result.vex);
    writeExclusive(join(dir, 'source-backport-classification.json'), result.classification);
    const counts = result.classification.counts;
    console.log('TOYBACO_CHATWOOT_BACKPORT_CLASSIFICATION=PASS RAW_CRITICAL=' + counts.raw_critical +
      ' RAW_HIGH=' + counts.raw_high + ' SOURCE_VERIFIED_FIXED=' + counts.source_verified_fixed +
      ' UNRESOLVED_CRITICAL=0 UNRESOLVED_HIGH=0');
    return;
  }
  if (mode === 'verify-attestations') {
    const classification = read('source-backport-classification.json'), vex = read('openvex.json');
    const expected = recompute();
    equal(classification, expected.classification, 'classification inputs or evidence changed');
    equal(vex, expected.vex, 'VEX inputs or evidence changed');
    validateVex(vex, classification.bindings, context, classification.bindings.installed_proof,
      classification.bindings.installed_rails_proof, expected.classification.evaluated_findings.map(row => row.finding.VulnerabilityID));
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
