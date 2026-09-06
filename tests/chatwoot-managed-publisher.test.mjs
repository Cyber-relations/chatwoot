#!/usr/bin/env node

import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { resolve, join } from 'node:path';
import vm from 'node:vm';

const root = resolve(process.argv[2] || '.');
const workflowPath = resolve(root, '.github/workflows/chatwoot-integration.yml');
const gatePath = resolve(root, 'bin/toybaco-chatwoot-gate');
const postEntryPath = resolve(root, 'overlay/app/public/brand-assets/toybaco-post-entry.js');
const workflow = readFileSync(workflowPath, 'utf8');
const gate = readFileSync(gatePath, 'utf8');
const postEntry = readFileSync(postEntryPath, 'utf8');
const instrumentedPostEntry = postEntry.replace(
  /\n\}\)\(\);\s*$/,
  '\nwindow.__TOYBACO_POST_ENTRY_TEST__ = { findMenu: findMenu, placeEntry: placeEntry };\n})();\n',
);
assert.notEqual(instrumentedPostEntry, postEntry, 'post-entry test instrumentation anchor missing');

const ACTIONS = Object.freeze({
  checkout: 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1',
  credentials:
    'aws-actions/configure-aws-credentials@e6de054238d6b7531b4efff3b6587d9aade6a06c',
  ecrLogin:
    'aws-actions/amazon-ecr-login@03f1aad4c6c7ffd436567f42f9384779290529bd',
  sbom: 'anchore/sbom-action@e22c389904149dbc22b58101806040fa8d37a610',
  attest: 'actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6',
});

function count(source, pattern) {
  return source.match(pattern)?.length || 0;
}

function jobBlock(source, name) {
  const marker = `  ${name}:\n`;
  const start = source.indexOf(marker);
  assert.ok(start >= 0, `job missing: ${name}`);
  const nextJob = /^  [a-zA-Z0-9_-]+:\n/gm;
  nextJob.lastIndex = start + marker.length;
  const next = nextJob.exec(source);
  return source.slice(start, next?.index ?? source.length);
}

function functionBlock(source, name, nextName) {
  const startMarker = `${name}() {\n`;
  const endMarker = `\n${nextName}() {\n`;
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.ok(start >= 0 && end > start, `shell function boundary missing: ${name}`);
  return source.slice(start, end);
}

function usedActions(source) {
  return [...source.matchAll(/^\s+uses:\s+(\S+)/gm)].map((match) => match[1]);
}

function validatePostEntryNavigation(source) {
  const placeEntry = `  function placeEntry(menu, entry) {
    if (entry.parentElement !== menu.ul || entry.previousElementSibling !== menu.li) {
      menu.ul.insertBefore(entry, menu.li.nextSibling);
    }
  }`;
  const nativeFirst = "li = ul.querySelector(':scope > li:not([data-' + MARK + '-wrap])');";
  const sameAccount = "if (existing && existing.getAttribute('data-account') === id) {";
  const existingWrap = 'var existingWrap = existing.parentElement;';
  const markedWrap =
    "if (existingWrap && existingWrap.getAttribute('data-' + MARK + '-wrap') === '1') {";
  const repairPosition = 'placeEntry(sample, existingWrap);';
  const removeExisting = '      removePostEntry();\n      var now = findMenu();';
  const duplicateGuard = "if (document.querySelector('[data-' + MARK + ']')) return;";
  const insertAfterFirst = 'placeEntry(now, buildEntry(now, id));';

  const positions = [
    placeEntry,
    nativeFirst,
    sameAccount,
    existingWrap,
    markedWrap,
    repairPosition,
    removeExisting,
    duplicateGuard,
    insertAfterFirst,
  ]
    .map((contract) => source.indexOf(contract));
  assert.ok(positions.every((position) => position >= 0), 'post-entry navigation contract missing');
  assert.deepEqual([...positions].sort((a, b) => a - b), positions,
    'post-entry account/idempotency checks must precede insertion');
  assert.equal(source.match(/buildEntry\(now, id\)/g)?.length, 1,
    'post-entry must be inserted exactly once');
  assert.ok(!source.includes('now.ul.appendChild(buildEntry(now, id));'),
    'post-entry must not be appended to the menu end');
}

