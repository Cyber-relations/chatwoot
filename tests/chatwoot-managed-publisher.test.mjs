#!/usr/bin/env node

// The publisher contract for both repositories. The private repository keeps its publisher parked after the
// public repository migration; the public repository (Cyber-relations/chatwoot) publishes. This file is a gate
// control file, so the public sync carries it with the evaluator and catalog it checks: a policy change updates
// both repositories' contract in the same review. The repository comes from the workflow's attestation identity,
// which must equal GitHub's repository name, never from the publish condition, so removing the private
// `false &&` cannot switch this contract to the public rules. Each repository's quality job runs it as a plain
// step whose name is pinned per repository (private: 非公開publisher契約を検証, public: 公開publisher契約を検証).
// Each run also transforms its own workflow into the other mode by the reviewed differences, checks that the
// reverse transformation restores it exactly, and applies the other mode's rules to the result:
// 自己変換の整合性(逆変換で元に戻る)と共有規則の検査. It does not check the other repository's actual file; that
// repository's CI runs this contract on its own.
//
// Run from the repository root with GitHub's repository name (CI sets it; set it yourself for a local run):
//   GITHUB_REPOSITORY=Cyber-relations/toybaco node tests/chatwoot-managed-publisher.test.mjs .
// (Cyber-relations/chatwoot in the public repository.) Any other or missing name fails. The private Postiz gate runs
// this contract in its fixed container and forwards the name from its own environment as is (checked below).