function loadPostEntryNavigation() {
  const window = {
    TOYBACO_POST_URL: 'https://post.staging.toybaco.jp',
    globalConfig: {},
    location: { hash: '', pathname: '/app/accounts/1/inbox', protocol: 'https:' },
    addEventListener() {},
  };
  const document = {
    readyState: 'loading',
    addEventListener() {},
  };
  vm.runInNewContext(instrumentedPostEntry, {
    window,
    document,
    URL,
    URLSearchParams,
    sessionStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  }, { filename: postEntryPath });
  return { api: window.__TOYBACO_POST_ENTRY_TEST__, document };
}

function makeRow(name) {
  const row = { name, parentElement: null };
  Object.defineProperties(row, {
    previousElementSibling: {
      get() {
        if (!row.parentElement) return null;
        const index = row.parentElement.children.indexOf(row);
        return index > 0 ? row.parentElement.children[index - 1] : null;
      },
    },
    nextSibling: {
      get() {
        if (!row.parentElement) return null;
        const index = row.parentElement.children.indexOf(row);
        return index >= 0 ? (row.parentElement.children[index + 1] || null) : null;
      },
    },
  });
  return row;
}

function makeList(rows) {
  const ul = {
    children: [...rows],
    insertCalls: 0,
    insertBefore(node, reference) {
      this.insertCalls += 1;
      if (node.parentElement) {
        const previous = node.parentElement.children.indexOf(node);
        if (previous >= 0) node.parentElement.children.splice(previous, 1);
      }
      const index = reference === null ? this.children.length : this.children.indexOf(reference);
      assert.notEqual(index, -1, 'reference row must belong to the destination menu');
      this.children.splice(index, 0, node);
      node.parentElement = this;
    },
  };
  rows.forEach((row) => { row.parentElement = ul; });
  return ul;
}

function testPostEntryNavigation() {
  const fixture = loadPostEntryNavigation();
  const postingFirst = makeRow('posting');
  const inbox = makeRow('inbox');
  const conversations = makeRow('conversations');
  const primaryList = makeList([postingFirst, inbox, conversations]);
  const inboxInner = {};
  inbox.querySelector = (selector) => {
    assert.equal(selector, 'a, [role="button"]');
    return inboxInner;
  };
  primaryList.querySelector = (selector) => {
    assert.equal(selector, ':scope > li:not([data-toybaco-post-entry-wrap])');
    return inbox;
  };
  const nav = {
    querySelector(selector) {
      assert.equal(selector, 'ul');
      return primaryList;
    },
  };
  fixture.document.querySelectorAll = (selector) => {
    assert.equal(selector, 'nav');
    return [nav];
  };

  const menu = fixture.api.findMenu();
  assert.equal(menu.li, inbox, 'posting row must not become the native navigation sample');
  fixture.api.placeEntry(menu, postingFirst);
  assert.deepEqual(primaryList.children.map((row) => row.name), [
    'inbox',
    'posting',
    'conversations',
  ]);
  assert.equal(primaryList.insertCalls, 1, 'posting-first drift must be repaired once');
  fixture.api.placeEntry(menu, postingFirst);
  assert.equal(primaryList.insertCalls, 1, 'correct repeated placement must not mutate the DOM');

  const stalePosting = makeRow('posting');
  const staleList = makeList([stalePosting]);
  const freshInbox = makeRow('fresh-inbox');
  const freshOther = makeRow('fresh-other');
  const freshList = makeList([freshInbox, freshOther]);
  fixture.api.placeEntry({ ul: freshList, li: freshInbox }, stalePosting);
  assert.deepEqual(staleList.children, [], 'entry must leave the stale navigation list');
  assert.deepEqual(freshList.children.map((row) => row.name), [
    'fresh-inbox',
    'posting',
    'fresh-other',
  ]);
}

function validate(workflowSource, gateSource) {
  for (const input of ['config/chatwoot-runtime-gems.json', 'scripts/harden-chatwoot-runtime-gems.rb', 'tests/verify_chatwoot*']) {
    assert.ok(workflowSource.includes(`      - '${input}'`), `runtime source push path missing: ${input}`);
  }
  const quality = jobBlock(workflowSource, 'quality');
  const publish = jobBlock(workflowSource, 'publish');

  assert.match(workflowSource, /^  pull_request:\n/m);
  assert.match(workflowSource, /^  push:\n/m);
  assert.match(workflowSource, /^    branches: \[main\]\n/m);
  assert.match(workflowSource, /^  workflow_dispatch:\n/m);
  for (const required of [
    'publish_reviewed_main:',
    'required: true',
    'type: boolean',
    'default: false',
  ]) assert.ok(workflowSource.includes(required), `manual republish trigger missing: ${required}`);
  assert.match(quality, /if: github\.event_name != 'schedule'/);
  assert.match(quality, /permissions:\n\s+contents: read/);
  assert.match(quality, /run: \.\/bin\/toybaco-chatwoot-gate --quality-only/);
  assert.deepEqual(usedActions(quality), [ACTIONS.checkout]);

  assert.ok(
    publish.includes("(github.event_name == 'push' && github.ref == 'refs/heads/main') ||"),
    'push publisher must remain main-only',
  );
  assert.ok(
    publish.includes(
      "(github.event_name == 'workflow_dispatch' && inputs.publish_reviewed_main)",
    ),
    'manual republish request must make the publisher job reachable',
  );
  assert.match(publish, /^    needs: quality$/m);
  assert.match(publish, /environment:\n\s+name: chatwoot-production/);
  for (const permission of [
    'artifact-metadata: write',
    'attestations: write',
    'contents: read',
    'id-token: write',
  ]) {
    assert.ok(publish.includes(permission), `publisher permission missing: ${permission}`);
  }
  assert.deepEqual(usedActions(publish), [
    ACTIONS.checkout,
    ACTIONS.credentials,
    ACTIONS.ecrLogin,
    ACTIONS.credentials,
    ACTIONS.sbom,
    ACTIONS.attest,
    ACTIONS.attest,
  ]);
  for (const action of usedActions(publish)) {
    assert.match(action, /^[a-z0-9-]+\/[a-z0-9-]+@[0-9a-f]{40}$/);
  }
  const buildIndex = publish.indexOf('linux/amd64 imageを一度だけbuild・pushしdigestとlabelを確認');
  const credentialRefreshIndex = publish.indexOf('scan前に本番publisher roleを再取得');
  const digestReadbackIndex = publish.indexOf('buildx digestをECRから再取得して照合');
  const scanIndex = publish.indexOf('ECR scan完了・Critical/Highゼロを確認');
  assert.ok(
    buildIndex >= 0 && buildIndex < credentialRefreshIndex &&
      credentialRefreshIndex < digestReadbackIndex && digestReadbackIndex < scanIndex,
    'publisher must refresh the standard OIDC session before ECR digest readback and scan',
  );

  for (const forbidden of [
    'uses: actions/upload-artifact',
    'uses: actions/download-artifact',
    './scripts/publish-chatwoot-image.sh',
    '--artifact-dir',
    'oras-project/setup-oras',
    'chatwoot-release.oci.tar',
    'release.json',
  ]) {
    assert.ok(!publish.includes(forbidden), `parked publisher path is active: ${forbidden}`);
  }
  assert.equal(count(workflowSource, /docker buildx build/g), 1);
  assert.equal(count(publish, /docker build(?:\s|$)/g), 0);
  for (const required of [
    'docker buildx build --no-cache --pull --platform linux/amd64',
    '--metadata-file "$metadata"',
    '--provenance=false',
    '--sbom=false',
    '--push .',
    '."containerimage.digest"',
    'aws ecr describe-images',
    'described_digest" == "$IMAGE_DIGEST',
    'docker buildx imagetools inspect',
    '"$ECR_REPOSITORY@$digest" --raw',
    '.schemaVersion == 2 and .manifests == null',
    'org.opencontainers.image.base.name',
    'org.opencontainers.image.revision',
    'jp.toybaco.source.tree',
    'jp.toybaco.gate.control-sha256',
    'image_digest=%s',
    'image_uri=%s@%s',
  ]) {
    assert.ok(publish.includes(required), `digest-first build contract missing: ${required}`);
  }

  for (const required of [
    'CHATWOOT_SOURCE_TAG: v4.17.1',
    'CHATWOOT_SOURCE_TAG_OBJECT: e194a693e2dbf4ebae5f78a4d3b9bf6dd8b53ff1',
    'CHATWOOT_SOURCE_COMMIT: b354a9550e1fb59fa537a9c384232cb076213e72',
    'CHATWOOT_SOURCE_TREE: 9a17426900d328a6acc2bdaecba0533e8b401120',
    'CHATWOOT_BASE_IMAGE: chatwoot/chatwoot@sha256:0dcaaacc41ba5219b48af80b236f7707dbd5d58228320950af71a4309c349a7a',
    'ruby tests/verify_chatwoot_overlay_manifest.rb verify . tests/chatwoot-overlay-manifest.tsv',
    './bin/toybaco-chatwoot-gate --control-sha-only',
    "REQUEST_REF: ${{ github.ref }}",
    "REQUEST_REF_TYPE: ${{ github.ref_type }}",
    `if [[ "$REQUEST_REF_TYPE" != 'branch' || "$REQUEST_REF" != 'refs/heads/main' ]]; then`,
    'publisherはreview済みmain branchからのみ実行できます',
  ]) {
    assert.ok(publish.includes(required), `source/overlay binding missing: ${required}`);
  }

  for (const required of [
    'describe-image-scan-findings',
    'ScanNotFoundException',
    'COMPLETE) complete=1; break',
    'PENDING|IN_PROGRESS',
    'findingSeverityCounts.CRITICAL',
    'findingSeverityCounts.HIGH',
    'attempt <= 60',
  ]) {
    assert.ok(publish.includes(required), `ECR scan contract missing: ${required}`);
  }
  assert.doesNotMatch(publish, /start-image-scan/);

  const trivyIndex = publish.indexOf('固定Trivyで同digest SBOMのOS・言語 Critical/Highゼロを確認');
  assert.ok(publish.indexOf('SPDX SBOMの形式と上限を確認') < trivyIndex &&
    trivyIndex < publish.indexOf('SLSA provenanceを署名してOCIへ保存'),
    'exact SBOM must pass all-package security scan before either attestation');
  for (const required of [
    'TRIVY_IMAGE: docker.io/aquasec/trivy:0.67.2@sha256:ac2f9d0197456a8ce460884b113e49d65b667f506c31d014c9955869a7a5d682',
    '--pkg-types os,library', '--severity CRITICAL,HIGH', '--ignore-unfixed=false',
    '--distro alpine/3.21.3', '--exit-code 1', '--config /dev/null sbom',
    '--workdir /scan', '"$TRIVY_IMAGE"', 'toybaco-chatwoot.spdx.json',
    '.checksumValue == $digest', '.relationshipType == "DESCRIBES"',
    'image: registry:${{ steps.build.outputs.image_uri }}',
    '.versionInfo == ("sha256:" + $digest)',
    'distro=alpine-3.21.3', '.Class == "os-pkgs"', '.Class == "lang-pkgs"',
    '[[ "$scan_status" -eq 0 ]] || exit "$scan_status"',
  ]) assert.ok(publish.includes(required), `strict Trivy SBOM contract missing: ${required}`);
  assert.doesNotMatch(publish, /--ignore-unfixed=true|--ignorefile|--ignore-policy|--vex/);


  assert.ok(publish.includes(`uses: ${ACTIONS.sbom}`));
  for (const required of [
    'format: spdx-json',
    'syft-version: v1.51.1',
    'SYFT_FILE_METADATA_SELECTION: none',
    "SYFT_RELATIONSHIPS_PACKAGE_FILE_OWNERSHIP: 'false'",
    'upload-artifact: false',
    'upload-release-assets: false',
    'SPDX-2.3',
    '((.packages // []) | length > 0)',
    '16777216',
  ]) {
    assert.ok(publish.includes(required), `SPDX contract missing: ${required}`);
  }
  assert.equal(count(publish, new RegExp(`uses: ${ACTIONS.attest}`, 'g')), 2);
  assert.equal(count(publish, /push-to-registry: true/g), 2);
  assert.equal(
    count(
      publish,
      /subject-name: 951034765053\.dkr\.ecr\.ap-northeast-1\.amazonaws\.com\/toybaco\/chatwoot/g,
    ),
    2,
  );
  assert.equal(count(publish, /gh attestation verify/g), 2);
  assert.equal(count(publish, /--cert-identity "\$identity"/g), 2);
  assert.equal(count(publish, /--source-digest "\$REPOSITORY_COMMIT"/g), 2);
  assert.equal(count(publish, /--source-ref refs\/heads\/main/g), 2);
  assert.equal(count(publish, /--deny-self-hosted-runners/g), 2);
  assert.ok(publish.includes('https://slsa.dev/provenance/v1'));
  assert.ok(publish.includes('https://spdx.dev/Document/v2.3'));
  assert.doesNotMatch(publish, /--signer-workflow|--signer-repo/);

  const controlFiles = functionBlock(gateSource, 'control_file_list', 'control_manifest');
  for (const required of ['config/chatwoot-runtime-gems.json', 'scripts/harden-chatwoot-runtime-gems.rb', 'tests/verify_chatwoot_runtime_gems.rb']) {
    assert.ok(controlFiles.includes(`'${required}'`), `runtime input missing from quality/export control: ${required}`);
  }
  for (const forbidden of [
    '.github/workflows/chatwoot-integration.yml',
    '.github/workflows/deploy-managed.yml',
    'scripts/publish-chatwoot-image.sh',
    'tests/verify_chatwoot_release_artifact.rb',
    'tests/verify_chatwoot_oci_archive.rb',
    'tests/verify_chatwoot_github_attestation.rb',
  ]) {
    assert.ok(!controlFiles.includes(forbidden), `parked release input remains in quality hash: ${forbidden}`);
  }
  for (const required of [
    "readonly CHATWOOT_SOURCE_TAG='v4.17.1'",
    "readonly CHATWOOT_SOURCE_TAG_OBJECT='e194a693e2dbf4ebae5f78a4d3b9bf6dd8b53ff1'",
    "readonly CHATWOOT_SOURCE_COMMIT='b354a9550e1fb59fa537a9c384232cb076213e72'",
    "readonly CHATWOOT_SOURCE_TREE='9a17426900d328a6acc2bdaecba0533e8b401120'",
    'assert_overlay_application',
    'find "$CONTROL_ROOT" -type d -exec chmod 0755 {} +',
    'find "$CONTROL_ROOT" -type f -exec chmod u=rwX,go=rX {} +',
    'chmod 0777 "$results"',
    'tests/chatwoot_full_japanese_test.rb',
    'Rake::Task["db:migrate"].invoke',
    'bundle exec rails db:toybaco_prepare',
    'bundle exec rspec',
    'tests/chatwoot-production-smoke.rb',
    'tests/chatwoot-http-smoke.rb',
    'bundle exec sidekiq -C config/sidekiq.yml',
    'DOCKER_BUILDKIT=1 docker build --no-cache --pull --platform linux/amd64',
    'test ! -e /app/tests/playwright',
    'test ! -e /app/node_modules',
    'test ! -e /usr/local/lib/node_modules/npm',
    'test ! -e /usr/local/bin/npm',
    'test ! -e /usr/local/bin/npx',
    'openjpeg-2.5.4-r0',
    'test ! -e /usr/lib/libopenjp2.so.2.5.2',
    'Fiddle::TYPE_VOIDP).call.to_s == %q{2.5.4}',
    'ruby /contract/tests/verify_chatwoot_runtime_gems.rb /contract/config/chatwoot-runtime-gems.json',
    'Rails.version == %q{7.2.3.2}',
    'Gem.loaded_specs.fetch(%q{ruby-vips}).version.to_s == %q{2.2.1}',
    '-ractive_storage/vips', 'ENV.fetch(%q{VIPS_BLOCK_UNTRUSTED}) == %q{1}',
    'Vips::Image.csvload(csv)', 'csvload: operation is blocked',


  ]) {
    assert.ok(gateSource.includes(required), `essential quality gate missing: ${required}`);
  }
  assert.match(gateSource, /^  verify_toybaco_database_prepare$/m);
  assert.match(gateSource, /^  run_ruby_quality$/m);
  assert.match(gateSource, /^  build_and_smoke_production_image$/m);
  assert.ok(
    gateSource.includes("fail '--artifact-dir release bundleはowner再baselineでpark済みです'"),
    'legacy artifact mode must fail closed',
  );
  assert.equal(count(gateSource, /^\s{2}publish_release_artifacts$/gm), 0);
  assert.equal(count(gateSource, /docker buildx build/g), 0);
}