import assert from 'node:assert/strict';
import { readFileSync, realpathSync, writeFileSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

// The tree under test is the one this file belongs to. The argument (or the working directory) must name that
// same tree, so this contract cannot be pointed at another checkout.
const root = realpathSync(fileURLToPath(new URL('..', import.meta.url)));
assert.equal(realpathSync(resolve(process.argv[2] || '.')), root,
  'run this contract on its own repository root: node tests/chatwoot-managed-publisher.test.mjs .');
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

// The two repositories' workflows differ only in the attestation identity, the publish condition and job name,
// and the name of the quality step that runs this contract (plus push paths for private-only tests).
const REPOSITORIES = Object.freeze({
  private: Object.freeze({ name: 'Cyber-relations/toybaco', publishName: '公開repoへ移管済み（常時停止）' }),
  public: Object.freeze({ name: 'Cyber-relations/chatwoot', publishName: 'reviewed mainからbuild・scan・署名・ECR公開' }),
});
const PUBLISH_CONDITION = Object.freeze({
  private: "    if: >-\n      false &&\n      ((github.event_name == 'push' && github.ref == 'refs/heads/main') ||\n" +
    "      (github.event_name == 'workflow_dispatch' && inputs.publish_reviewed_main))\n",
  public: "    if: >-\n      (github.event_name == 'push' && github.ref == 'refs/heads/main') ||\n" +
    "      (github.event_name == 'workflow_dispatch' && inputs.publish_reviewed_main)\n",
});
const CLASSIFIER_STEP = '      - name: 実image backport分類の否定契約を検証\n' +
  '        run: node tests/chatwoot-ruby-llm-classification.test.mjs .\n';
// Push path filters only the private repository's workflow has (its private-only tests), and where they sit.
const PRIVATE_ONLY_PATHS = Object.freeze(['config/toybaco-plans.json', 'scripts/generate-plan-catalog.py',
  'tests/toybaco_plan_catalog_test.rb', 'tests/toybaco_billing_subscription_test.rb',
  'tests/toybaco_subscription_sync_test.rb', 'tests/toybaco_ai_usage_test.rb']);
const pathLines = paths => paths.map(path => `      - '${path}'\n`).join('');
const PUSH_PATH_BLOCKS = Object.freeze([
  Object.freeze({ public: pathLines(['overlay/app/**']), private: pathLines(['overlay/app/**', ...PRIVATE_ONLY_PATHS.slice(0, 1)]) }),
  Object.freeze({ public: pathLines(['scripts/harden-chatwoot-runtime-gems.rb']),
    private: pathLines(['scripts/harden-chatwoot-runtime-gems.rb', ...PRIVATE_ONLY_PATHS.slice(1)]) }),
]);
const ECR_SUBJECT = '951034765053.dkr.ecr.ap-northeast-1.amazonaws.com/toybaco/chatwoot';
const CONTRACT_RUN = 'node tests/chatwoot-managed-publisher.test.mjs .';
const CONTRACT_STEP_NAME = Object.freeze({ private: '非公開publisher契約を検証', public: '公開publisher契約を検証' });
const contractStep = mode => `      - name: ${CONTRACT_STEP_NAME[mode]}\n        run: ${CONTRACT_RUN}\n`;
const otherMode = mode => (mode === 'private' ? 'public' : 'private');

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

function swapOnce(source, from, to, label) {
  assert.equal(source.split(from).length - 1, 1, `${label}: expected exactly one occurrence`);
  return source.replace(from, () => to);
}

// Every repository the workflow names, as whole tokens whatever the owner. The identity is its own shell line.
// Repository arguments are gh's --repo / --owner / --signer-repo / --signer-workflow anywhere, gh's short -R / -o
// on a gh command line (other commands' -R / -o are not repositories), GH_REPO and a `repository:` key; each
// attestation check is one `gh attestation verify` command line. URLs are github.com / githubusercontent.com
// <owner>/<repo>. Action `uses:` pins are ACTIONS.
const REPOSITORY_FLAG = /(?<![\w-])(?:--repo|--owner|--signer-repo|--signer-workflow)(?![\w-])["']?(?:[ \t]+|=)["']?([^\s"']+)/g;
const SHORT_REPOSITORY_FLAG = /(?<![\w-])-[Ro](?:["']?(?:[ \t]+|=)["']?|(?=[^\s"'=]))([^\s"']+)/g;
const REPOSITORY_KEY = /(?<![\w-])(?:GH_REPO|repository)["']?(?::\s*|=)["']?([^\s"']+)/g;
function repositoryReferences(workflowSource) {
  const values = (source, pattern) => [...source.matchAll(pattern)].map(match => match[1]);
  const ghCommands = [...workflowSource.matchAll(/(?<![\w.-])gh[ \t](?:[^\n]*\\\n)*[^\n]*/g)].map(match => match[0]);
  const repositoryFlags = command => [...values(command, REPOSITORY_FLAG), ...values(command, SHORT_REPOSITORY_FLAG)];
  return {
    identities: values(workflowSource,
      /^[ \t]*identity='https:\/\/github\.com\/([^/'\s]+\/[^/'\s]+)\/\.github\/workflows\/chatwoot-integration\.yml@refs\/heads\/main'[ \t]*$/gm),
    checks: ghCommands.filter(command => /^gh[ \t]+attestation[ \t]+verify[ \t]/.test(command)).map(repositoryFlags),
    arguments: [
      ...values(workflowSource, REPOSITORY_FLAG),
      ...ghCommands.flatMap(command => values(command, SHORT_REPOSITORY_FLAG)),
      ...values(workflowSource, REPOSITORY_KEY),
    ],
    urls: values(workflowSource, /(?:github|githubusercontent)\.com\/([\w.-]+\/[\w.-]+)/g),
    subjects: values(workflowSource, /^[ \t]*subject-name:[ \t]*(\S+)[ \t]*$/gm),
  };
}

// The repository whose workflow this is: one attestation identity of the two repositories, that repository named
// exactly once by each of the four attestation checks and by no other repository argument or URL, and the attested
// image as the only subject. `repository` is GitHub's repository name and must be one of the two and this
// workflow's; null only marks a workflow this contract derived itself (counterpartWorkflow).
function repositoryMode(workflowSource, repository) {
  const references = repositoryReferences(workflowSource);
  assert.equal(references.identities.length, 1, 'the workflow must have exactly one attestation identity line');
  const [identity] = references.identities;
  const mode = Object.keys(REPOSITORIES).find(key => REPOSITORIES[key].name === identity);
  assert.ok(mode, `the attestation identity must be one of the two repositories: ${identity}`);
  assert.deepEqual(references.checks, Array(4).fill([identity]), 'every attestation check must name this repository once');
  assert.deepEqual(references.arguments, Array(4).fill(identity), 'no other repository argument may be given');
  assert.deepEqual(references.urls, [identity], 'no other repository may be named');
  assert.equal(count(workflowSource, /Cyber-relations\//g), 5, 'no other repository of the organization may be named');
  assert.deepEqual(references.subjects, Array(4).fill(ECR_SUBJECT), 'every attestation subject must be the published image');
  if (repository === null) return mode;
  assert.ok(Object.values(REPOSITORIES).some(({ name }) => name === repository),
    `GITHUB_REPOSITORY must be Cyber-relations/toybaco or Cyber-relations/chatwoot: ${JSON.stringify(repository)}`);
  assert.equal(repository, REPOSITORIES[mode].name, 'the workflow attestation identity must be this repository');
  return mode;
}

// This workflow transformed into the other mode by the reviewed differences: the publish condition and job name,
// the attestation identity, the contract step name and the private-only push paths. It is not the other
// repository's actual file: 自己変換の整合性(逆変換で元に戻る)と共有規則の検査.
function counterpartWorkflow(source, mode) {
  const target = otherMode(mode);
  let derived = swapOnce(source, PUBLISH_CONDITION[mode], PUBLISH_CONDITION[target], 'publish condition');
  for (const block of PUSH_PATH_BLOCKS) derived = swapOnce(derived, block[mode], block[target], 'push paths');
  derived = swapOnce(derived, `    name: ${REPOSITORIES[mode].publishName}\n`, `    name: ${REPOSITORIES[target].publishName}\n`,
    'publish job name');
  derived = derived.replaceAll(REPOSITORIES[mode].name, REPOSITORIES[target].name);
  return swapOnce(derived, contractStep(mode), contractStep(target), 'publisher contract step');
}

function validate(workflowSource, gateSource, { repository = process.env.GITHUB_REPOSITORY } = {}) {
  const mode = repositoryMode(workflowSource, repository);
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

  assert.ok(publish.startsWith(`  publish:\n${PUBLISH_CONDITION[mode]}    needs: quality\n    name: ${REPOSITORIES[mode].publishName}\n`),
    `${mode} publisher condition and name must be exactly the reviewed ones`);
  if (mode === 'private') {
    assert.ok(
      publish.includes('false &&'),
      'private repository publisher must remain fail-closed after public repository migration',
    );
    assert.ok(
      publish.includes("(github.event_name == 'push' && github.ref == 'refs/heads/main') ||"),
      'parked publisher source must document its former main-only condition',
    );
    assert.ok(
      publish.includes(
        "(github.event_name == 'workflow_dispatch' && inputs.publish_reviewed_main)",
      ),
      'parked publisher source must document its former manual condition',
    );
  } else {
    assert.ok(!publish.includes('false &&'), 'public repository publisher must stay reachable');
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
  }
  // Push paths: the private-only filters exist only in the private workflow.
  for (const path of PRIVATE_ONLY_PATHS) {
    assert.equal(count(workflowSource, new RegExp(`^      - '${path.replaceAll('.', '\\.')}'$`, 'gm')), mode === 'private' ? 1 : 0,
      `${mode} push paths: ${path}`);
  }
  // No defaults (working directory, shell) for the workflow or the quality job, and only the reviewed job keys.
  assert.deepEqual([...workflowSource.matchAll(/^([a-z-]+):/gm)].map(match => match[1]),
    ['name', 'on', 'concurrency', 'permissions', 'jobs'], 'workflow keys: no workflow defaults or env');
  assert.doesNotMatch(quality, /^    defaults:/m, 'the quality job must not set defaults');
  assert.deepEqual([...quality.matchAll(/^    ([a-z-]+):/gm)].map(match => match[1]),
    ['if', 'name', 'runs-on', 'timeout-minutes', 'permissions', 'steps'], 'quality job keys');
  // This contract runs once, as a plain quality step: exactly its pinned name and run line, with no condition,
  // tolerance or limit, in a quality job that tolerates no failure.
  assert.equal(workflowSource.split(CONTRACT_RUN).length - 1, 1, 'this publisher contract must run exactly once');
  const contractMarker = `      - name: ${CONTRACT_STEP_NAME[mode]}\n`;
  const contractStart = quality.indexOf(contractMarker);
  assert.ok(contractStart >= 0, `${mode} CI must run this publisher contract`);
  const contractEnd = quality.indexOf('\n      - ', contractStart + contractMarker.length);
  const contractBlock = quality.slice(contractStart, contractEnd < 0 ? quality.length : contractEnd + 1).replace(/\n+$/, '\n');
  assert.equal(contractBlock, contractStep(mode), 'the publisher contract step must be exactly its name and run line');
  assert.doesNotMatch(quality, /continue-on-error/, 'the quality job must not tolerate failures');
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
    '--build-arg "TOYBACO_PUBLIC_REVISION=$REPOSITORY_COMMIT"',
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
    'CHATWOOT_SOURCE_TAG: v4.18.0',
    'CHATWOOT_SOURCE_TAG_OBJECT: 5c1487713ff2ea407188855211533a1e30e24589',
    'CHATWOOT_SOURCE_COMMIT: 9f920b549c14491a4e587687a3eed5d21c6ccc7d',
    'CHATWOOT_SOURCE_TREE: 16432eeeef9153f7aff66be382e04a20e6f5683a',
    'CHATWOOT_BASE_IMAGE: chatwoot/chatwoot@sha256:03a03a85a00f1d119367deb0d090a56e553468d0aa5e9194a57eba7c61deb7de',
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
  const trivyIndex = publish.indexOf('固定Trivyの生結果と実imageのRubyLLM backportを検証');
  assert.ok(publish.indexOf('SPDX SBOMの形式と上限を確認') < trivyIndex &&
    trivyIndex < publish.indexOf('SLSA provenanceを署名してOCIへ保存'),
    'exact raw scan and independent backport proof must precede all attestations');
  for (const required of [
    'TRIVY_IMAGE: docker.io/aquasec/trivy:0.67.2@sha256:ac2f9d0197456a8ce460884b113e49d65b667f506c31d014c9955869a7a5d682',
    '--pkg-types os,library', '--severity CRITICAL,HIGH', '--ignore-unfixed=false',
    '--distro alpine/3.21.3', '--exit-code 1 --list-all-pkgs', '--config /dev/null sbom',
    '--network none --workdir /scan', '"$TRIVY_IMAGE"', 'toybaco-chatwoot.spdx.json',
    '.checksumValue == $digest', '.relationshipType == "DESCRIBES"',
    'image: registry:${{ steps.build.outputs.image_uri }}',
    '.versionInfo == ("sha256:" + $digest)', 'distro=alpine-3.21.3',
    '--config /dev/null image --download-db-only --no-progress',
    '--skip-db-update --skip-java-db-update --offline-scan',
    'src=$security/db,dst=/root/.cache/trivy/db"',
    'scripts/verify-chatwoot-ruby-llm-classification.mjs snapshot-before',
    'scripts/verify-chatwoot-ruby-llm-classification.mjs snapshot-after',
    'scripts/verify-chatwoot-ruby-llm-classification.mjs evaluate',
    'scripts/verify-chatwoot-ruby-llm-classification.mjs verify-attestations',
    'printf \'%s\\n\' "$scan_status" > "$security/raw-exit.txt"',
    'docker image inspect "$ECR_REPOSITORY@$IMAGE_DIGEST"',
    '--platform linux/amd64 --network none --read-only',
    '--cap-drop ALL --security-opt no-new-privileges --workdir /app --entrypoint ruby',
    '-rbundler/setup /contract/tests/verify_chatwoot_ruby_llm_backport.rb /contract/config/chatwoot-ruby-llm-backport.json',
    '> "$security/installed-proof.json"',
    'predicate-type: https://openvex.dev/ns/v0.2.0',
    'predicate-type: https://toybaco.jp/attestations/chatwoot-ruby-llm-backport/v1',
    'predicate-path: ${{ runner.temp }}/chatwoot-source-backport/openvex.json',
    'predicate-path: ${{ runner.temp }}/chatwoot-source-backport/source-backport-classification.json',
  ]) assert.ok(publish.includes(required), `strict source-backport contract missing: ${required}`);
  const databaseCopyContracts = [
    'frozen="$security/frozen-source"',
    'mkdir -m 0700 "$frozen"',
    '--mount "type=bind,src=$frozen,dst=/root/.cache/trivy"',
    '"$frozen" config/chatwoot-ruby-llm-backport.json',
    'mkdir -m 0700 "$security/db"',
    'cp -- "$frozen/db/trivy.db" "$frozen/db/metadata.json" "$security/db/"',
    'cmp -- "$frozen/db-before.json" "$security/db-before.json"',
    '--mount "type=bind,src=$security/db,dst=/root/.cache/trivy/db"',
    'cmp -- "$frozen/db-before.json" "$frozen/db-after.json"',
    'cmp -- "$frozen/db-after.json" "$security/db-after.json"',
    'scripts/verify-chatwoot-ruby-llm-classification.mjs evaluate',
  ];
  const databaseCopyPositions = databaseCopyContracts.map(contract => publish.indexOf(contract));
  assert.ok(databaseCopyPositions.every(index => index >= 0), 'frozen original / actual scan copy proof missing');
  assert.deepEqual([...databaseCopyPositions].sort((a, b) => a - b), databaseCopyPositions,
    'copy and equality checks must surround the raw scan before classification');
  const rawScan = publish.slice(publish.indexOf('docker run --rm --network none --workdir /scan'),
    publish.indexOf('|| scan_status=$?'));
  assert.ok(rawScan.includes('src=$security/db,dst=/root/.cache/trivy/db"'));
  assert.ok(!rawScan.includes('$frozen'), 'frozen source must never be mounted into the scanner');
  assert.ok(!rawScan.includes('dst=/root/.cache/trivy/db,readonly'), 'pinned bbolt requires a writable scan copy');
  assert.equal(count(publish, /scripts\/verify-chatwoot-ruby-llm-classification\.mjs snapshot-before/g), 2, 'snapshot original and scanned copy before scan');
  assert.equal(count(publish, /scripts\/verify-chatwoot-ruby-llm-classification\.mjs snapshot-after/g), 2, 'snapshot original and scanned copy after scan');
  assert.equal(count(publish, /--config \/dev\/null sbom/g), 1, 'one raw pinned scanner invocation');
  assert.equal(count(publish, /--download-db-only/g), 1, 'one fresh DB download');
  assert.equal(count(publish, /--cert-oidc-issuer 'https:\/\/token\.actions\.githubusercontent\.com'/g), 4);
  assert.doesNotMatch(publish, /--ignore-unfixed=true|--ignorefile|--ignore-policy|--vex|--skip-files|--skip-dirs|--ignore-status/);
  for (const name of ['config/chatwoot-ruby-llm-backport.json', 'scripts/harden-chatwoot-ruby-llm.rb',
    'scripts/verify-chatwoot-ruby-llm-classification.mjs', 'docs/chatwoot-ruby-llm-backport-policy.md']) {
    assert.ok(workflowSource.includes("      - '" + name + "'"), 'backport push path missing: ' + name);
  }
  assert.ok(quality.includes('node tests/chatwoot-ruby-llm-classification.test.mjs .'));

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
  assert.equal(count(publish, new RegExp(`uses: ${ACTIONS.attest}`, 'g')), 4);
  assert.equal(count(publish, /push-to-registry: true/g), 4);
  assert.equal(
    count(
      publish,
      /subject-name: 951034765053\.dkr\.ecr\.ap-northeast-1\.amazonaws\.com\/toybaco\/chatwoot/g,
    ),
    4,
  );
  assert.equal(count(publish, /gh attestation verify/g), 4);
  assert.equal(count(publish, /--cert-identity "\$identity"/g), 4);
  assert.equal(count(publish, /--source-digest "\$REPOSITORY_COMMIT"/g), 4);
  assert.equal(count(publish, /--source-ref refs\/heads\/main/g), 4);
  assert.equal(count(publish, /--deny-self-hosted-runners/g), 4);
  assert.ok(publish.includes('https://slsa.dev/provenance/v1'));
  assert.ok(publish.includes('https://spdx.dev/Document/v2.3'));
  assert.doesNotMatch(publish, /--signer-workflow|--signer-repo/);

  const controlFiles = functionBlock(gateSource, 'control_file_list', 'control_manifest');
  for (const required of ['config/chatwoot-runtime-gems.json', 'scripts/harden-chatwoot-runtime-gems.rb', 'tests/verify_chatwoot_runtime_gems.rb', 'config/chatwoot-ruby-llm-backport.json', 'scripts/harden-chatwoot-ruby-llm.rb', 'tests/verify_chatwoot_ruby_llm_backport.rb', 'tests/chatwoot_ruby_llm_backport_test.rb', 'scripts/verify-chatwoot-ruby-llm-classification.mjs', 'tests/chatwoot-ruby-llm-classification.test.mjs', 'docs/chatwoot-ruby-llm-backport-policy.md', 'tests/chatwoot-managed-publisher.test.mjs']) {
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
    "readonly CHATWOOT_SOURCE_TAG='v4.18.0'",
    "readonly CHATWOOT_SOURCE_TAG_OBJECT='5c1487713ff2ea407188855211533a1e30e24589'",
    "readonly CHATWOOT_SOURCE_COMMIT='9f920b549c14491a4e587687a3eed5d21c6ccc7d'",
    "readonly CHATWOOT_SOURCE_TREE='16432eeeef9153f7aff66be382e04a20e6f5683a'",
    'assert_overlay_application',
    'find "$CONTROL_ROOT" -type d -exec chmod 0755 {} +',
    'find "$CONTROL_ROOT" -type f -exec chmod u=rwX,go=rX {} +',
    'chmod 0777 "$results"',
    'tests/chatwoot_full_japanese_test.rb',
    'tests/chatwoot_checkout_session_test.rb',
    'tests/chatwoot_billing_plan_names_test.rb',
    'tests/chatwoot_ai_reply_mode_test.rb',
    'Rake::Task["db:migrate"].invoke',
    'bundle exec rails db:toybaco_prepare',
    'bundle exec rspec',
    'tests/chatwoot-production-smoke.rb',
    'tests/chatwoot-http-smoke.rb',
    'bundle exec sidekiq -C config/sidekiq.yml',
    'DOCKER_BUILDKIT=1 docker build --no-cache --pull --platform linux/amd64',
    'grep -Fq "libexpat=2.9.0-r0" "$CONTROL_ROOT/Dockerfile"',
    'test ! -e /usr/lib/libexpat.so.1.12.3',
    'test ! -e /usr/lib/libexpat.so.1.12.4',
    'Fiddle::TYPE_VOIDP).call.to_s == %q{expat_2.9.0}',
    "grep -Fq \"'tiff=4.7.2-r0'\" \"$CONTROL_ROOT/Dockerfile\"",
    'tiff-4.7.2-r0',
    'Fiddle.dlopen(%q{libtiff.so.6})[%q{TIFFGetVersion}]',
    'Fiddle::TYPE_VOIDP).call.to_s.lines.first.chomp == %q{LIBTIFF, Version 4.7.2}',
    '"$PRODUCTION_IMAGE" sh -c \'\n      set -e\n',
    'assert_single_exact_line "$CONTROL_ROOT/.dockerignore" \'overlay/app/spec\'',
    'test ! -e /app/spec',
    'test ! -e /app/tests/playwright',
    'test ! -e /app/node_modules',
    'test ! -e /usr/local/lib/node_modules/npm',
    'test ! -e /usr/local/bin/npm',
    'test ! -e /usr/local/bin/npx',
    'openjpeg-2.5.4-r1',
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
  assert.ok(gateSource.includes('"$TEST_IMAGE" /app/bin/toybaco-chatwoot-schema-preflight'));
  assert.ok(gateSource.includes('--env TOYBACO_CHATWOOT_SCHEMA_REQUIRE_TARGET=true'));
  assert.match(gateSource, /^  run_ruby_quality$/m);
  assert.match(gateSource, /^  build_and_smoke_production_image$/m);
  assert.ok(
    gateSource.includes("fail '--artifact-dir release bundleはowner再baselineでpark済みです'"),
    'legacy artifact mode must fail closed',
  );
  assert.equal(count(gateSource, /^\s{2}publish_release_artifacts$/gm), 0);
  assert.equal(count(gateSource, /docker buildx build/g), 0);
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
  // The native group uses a role=button div when expanded and a button when
  // collapsed. Without that group, the remaining inbox link is the fallback.
  for (const conversationTag of [null, 'DIV', 'BUTTON']) {
    const postingFirst = makeRow('posting');
    postingFirst.getAttribute = (name) =>
      name === 'data-toybaco-post-entry-wrap' ? '1' : null;
    const inbox = makeRow('inbox');
    const conversations = makeRow('conversations');
    const primaryList = makeList([postingFirst, inbox, conversations]);
    const inboxInner = {
      tagName: 'A',
      getAttribute: (name) => ({
        title: '通知', href: '/app/accounts/1/inbox-view',
      })[name] ?? null,
    };
    const conversationInner = conversationTag && {
      tagName: conversationTag,
      getAttribute: (name) => ({
        title: '会話', role: conversationTag === 'DIV' ? 'button' : null,
      })[name] ?? null,
    };
    for (const [row, inner] of [[inbox, inboxInner], [conversations, conversationInner]]) {
      row.children = inner ? [inner] : [];
      row.querySelector = (selector) => inner && selector.split(',').some((part) =>
        part.trim() === inner.tagName.toLowerCase() ||
        (part.trim() === '[role="button"]' && inner.getAttribute('role') === 'button'))
        ? inner : null;
    }
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
    assert.ok(menu, 'native conversation controls must yield a navigation sample');
    assert.equal(menu.li, conversationTag ? conversations : inbox,
      'the conversation parent must outrank the notification link and injected posting row');
    assert.equal(menu.inner, conversationInner || inboxInner);
    fixture.api.placeEntry(menu, postingFirst);
    assert.deepEqual(primaryList.children.map((row) => row.name), conversationTag
      ? ['inbox', 'conversations', 'posting']
      : ['inbox', 'posting', 'conversations']);
    assert.equal(primaryList.insertCalls, 1, 'posting-first drift must be repaired once');
    fixture.api.placeEntry(menu, postingFirst);
    assert.equal(primaryList.insertCalls, 1, 'correct repeated placement must not mutate the DOM');
  }

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

function validateBackportBuild(dockerfile, testDockerfile, ignore, gateSource) {
  const copies = [
    'COPY config/chatwoot-ruby-llm-backport.json /opt/toybaco/config/',
    'COPY scripts/harden-chatwoot-ruby-llm.rb /opt/toybaco/scripts/',
    'COPY tests/verify_chatwoot_ruby_llm_backport.rb /opt/toybaco/tests/',
  ];
  for (const text of copies) {
    assert.ok(dockerfile.includes(text), 'production backport input missing: ' + text);
    assert.ok(testDockerfile.includes(text), 'test backport input missing: ' + text);
  }
  const apply = 'bundle exec ruby /opt/toybaco/scripts/harden-chatwoot-ruby-llm.rb apply';
  const verify = 'bundle exec ruby /opt/toybaco/tests/verify_chatwoot_ruby_llm_backport.rb';
  assert.equal(dockerfile.split(apply).length - 1, 1, 'one production gem patch application');
  assert.equal(testDockerfile.split(apply).length - 1, 1, 'one test gem patch application');
  assert.equal(dockerfile.split(verify).length - 1, 2, 'bundled and final production proof');
  assert.equal(testDockerfile.split(verify).length - 1, 1, 'test gem proof');
  assert.ok(dockerfile.indexOf('bundle clean --force') < dockerfile.indexOf(apply));
  assert.ok(dockerfile.lastIndexOf(verify) > dockerfile.indexOf('/app/TOYBACO_PUBLIC_REVISION'));
  for (const path of ['config/chatwoot-ruby-llm-backport.json', 'scripts/harden-chatwoot-ruby-llm.rb',
    'tests/verify_chatwoot_ruby_llm_backport.rb']) {
    assert.ok(ignore.split('\n').includes('!' + path), 'Docker context backport path missing');
  }
  for (const text of [
    '"$TEST_IMAGE" ' + verify, '"$PRODUCTION_IMAGE" ' + verify,
    '"$TEST_IMAGE" bundle exec ruby /app/tests/chatwoot_ruby_llm_backport_test.rb',
    'abort "expected production CE setting" unless ENV.fetch("DISABLE_ENTERPRISE") == "true"',
    'abort "CE Captain task service missing" unless Captain::RewriteService < Captain::BaseTaskService',
    'load "/opt/toybaco/tests/verify_chatwoot_ruby_llm_backport.rb"',
  ]) assert.ok(gateSource.includes(text), 'test/production/CE backport proof missing: ' + text);
}
const buildInputs = ['Dockerfile', 'tests/chatwoot-test.Dockerfile', '.dockerignore'].map(path =>
  readFileSync(join(root, path), 'utf8'));
function validateFinalCurlPcre(dockerfile, gateSource) {
  const final = dockerfile.slice(dockerfile.lastIndexOf('\nFROM bundled-gems\n'));
  assert.ok(final.includes("apk add --no-cache 'curl=8.14.1-r3'"), 'CA-preserving package install missing');
  assert.ok(final.includes("ca_bundle_before=\"$(apk info -v | grep '^ca-certificates-bundle-')\""), 'CA-preserving package install missing');
  assert.ok(final.includes("test \"$(apk info -v | grep '^ca-certificates-bundle-')\" = \"$ca_bundle_before\""), 'CA-preserving package install missing');
  assert.ok(gateSource.includes("= \"ca-certificates-bundle-20241121-r1\""), 'runtime CA bundle changed');
  for (const [name, version] of [['curl', '8.14.1-r3'], ['libcurl', '8.14.1-r3'], ['pcre2', '10.43-r1']]) {
    assert.ok(final.includes(`'${name}=${version}'`), `final security upgrade missing: ${name}`);
    assert.ok(final.includes(`= '${name}-${version}'`), `final package verification missing: ${name}`);
    assert.match(gateSource, new RegExp(`\\b${name}=${version.replaceAll('.', '\\.')}\\b`),
      `gate security pin missing: ${name}`);
    assert.ok(gateSource.includes(`= "${name}-${version}"`), `runtime package verification missing: ${name}`);
  }
  for (const required of [
    'Fiddle.dlopen(%q{libcurl.so.4})[%q{curl_version}]',
    'call.to_s.start_with?(%q{libcurl/8.14.1 })',
    'Fiddle.dlopen(%q{libpcre2-8.so.0})[%q{pcre2_config_8}]',
    'config.call(11, version).positive? && version.to_s.start_with?(%q{10.43 })',
  ]) {
    assert.ok(final.includes(required), `final library verification missing: ${required}`);
    assert.ok(gateSource.includes(required), `runtime library verification missing: ${required}`);
  }
}
validateFinalCurlPcre(buildInputs[0], gate);
let curlPcreNegatives = 0;
for (const text of [
  "apk add --no-cache 'curl=8.14.1-r3'",
  "ca_bundle_before=\"$(apk info -v | grep '^ca-certificates-bundle-')\"",
  "test \"$(apk info -v | grep '^ca-certificates-bundle-')\" = \"$ca_bundle_before\"",
  "'curl=8.14.1-r3'", "'libcurl=8.14.1-r3'", "'pcre2=10.43-r1'",
  "= 'curl-8.14.1-r3'", "= 'libcurl-8.14.1-r3'", "= 'pcre2-10.43-r1'",
  'Fiddle.dlopen(%q{libcurl.so.4})[%q{curl_version}]',
  'Fiddle.dlopen(%q{libpcre2-8.so.0})[%q{pcre2_config_8}]',
]) {
  assert.throws(() => validateFinalCurlPcre(buildInputs[0].replace(text, 'omitted'), gate));
  curlPcreNegatives++;
}
for (const text of [
  "= \"ca-certificates-bundle-20241121-r1\"",
  'curl=8.14.1-r3', 'libcurl=8.14.1-r3', 'pcre2=10.43-r1',
  '= "curl-8.14.1-r3"', '= "libcurl-8.14.1-r3"', '= "pcre2-10.43-r1"',
  'Fiddle.dlopen(%q{libcurl.so.4})[%q{curl_version}]',
  'Fiddle.dlopen(%q{libpcre2-8.so.0})[%q{pcre2_config_8}]',
]) {
  assert.throws(() => validateFinalCurlPcre(buildInputs[0], gate.replace(text, 'omitted')),
    `omitted gate proof must fail: ${text}`);
  curlPcreNegatives++;
}
console.log(`Chatwoot final curl/pcre2 security contract: PASS (${curlPcreNegatives} omission controls)`);
// Alpine 3.21 musl 1.2.5-r12 (CVE-2026-107891), c-ares 1.34.9-r0 and brotli-libs 1.1.1-r0 (CVE-2026-111497).
// runtime-hardening hands its apk DB to the final stage without /lib/ld-musl-x86_64.so.1 (or libcares, libbrotli*),
// so none may move there: a DB claiming the new build over the old loader would also make the final stage's request a
// no-op. The final stage upgrades them, and the build and the runtime probe check the installed files against the apk
// records, because musl's version cannot tell r11 from r12. The same check binds openjpeg, which runtime-hardening
// installs and copies: its version string is 2.5.4 for r0 and r1 alike.
const MUSL_CARES = [['musl', '1.2.5-r12'], ['musl-utils', '1.2.5-r12'], ['musl-dev', '1.2.5-r12'], ['c-ares', '1.34.9-r0'],
  ['brotli-libs', '1.1.1-r0']];
const MUSL_CARES_INSTALL = "apk add --no-cache 'musl=1.2.5-r12' 'musl-utils=1.2.5-r12' 'musl-dev=1.2.5-r12' 'c-ares=1.34.9-r0' 'brotli-libs=1.1.1-r0'";
const MUSL_FAMILY = "apk info -v | grep -E '^musl-(dev-|utils-)?[0-9]'";
const OTHER_PACKAGES = "apk info -v | grep -v -E '^(musl|musl-utils|musl-dev|c-ares|brotli-libs)-[0-9]' | sort";
const APK_RECORD_PROOF = 'Dir.chdir(%q{/}); records = File.binread(%q{lib/apk/db/installed}).split(10.chr * 2).map { |record| record.lines.map(&:chomp) }; verified = []; { %q{musl} => %q{1.2.5-r12}, %q{musl-utils} => %q{1.2.5-r12}, %q{musl-dev} => %q{1.2.5-r12}, %q{c-ares} => %q{1.34.9-r0}, %q{brotli-libs} => %q{1.1.1-r0}, %q{openjpeg} => %q{2.5.4-r1} }.each { |name, version| found = records.select { |lines| lines.include?(%q{P:} + name) }; abort %q{apk record: } + name unless found.size == 1 && found.first.include?(%q{V:} + version); dir = path = nil; found.first.each { |line| key, value = line.split(%q{:}, 2); if key == %q{F} then dir = value elsif key == %q{R} then abort %q{apk checksum missing: } + path if path; path = File.join(dir.to_s, value) elsif key == %q{Z} then actual = File.symlink?(path) ? Digest::SHA1.digest(File.readlink(path)) : Digest::SHA1.file(path).digest; abort %q{apk checksum mismatch: } + path unless value == %q{Q1} + [actual].pack(%q{m0}); verified << path; path = nil end }; abort %q{apk checksum missing: } + path if path }; abort %q{apk record proof incomplete} unless (%w[lib/ld-musl-x86_64.so.1 lib/libc.musl-x86_64.so.1 usr/lib/libcares.so.2 usr/lib/libcares.so.2.19.8 usr/lib/libbrotlicommon.so.1 usr/lib/libbrotlicommon.so.1.1.1 usr/lib/libbrotlidec.so.1 usr/lib/libbrotlidec.so.1.1.1 usr/lib/libbrotlienc.so.1 usr/lib/libbrotlienc.so.1.1.1 usr/lib/libopenjp2.so.7 usr/lib/libopenjp2.so.2.5.4] - verified).empty?';
const CARES_LOAD_PROOF = 'abort unless Fiddle::Function.new(Fiddle.dlopen(%q{libcares.so.2})[%q{ares_version}], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP).call(nil).to_s == %q{1.34.9}';
// BrotliDecoderVersion returns (major << 24) | (minor << 12) | patch.
const BROTLI_LOAD_PROOF = 'abort unless Fiddle::Function.new(Fiddle.dlopen(%q{libbrotlidec.so.1})[%q{BrotliDecoderVersion}], [], Fiddle::TYPE_INT).call == 0x1001001';
const OLD_BROTLI_FILES = ['libbrotlicommon', 'libbrotlidec', 'libbrotlienc'].map(name => `test ! -e /usr/lib/${name}.so.1.1.0`);
// The record check must keep binding these packages and files.
const RECORD_PROOF_TARGETS = [...MUSL_CARES, ['openjpeg', '2.5.4-r1']].map(([name, version]) => `%q{${name}} => %q{${version}}`);
const RECORD_PROOF_FILES = ['lib/ld-musl-x86_64.so.1', 'lib/libc.musl-x86_64.so.1', 'usr/lib/libcares.so.2',
  'usr/lib/libcares.so.2.19.8', ...['libbrotlicommon', 'libbrotlidec', 'libbrotlienc'].flatMap(name =>
    [`usr/lib/${name}.so.1`, `usr/lib/${name}.so.1.1.1`]), 'usr/lib/libopenjp2.so.7', 'usr/lib/libopenjp2.so.2.5.4'];
for (const required of RECORD_PROOF_TARGETS) assert.ok(APK_RECORD_PROOF.includes(required), `record proof target: ${required}`);
assert.ok(APK_RECORD_PROOF.includes(`(%w[${RECORD_PROOF_FILES.join(' ')}] - verified).empty?`), 'record proof files');
const HARDENING_MUSL_GUARD = [
  `RUN musl_before="$(${MUSL_FAMILY})" \\\n    && apk add --no-cache 'zlib=1.3.2-r1' 'libexpat=2.9.0-r0' \\\n`,
  `test "$(${MUSL_FAMILY})" = "$musl_before"`,
];
const MUSL_CARES_DOCKER_PROOFS = [
  "ca_trust_before=\"$(apk info -v | grep '^ca-certificates-bundle-')\"",
  "test \"$(apk info -v | grep '^ca-certificates-bundle-')\" = \"$ca_trust_before\"",
  `others_before="$(${OTHER_PACKAGES})"`,
  `test "$(${OTHER_PACKAGES})" = "$others_before"`,
  ...MUSL_CARES.map(([name, version]) => `test "$(apk info -v | grep '^${name}-[0-9]')" = '${name}-${version}'`),
  "test \"$(readlink /lib/libc.musl-x86_64.so.1)\" = 'ld-musl-x86_64.so.1'",
  'test ! -e /usr/lib/libcares.so.2.19.7',
  ...OLD_BROTLI_FILES,
  `ruby -rdigest -e '${APK_RECORD_PROOF}'`,
  "curl --version | head -n 1 | grep -F ' c-ares/1.34.9 '",
  "curl --version | head -n 1 | grep -F ' brotli/1.1.1 '",
  `ruby -rfiddle -e '${CARES_LOAD_PROOF}'`,
  `ruby -rfiddle -e '${BROTLI_LOAD_PROOF}'`,
];
const MUSL_CARES_GATE_PROOFS = [
  "grep -Fq '= \"$musl_before\"' \"$CONTROL_ROOT/Dockerfile\"",
  `grep -Fq '${APK_RECORD_PROOF}' \\\n    "$CONTROL_ROOT/Dockerfile"`,
  "grep -Fq 'Fiddle.dlopen(%q{libcares.so.2})[%q{ares_version}]' \"$CONTROL_ROOT/Dockerfile\"",
  "grep -Fq 'Fiddle.dlopen(%q{libbrotlidec.so.1})[%q{BrotliDecoderVersion}]' \"$CONTROL_ROOT/Dockerfile\"",
  ...MUSL_CARES.map(([name, version]) => `test "$(apk info -v | grep "^${name}-[0-9]")" = "${name}-${version}"`),
  'test "$(readlink /lib/libc.musl-x86_64.so.1)" = "ld-musl-x86_64.so.1"',
  'test ! -e /usr/lib/libcares.so.2.19.7',
  ...OLD_BROTLI_FILES,
  `ruby -rdigest -e "${APK_RECORD_PROOF}"`,
  'curl --version | head -n 1 | grep -F " c-ares/1.34.9 "',
  'curl --version | head -n 1 | grep -F " brotli/1.1.1 "',
  `ruby -rfiddle -e "${CARES_LOAD_PROOF}"`,
  `ruby -rfiddle -e "${BROTLI_LOAD_PROOF}"`,
];
const SBOM_PROOFS = [
  "{ 'musl' => '1.2.5-r12', 'musl-utils' => '1.2.5-r12', 'musl-dev' => '1.2.5-r12', 'c-ares' => '1.34.9-r0',\n" +
    "  'brotli-libs' => '1.1.1-r0' }.each do |name, version|",
  "package['name'] == name && package['versionInfo'] == version",
];
// The SBOM verifiers are parked release inputs of the private repository only (kept out of the quality hash and
// so never synced to the public repository). Read them there; the identity check below binds GITHUB_REPOSITORY to
// this workflow, so a private run cannot skip them by naming the public repository.
const sbomVerifiers = process.env.GITHUB_REPOSITORY === REPOSITORIES.private.name
  ? ['tests/verify_chatwoot_oci_archive.rb', 'tests/verify_chatwoot_release_artifact.rb'].map(path =>
    readFileSync(join(root, path), 'utf8'))
  : [];
function validateFinalMuslCares(dockerfile, gateSource, verifiers) {
  const hardeningStart = dockerfile.indexOf('\nFROM localized-assets AS runtime-hardening\n');
  const finalStart = dockerfile.lastIndexOf('\nFROM bundled-gems\n');
  assert.ok(hardeningStart >= 0 && finalStart > hardeningStart, 'runtime-hardening stage missing');
  const hardening = dockerfile.slice(hardeningStart, finalStart);
  for (const required of HARDENING_MUSL_GUARD) {
    assert.ok(hardening.includes(required), `runtime-hardening musl guard missing: ${required}`);
  }
  assert.doesNotMatch(hardening, /'(musl|musl-utils|musl-dev|c-ares|brotli-libs)=|apk add --no-cache --upgrade/,
    'runtime-hardening must not move musl, c-ares or brotli-libs');
  const final = dockerfile.slice(finalStart);
  const install = final.indexOf(MUSL_CARES_INSTALL);
  const curlPcre = final.indexOf("apk add --no-cache 'curl=8.14.1-r3'");
  assert.ok(install >= 0 && curlPcre >= 0 && final.lastIndexOf('\nRUN ', install) > curlPcre,
    'musl/c-ares/brotli upgrade must be its own final-stage RUN after curl/pcre2');
  const end = final.indexOf('\nRUN ', install);
  const run = final.slice(final.lastIndexOf('\nRUN ', install), end < 0 ? undefined : end);
  for (const required of MUSL_CARES_DOCKER_PROOFS) {
    assert.ok(run.includes(required), `final musl/c-ares proof missing: ${required}`);
  }
  for (const [name, version] of MUSL_CARES) {
    assert.match(gateSource, new RegExp(`\\b${name}=${version.replaceAll('.', '\\.')}\\b`),
      `gate musl/c-ares pin missing: ${name}`);
  }
  for (const required of MUSL_CARES_GATE_PROOFS) {
    assert.ok(gateSource.includes(required), `gate musl/c-ares proof missing: ${required}`);
  }
  for (const verifier of verifiers) {
    for (const required of SBOM_PROOFS) {
      assert.ok(verifier.includes(required), `SBOM musl/c-ares proof missing: ${required}`);
    }
  }
  for (const source of [dockerfile, gateSource, ...verifiers]) {
    assert.ok(!source.includes('1.2.5-r11'), 'superseded musl 1.2.5-r11 remains');
  }
}
validateFinalMuslCares(buildInputs[0], gate, sbomVerifiers);
let muslCaresNegatives = 0;
for (const text of [
  ...HARDENING_MUSL_GUARD, MUSL_CARES_INSTALL,
  ...MUSL_CARES.map(([name, version]) => `'${name}=${version}'`),
  ...MUSL_CARES_DOCKER_PROOFS,
]) {
  assert.throws(() => validateFinalMuslCares(swapOnce(buildInputs[0], text, 'omitted', text), gate, sbomVerifiers),
    `omitted Dockerfile musl/c-ares proof must fail: ${text}`);
  muslCaresNegatives++;
}
// Re-creating the trap: musl, musl-utils, c-ares or brotli-libs moved in runtime-hardening, or its request upgrading
// dependencies; and openjpeg or a pinned file dropped from the record check.
for (const [from, to] of [
  ["&& apk add --no-cache 'zlib=1.3.2-r1'", "&& apk add --no-cache 'musl-utils=1.2.5-r12' 'zlib=1.3.2-r1'"],
  ["&& apk add --no-cache 'zlib=1.3.2-r1'", "&& apk add --no-cache 'musl=1.2.5-r12' 'zlib=1.3.2-r1'"],
  ["&& apk add --no-cache 'zlib=1.3.2-r1'", "&& apk add --no-cache 'c-ares=1.34.9-r0' 'zlib=1.3.2-r1'"],
  ["&& apk add --no-cache 'zlib=1.3.2-r1'", "&& apk add --no-cache 'brotli-libs=1.1.1-r0' 'zlib=1.3.2-r1'"],
  ["&& apk add --no-cache 'zlib=1.3.2-r1'", "&& apk add --no-cache --upgrade 'zlib=1.3.2-r1'"],
  [", %q{openjpeg} => %q{2.5.4-r1}", ''],
  [' usr/lib/libopenjp2.so.7', ''],
  [' usr/lib/libbrotlidec.so.1.1.1', ''],
]) {
  assert.throws(() => validateFinalMuslCares(swapOnce(buildInputs[0], from, to, from), gate, sbomVerifiers),
    `runtime-hardening musl trap must fail: ${to}`);
  muslCaresNegatives++;
}
for (const text of [
  ...MUSL_CARES.map(([name, version]) => `${name}=${version}`),
  ...MUSL_CARES_GATE_PROOFS,
]) {
  assert.throws(() => validateFinalMuslCares(buildInputs[0], swapOnce(gate, text, 'omitted', text), sbomVerifiers),
    `omitted gate musl/c-ares proof must fail: ${text}`);
  muslCaresNegatives++;
}
for (const [index, verifier] of sbomVerifiers.entries()) {
  for (const text of [...MUSL_CARES.map(([name, version]) => `'${name}' => '${version}'`), SBOM_PROOFS[1]]) {
    const mutated = [...sbomVerifiers];
    mutated[index] = swapOnce(verifier, text, 'omitted', text);
    assert.throws(() => validateFinalMuslCares(buildInputs[0], gate, mutated),
      `omitted SBOM musl/c-ares proof must fail: ${text}`);
    muslCaresNegatives++;
  }
}
// The record check without openjpeg in either copy of the gate (control contract and runtime probe).
for (const at of ['first', 'last']) {
  const target = ', %q{openjpeg} => %q{2.5.4-r1}';
  const index = at === 'first' ? gate.indexOf(target) : gate.lastIndexOf(target);
  assert.ok(index >= 0 && gate.indexOf(target) !== gate.lastIndexOf(target));
  assert.throws(() => validateFinalMuslCares(buildInputs[0], gate.slice(0, index) + gate.slice(index + target.length),
    sbomVerifiers), `gate record check without openjpeg must fail (${at})`);
  muslCaresNegatives++;
}
console.log(`Chatwoot final musl/c-ares/brotli security contract: PASS (${muslCaresNegatives} omission controls)`);
// Alpine v3.21 openjpeg 2.5.4-r1 (CVE-2026-6192, OSV-2025-219) from the regular repository, in runtime-hardening and
// copied to the final stage under the same file names. The earlier v3.22 2.5.4-r0 APK fetch failed with 404 once r1
// replaced it. No other release's APK, and no --upgrade (it would move dependencies such as musl); the musl guard
// must follow the request.
const OPENJPEG_INSTALL = "    && apk add --no-cache 'openjpeg=2.5.4-r1' \\\n";
const OPENJPEG_VERSION = "test \"$(apk info -v | grep '^openjpeg-')\" = 'openjpeg-2.5.4-r1'";
const OPENJPEG_COPY = 'cp -a /usr/lib/libopenjp2.so.7 /usr/lib/libopenjp2.so.2.5.4 /toybaco-runtime-root/usr/lib/';
const OPENJPEG_FINAL_PROOFS = [
  OPENJPEG_VERSION,
  "test \"$(readlink /usr/lib/libopenjp2.so.7)\" = 'libopenjp2.so.2.5.4'",
  'test ! -e /usr/lib/libopenjp2.so.2.5.2',
];
const OPENJPEG_GATE_PROOFS = [
  "grep -Fq \"'openjpeg=2.5.4-r1'\" \"$CONTROL_ROOT/Dockerfile\"",
  "if grep -Fq 'alpine/v3.22/' \"$CONTROL_ROOT/Dockerfile\"; then",
  'test "$(apk info -v | grep "^openjpeg-")" = "openjpeg-2.5.4-r1"',
];
function validateOpenjpeg(dockerfile, gateSource) {
  const hardeningStart = dockerfile.indexOf('\nFROM localized-assets AS runtime-hardening\n');
  const finalStart = dockerfile.lastIndexOf('\nFROM bundled-gems\n');
  assert.ok(hardeningStart >= 0 && finalStart > hardeningStart, 'runtime-hardening stage missing');
  const hardening = dockerfile.slice(hardeningStart, finalStart);
  const final = dockerfile.slice(finalStart);
  for (const required of [OPENJPEG_INSTALL, OPENJPEG_VERSION, OPENJPEG_COPY]) {
    assert.ok(hardening.includes(required), `runtime-hardening OpenJPEG contract missing: ${required}`);
  }
  assert.ok(hardening.indexOf(`test "$(${MUSL_FAMILY})" = "$musl_before"`) > hardening.indexOf(OPENJPEG_INSTALL),
    'the musl guard must cover the OpenJPEG request');
  assert.doesNotMatch(hardening, /apk add[^\n]*--upgrade/, 'runtime-hardening must not upgrade dependencies');
  assert.doesNotMatch(dockerfile, /alpine\/v3\.22\/|openjpeg-2\.5\.4-r0|apk add --no-network|toybaco-openjpeg\.apk/,
    'superseded v3.22 OpenJPEG APK fetch remains');
  for (const required of OPENJPEG_FINAL_PROOFS) {
    assert.ok(final.includes(required), `final OpenJPEG proof missing: ${required}`);
  }
  for (const required of OPENJPEG_GATE_PROOFS) {
    assert.ok(gateSource.includes(required), `gate OpenJPEG proof missing: ${required}`);
  }
  assert.ok(!gateSource.includes('openjpeg-2.5.4-r0'), 'gate still expects the superseded OpenJPEG build');
}
validateOpenjpeg(buildInputs[0], gate);
// Replace the occurrence inside one stage: the version test appears in both runtime-hardening and the final stage.
function swapInStage(dockerfile, text, to, stage) {
  const finalStart = dockerfile.lastIndexOf('\nFROM bundled-gems\n');
  const at = stage === 'final' ? dockerfile.indexOf(text, finalStart) : dockerfile.indexOf(text);
  assert.ok(at >= 0 && (stage === 'final' ? at > finalStart : at < finalStart), `${stage} occurrence missing: ${text}`);
  return dockerfile.slice(0, at) + to + dockerfile.slice(at + text.length);
}
let openjpegNegatives = 0;
const openjpegMutants = [
  ...[OPENJPEG_INSTALL, OPENJPEG_VERSION, OPENJPEG_COPY].map(text => swapInStage(buildInputs[0], text, '', 'hardening')),
  ...OPENJPEG_FINAL_PROOFS.map(text => swapInStage(buildInputs[0], text, 'true', 'final')),
  // The superseded fetch, a local APK install, --upgrade, and the request moved past the musl guard.
  swapInStage(buildInputs[0], OPENJPEG_INSTALL, '    && ruby -ropen-uri -e \'URI.open("https://dl-cdn.alpinelinux.org/alpine/v3.22/main/x86_64/openjpeg-2.5.4-r1.apk")\' \\\n' + OPENJPEG_INSTALL, 'hardening'),
  swapInStage(buildInputs[0], OPENJPEG_INSTALL, OPENJPEG_INSTALL + '    && apk add --no-network /tmp/toybaco-openjpeg.apk \\\n', 'hardening'),
  swapInStage(buildInputs[0], OPENJPEG_INSTALL, "    && apk add --no-cache --upgrade 'openjpeg=2.5.4-r1' \\\n", 'hardening'),
  swapInStage(buildInputs[0], OPENJPEG_VERSION, "test \"$(apk info -v | grep '^openjpeg-')\" = 'openjpeg-2.5.4-r0'", 'final'),
  swapInStage(swapInStage(buildInputs[0], OPENJPEG_INSTALL, '', 'hardening'),
    `    && test "$(${MUSL_FAMILY})" = "$musl_before" \\\n`,
    `    && test "$(${MUSL_FAMILY})" = "$musl_before" \\\n${OPENJPEG_INSTALL}`, 'hardening'),
];
for (const mutated of openjpegMutants) {
  assert.notEqual(mutated, buildInputs[0]);
  assert.throws(() => validateOpenjpeg(mutated, gate), 'OpenJPEG Dockerfile mutant must fail');
  openjpegNegatives++;
}
for (const [from, to] of [
  ...OPENJPEG_GATE_PROOFS.map(text => [text, ': # omitted']),
  ['= "openjpeg-2.5.4-r1"', '= "openjpeg-2.5.4-r0"'],
]) {
  assert.throws(() => validateOpenjpeg(buildInputs[0], swapOnce(gate, from, to, from)),
    `OpenJPEG gate mutant must fail: ${from}`);
  openjpegNegatives++;
}
console.log(`Chatwoot OpenJPEG v3.21 contract: PASS (${openjpegNegatives} omission/regression controls)`);
// The Dockerfile is bound byte for byte: the sha256 of its exact bytes (newlines, blanks and continuations included)
// is pinned below, and ONBUILD anywhere or a parser directive fails by name. Imitating Docker's parser and normalizing
// RUN text left gaps (#582: a LABEL ending in `\\` hiding the next RUN, a COPY heredoc read through ARG RUBYOPT, a
// COPY after the checks, a parent stage's ONBUILD, `test -f\` + newline), so the pin is what binds. The Dockerfile is
// a control file: the private CW gate, the PZ gate's control snapshot and the public repository read the same bytes.
// Changing the Dockerfile means reviewing the whole diff and then updating DOCKERFILE_SHA256.
const DOCKERFILE_SHA256 = '49ec95ce8706223c0b7b5a67fdf722cef7d0a27dadf938fa867e00362f4c7f95';
const dockerfileBytes = readFileSync(join(root, 'Dockerfile'));
assert.ok(Buffer.from(buildInputs[0], 'utf8').equals(dockerfileBytes), 'Dockerfile must be UTF-8 text');
function validateDockerfileBytes(bytes) {
  const text = bytes.toString('utf8');
  assert.equal(/^[ \t]*onbuild(?:[ \t]|$)/im.exec(text), null, 'Dockerfile: ONBUILD is not allowed in any stage');
  for (const line of text.split('\n')) {
    if (/^\s*$/.test(line)) continue;
    if (!/^\s*#/.test(line)) break;
    assert.doesNotMatch(line, /^\s*#\s*(?:escape|syntax|check)\s*=/i, 'Dockerfile: parser directives are not allowed');
  }
  const actual = createHash('sha256').update(bytes).digest('hex');
  assert.equal(actual, DOCKERFILE_SHA256, `Dockerfile bytes changed (sha256 ${actual}). Review the whole Dockerfile ` +
    'diff, then update DOCKERFILE_SHA256 in tests/chatwoot-managed-publisher.test.mjs.');
}
validateDockerfileBytes(dockerfileBytes);
// Readable reasons for common mistakes, not the boundary: the stage list, the instruction kinds, the COPY sources and
// the RUN forms of runtime-hardening and the final stage, read roughly the way Docker reads them (keywords in any case
// after optional indentation, `\` continuations joined, comment lines dropped, lines that do not parse failing).
const DOCKERFILE_FROMS = ['${CHATWOOT_IMAGE} AS overlay-normalizer', '${CHATWOOT_IMAGE} AS bundled-gems',
  'bundled-gems AS localized-assets', 'localized-assets AS runtime-hardening', 'bundled-gems'];
const STAGE_INSTRUCTIONS = { hardening: ['RUN'], final: ['RUN', 'COPY', 'ARG', 'LABEL'] };
const STAGE_COPY_SOURCES = ['runtime-hardening', 'overlay-normalizer'];
function dockerInstructions(dockerfile) {
  const instructions = [];
  let current = null;
  let seenInstruction = false;
  for (const [index, raw] of dockerfile.split('\n').entries()) {
    const line = raw.replace(/\r$/, '');
    if (current === null) {
      if (/^\s*$/.test(line)) continue;
      if (/^\s*#/.test(line)) {
        assert.ok(seenInstruction || !/^\s*#\s*(?:escape|syntax|check)\s*=/i.test(line),
          `Dockerfile line ${index + 1}: parser directives are not supported`);
        continue;
      }
      const match = /^\s*([A-Za-z]+)(?:[ \t]+|$)(.*)$/.exec(line);
      assert.ok(match, `Dockerfile line ${index + 1} does not parse`);
      seenInstruction = true;
      current = { keyword: match[1].toUpperCase(), line: index + 1, parts: [match[2]] };
    } else {
      assert.ok(!/^\s*$/.test(line), `Dockerfile line ${index + 1}: empty continuation line`);
      if (/^\s*#/.test(line)) continue;
      current.parts.push(line);
    }
    const last = current.parts.length - 1;
    if (/\\[ \t]*$/.test(current.parts[last])) {
      current.parts[last] = current.parts[last].replace(/\\[ \t]*$/, '');
    } else {
      instructions.push({ keyword: current.keyword, line: current.line,
        text: current.parts.map(part => part.trim()).filter(Boolean).join(' ') });
      current = null;
    }
  }
  assert.equal(current, null, 'Dockerfile ends inside a continuation');
  return instructions;
}
function dockerStages(dockerfile) {
  const instructions = dockerInstructions(dockerfile);
  const froms = instructions.flatMap((instruction, index) => instruction.keyword === 'FROM'
    ? [{ index, text: instruction.text.replace(/\s+as\s+/i, ' AS ') }] : []);
  assert.deepEqual(froms.map(from => from.text), DOCKERFILE_FROMS, 'Dockerfile stages differ from the reviewed list');
  return {
    hardening: instructions.slice(froms[3].index + 1, froms[4].index),
    final: instructions.slice(froms[4].index + 1),
  };
}
function validateStageClosure(dockerfile) {
  const stages = dockerStages(dockerfile);
  for (const stage of ['hardening', 'final']) {
    for (const { keyword, line, text } of stages[stage]) {
      const where = `${stage} (Dockerfile line ${line})`;
      assert.notEqual(keyword, 'ONBUILD', `${where}: ONBUILD is not allowed`);
      assert.notEqual(keyword, 'SHELL', `${where}: SHELL is not allowed`);
      assert.ok(STAGE_INSTRUCTIONS[stage].includes(keyword), `${where}: ${keyword} is not allowed`);
      if (keyword === 'COPY') {
        for (const flag of text.match(/^(?:--\S+\s+)*/)[0].split(/\s+/).filter(Boolean)) {
          const source = /^--from=(\S+)$/.exec(flag);
          assert.ok(source && STAGE_COPY_SOURCES.includes(source[1]), `${where}: COPY ${flag} is not allowed`);
        }
      }
      if (keyword === 'RUN') {
        assert.doesNotMatch(text, /^(?:\[|--)/, `${where}: RUN exec form or RUN flags are not allowed`);
        assert.doesNotMatch(text, /<<-?["']?[A-Za-z_]/, `${where}: RUN heredocs are not allowed`);
      }
    }
  }
}
validateStageClosure(buildInputs[0]);
const APK_ALLOWED = {
  hardening: [
    "apk add --no-cache 'zlib=1.3.2-r1' 'libexpat=2.9.0-r0'",
    "apk add --no-cache 'openjpeg=2.5.4-r1'",
  ],
  final: [
    "apk add --no-cache --upgrade 'openssl=3.3.7-r2' 'libcrypto3=3.3.7-r2' 'libssl3=3.3.7-r2' 'tiff=4.7.2-r0'",
    "apk add --no-cache 'curl=8.14.1-r3' 'libcurl=8.14.1-r3' 'pcre2=10.43-r1'",
    MUSL_CARES_INSTALL,
  ],
};
const COMMAND_START = String.raw`(?<=(?:^|\bRUN|&&|\|\||;|\$\(|\||!|\bthen|\bdo)[ \t]*)`;
const COMMAND_END = String.raw`(?=[ \t]*(?:\\\n|&&|\|\||;|\)|\||$))`;
function commandPattern(command) {
  return new RegExp(COMMAND_START + command.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + COMMAND_END, 'gm');
}
function stageRuns(dockerfile, stage) {
  return dockerStages(dockerfile)[stage].filter(({ keyword }) => keyword === 'RUN').map(({ text }) => `RUN ${text}`)
    .join('\n');
}
function validateApkAndFetch(dockerfile) {
  for (const stage of ['hardening', 'final']) {
    let rest = stageRuns(dockerfile, stage);
    for (const command of APK_ALLOWED[stage]) {
      assert.equal((rest.match(commandPattern(command)) || []).length, 1, `${stage}: allowed apk request once: ${command}`);
      rest = rest.replace(commandPattern(command), 'ALLOWED_APK_REQUEST');
    }
    rest = rest.replace(commandPattern('apk info -v'), 'ALLOWED_APK_READ').split(APK_RECORD_PROOF).join('RECORD_PROOF')
      .replace(/(?<![\w/.-])\/?(?:lib\/apk\/db\/(?:installed|scripts\.tar|triggers)|etc\/apk\/world)(?![\w/.-])/g, 'APK_DB_PATH');
    assert.doesNotMatch(rest, /\bapk\b/, `${stage}: apk used outside the allowed operations`);
    assert.doesNotMatch(rest, /\.apk\b|--no-network|--allow-untrusted|--repositor|--keys-dir|--upgrade|(?:^|\s)-[uX]\b/m,
      `${stage}: APK file, repository, untrusted or upgrade option`);
    assert.doesNotMatch(rest, /https?:|ftp:/i, `${stage}: URL`);
    assert.doesNotMatch(rest, /\bURI\b|open-?uri|OpenURI|Net::HTTP|net\/http|\bwget\b|\w*Socket\b|\bfetch\(/,
      `${stage}: network fetch`);
    for (const match of rest.matchAll(new RegExp(COMMAND_START + String.raw`(?:[\w./-]*\/)?curl\b`, 'gm'))) {
      assert.ok(rest.startsWith('curl --version | head -n 1 | grep -F ', match.index), `${stage}: curl beyond --version`);
    }
  }
}
validateApkAndFetch(buildInputs[0]);
let apkFetchNegatives = 0;
const OPENJPEG_REQUEST = "    && apk add --no-cache 'openjpeg=2.5.4-r1' \\\n";
const MUSL_REQUEST = `    && ${MUSL_CARES_INSTALL} \\\n`;
for (const [from, to] of [
  // Astra's #581 counterexample: a concatenated v3.22 URL fetched, then installed by an apk call with the option first.
  [OPENJPEG_REQUEST, '    && ruby -ropen-uri -e \'URI.open("https://dl-cdn.alpinelinux.org/alpine/" + "v3.22/main/x86_64/openjpeg-2.5.4-r1.apk") { |input| File.binwrite("/tmp/x.apk", input.read) }\' \\\n    && apk --no-network add /tmp/x.apk \\\n' + OPENJPEG_REQUEST],
  [OPENJPEG_REQUEST, '    && apk --no-network add /tmp/x.apk \\\n' + OPENJPEG_REQUEST],
  [OPENJPEG_REQUEST, '    && ruby -e \'require %q{open-uri}; IO.copy_stream(URI.open(%q{dl-cdn.alpinelinux.org}), %q{/tmp/o})\' \\\n' + OPENJPEG_REQUEST],
  [OPENJPEG_REQUEST, '    && ruby -rnet/http -e \'Net::HTTP.get(%q{dl-cdn.alpinelinux.org}, %q{/x})\' \\\n' + OPENJPEG_REQUEST],
  [OPENJPEG_REQUEST, '    && wget -qO /tmp/o dl-cdn.alpinelinux.org/alpine \\\n' + OPENJPEG_REQUEST],
  [OPENJPEG_REQUEST, '    && ruby -e \'Kernel.open(%q{https://dl-cdn.alpinelinux.org/x}) { |input| input.read }\' \\\n' + OPENJPEG_REQUEST],
  [OPENJPEG_REQUEST, '    && curl -fsSo /tmp/o dl-cdn.alpinelinux.org/alpine \\\n' + OPENJPEG_REQUEST],
  // A differently named APK file, an unverified install, and apk under another path or a built-up name, each next
  // to the allowed request.
  [OPENJPEG_REQUEST, '    && apk add /tmp/renamed.apk \\\n' + OPENJPEG_REQUEST],
  [OPENJPEG_REQUEST, OPENJPEG_REQUEST + "    && apk add --no-cache 'openjpeg=2.5.4-r1' --allow-untrusted \\\n"],
  [OPENJPEG_REQUEST, OPENJPEG_REQUEST + "    && apk add --allow-untrusted --no-cache 'openjpeg=2.5.4-r1' \\\n"],
  [OPENJPEG_REQUEST, OPENJPEG_REQUEST + "    && /sbin/apk add --no-cache 'openjpeg=2.5.4-r1' \\\n"],
  [OPENJPEG_REQUEST, OPENJPEG_REQUEST + '    && tool=ap && "${tool}k" add --allow-untrusted /tmp/x \\\n'],
  [OPENJPEG_REQUEST, OPENJPEG_REQUEST + '    && tool=ap && "${tool}k" add --no-network /tmp/x \\\n'],
  // Another repository, an upgrade, a second request, and an extra apk operation in the final stage.
  [OPENJPEG_REQUEST, OPENJPEG_REQUEST + "    && apk add --no-cache -X https://dl-cdn.alpinelinux.org/alpine/v3.22/main 'openjpeg=2.5.4-r1' \\\n"],
  [OPENJPEG_REQUEST, OPENJPEG_REQUEST + '    && tool=ap && "${tool}k" --repository=/tmp/repo add openjpeg \\\n'],
  [OPENJPEG_REQUEST, OPENJPEG_REQUEST + '    && tool=ap && "${tool}k" add -X /tmp/repo openjpeg \\\n'],
  [OPENJPEG_REQUEST, OPENJPEG_REQUEST + '    && tool=ap && "${tool}k" add -u openjpeg \\\n'],
  [OPENJPEG_REQUEST, OPENJPEG_REQUEST + "    && apk add --no-cache 'openjpeg=2.5.4-r1' -u \\\n"],
  [OPENJPEG_REQUEST, OPENJPEG_REQUEST + OPENJPEG_REQUEST],
  [MUSL_REQUEST, MUSL_REQUEST.replace('apk add --no-cache ', 'apk add --no-cache --upgrade ')],
  [MUSL_REQUEST, MUSL_REQUEST + '    && apk fix \\\n'],
  [MUSL_REQUEST, MUSL_REQUEST + '    && sh -c "apk add brotli" \\\n'],
]) {
  assert.throws(() => validateApkAndFetch(swapOnce(buildInputs[0], from, to, from)), `apk/fetch mutant must fail: ${to}`);
  apkFetchNegatives++;
}
console.log(`Chatwoot runtime-hardening/final apk and fetch allowlist: PASS (${apkFetchNegatives} bypass controls)`);
// Every counterexample from the #582 reviews must fail the byte pin: names and options assembled at run time, RUN
// written in other forms Docker accepts, instructions around the RUNs, and changes that only parser-imitating
// normalization would ignore.
const FOREIGN = '/tmp/foreign-package';
const LAST_RUN = "RUN ruby -r /app/lib/toybaco_rds_trust.rb -e 'ToybacoRdsTrust.verify!'";
const appendFinal = text => `${buildInputs[0].trimEnd()}\n${text}\n`;
const beforeFinalFrom = text => {
  const at = buildInputs[0].lastIndexOf('\nFROM bundled-gems\n');
  return `${buildInputs[0].slice(0, at)}\n${text}${buildInputs[0].slice(at)}`;
};
let bytePinNegatives = 0;
for (const mutated of [
  // #582 first review (Astra): dynamic names and options, RUN in other forms, other instructions.
  appendFinal(`RUN tool=ap; "\${tool}k" --allow-""untrusted add ${FOREIGN}`),
  appendFinal(`RUN eval "a""pk --allow-un""trusted add ${FOREIGN}"`),
  appendFinal(`RUN "$(printf '%s' ap)k" --allow-untrusted add ${FOREIGN}`),
  appendFinal('RUN c""url -fsSo /tmp/x dl-cdn.alpinelinux.org/alpine/v3.22/main/x86_64/openjpeg-2.5.4-r1.apk'),
  swapOnce(buildInputs[0], MUSL_REQUEST, `${MUSL_REQUEST}    && tool=ap && "\${tool}k" --allow-""untrusted add ${FOREIGN} \\\n`,
    MUSL_REQUEST),
  swapOnce(buildInputs[0], OPENJPEG_REQUEST, `${OPENJPEG_REQUEST}    && eval "a""pk add --allow-un""trusted ${FOREIGN}" \\\n`,
    OPENJPEG_REQUEST),
  appendFinal(`run apk --allow-untrusted add ${FOREIGN}`),
  appendFinal(`  RUN apk --allow-untrusted add ${FOREIGN}`),
  appendFinal(`RUN\tapk --allow-untrusted add ${FOREIGN}`),
  beforeFinalFrom(`run apk --allow-untrusted add ${FOREIGN}`),
  beforeFinalFrom(`\tRun\tapk --allow-untrusted add ${FOREIGN}`),
  appendFinal(`ONBUILD RUN apk --allow-untrusted add ${FOREIGN}`),
  appendFinal('SHELL ["/bin/bash", "-c"]'),
  appendFinal('ADD https://dl-cdn.alpinelinux.org/alpine/v3.22/main/x86_64/openjpeg-2.5.4-r1.apk /tmp/'),
  appendFinal('ENV LD_PRELOAD=/tmp/foreign.so'),
  appendFinal('COPY --from=alpine:3.22 /sbin/apk /tmp/apk'),
  appendFinal(`RUN ["/sbin/apk", "--allow-untrusted", "add", "${FOREIGN}"]`),
  appendFinal('RUN --network=host apk add brotli'),
  appendFinal(`RUN <<EOF\napk --allow-untrusted add ${FOREIGN}\nEOF`),
  beforeFinalFrom(`FROM bundled-gems AS hidden\nRUN apk --allow-untrusted add ${FOREIGN}`),
  `# escape=\`\n${buildInputs[0]}`,
  appendFinal('%% not an instruction'),
  appendFinal('RUN true \\'),
  swapOnce(buildInputs[0], MUSL_REQUEST, `${MUSL_REQUEST}\n`, MUSL_REQUEST),
  // #582 second review (Astra, Grok): a LABEL ending in `\\` hiding the next RUN, a COPY heredoc read through
  // ARG RUBYOPT by an existing RUN, a COPY after the checks, a parent stage's ONBUILD, `test -f\` + newline, a COPY
  // without flags, `\` + blank, `cat<<EOF`, continuation spacing, a proxy ARG, CRLF, and parser directives.
  appendFinal('LABEL review=ok \\\\\nRUN echo UNREVIEWED_EXECUTION'),
  swapOnce(buildInputs[0], LAST_RUN,
    `COPY <<LABEL /tmp/x.rb\nARG = system(%q{echo UNREVIEWED})\nLABEL\nARG RUBYOPT=-r/tmp/x.rb\n${LAST_RUN}`, LAST_RUN),
  appendFinal('COPY --from=overlay-normalizer /usr/lib/libopenjp2.so.2.5.2 /usr/lib/libopenjp2.so.2.5.4'),
  swapOnce(buildInputs[0], '\nFROM localized-assets AS runtime-hardening\n',
    '\nONBUILD RUN echo UNREVIEWED_EXECUTION\nFROM localized-assets AS runtime-hardening\n', 'runtime-hardening FROM'),
  appendFinal('  onbuild run echo UNREVIEWED_EXECUTION'),
  swapOnce(buildInputs[0], '    && test -f /usr/lib/libz.so.1.3.2 \\\n', '    && test -f\\\n/usr/lib/libz.so.1.3.2 \\\n',
    'test -f libz'),
  appendFinal(`COPY foreign.apk ${FOREIGN}`),
  swapOnce(buildInputs[0], MUSL_REQUEST, MUSL_REQUEST.replace(/\\\n$/, '\\ \n'), MUSL_REQUEST),
  appendFinal('RUN cat<<EOF > /tmp/x.rb\nsystem(%q{echo UNREVIEWED})\nEOF'),
  swapOnce(buildInputs[0], MUSL_REQUEST, MUSL_REQUEST.replace(/^ {4}/, '  '), MUSL_REQUEST),
  swapOnce(buildInputs[0], MUSL_REQUEST, MUSL_REQUEST.replace(/ \\\n$/, '\\\n'), MUSL_REQUEST),
  appendFinal('ARG HTTP_PROXY=http://127.0.0.1:3128'),
  buildInputs[0].replace('\n', '\r\n'),
  `# syntax=docker/dockerfile:1\n${buildInputs[0]}`,
  `# check=skip=all\n${buildInputs[0]}`,
]) {
  assert.notEqual(mutated, buildInputs[0]);
  assert.throws(() => validateDockerfileBytes(Buffer.from(mutated, 'utf8')), 'the Dockerfile byte pin must reject the mutant');
  bytePinNegatives++;
}
console.log(`Chatwoot Dockerfile byte pin: PASS (${bytePinNegatives} bypass/form controls)`);
function validateFinalTiff(dockerfile) {
  const final = dockerfile.slice(dockerfile.lastIndexOf('\nFROM bundled-gems\n'));
  for (const required of ["'tiff=4.7.2-r0'", "= 'tiff-4.7.2-r0'",
    'Fiddle.dlopen(%q{libtiff.so.6})[%q{TIFFGetVersion}]',
    'call.to_s.lines.first.chomp == %q{LIBTIFF, Version 4.7.2}']) {
    assert.ok(final.includes(required), 'final TIFF artifact contract missing: ' + required);
  }
}
validateFinalTiff(buildInputs[0]);
for (const required of ["'tiff=4.7.2-r0'", "= 'tiff-4.7.2-r0'",
  'Fiddle.dlopen(%q{libtiff.so.6})[%q{TIFFGetVersion}]',
  'call.to_s.lines.first.chomp == %q{LIBTIFF, Version 4.7.2}']) {
  assert.throws(() => validateFinalTiff(buildInputs[0].replace(required, 'obsolete TIFF contract')));
}
validateBackportBuild(...buildInputs, gate);
let buildNegativeCount = 0;
for (const [index, text] of [
  [0, 'COPY config/chatwoot-ruby-llm-backport.json'], [1, 'COPY config/chatwoot-ruby-llm-backport.json'],
  [0, 'harden-chatwoot-ruby-llm.rb apply'], [1, 'harden-chatwoot-ruby-llm.rb apply'],
  [0, 'bundle exec ruby /opt/toybaco/tests/verify_chatwoot_ruby_llm_backport.rb'],
  [1, 'bundle exec ruby /opt/toybaco/tests/verify_chatwoot_ruby_llm_backport.rb'],
  [2, '!scripts/harden-chatwoot-ruby-llm.rb'], [2, '!tests/verify_chatwoot_ruby_llm_backport.rb'],
  [3, '"$TEST_IMAGE" bundle exec ruby /opt/toybaco/tests/verify_chatwoot_ruby_llm_backport.rb'],
  [3, '"$PRODUCTION_IMAGE" bundle exec ruby /opt/toybaco/tests/verify_chatwoot_ruby_llm_backport.rb'],
  [3, '"$TEST_IMAGE" bundle exec ruby /app/tests/chatwoot_ruby_llm_backport_test.rb'],
  [3, 'abort "CE Captain task service missing"'],
]) {
  const modified = [...buildInputs, gate];
  assert.ok(modified[index].includes(text));
  modified[index] = modified[index].replace(text, '# omitted');
  assert.throws(() => validateBackportBuild(...modified), 'omitted backport build proof must fail');
  buildNegativeCount++;
}
console.log('Chatwoot backport build wiring: PASS (' + buildNegativeCount + ' omission controls)');

const mode = repositoryMode(workflow, process.env.GITHUB_REPOSITORY);
const counterpart = counterpartWorkflow(workflow, mode);
validate(workflow, gate);
// The other mode's rules on this workflow's own transformation, and the reverse transformation restoring it
// (自己変換の整合性と共有規則の検査; null: a derived workflow has no GitHub repository to bind).
validate(counterpart, gate, { repository: null });
assert.equal(counterpartWorkflow(counterpart, otherMode(mode)), workflow, 'the derived workflow must map back exactly');
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

  [workflow.replace('scripts/verify-chatwoot-ruby-llm-classification.mjs snapshot-before', 'scripts/not-run.mjs snapshot-before'), gate],
  [workflow.replace('scripts/verify-chatwoot-ruby-llm-classification.mjs snapshot-after', 'scripts/not-run.mjs snapshot-after'), gate],
  [workflow.replace('--network none --workdir /scan', '--workdir /scan'), gate],
  [workflow.replace('src=$security/db,dst=/root/.cache/trivy/db"', 'src=$frozen/db,dst=/root/.cache/trivy/db"'), gate],
  [workflow.replace('src=$security/db,dst=/root/.cache/trivy/db"', 'src=$security/db,dst=/root/.cache/trivy/db,readonly"'), gate],
  ...[
    'mkdir -m 0700 "$frozen"',
    'mkdir -m 0700 "$security/db"',
    'cp -- "$frozen/db/trivy.db" "$frozen/db/metadata.json" "$security/db/"',
    'cmp -- "$frozen/db-before.json" "$security/db-before.json"',
    'cmp -- "$frozen/db-before.json" "$frozen/db-after.json"',
    'cmp -- "$frozen/db-after.json" "$security/db-after.json"',
  ].map(contract => [workflow.replace(contract, ': # omitted copy proof'), gate]),
  [workflow.replace('/contract/tests/verify_chatwoot_ruby_llm_backport.rb /contract/config/chatwoot-ruby-llm-backport.json', '/contract/tests/not-run.rb'), gate],
  [workflow.replace('-rbundler/setup ', ''), gate],
  [workflow.replace('-rbundler/setup /contract/tests/verify_chatwoot_ruby_llm_backport.rb /contract/config/chatwoot-ruby-llm-backport.json', '/contract/tests/verify_chatwoot_ruby_llm_backport.rb /contract/config/chatwoot-ruby-llm-backport.json -rbundler/setup'), gate],
  [workflow.replace('--exit-code 1 --list-all-pkgs', '--exit-code 1'), gate],
  [workflow.replace('predicate-path: ${{ runner.temp }}/chatwoot-source-backport/openvex.json', 'predicate-path: /arbitrary.json'), gate],
  [workflow.replace('predicate-path: ${{ runner.temp }}/chatwoot-source-backport/source-backport-classification.json', 'predicate-path: /arbitrary.json'), gate],
  [workflow.replace("--cert-oidc-issuer 'https://token.actions.githubusercontent.com'", "--cert-oidc-issuer 'https://example.com'"), gate],
  [workflow.replace('--exit-code 1', '--exit-code 1 --skip-files ruby_llm'), gate],
  [workflow.replace('node tests/chatwoot-ruby-llm-classification.test.mjs .', 'true'), gate],
  [workflow.replace('TOYBACO_PUBLIC_REVISION=$REPOSITORY_COMMIT', 'TOYBACO_PUBLIC_REVISION=main'), gate],
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
  [workflow.replace('scripts/verify-chatwoot-ruby-llm-classification.mjs evaluate', 'scripts/not-run.mjs evaluate'), gate],
  [workflow.replace('scripts/verify-chatwoot-ruby-llm-classification.mjs verify-attestations', 'scripts/not-run.mjs verify-attestations'), gate],
  [workflow.replace('--skip-db-update --skip-java-db-update --offline-scan', '--skip-db-update'), gate],
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
  [workflow, gate.replace('assert_single_exact_line "$CONTROL_ROOT/.dockerignore" \'overlay/app/spec\'', ':')],
  [workflow, gate.replace('test ! -e /app/spec', ':')],
  [workflow, gate.replaceAll('libexpat=2.9.0-r0', 'libexpat=2.8.4-r0')],
  [workflow, gate.replaceAll('test ! -e /usr/lib/libexpat.so.1.12.3', ':')],
  [workflow, gate.replaceAll('test ! -e /usr/lib/libexpat.so.1.12.4', ':')],
  [workflow, gate.replaceAll('Fiddle::TYPE_VOIDP).call.to_s == %q{expat_2.9.0}', 'Fiddle::TYPE_VOIDP).call.to_s == %q{expat_2.8.4}')],
  [workflow, gate.replace('"$PRODUCTION_IMAGE" sh -c \'\n      set -e\n', '"$PRODUCTION_IMAGE" sh -c \'\n')],
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
  [workflow, gate.replace("    'tests/chatwoot-managed-publisher.test.mjs' \\\n", '')],
];

// Repository-specific negatives, for a workflow of the given repository.
function repositoryMutations(source, sourceMode) {
  const own = REPOSITORIES[sourceMode].name, other = REPOSITORIES[otherMode(sourceMode)].name;
  const step = contractStep(sourceMode), stepName = `      - name: ${CONTRACT_STEP_NAME[sourceMode]}\n`;
  const shared = [
    // A second identity, or every identity moved to the other repository without its publisher rules.
    source.replace(`--repo ${own} \\\n`, `--repo ${other} \\\n`),
    source.replaceAll(own, other),
    source.replace(`    name: ${REPOSITORIES[sourceMode].publishName}\n`, '    name: publisher\n'),
    // The contract step removed, renamed, skipped, tolerated or limited, or the quality job tolerating failures.
    source.replace(`\n${step}`, ''),
    source.replace(stepName, '      - name: publisher契約を検証\n'),
    source.replace(step, `${step}        if: false\n`),
    source.replace(stepName, `${stepName}        if: false\n`),
    source.replace(step, `${step}        continue-on-error: true\n`),
    source.replace(step, `${step}        timeout-minutes: 1\n`),
    source.replace('  quality:\n', '  quality:\n    continue-on-error: true\n'),
    source.replace(`run: ${CONTRACT_RUN}`, 'run: true'),
    // Another working directory or environment for the contract, by job / workflow defaults or step keys.
    source.replace('  quality:\n', '  quality:\n    defaults:\n      run:\n        working-directory: overlay\n'),
    source.replace('\njobs:\n', '\ndefaults:\n  run:\n    working-directory: overlay\n\njobs:\n'),
    source.replace(step, `${step}        working-directory: overlay\n`),
    source.replace(step, `${step}        env:\n          NODE_OPTIONS: --require=./preload.cjs\n`),
    // Repository tokens: another owner, a fifth repository argument, another repository URL, another subject.
    source.replace(`--repo ${own} \\\n`, `--repo Other-org/${own.split('/')[1]} \\\n`),
    source.replace(`--repo ${own} \\\n`, `--repo ${own} -R ${own} \\\n`),
    source.replace('\njobs:\n', '\n# mirror: https://github.com/other-org/chatwoot\njobs:\n'),
    source.replace(`subject-name: ${ECR_SUBJECT}`, 'subject-name: 951034765053.dkr.ecr.ap-northeast-1.amazonaws.com/toybaco/other'),
    // Token boundaries: a longer name containing this one, the identity under another variable, and repository
    // arguments in other forms (--owner, gh -o, gh -R in a command substitution, GH_REPO, a checkout
    // repository:, a raw.githubusercontent.com URL).
    source.replace(`--repo ${own} \\\n`, `--repo ${own}-fork \\\n`),
    source.replace(`github.com/${own}/.github/`, `github.com/${own}-fork/.github/`),
    source.replace("          identity='", "          release_identity='"),
    source.replace(`--repo ${own} \\\n`, `--repo ${own} \\\n            --owner Other-org \\\n`),
    source.replace(`--repo ${own} \\\n`, `--repo ${own} -o Other-org \\\n`),
    source.replace("          identity='", '          notes="$(gh release view -R Other-org/chatwoot)"\n          identity=\''),
    source.replace('          GH_TOKEN: ${{ github.token }}\n', '          GH_TOKEN: ${{ github.token }}\n          GH_REPO: Other-org/chatwoot\n'),
    source.replace('          persist-credentials: false\n          fetch-depth: 1\n',
      '          repository: Other-org/chatwoot\n          persist-credentials: false\n          fetch-depth: 1\n'),
    source.replace('\njobs:\n', '\n# raw: https://raw.githubusercontent.com/Other-org/chatwoot/main/Dockerfile\njobs:\n'),
  ];
  if (sourceMode === 'private') {
    return [
      ...shared,
      source.replace('false &&', 'true &&'),
      source.replace('      false &&\n', ''),
      source.replace(pathLines(PRIVATE_ONLY_PATHS.slice(-1)), ''),
    ];
  }
  return [
    ...shared,
    source.replace(PUSH_PATH_BLOCKS[0].public, PUSH_PATH_BLOCKS[0].private),
    source.replace("      (github.event_name == 'push' && github.ref == 'refs/heads/main') ||\n",
      "      false &&\n      ((github.event_name == 'push' && github.ref == 'refs/heads/main') ||\n"),
    source.replace("(github.event_name == 'push' && github.ref == 'refs/heads/main') ||", "(github.event_name == 'push') ||"),
  ];
}
const repositoryNegatives = [
  ...repositoryMutations(workflow, mode).map(source => [source, gate, process.env.GITHUB_REPOSITORY, workflow]),
  ...repositoryMutations(counterpart, otherMode(mode)).map(source => [source, gate, null, counterpart]),
];

for (const [index, [mutatedWorkflow, mutatedGate]] of mutations.entries()) {
  assert.ok(mutatedWorkflow !== workflow || mutatedGate !== gate, `negative control must change its input: ${index + 1}`);
  assert.throws(
    () => validate(mutatedWorkflow, mutatedGate),
    `negative control was accepted: ${index + 1}`,
  );
}
for (const [index, [mutatedWorkflow, mutatedGate, repository, base]] of repositoryNegatives.entries()) {
  assert.notEqual(mutatedWorkflow, base, `repository negative control must change its input: ${index + 1}`);
  assert.throws(
    () => validate(mutatedWorkflow, mutatedGate, { repository }),
    `repository negative control was accepted: ${index + 1}`,
  );
}
// GitHub's repository name: required, one of the two, and this workflow's.
const bindingNegatives = ['', 'Cyber-relations/other', REPOSITORIES[otherMode(mode)].name, undefined];
for (const repository of bindingNegatives) {
  assert.throws(() => repositoryMode(workflow, repository), `repository binding was accepted: ${JSON.stringify(repository)}`);
}
// Other commands' short -R / -o are not repository arguments: only gh command lines are read for them.
const nonGhShortFlags = workflow.replace("          identity='",
  '          chmod -R go-w "$RUNNER_TEMP"; set -o pipefail\n          identity=\'');
assert.notEqual(nonGhShortFlags, workflow, 'the short flag positive control must change its input');
assert.equal(repositoryMode(nonGhShortFlags, process.env.GITHUB_REPOSITORY), mode,
  'a non-gh -R / -o must not count as a repository argument');

// The private Postiz gate runs this contract inside its fixed container. Its one container bootstrap forwards
// GitHub's repository name from the host as is, and nothing else in the gate names it, so the gate never fills in
// a repository: an unset name stays unset in the container and fails this contract there.
const POSTIZ_GATE_LAUNCH = '  if docker run --rm --init --pull=missing \\\n';
const POSTIZ_GATE_FORWARD = '    --env GITHUB_REPOSITORY \\\n';
const POSTIZ_GATE_NODEDIR = '    --env npm_config_nodedir=/usr/local \\\n';
function validatePostizGateForwarding(postizGateSource) {
  const start = postizGateSource.indexOf(POSTIZ_GATE_LAUNCH);
  assert.ok(start >= 0 && postizGateSource.indexOf(POSTIZ_GATE_LAUNCH, start + 1) < 0,
    'the Postiz gate must have exactly one container bootstrap');
  const end = postizGateSource.indexOf('    "$BOOTSTRAP_IMAGE" \\\n', start);
  assert.ok(end > start, 'the Postiz gate container bootstrap must run the bootstrap image');
  const bootstrap = postizGateSource.slice(start, end);
  assert.ok(bootstrap.includes('    --env TOYBACO_POSTIZ_GATE_CONTAINER=1 \\\n'),
    'the container bootstrap must run the Postiz gate in its container');
  assert.equal(bootstrap.split(POSTIZ_GATE_FORWARD).length - 1, 1,
    'the Postiz gate container bootstrap must forward GITHUB_REPOSITORY as is');
  // node-gyp fallback builds use the fixed image headers; a header download cannot be extracted under --cap-drop=ALL.
  // Count on the bootstrap without comment lines, so a commented-out forward does not satisfy the contract.
  const bootstrapCode = bootstrap.split('\n').filter(line => !/^\s*#/.test(line)).join('\n');
  assert.equal(bootstrapCode.split(POSTIZ_GATE_NODEDIR).length - 1, 1,
    'the Postiz gate container bootstrap must point native fallback builds at the fixed image headers');
  const code = postizGateSource.split('\n').filter(line => !/^\s*#/.test(line)).join('\n');
  assert.equal(count(code, /GITHUB_REPOSITORY/g), 1, 'the Postiz gate must not set or default GITHUB_REPOSITORY');
}
const postizGateNegatives = [];
if (mode === 'private') {
  const postizGate = readFileSync(resolve(root, 'bin/toybaco-postiz-gate'), 'utf8');
  validatePostizGateForwarding(postizGate);
  postizGateNegatives.push(
    postizGate.replace(POSTIZ_GATE_FORWARD, ''),
    postizGate.replace(POSTIZ_GATE_NODEDIR, ''),
    postizGate.replace(POSTIZ_GATE_NODEDIR, '#' + POSTIZ_GATE_NODEDIR),
    postizGate.replace(POSTIZ_GATE_FORWARD, '    --env GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-Cyber-relations/toybaco}" \\\n'),
    postizGate.replace("  STAGE='container bootstrap'\n",
      "  STAGE='container bootstrap'\n  export GITHUB_REPOSITORY=\"${GITHUB_REPOSITORY:-Cyber-relations/toybaco}\"\n"),
  );
  for (const [index, source] of postizGateNegatives.entries()) {
    assert.notEqual(source, postizGate, `Postiz gate negative control must change its input: ${index + 1}`);
    assert.throws(() => validatePostizGateForwarding(source), `Postiz gate negative control was accepted: ${index + 1}`);
  }
}

console.log(`Chatwoot managed publisher: PASS (${mode} repository; ${mutations.length} publisher + ` +
  `${repositoryNegatives.length} repository + ${bindingNegatives.length} binding + ` +
  `${mode === 'private' ? `${postizGateNegatives.length} Postiz gate + ` : ''}2 post-entry negative controls; ` +
  'derived-mode round trip and shared rules checked)');

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
const scanRun = stepRun(workflow, '固定Trivyの生結果と実imageのRubyLLM backportを検証');
const imageName = '951034765053.dkr.ecr.ap-northeast-1.amazonaws.com/toybaco/chatwoot';
const digest = 'sha256:' + 'a'.repeat(64);

const { classificationFixture } = await import(join(root, 'tests/chatwoot-ruby-llm-classification.test.mjs'));
function executePolicy(label, change, expected) {
  const directory = mkdtempSync(join(tmpdir(), 'toybaco-cw-sbom-policy-'));
  try {
    const fixture = classificationFixture(), sbom = fixture.sbom, report = fixture.raw;
    const settings = { scannerExit: 1, changedDatabase: false, changedOriginal: false, changedMetadata: false, proofStartup: null };
    change(sbom, report, settings, fixture);
    const bin = join(directory, 'bin'); mkdirSync(bin);
    writeFileSync(join(bin, 'stat'), `#!/bin/sh\nexec '${process.execPath}' -e 'console.log(require("node:fs").statSync(process.argv[1]).size)' "$3"\n`, { mode: 0o755 });
    writeFileSync(join(bin, 'date'), '#!/bin/sh\nprintf "%s\\n" "2026-09-17T07:01:00Z"\n', { mode: 0o755 });
    writeFileSync(join(bin, 'docker'), `#!${process.execPath}
const fs = require('node:fs'), path = require('node:path'), a = process.argv.slice(2);
const dir = process.env.RUNNER_TEMP, security = path.join(dir, 'chatwoot-source-backport');
if (a[0] === 'pull') process.exit(0);
if (a[0] === 'image' && a[1] === 'inspect') {
 process.stdout.write(fs.readFileSync(path.join(dir, 'fixture-image.json'))); process.exit(0);
}
if (a[0] !== 'run') process.exit(97);
if (a.includes('--download-db-only')) {
 const frozen = path.join(security, 'frozen-source');
 if (!a.includes('type=bind,src=' + frozen + ',dst=/root/.cache/trivy')) process.exit(94);
 fs.mkdirSync(path.join(frozen, 'db'));
 fs.writeFileSync(path.join(frozen, 'db/trivy.db'), 'isolated frozen DB fixture');
 fs.copyFileSync(path.join(dir, 'fixture-db.json'), path.join(frozen, 'db/metadata.json')); process.exit(0);
}
if (a.includes('sbom')) {
 if (!a.includes('type=bind,src=' + security + '/db,dst=/root/.cache/trivy/db')) process.exit(95);
 if (a.some(value => value.includes('frozen-source'))) process.exit(96);
 if (process.env.TOYBACO_TEST_ORIGINAL_CHANGE === 'true') fs.appendFileSync(path.join(security, 'frozen-source/db/trivy.db'), 'changed');
 if (process.env.TOYBACO_TEST_METADATA_CHANGE === 'true') {
  const metadataPath = path.join(security, 'db/metadata.json');
  const metadata = JSON.parse(fs.readFileSync(metadataPath)); metadata.NextUpdate = '2026-09-18T00:00:00Z';
  fs.writeFileSync(metadataPath, JSON.stringify(metadata));
 }
 fs.copyFileSync(path.join(dir, 'fixture-report.json'), path.join(security, 'scan-output/raw-report.json'));
 if (process.env.TOYBACO_TEST_DB_CHANGE === 'true') fs.appendFileSync(path.join(security, 'db/trivy.db'), 'changed');
 process.exit(Number(process.env.TOYBACO_TEST_SCANNER_EXIT));
}
if (a.includes('/contract/tests/verify_chatwoot_ruby_llm_backport.rb')) {
 const imageIndex = a.indexOf(process.env.ECR_REPOSITORY + '@' + process.env.IMAGE_DIGEST);
 const expected = ['-rbundler/setup', '/contract/tests/verify_chatwoot_ruby_llm_backport.rb', '/contract/config/chatwoot-ruby-llm-backport.json'];
 if (imageIndex < 0 || JSON.stringify(a.slice(imageIndex + 1)) !== JSON.stringify(expected)) {
  process.stderr.write('BUNDLER_PRELOAD_REQUIRED'); process.exit(93);
 }
 process.stdout.write(fs.readFileSync(path.join(dir, 'fixture-proof.json'))); process.exit(0);
}
process.exit(98);
`, { mode: 0o755 });
    for (const [name, data] of Object.entries({
      'toybaco-chatwoot.spdx.json': sbom, 'fixture-report.json': report,
      'fixture-image.json': fixture.imageInspect, 'fixture-proof.json': fixture.proof,
      'fixture-db.json': fixture.before.metadata,
    })) writeFileSync(join(directory, name), JSON.stringify(data));
    let executedScan = scanRun;
    if (settings.proofStartup) {
      const invocation = '-rbundler/setup /contract/tests/verify_chatwoot_ruby_llm_backport.rb /contract/config/chatwoot-ruby-llm-backport.json';
      assert.ok(scanRun.includes(invocation));
      const scriptArgs = invocation.slice('-rbundler/setup '.length);
      executedScan = scanRun.replace(invocation, settings.proofStartup === 'missing'
        ? scriptArgs : scriptArgs + ' -rbundler/setup');
    }
    const result = spawnSync('bash', ['-c', `${bindingRun}\n${executedScan}`], {
      cwd: root, encoding: 'utf8', timeout: 15000,
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, RUNNER_TEMP: directory,
        GITHUB_WORKSPACE: root, IMAGE_DIGEST: digest, ECR_REPOSITORY: imageName,
        REPOSITORY_COMMIT: fixture.context.source_commit, CONTROL_SHA: fixture.context.control_sha256,
        TRIVY_IMAGE: fixture.context.trivy_image, TOYBACO_TEST_DB_CHANGE: String(settings.changedDatabase),
        TOYBACO_TEST_ORIGINAL_CHANGE: String(settings.changedOriginal),
        TOYBACO_TEST_METADATA_CHANGE: String(settings.changedMetadata),
        TOYBACO_TEST_SCANNER_EXIT: String(settings.scannerExit) },
    });
    assert.equal(result.error, undefined, `${label}: ${result.error}`);
    assert.equal(result.status === 0, expected, `${label}: ${result.stdout}${result.stderr}`);
    if (settings.proofStartup) assert.match(result.stderr, /BUNDLER_PRELOAD_REQUIRED/, 'startup regression fails at the actual Ruby invocation');
    if (expected) {
      const proof = JSON.parse(readFileSync(join(directory, 'chatwoot-source-backport/source-backport-classification.json')));
      assert.deepEqual(proof.raw_report, report, 'raw report is retained truthfully');
      assert.equal(proof.scanner_vex_filtering, false);
      assert.equal(proof.counts.raw_high, 3);
      assert.equal(proof.counts.source_verified_fixed, 3);
      const security = join(directory, 'chatwoot-source-backport');
      const originalBefore = readFileSync(join(security, 'frozen-source/db-before.json'));
      assert.deepEqual(readFileSync(join(security, 'frozen-source/db-after.json')), originalBefore);
      assert.deepEqual(readFileSync(join(security, 'db-before.json')), originalBefore);
      assert.deepEqual(readFileSync(join(security, 'db-after.json')), originalBefore);
      assert.deepEqual(proof.scanner.database, JSON.parse(originalBefore), 'signed snapshot binds the actual scanned copy');
      const vex = JSON.parse(readFileSync(join(security, 'openvex.json')));
      const verified = (predicateType, predicate) => [{ verificationResult: {
        signature: { certificate: {} }, verifiedTimestamps: [{ type: 'tlog' }],
        statement: { _type: 'https://in-toto.io/Statement/v1',
          subject: [{ name: imageName, digest: { sha256: digest.slice(7) } }], predicateType, predicate },
      } }];
      writeFileSync(join(security, 'verified-openvex.json'),
        JSON.stringify(verified('https://openvex.dev/ns/v0.2.0', vex)));
      writeFileSync(join(security, 'verified-source-backport.json'),
        JSON.stringify(verified('https://toybaco.jp/attestations/chatwoot-ruby-llm-backport/v1', proof)));
      const args = [join(root, 'scripts/verify-chatwoot-ruby-llm-classification.mjs'),
        'verify-attestations', security, join(root, 'config/chatwoot-ruby-llm-backport.json')];
      const verifiedResult = spawnSync(process.execPath, args, { encoding: 'utf8' });
      assert.equal(verifiedResult.status, 0, verifiedResult.stderr);
      const changed = structuredClone(report); changed.CreatedAt = 'tampered after classification';
      writeFileSync(join(security, 'raw-report.json'), JSON.stringify(changed));
      const changedResult = spawnSync(process.execPath, args, { encoding: 'utf8' });
      assert.notEqual(changedResult.status, 0, 'signed predicates cannot accept changed raw evidence');
    }
  } finally { rmSync(directory, { recursive: true, force: true }); }
}
executePolicy('exact image, raw HIGH and complete source proof authorize only the backport classification', () => {}, true);
for (const [label, change] of [
  ['wrong manifest checksum', sbom => { sbom.packages[0].checksums[0].checksumValue = 'c'.repeat(64); }],
  ['wrong requested digest', sbom => { sbom.packages[0].versionInfo = 'sha256:' + 'b'.repeat(64); }],
  ['version alone cannot bind manifest', sbom => { sbom.packages[0].checksums = []; }],
  ['wrong repository', sbom => { sbom.packages[0].name = 'other/image'; }],
  ['no described image', sbom => { sbom.relationships.shift(); }],
  ['ambiguous described image', sbom => { sbom.relationships.push({ ...sbom.relationships[0], relatedSpdxElement: 'other' }); }],
  ['wrong distro', sbom => { sbom.packages[2].externalRefs[0].referenceLocator = 'pkg:apk/alpine/a@1?distro=alpine-3.22'; }],
  ['distro prefix is not exact', sbom => { sbom.packages[2].externalRefs[0].referenceLocator = 'pkg:apk/alpine/a@1?distro=alpine-3.21.30'; }],
  ['missing OS coverage', (_sbom, report) => { report.Results.shift(); }],
  ['missing language coverage', (_sbom, report) => { report.Results.pop(); }],
  ['empty package scan', (_sbom, report) => { report.Results[0].Packages = []; }],
  ['scanner failed', (_sbom, _report, settings) => { settings.scannerExit = 2; }],
  ['additional unfixed High rejected', (_sbom, report) => { report.Results[0].Vulnerabilities = [{ Severity: 'HIGH', FixedVersion: '' }]; }],
  ['Critical rejected', (_sbom, report) => { report.Results[0].Vulnerabilities = [{ Severity: 'CRITICAL' }]; }],
  ['raw-zero receipt cannot be reused', (_sbom, report, settings) => { report.Results[1].Vulnerabilities = []; settings.scannerExit = 0; }],
  ['one-advisory receipt cannot be reused', (_sbom, report) => { report.Results[1].Vulnerabilities.splice(0, 2); }],
  ['fourth ruby_llm finding rejected', (_sbom, report) => {
    report.Results[1].Vulnerabilities.push({ ...report.Results[1].Vulnerabilities[0], VulnerabilityID: 'CVE-2099-4' });
  }],
  ['Bundler preload missing before proof script', (_sbom, _report, settings) => { settings.proofStartup = 'missing'; }],
  ['Bundler preload after script is only an argument', (_sbom, _report, settings) => { settings.proofStartup = 'late'; }],
  ['source proof failure', (_sbom, _report, _settings, fixture) => { fixture.proof.files[0].sha256 = 'f'.repeat(64); }],
  ['actual scanned copy DB changed during raw scan', (_sbom, _report, settings) => { settings.changedDatabase = true; }],
  ['original DB changed during raw scan', (_sbom, _report, settings) => { settings.changedOriginal = true; }],
  ['actual scanned copy metadata changed during raw scan', (_sbom, _report, settings) => { settings.changedMetadata = true; }],
]) executePolicy(label, change, false);
console.log('Chatwoot exact SBOM/raw-scan/proof shell: PASS (1 positive / 23 negative controls; Docker stand-in, no external calls)');