validate(workflow, gate);
validatePostEntryNavigation(postEntry);
testPostEntryNavigation();

assert.throws(
  () => validatePostEntryNavigation(postEntry.replace(
    'placeEntry(now, buildEntry(now, id));',
    'now.ul.appendChild(buildEntry(now, id));',
  )),
  'post-entry end-append negative control was accepted',
);

assert.throws(
  () => validatePostEntryNavigation(postEntry.replace(
    'menu.ul.insertBefore(entry, menu.li.nextSibling);',
    '',
  )),
  'post-entry position-repair negative control was accepted',
);

const mutations = [
  [workflow.replace('--pkg-types os,library', '--pkg-types os'), gate],
  [workflow.replace('--severity CRITICAL,HIGH', '--severity CRITICAL'), gate],
  [workflow.replace('--ignore-unfixed=false', '--ignore-unfixed=true'), gate],
  [workflow.replace('--exit-code 1', '--exit-code 0'), gate],
  [workflow.replace('--config /dev/null sbom', '--config /repo/trivy.yaml sbom'), gate],
  [workflow.replace('--distro alpine/3.21.3', '--distro alpine/3.22'), gate],
  [workflow.replaceAll('trivy:0.67.2@sha256:ac2f9d0197456a8ce460884b113e49d65b667f506c31d014c9955869a7a5d682', 'trivy:latest'), gate],
  [workflow.replace('.checksumValue == $digest', 'true'), gate],
  [workflow.replace('.manifests == null', 'true'), gate],
  [workflow.replace('image: registry:', 'image: '), gate],
  [workflow.replace('.versionInfo == ("sha256:" + $digest)', 'true'), gate],
  [workflow.replace('.Class == "os-pkgs"', 'true'), gate],
  [workflow.replace('.Class == "lang-pkgs"', 'true'), gate],
  [workflow.replace('[[ "$scan_status" -eq 0 ]] || exit "$scan_status"', ':'), gate],
  [workflow.replace('--exit-code 1', '--exit-code 1 --vex /some/vex.json'), gate],
  [workflow.replace("      - 'config/chatwoot-runtime-gems.json'", ''), gate],
  [workflow.replace("      - 'scripts/harden-chatwoot-runtime-gems.rb'", ''), gate],
  [workflow, gate.replace("    'config/chatwoot-runtime-gems.json'", "    'config/missing-runtime.json'")],
  [workflow, gate.replace("    'scripts/harden-chatwoot-runtime-gems.rb'", "    'scripts/missing-runtime.rb'")],
  [workflow, gate.replace("    'tests/verify_chatwoot_runtime_gems.rb'", "    'tests/missing-runtime.rb'")],
  [workflow, gate.replace('test ! -e /app/tests/playwright', ':')],
  [workflow, gate.replace('test ! -e /app/node_modules', ':')],
  [workflow, gate.replace('test ! -e /usr/local/lib/node_modules/npm', ':')],
  [workflow, gate.replace('Rails.version == %q{7.2.3.2}', 'Rails.version == %q{7.2.2.2}')],
  [workflow, gate.replace('version.to_s == %q{2.2.1}', 'version.to_s == %q{2.2.0}')],
  [workflow, gate.replace('-ractive_storage/vips', '')],
  [workflow, gate.replace('Vips::Image.csvload(csv)', 'Vips::Image.black(1, 1)')],
  [workflow, gate.replace('ENV.fetch(%q{VIPS_BLOCK_UNTRUSTED}) == %q{1}', 'true')],
  [workflow, gate.replace('ruby /contract/tests/verify_chatwoot_runtime_gems.rb', 'ruby /contract/tests/not-run.rb')],
  [workflow, gate.replace('Fiddle::TYPE_VOIDP).call.to_s == %q{2.5.4}', 'Fiddle::TYPE_VOIDP).call.to_s == %q{2.5.2}')],
  [workflow.replace('needs: quality', 'needs: []'), gate],
  [workflow.replace(
    `if [[ "$REQUEST_REF_TYPE" != 'branch' || "$REQUEST_REF" != 'refs/heads/main' ]]; then`,
    'if false; then',
  ), gate],
  [workflow.replace('name: chatwoot-production', 'name: staging'), gate],
  [workflow.replace('--push .', '.'), gate],
  [workflow.replace('PENDING|IN_PROGRESS', 'IN_PROGRESS'), gate],
  [workflow.replace(`uses: ${ACTIONS.sbom}`, 'uses: anchore/sbom-action@main'), gate],
  [workflow.replace('SYFT_FILE_METADATA_SELECTION: none', 'SYFT_FILE_METADATA_SELECTION: all'), gate],
  [workflow.replace(
    "SYFT_RELATIONSHIPS_PACKAGE_FILE_OWNERSHIP: 'false'",
    "SYFT_RELATIONSHIPS_PACKAGE_FILE_OWNERSHIP: 'true'",
  ), gate],
  [workflow.replace('((.packages // []) | length > 0)', 'true'), gate],
  [workflow.replace('--cert-identity "$identity"', '--signer-workflow "$identity"'), gate],
  [workflow.replace(
    'ruby tests/verify_chatwoot_overlay_manifest.rb verify . tests/chatwoot-overlay-manifest.tsv',
    'true',
  ), gate],
  [workflow.replace(
    'docker buildx build --no-cache --pull --platform linux/amd64',
    'docker buildx build --no-cache --pull --platform linux/amd64\n          docker buildx build',
  ), gate],
  [workflow.replace(
    'docker buildx version',
    'docker buildx version\n          ./scripts/publish-chatwoot-image.sh',
  ), gate],
  [workflow, gate.replace('  run_ruby_quality\n', '  : # RSpec quality removed\n')],
  [workflow, gate.replace('  verify_toybaco_database_prepare\n', '  : # database prepare regression removed\n')],
  [workflow, gate.replace(
    '  find "$CONTROL_ROOT" -type d -exec chmod 0755 {} +\n',
    '',
  )],
  [workflow, gate.replace(
    '  find "$CONTROL_ROOT" -type f -exec chmod u=rwX,go=rX {} +\n',
    '',
  )],
  [workflow, gate.replace('  chmod 0777 "$results"\n', '')],
  [workflow, gate.replace(
    "fail '--artifact-dir release bundleはowner再baselineでpark済みです'",
    'ARTIFACT_DIR="$2"',
  )],
  [workflow, gate.replace(
    "    'tests/verify_chatwoot_rspec_result.rb'",
    "    'tests/verify_chatwoot_rspec_result.rb' \\\n+    'scripts/publish-chatwoot-image.sh'",
  )],
];

for (const [index, [mutatedWorkflow, mutatedGate]] of mutations.entries()) {
  assert.throws(
    () => validate(mutatedWorkflow, mutatedGate),
    `negative control was accepted: ${index + 1}`,
  );
}

console.log(
  `Chatwoot managed publisher: PASS (${mutations.length} publisher + 2 post-entry negative controls)`,
);

// Execute the exact publisher shell with synthetic SPDX/reports and a Docker
// stand-in. These are policy regressions, not a replacement for a real scan.
function stepRun(source, name) {
  const marker = `      - name: ${name}\n`;
  const start = source.indexOf(marker);
  assert.ok(start >= 0);
  const end = source.indexOf('\n      - name:', start + marker.length);
  const step = source.slice(start, end < 0 ? source.length : end);
  const runStart = step.indexOf('        run: |\n');
  assert.ok(runStart >= 0);
  return step.slice(runStart + '        run: |\n'.length)
    .split('\n').map(line => line.startsWith('          ') ? line.slice(10) : line).join('\n');
}
const bindingRun = stepRun(workflow, 'SPDX SBOMの形式と上限を確認');
const scanRun = stepRun(workflow, '固定Trivyで同digest SBOMのOS・言語 Critical/Highゼロを確認');
const imageName = '951034765053.dkr.ecr.ap-northeast-1.amazonaws.com/toybaco/chatwoot';
const digest = 'sha256:' + 'a'.repeat(64);
function sbomFixture() {
  return { spdxVersion: 'SPDX-2.3', SPDXID: 'SPDXRef-DOCUMENT',
    relationships: [{ spdxElementId: 'SPDXRef-DOCUMENT', relationshipType: 'DESCRIBES', relatedSpdxElement: 'SPDXRef-Image' }],
    packages: [
      { SPDXID: 'SPDXRef-Image', name: imageName, primaryPackagePurpose: 'CONTAINER',
        versionInfo: digest, checksums: [{ algorithm: 'SHA256', checksumValue: 'a'.repeat(64) }] },
      { SPDXID: 'SPDXRef-Alpine', name: 'alpine-baselayout', externalRefs: [
        { referenceType: 'purl', referenceLocator: 'pkg:apk/alpine/alpine-baselayout@3.6.8-r1?arch=x86_64&distro=alpine-3.21.3' },
      ] },
    ] };
}
function reportFixture() {
  return { Metadata: { OS: { Family: 'alpine', Name: '3.21.3' } }, Results: [
    { Class: 'os-pkgs', Packages: [{ Name: 'openjpeg', Version: '2.5.4-r0' }], Vulnerabilities: [] },
    { Class: 'lang-pkgs', Packages: [{ Name: 'rails', Version: '7.2.3.2' }], Vulnerabilities: [] },
  ] };
}
function executePolicy(label, change, expected) {
  const directory = mkdtempSync(join(tmpdir(), 'toybaco-cw-sbom-policy-'));
  try {
    const sbom = sbomFixture(), report = reportFixture();
    const settings = { scannerExit: 0 };
    change(sbom, report, settings);
    const bin = join(directory, 'bin'); mkdirSync(bin);
    // GNU stat is used by Ubuntu; the stand-in keeps the exact shell portable.
    writeFileSync(join(bin, 'stat'), `#!/bin/sh\nexec '${process.execPath}' -e 'console.log(require("node:fs").statSync(process.argv[1]).size)' "$3"\n`, { mode: 0o755 });
    writeFileSync(join(bin, 'docker'), '#!/bin/sh\nset -eu\ncase "$1" in\n  pull) exit 0 ;;\n  run) cp "$TOYBACO_TEST_REPORT" "$RUNNER_TEMP/chatwoot-trivy-output/report.json"; exit "$TOYBACO_TEST_SCANNER_EXIT" ;;\n  *) exit 97 ;;\nesac\n', { mode: 0o755 });
    writeFileSync(join(directory, 'toybaco-chatwoot.spdx.json'), JSON.stringify(sbom));
    const reportPath = join(directory, 'scanner-report.json'); writeFileSync(reportPath, JSON.stringify(report));
    const result = spawnSync('bash', ['-c', `${bindingRun}\n${scanRun}`], {
      encoding: 'utf8', timeout: 10000,
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, RUNNER_TEMP: directory,
        IMAGE_DIGEST: digest, ECR_REPOSITORY: imageName,
        TRIVY_IMAGE: 'docker.io/aquasec/trivy:0.67.2@sha256:ac2f9d0197456a8ce460884b113e49d65b667f506c31d014c9955869a7a5d682',
        TOYBACO_TEST_REPORT: reportPath, TOYBACO_TEST_SCANNER_EXIT: String(settings.scannerExit) },
    });
    assert.equal(result.error, undefined, `${label}: ${result.error}`);
    assert.equal(result.status === 0, expected, `${label}: ${result.stdout}${result.stderr}`);
  } finally { rmSync(directory, { recursive: true, force: true }); }
}
executePolicy('registry source and cataloged manifest use the exact digest', () => {}, true);
for (const [label, change] of [
  ['wrong manifest checksum', sbom => { sbom.packages[0].checksums[0].checksumValue = 'c'.repeat(64); }],
  ['wrong requested digest', sbom => { sbom.packages[0].versionInfo = 'sha256:' + 'b'.repeat(64); }],
  ['versionInfo alone cannot bind manifest', sbom => { sbom.packages[0].versionInfo = digest; sbom.packages[0].checksums = []; }],
  ['wrong repository', sbom => { sbom.packages[0].name = 'other/image'; }],
  ['no described image', sbom => { sbom.relationships = []; }],
  ['ambiguous described images', sbom => { sbom.relationships.push({ ...sbom.relationships[0], relatedSpdxElement: 'other' }); }],
  ['wrong distro', sbom => { sbom.packages[1].externalRefs[0].referenceLocator = 'pkg:apk/alpine/a@1?distro=alpine-3.22'; }],
  ['distro prefix is not exact identity', sbom => { sbom.packages[1].externalRefs[0].referenceLocator = 'pkg:apk/alpine/a@1?distro=alpine-3.21.30'; }],
  ['missing OS coverage', (_sbom, report) => { report.Results.shift(); }],
  ['missing language coverage', (_sbom, report) => { report.Results.pop(); }],
  ['empty package scan', (_sbom, report) => { report.Results[0].Packages = []; }],
  ['scanner failed despite empty findings', (_sbom, _report, settings) => { settings.scannerExit = 2; }],
  ['unfixed High is still rejected', (_sbom, report) => { report.Results[1].Vulnerabilities = [{ Severity: 'HIGH', FixedVersion: '' }]; }],
  ['Critical is rejected', (_sbom, report) => { report.Results[0].Vulnerabilities = [{ Severity: 'CRITICAL', FixedVersion: 'fixed' }]; }],
]) executePolicy(label, change, false);
console.log('Chatwoot exact SBOM/scan shell: PASS (1 positive / 14 negative controls; no external calls)');
