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
import { existsSync, readFileSync, realpathSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, symlinkSync } from 'node:fs';
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
// The Rails 7.2.3.2 installed proof on the exact digest (docs/chatwoot-rails-backport-policy.md): network off, read-only, Bundler
// preloaded, the contract mounted read-only and a private /tmp for its tempfiles and Disk-service blobs.
const RAILS_PROOF_RUN = '          docker run --rm --platform linux/amd64 --network none --read-only \\\n' +
  '            --cap-drop ALL --security-opt no-new-privileges --workdir /app --entrypoint ruby \\\n' +
  '            --tmpfs /tmp:rw,noexec,nosuid,size=16m \\\n' +
  '            --mount "type=bind,src=$GITHUB_WORKSPACE/config,dst=/contract/config,readonly" \\\n' +
  '            --mount "type=bind,src=$GITHUB_WORKSPACE/scripts,dst=/contract/scripts,readonly" \\\n' +
  '            --mount "type=bind,src=$GITHUB_WORKSPACE/tests,dst=/contract/tests,readonly" \\\n' +
  '            "$ECR_REPOSITORY@$IMAGE_DIGEST" \\\n' +
  '            -rbundler/setup /contract/tests/verify_chatwoot_rails_backport.rb /contract/config/chatwoot-rails-backport.json \\\n' +
  '            > "$security/installed-rails-proof.json"\n';
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
// The shipped runtime: Alpine 3.22 with upstream's Ruby 3.4.4, pinned by digest; the upstream image supplies the code
// and every build-only stage. alpine-release stays at this base image's own build (docs/chatwoot-runtime-os-policy.md),
// so the SBOM distro, Trivy --distro and the evaluator bind one fixed release that point releases do not move.
const RUNTIME_IMAGE = 'ruby:3.4.4-alpine3.22@sha256:017bd0bf72da696261a11a1575ab04d65b3340def62ce39219e8862fc0aa13d1';
const UPSTREAM_IMAGE = 'chatwoot/chatwoot@sha256:03a03a85a00f1d119367deb0d090a56e553468d0aa5e9194a57eba7c61deb7de';
// The runtime package verifier takes the reviewed list, the CVE floor table and the reviewed unowned-file list (all three
// control files) in the runtime base, on the final filesystem and in the gate's production probe.
const RUNTIME_APK_INPUTS = ['config/chatwoot-runtime-apk.txt', 'config/chatwoot-runtime-apk-cve-floors.tsv',
  'config/chatwoot-runtime-apk-unowned-files.tsv'];
const RUNTIME_APK_VERIFY = 'ruby /opt/toybaco/tests/verify_chatwoot_runtime_apk.rb ' +
  RUNTIME_APK_INPUTS.map(path => `/opt/toybaco/${path}`).join(' ');
const RUNTIME_APK_PROBE = 'ruby /contract/tests/verify_chatwoot_runtime_apk.rb /contract/config/chatwoot-runtime-apk.txt \\\n' +
  '    /contract/config/chatwoot-runtime-apk-cve-floors.tsv /contract/config/chatwoot-runtime-apk-unowned-files.tsv';
const RUNTIME_APK_LINT = 'ruby "$CONTROL_ROOT/tests/verify_chatwoot_runtime_apk.rb" --lint "$CONTROL_ROOT/config/chatwoot-runtime-apk.txt" \\\n' +
  '    "$CONTROL_ROOT/config/chatwoot-runtime-apk-cve-floors.tsv" "$CONTROL_ROOT/config/chatwoot-runtime-apk-unowned-files.tsv"';
// The gate's proof that the production image ships no Node. `! command -v node` would never fail: set -e ignores `!`.
const NODE_FILE_PROBE = 'test ! -e /usr/local/bin/node';
const NODE_PATH_PROBE = 'test -z "$(command -v node || :)"';
const NODE_GATE_PROBES = `      test ! -e /usr/local/bin/npx\n      ${NODE_FILE_PROBE}\n      ${NODE_PATH_PROBE}\n` +
  '      sha256sum -c /contract/production-overlay.sha256\n';
// The Alpine EOL line (CW-1) is display only. The publisher prints it right after the source check with the same
// fixed release as the SBOM distro and Trivy --distro; the quality gate reads the fixed runtime image's release.
// Neither may stop a release (`|| true`).
const ALPINE_RELEASE = '3.22.0';
const ALPINE_EOL_STEP = '      - name: Alpine branchのEOLをStep Summaryへ出す(出荷は止めない)\n' +
  `        run: python3 -I scripts/chatwoot-alpine-status.py eol --release ${ALPINE_RELEASE} || true\n`;
const ALPINE_EOL_GATE = '  python3 "$CONTROL_ROOT/scripts/chatwoot-alpine-status.py" eol --release="$alpine_release" || true\n';
const ALPINE_RELEASE_GATE = `"$CHATWOOT_RUNTIME_IMAGE" sh -c 'cat /etc/alpine-release' 2>/dev/null)" || \\\n    alpine_release=''\n`;
// Pinned Trivy reads an OS package's source name only from SPDX sourceInfo; pinned Syft writes it only as purl upstream=, so
// renamed Alpine packages (ssl_client, libcrypto3, libcurl ...) were scanned under their own names. The raw scan reads a copy
// supplemented once by the shared script (the same implementation the daily advisory watch loads). The attested SBOM and the copy
// the classification binds stay byte-identical; an unreadable shape or no package to supplement fails the step.
const OS_SOURCE_SCRIPT = 'scripts/spdx-os-source.py';
const OS_SOURCE_LINE = `python3 -I ${OS_SOURCE_SCRIPT} "$security/sbom.spdx.json" "$security/scan-sbom.spdx.json"`;
const BINDING_COPY_LINE = 'cp "$RUNNER_TEMP/toybaco-chatwoot.spdx.json" "$security/sbom.spdx.json"';
const SCAN_SBOM_MOUNT = '--mount "type=bind,src=$security/scan-sbom.spdx.json,dst=/scan/sbom.spdx.json,readonly"';
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
// Runner CLI check: the hosted runner's gh, aws and docker change with the weekly runner image update (Docker 29 and
// the containerd image store were rolled out once in 2026-02 and rolled back). The publisher reads the buildx digest,
// ECR's DescribeImages and imagetools manifest, the ECR scan, the pulled image's `docker image inspect` and the
// attestations as the behavior of these majors and the classic overlay2 image store; with the containerd image store
// the image ID is no longer the config digest. Right after checkout (before the source recheck, OIDC and the build)
// one step stops with TOYBACO_RUNNER_CLI=UNEXPECTED on another image store, another gh or aws major (their output is parsed),
// or a missing, failing or unparsable tool; another Docker major only warns (TOYBACO_RUNNER_CLI=WARN in the log and the
// Step Summary), so a new Docker major that keeps overlay2 does not stop every release. Expected values: runner image
// 20261012.334.1 (gh 2.102.0, AWS CLI 2.37.13, Docker 28.0.4). The step is the same in both repositories.
const RUNNER_CLI_STEP = 'runner付属のgh・aws・dockerの版とimage storeをbuild前に確認';
const RUNNER_CLI_RUN_LINES = Object.freeze([
  "set -Eeuo pipefail",
  "export LC_ALL=C",
  "# hosted runner(ubuntu-24.04)の gh・aws・docker は、runner image の週次の更新で版が変わる。この publisher は、buildx の",
  "# metadata の digest と ECR の DescribeImages・imagetools の manifest の照合、ECR の scan、pull した image の docker image",
  "# inspect と proof、attestation の検証を、下の major と従来の image store(overlay2)の挙動として読む。Docker 29 の containerd",
  "# image store では image ID の意味が変わる。image store が違う、gh か aws の major が違う、道具が無いか読めないときは、",
  "# 何が想定外かを固定語(TOYBACO_RUNNER_CLI=UNEXPECTED)で出して build の前に止める。docker の major の違いだけは警告",
  "# (TOYBACO_RUNNER_CLI=WARN)にとどめる。期待値は、新しい版の挙動を確かめてから契約テストと同じ変更で上げる。",
  "expected_gh_major='2'",
  "expected_aws_major='2'",
  "expected_docker_major='28'",
  "unexpected() {",
  "  echo \"::error::TOYBACO_RUNNER_CLI=UNEXPECTED $1\"",
  "  exit 1",
  "}",
  "# 版の文字列から major.minor.patch だけを取り出す。取り出せない出力はそのまま出さずに止める。",
  "parsed_major=''",
  "parsed_version=''",
  "parse_version() {",
  "  if [[ ! \"$2\" =~ $3 ]]; then",
  "    unexpected \"${1}=unparsable\"",
  "  fi",
  "  parsed_major=\"${BASH_REMATCH[1]}\"",
  "  parsed_version=\"${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}\"",
  "}",
  "# gh・aws は major が違うと出力の解析が壊れうるので止める。",
  "require_major() {",
  "  if [[ \"$parsed_major\" != \"$2\" ]]; then",
  "    unexpected \"${1}_major=${parsed_major} expected_major=${2} version=${parsed_version}\"",
  "  fi",
  "}",
  "# docker の major の違いは警告だけにする(image store は下で別に止める)。overlay2 のままの新しい major で hotfix まで止めないため。",
  "warn_docker_major() {",
  "  if [[ \"$parsed_major\" != \"$expected_docker_major\" ]]; then",
  "    echo \"::warning::TOYBACO_RUNNER_CLI=WARN docker_major=${parsed_major} component=${1} expected_major=${expected_docker_major} version=${parsed_version}\"",
  "    printf 'TOYBACO_RUNNER_CLI=WARN docker_major=%s component=%s expected_major=%s version=%s\\n' \\",
  "      \"$parsed_major\" \"$1\" \"$expected_docker_major\" \"$parsed_version\" >> \"$GITHUB_STEP_SUMMARY\"",
  "  fi",
  "}",
  "for tool in gh aws docker; do",
  "  if ! command -v \"$tool\" >/dev/null 2>&1; then",
  "    unexpected \"${tool}=missing\"",
  "  fi",
  "done",
  "gh_output=\"$(gh --version)\" || unexpected 'gh=failed'",
  "parse_version gh \"$gh_output\" '^gh version ([0-9]+)\\.([0-9]+)\\.([0-9]+)'",
  "require_major gh \"$expected_gh_major\"",
  "gh_version=\"$parsed_version\"",
  "aws_output=\"$(aws --version)\" || unexpected 'aws=failed'",
  "parse_version aws \"$aws_output\" '^aws-cli/([0-9]+)\\.([0-9]+)\\.([0-9]+)'",
  "require_major aws \"$expected_aws_major\"",
  "aws_version=\"$parsed_version\"",
  "docker_client_output=\"$(docker version --format '{{.Client.Version}}')\" || unexpected 'docker_client=failed'",
  "parse_version docker_client \"$docker_client_output\" '^([0-9]+)\\.([0-9]+)\\.([0-9]+)([-+][0-9A-Za-z.+-]*)?$'",
  "warn_docker_major client",
  "docker_client_version=\"$parsed_version\"",
  "docker_server_output=\"$(docker version --format '{{.Server.Version}}')\" || unexpected 'docker_server=failed'",
  "parse_version docker_server \"$docker_server_output\" '^([0-9]+)\\.([0-9]+)\\.([0-9]+)([-+][0-9A-Za-z.+-]*)?$'",
  "warn_docker_major server",
  "docker_server_version=\"$parsed_version\"",
  "# image store は従来の graph driver の overlay2 だけを受ける。containerd image store は Driver が overlayfs などになり、",
  "# DriverStatus に driver-type io.containerd.snapshotter.v1 が出る(image ID が config digest でなくなる)。",
  "docker_driver=\"$(docker info --format '{{.Driver}}')\" || unexpected 'docker_info=failed'",
  "docker_driver_status=\"$(docker info --format '{{json .DriverStatus}}')\" || unexpected 'docker_info=failed'",
  "if [[ \"$docker_driver_status\" == *io.containerd.snapshotter* ]]; then",
  "  unexpected 'docker_image_store=containerd-snapshotter'",
  "fi",
  "if [[ \"$docker_driver\" != 'overlay2' ]]; then",
  "  if [[ ! \"$docker_driver\" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then",
  "    docker_driver='unparsable'",
  "  fi",
  "  unexpected \"docker_storage_driver=${docker_driver} expected=overlay2\"",
  "fi",
  "runner_image=\"${ImageOS:-unknown}-${ImageVersion:-unknown}\"",
  "if [[ ! \"$runner_image\" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then",
  "  runner_image='unknown'",
  "fi",
  "printf 'TOYBACO_RUNNER_CLI=OK gh=%s aws=%s docker_client=%s docker_server=%s docker_storage_driver=%s runner_image=%s\\n' \\",
  "  \"$gh_version\" \"$aws_version\" \"$docker_client_version\" \"$docker_server_version\" \"$docker_driver\" \"$runner_image\" \\",
  "  | tee -a \"$GITHUB_STEP_SUMMARY\"",
]);
const RUNNER_CLI_STEP_TEXT = `      - name: ${RUNNER_CLI_STEP}\n        shell: bash\n        run: |\n` +
  RUNNER_CLI_RUN_LINES.map(line => (line ? `          ${line}` : '')).join('\n') + '\n';
const PUBLISH_CHECKOUT_STEP = 'owner review済みmain sourceを取得';
const PUBLISH_SOURCE_STEP = 'main commit・固定Chatwoot source・exact overlayを再確認';

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
  // The runner CLI check runs once, exactly as reviewed, between the checkout (the job's first step) and the source
  // recheck, so it precedes the OIDC session, the registry login and the build.
  const runnerCliMarker = `      - name: ${RUNNER_CLI_STEP}\n`;
  assert.equal(workflowSource.split(runnerCliMarker).length - 1, 1, 'the runner CLI check must run exactly once');
  const publishSteps = publish.indexOf('    steps:\n      - name: ');
  const runnerCliStart = publish.indexOf(runnerCliMarker);
  const runnerCliEnd = publish.indexOf('\n      - name: ', runnerCliStart + runnerCliMarker.length);
  assert.ok(publishSteps >= 0 && runnerCliStart > publishSteps && runnerCliEnd > runnerCliStart,
    'the publish job must check the runner CLIs');
  const checkoutStart = publishSteps + '    steps:\n'.length;
  const checkout = publish.slice(checkoutStart, runnerCliStart);
  assert.ok(checkout.startsWith(`      - name: ${PUBLISH_CHECKOUT_STEP}\n        uses: ${ACTIONS.checkout} `) &&
    count(checkout, /^ {6}- /gm) === 1, 'the runner CLI check must directly follow the checkout, the first publisher step');
  assert.equal(publish.slice(runnerCliStart, runnerCliEnd), RUNNER_CLI_STEP_TEXT,
    'the runner CLI check must be exactly the reviewed step (no condition, env or tolerance)');
  assert.ok(publish.startsWith(`\n      - name: ${PUBLISH_SOURCE_STEP}\n`, runnerCliEnd),
    'the runner CLI check must run right before the source recheck');
  assert.equal(publish.split(ALPINE_EOL_STEP).length - 1, 1, 'publisher must print the Alpine EOL line exactly once');
  const alpineEolIndex = publish.indexOf(ALPINE_EOL_STEP);
  assert.ok(publish.indexOf('main commit・固定Chatwoot source・exact overlayを再確認') < alpineEolIndex &&
    alpineEolIndex < publish.indexOf('GitHub OIDCで本番publisher roleを取得'),
    'the Alpine EOL line must follow the source check and precede the publisher credentials');
  assert.equal(count(workflowSource, /chatwoot-alpine-status\.py"? eol /g), 1, 'one Alpine EOL line in the workflow');
  assert.deepEqual([...publish.matchAll(/--distro alpine\/(\S+)/g)].map(match => match[1]), [ALPINE_RELEASE],
    'the Alpine EOL release must be the raw scan distro');
  assert.deepEqual([...publish.matchAll(/distro=alpine-([0-9.]+)/g)].map(match => match[1]), [ALPINE_RELEASE],
    'the Alpine EOL release must be the SBOM distro');

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
    `CHATWOOT_RUNTIME_IMAGE: ${RUNTIME_IMAGE}`,
    `[[ "$CHATWOOT_RUNTIME_IMAGE" == '${RUNTIME_IMAGE}' ]]`,
    'grep -Fqx "ARG RUBY_RUNTIME_IMAGE=$CHATWOOT_RUNTIME_IMAGE" Dockerfile',
    '--build-arg "RUBY_RUNTIME_IMAGE=$CHATWOOT_RUNTIME_IMAGE"',
    '--arg base "$CHATWOOT_RUNTIME_IMAGE"',
    '--arg upstream "$CHATWOOT_BASE_IMAGE"',
    '.config.Labels["org.opencontainers.image.base.name"] == $base and',
    '.config.Labels["jp.toybaco.upstream.image"] == $upstream and',
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
    `--distro alpine/${ALPINE_RELEASE}`, '--exit-code 1 --list-all-pkgs', '--config /dev/null sbom',
    '--network none --workdir /scan', '"$TRIVY_IMAGE"', 'toybaco-chatwoot.spdx.json',
    '.checksumValue == $digest', '.relationshipType == "DESCRIBES"',
    'image: registry:${{ steps.build.outputs.image_uri }}',
    '.versionInfo == ("sha256:" + $digest)', `distro=alpine-${ALPINE_RELEASE}`,
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
    RAILS_PROOF_RUN,
    'scripts/verify-chatwoot-ruby-llm-classification.mjs evaluate \\\n' +
      '            "$security" config/chatwoot-ruby-llm-backport.json config/chatwoot-rails-backport.json',
    'scripts/verify-chatwoot-ruby-llm-classification.mjs verify-attestations \\\n' +
      '            "$security" config/chatwoot-ruby-llm-backport.json config/chatwoot-rails-backport.json',
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
  // Both installed proofs run on the exact digest before the classification; only the Rails proof gets a private /tmp.
  assert.equal(publish.split(RAILS_PROOF_RUN).length - 1, 1, 'one Rails installed proof on the exact image');
  assert.equal(count(publish, /--tmpfs /g), 1, 'only the Rails proof gets a writable /tmp');
  assert.ok(publish.indexOf('> "$security/installed-proof.json"') < publish.indexOf(RAILS_PROOF_RUN) &&
    publish.indexOf(RAILS_PROOF_RUN) < publish.indexOf('scripts/verify-chatwoot-ruby-llm-classification.mjs evaluate'),
  'the Rails proof follows the RubyLLM proof and precedes the classification');
  // The raw scan reads the supplemented copy, made once right after the binding copy and before the scanner runs.
  assert.equal(count(workflowSource, /spdx-os-source\.py/g), 2, 'the OS source script: one push path and one call');
  assert.equal(publish.split(OS_SOURCE_LINE).length - 1, 1, 'the raw scan input must be supplemented exactly once');
  assert.ok(publish.includes(`          ${OS_SOURCE_LINE}\n`), 'the OS source supplement must be a plain line (no tolerance)');
  assert.equal(publish.split(BINDING_COPY_LINE).length - 1, 1, 'the classification binds an exact copy of the attested SBOM');
  assert.ok(publish.indexOf(BINDING_COPY_LINE) < publish.indexOf(OS_SOURCE_LINE) &&
    publish.indexOf(OS_SOURCE_LINE) < publish.indexOf('docker pull "$TRIVY_IMAGE"'),
  'the supplement must follow the binding copy and precede the scanner');
  assert.ok(rawScan.includes(SCAN_SBOM_MOUNT), 'the raw scan must read the supplemented copy');
  assert.equal(count(publish, /dst=\/scan\/sbom\.spdx\.json/g), 1, 'one SBOM mount into the scanner');
  assert.ok(workflowSource.includes(`      - '${OS_SOURCE_SCRIPT}'\n`), 'OS source push path missing');
  assert.equal(count(publish, /--download-db-only/g), 1, 'one fresh DB download');
  assert.equal(count(publish, /--cert-oidc-issuer 'https:\/\/token\.actions\.githubusercontent\.com'/g), 4);
  assert.doesNotMatch(publish, /--ignore-unfixed=true|--ignorefile|--ignore-policy|--vex|--skip-files|--skip-dirs|--ignore-status/);
  for (const name of ['config/chatwoot-ruby-llm-backport.json', 'scripts/harden-chatwoot-ruby-llm.rb',
    'scripts/verify-chatwoot-ruby-llm-classification.mjs', 'docs/chatwoot-ruby-llm-backport-policy.md',
    'config/chatwoot-rails-backport.json', 'scripts/harden-chatwoot-rails.rb', 'docs/chatwoot-rails-backport-policy.md']) {
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
  for (const required of ['config/chatwoot-runtime-gems.json', 'scripts/harden-chatwoot-runtime-gems.rb', 'tests/verify_chatwoot_runtime_gems.rb', 'config/chatwoot-ruby-llm-backport.json', 'scripts/harden-chatwoot-ruby-llm.rb', 'tests/verify_chatwoot_ruby_llm_backport.rb', 'tests/chatwoot_ruby_llm_backport_test.rb', 'scripts/verify-chatwoot-ruby-llm-classification.mjs', 'tests/chatwoot-ruby-llm-classification.test.mjs', 'docs/chatwoot-ruby-llm-backport-policy.md', 'tests/chatwoot-managed-publisher.test.mjs', 'scripts/chatwoot-alpine-status.py', OS_SOURCE_SCRIPT, 'config/chatwoot-rails-backport.json', 'scripts/harden-chatwoot-rails.rb', 'tests/verify_chatwoot_rails_backport.rb', 'tests/chatwoot_rails_backport_test.rb', 'docs/chatwoot-rails-backport-policy.md']) {
    assert.ok(controlFiles.includes(`'${required}'`), `runtime input missing from quality/export control: ${required}`);
  }
  const baseContract = functionBlock(gateSource, 'verify_base_and_frame_contract', 'build_test_image');
  assert.equal(baseContract.split(ALPINE_RELEASE_GATE + ALPINE_EOL_GATE).length - 1, 1,
    'the quality gate must print the Alpine EOL line once from the fixed base image without failing');
  assert.equal(count(gateSource, /chatwoot-alpine-status\.py"? eol /g), 1, 'one Alpine EOL line in the gate');
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
    `readonly CHATWOOT_RUNTIME_IMAGE='${RUNTIME_IMAGE}'`,
    '"ARG RUBY_RUNTIME_IMAGE=$CHATWOOT_RUNTIME_IMAGE"',
    '--build-arg "RUBY_RUNTIME_IMAGE=$CHATWOOT_RUNTIME_IMAGE"',
    '[[ "$actual_base_label" == "$CHATWOOT_RUNTIME_IMAGE" ]]',
    'production imageの上流image labelが不一致です',
    'production imageに上流imageのENVがありません',
    '"$CHATWOOT_RUNTIME_IMAGE" \\\n    | sed \'/^$/d\' > "$RUN_ROOT/base-layers"',
    '--build-arg "CHATWOOT_IMAGE=$PRODUCTION_IMAGE"',
    RUNTIME_APK_PROBE,
    RUNTIME_APK_LINT,
    'ruby "$CONTROL_ROOT/tests/chatwoot_runtime_apk_test.rb"',
    '"$PRODUCTION_IMAGE" sh -c \'\n      set -e\n',
    'assert_single_exact_line "$CONTROL_ROOT/.dockerignore" \'overlay/app/spec\'',
    'test ! -e /app/spec',
    'test ! -e /app/tests/playwright',
    'test ! -e /app/node_modules',
    'test ! -e /usr/local/lib/node_modules/npm',
    'test ! -e /usr/local/bin/npm',
    'test ! -e /usr/local/bin/npx',
    NODE_GATE_PROBES,
    'ruby /contract/tests/verify_chatwoot_runtime_gems.rb /contract/config/chatwoot-runtime-gems.json',
    'Rails.version == %q{7.2.3.2}',
    'Gem.loaded_specs.fetch(%q{ruby-vips}).version.to_s == %q{2.2.1}',
    '-ractive_storage/vips', 'ENV.fetch(%q{VIPS_BLOCK_UNTRUSTED}) == %q{1}',
    'Vips::Image.csvload(csv)', 'csvload: operation is blocked',
    'File.binwrite(exr, "\\x76\\x2f\\x31\\x01".b + ("\\0" * 60).b)',
    'Vips::Image.openexrload(exr)', 'abort unless lines.last == "openexrload: operation is blocked\\n" && lines.size <= 2',
    'Vips::Image.fitsload(fits)', 'abort unless lines.last == "fitsload: operation is blocked\\n" && lines.size <= 2',
    'abort unless error.message == "VipsForeignLoad: \\"#{exr}\\" is not a known file format\\n"',
    'abort unless error.message == "VipsForeignLoad: \\"#{fits}\\" is not a known file format\\n"',
    '"$PRODUCTION_IMAGE" env -u VIPS_BLOCK_UNTRUSTED bundle exec ruby -rruby-vips -rtmpdir -e \'',
    'abort if defined?(Rails) || ENV.key?(%q{VIPS_BLOCK_UNTRUSTED})',
    'abort unless error.message.start_with?("exr2vips: EXR error: ")',
    'abort unless error.message.lines.last == "fits: no HDU found with naxes > 0\\n"',


  ]) {
    assert.ok(gateSource.includes(required), `essential quality gate missing: ${required}`);
  }
  // EXR と FITS の fixture は、受信の経路の probe と block を外した対照の 2 か所に、同じ bytes で置く(片側だけを壊させない)。
  const gateLines = gateSource.split('\n');
  for (const [name, expected] of [
    ['exr', ['        File.binwrite(exr, "\\x76\\x2f\\x31\\x01".b + ("\\0" * 60).b)']],
    ['fits', ['        File.binwrite(fits, (%q{SIMPLE  =                    T}.ljust(80) + %q{BITPIX  =                    8}.ljust(80) +',
      '          %q{NAXIS   =                    0}.ljust(80) + %q{END}.ljust(80)).ljust(2880))']],
  ]) {
    const found = gateLines.flatMap((line, index) => (line.trim().startsWith(`File.binwrite(${name},`)
      ? [gateLines.slice(index, index + expected.length)] : []));
    assert.deepEqual(found, [expected, expected], `vips ${name} fixture must be the same in the probe and the control`);
  }
  assert.match(gateSource, /^  verify_toybaco_database_prepare$/m);
  assert.ok(gateSource.includes('"$TEST_IMAGE" /app/bin/toybaco-chatwoot-schema-preflight'));
  assert.ok(gateSource.includes('--env TOYBACO_CHATWOOT_SCHEMA_REQUIRE_TARGET=true'));
  assert.match(gateSource, /^  run_ruby_quality$/m);
  // The production image is built before the test image, which is made from it, and smoked after the Ruby quality.
  assert.match(gateSource, /^  build_production_image\n  build_test_image\n  start_services$/m);
  assert.match(gateSource, /^  run_ruby_quality\n  smoke_production_image\n  assert_final_boundaries$/m);
  for (const required of [...RUNTIME_APK_INPUTS, 'tests/verify_chatwoot_runtime_apk.rb',
    'tests/chatwoot_runtime_apk_test.rb', 'docs/chatwoot-runtime-os-policy.md']) {
    assert.ok(controlFiles.includes(`'${required}'`), `runtime package input missing from quality/export control: ${required}`);
  }
  for (const input of RUNTIME_APK_INPUTS) {
    assert.ok(workflowSource.includes(`      - '${input}'\n`), `runtime package input push path missing: ${input}`);
  }
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
    'COPY config/chatwoot-rails-backport.json /opt/toybaco/config/',
    'COPY scripts/harden-chatwoot-rails.rb /opt/toybaco/scripts/',
    'COPY tests/verify_chatwoot_rails_backport.rb /opt/toybaco/tests/',
  ];
  for (const text of copies) {
    assert.equal(dockerfile.split(text).length - 1, 2, 'build-only and shipped backport inputs: ' + text);
    assert.ok(testDockerfile.includes(text), 'test backport input missing: ' + text);
  }
  const apply = 'bundle exec ruby /opt/toybaco/scripts/harden-chatwoot-ruby-llm.rb apply';
  const verify = 'bundle exec ruby /opt/toybaco/tests/verify_chatwoot_ruby_llm_backport.rb';
  // The build-only bundle (upstream base, for the asset build) and the shipped Alpine 3.22 gems are both patched.
  assert.equal(dockerfile.split(apply).length - 1, 2, 'build-only and shipped gem patch applications');
  assert.equal(testDockerfile.split(apply).length - 1, 1, 'one test gem patch application');
  assert.equal(dockerfile.split(verify).length - 1, 3, 'build-only, shipped and final production proofs');
  assert.equal(testDockerfile.split(verify).length - 1, 1, 'test gem proof');
  assert.ok(dockerfile.indexOf('bundle clean --force') < dockerfile.indexOf(apply));
  const shippedGems = dockerfile.indexOf('\nFROM runtime-base AS gems\n');
  assert.ok(shippedGems >= 0 && shippedGems < dockerfile.lastIndexOf('bundle clean --force') &&
    dockerfile.lastIndexOf('bundle clean --force') < dockerfile.lastIndexOf(apply) &&
    dockerfile.lastIndexOf(apply) < dockerfile.indexOf('\nFROM runtime-base AS runtime-app\n'),
  'the shipped gems are cleaned and patched in the Alpine 3.22 gems stage');
  assert.ok(dockerfile.lastIndexOf(verify) > dockerfile.indexOf('/app/TOYBACO_PUBLIC_REVISION'));
  // The Rails 7.2.3.2 backport follows each RubyLLM one: the same two gem stages, the final filesystem and the test image.
  const railsApply = 'bundle exec ruby /opt/toybaco/scripts/harden-chatwoot-rails.rb apply';
  const railsVerify = 'bundle exec ruby /opt/toybaco/tests/verify_chatwoot_rails_backport.rb';
  assert.equal(dockerfile.split(verify + ' \\\n    && ' + railsApply + ' \\\n    && ' + railsVerify + ' \\\n').length - 1, 2,
    'build-only and shipped Rails gem patch applications right after the RubyLLM proof');
  assert.equal(dockerfile.split(railsApply).length - 1, 2, 'build-only and shipped Rails gem patch applications');
  assert.equal(dockerfile.split(railsVerify).length - 1, 3, 'build-only, shipped and final production Rails proofs');
  assert.ok(dockerfile.includes(verify + ' \\\n    && ' + railsVerify + '\n'), 'final production Rails proof');
  assert.ok(dockerfile.lastIndexOf(railsApply) < dockerfile.indexOf('\nFROM runtime-base AS runtime-app\n') &&
    dockerfile.lastIndexOf(railsApply) > dockerfile.indexOf('\nFROM runtime-base AS gems\n'), 'the shipped Rails gems are patched');
  assert.ok(dockerfile.lastIndexOf(railsVerify) > dockerfile.indexOf('/app/TOYBACO_PUBLIC_REVISION'));
  assert.equal(testDockerfile.split(railsApply).length - 1, 1, 'one test Rails gem patch application');
  assert.equal(testDockerfile.split(railsVerify).length - 1, 1, 'test Rails gem proof');
  for (const path of ['config/chatwoot-ruby-llm-backport.json', 'scripts/harden-chatwoot-ruby-llm.rb',
    'tests/verify_chatwoot_ruby_llm_backport.rb', 'config/chatwoot-rails-backport.json', 'scripts/harden-chatwoot-rails.rb',
    'tests/verify_chatwoot_rails_backport.rb']) {
    assert.ok(ignore.split('\n').includes('!' + path), 'Docker context backport path missing');
  }
  for (const text of [
    '"$TEST_IMAGE" ' + verify, '"$PRODUCTION_IMAGE" ' + verify,
    '"$TEST_IMAGE" bundle exec ruby /app/tests/chatwoot_ruby_llm_backport_test.rb',
    '    --tmpfs /tmp:rw,noexec,nosuid,size=16m \\\n    "$TEST_IMAGE" ' + railsVerify,
    '    --tmpfs /tmp:rw,noexec,nosuid,size=16m \\\n    "$PRODUCTION_IMAGE" ' + railsVerify,
    '    --tmpfs /tmp:rw,noexec,nosuid,size=64m \\\n    "$TEST_IMAGE" bundle exec ruby /app/tests/chatwoot_rails_backport_test.rb',
    'ActiveStorage.variant_processor == :vips && ActiveStorage.previewers.empty? && ActiveStorage::MINIMAGICK_UNSECURABLE',
    'abort "expected production CE setting" unless ENV.fetch("DISABLE_ENTERPRISE") == "true"',
    'abort "CE Captain task service missing" unless Captain::RewriteService < Captain::BaseTaskService',
    'load "/opt/toybaco/tests/verify_chatwoot_ruby_llm_backport.rb"',
  ]) assert.ok(gateSource.includes(text), 'test/production/CE backport proof missing: ' + text);
}
const buildInputs = ['Dockerfile', 'tests/chatwoot-test.Dockerfile', '.dockerignore'].map(path =>
  readFileSync(join(root, path), 'utf8'));
// The parked SBOM verifiers (release inputs, not run by the quality gate) still prove the Alpine 3.21 builds of
// musl, c-ares and brotli-libs that #579 and #582 shipped. Before they are un-parked for the Alpine 3.22 runtime,
// these versions are to be reviewed against config/chatwoot-runtime-apk.txt.
const MUSL_CARES = [['musl', '1.2.5-r12'], ['musl-utils', '1.2.5-r12'], ['musl-dev', '1.2.5-r12'], ['c-ares', '1.34.9-r0'],
  ['brotli-libs', '1.1.1-r0']];
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
function validateParkedSbomVerifiers(dockerfile, gateSource, verifiers) {
  for (const verifier of verifiers) {
    for (const required of SBOM_PROOFS) {
      assert.ok(verifier.includes(required), `SBOM musl/c-ares proof missing: ${required}`);
    }
  }
  for (const source of [dockerfile, gateSource, ...verifiers]) {
    assert.ok(!source.includes('1.2.5-r11'), 'superseded musl 1.2.5-r11 remains');
  }
}
validateParkedSbomVerifiers(buildInputs[0], gate, sbomVerifiers);
let sbomVerifierNegatives = 0;
for (const [index, verifier] of sbomVerifiers.entries()) {
  for (const text of [...MUSL_CARES.map(([name, version]) => `'${name}' => '${version}'`), SBOM_PROOFS[1]]) {
    const mutated = [...sbomVerifiers];
    mutated[index] = swapOnce(verifier, text, 'omitted', text);
    assert.throws(() => validateParkedSbomVerifiers(buildInputs[0], gate, mutated),
      `omitted SBOM musl/c-ares proof must fail: ${text}`);
    sbomVerifierNegatives++;
  }
}
console.log(`Chatwoot parked SBOM verifiers: PASS (${sbomVerifierNegatives} omission controls)`);
// The Dockerfile is bound byte for byte: the sha256 of its exact bytes (newlines, blanks and continuations included)
// is pinned below, and ONBUILD anywhere or a parser directive fails by name. Imitating Docker's parser and normalizing
// RUN text left gaps (#582: a LABEL ending in `\\` hiding the next RUN, a COPY heredoc read through ARG RUBYOPT, a
// COPY after the checks, a parent stage's ONBUILD, `test -f\` + newline), so the pin is what binds. The Dockerfile is
// a control file: the private CW gate, the PZ gate's control snapshot and the public repository read the same bytes.
// Changing the Dockerfile means reviewing the whole diff and then updating DOCKERFILE_SHA256.
const DOCKERFILE_SHA256 = '4a86555c15e217b980b6d7345074b1b245d1aed661cdd13cb8ccda29765cb718';
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
  'bundled-gems AS localized-assets', 'localized-assets AS runtime-hardening', '${CHATWOOT_IMAGE} AS upstream',
  '${RUBY_RUNTIME_IMAGE} AS runtime-base', 'runtime-base AS gems', 'runtime-base AS runtime-app', 'runtime-app'];
const STAGE_INSTRUCTIONS = { hardening: ['RUN'], final: ['RUN', 'COPY', 'ARG', 'LABEL'] };
const STAGE_COPY_SOURCES = ['runtime-hardening', 'overlay-normalizer'];
// The only RUN flag: the final stage's two checks borrow the upstream Node, read-only, for their own RUN.
const NODE_BUILD_MOUNT = '--mount=type=bind,from=upstream,source=/usr/local/bin/node,target=/usr/local/bin/node';
const NODE_BUILD_CHECKS = Object.freeze([
  `${NODE_BUILD_MOUNT} /usr/local/bin/node /opt/toybaco/tests/verify_chatwoot_sdk_artifacts.mjs /app/public/packs/js`,
  `${NODE_BUILD_MOUNT} /usr/local/bin/node /opt/toybaco/tests/verify_chatwoot_sprockets_artifacts.mjs --verify-final /app/public/assets`,
]);
const NODE_ABSENT_CHECK = `${NODE_FILE_PROBE} && ${NODE_PATH_PROBE}`;
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
  const hardening = instructions.slice(froms[3].index + 1, froms[4].index);
  return {
    hardening,
    final: instructions.slice(froms[froms.length - 1].index + 1),
    // Every stage whose files reach the shipped image: all but bundled-gems and localized-assets (only their assets
    // arrive, through runtime-hardening) and the empty upstream stage.
    shipped: [...instructions.slice(froms[0].index + 1, froms[1].index), ...hardening, ...instructions.slice(froms[5].index + 1)],
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
        if (stage !== 'final' || !NODE_BUILD_CHECKS.includes(text)) {
          assert.doesNotMatch(text, /^(?:\[|--)/, `${where}: RUN exec form or RUN flags are not allowed`);
        }
        assert.doesNotMatch(text, /<<-?["']?[A-Za-z_]/, `${where}: RUN heredocs are not allowed`);
      }
    }
  }
}
validateStageClosure(buildInputs[0]);
// On the Alpine 3.22 runtime neither stage requests a package: runtime-base installs the reviewed list
// (config/chatwoot-runtime-apk.txt), and the final stage only verifies it.
const APK_ALLOWED = { hardening: [], final: [] };
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
    rest = rest.replace(commandPattern('apk info -v'), 'ALLOWED_APK_READ').split(RUNTIME_APK_VERIFY).join('RUNTIME_APK_VERIFY')
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
// Mutants are spliced next to a continuation line of runtime-hardening's RUN and of the final stage's check RUN.
const HARDENING_LINE = '    && cp -a /app/public/vite /toybaco-runtime-root/app/public/vite \\\n';
const FINAL_LINE = `    && ${RUNTIME_APK_VERIFY} \\\n`;
for (const [from, to] of [
  // Astra's #581 counterexample: a concatenated v3.22 URL fetched, then installed by an apk call with the option first.
  [HARDENING_LINE, '    && ruby -ropen-uri -e \'URI.open("https://dl-cdn.alpinelinux.org/alpine/" + "v3.22/main/x86_64/openjpeg-2.5.4-r1.apk") { |input| File.binwrite("/tmp/x.apk", input.read) }\' \\\n    && apk --no-network add /tmp/x.apk \\\n' + HARDENING_LINE],
  [HARDENING_LINE, '    && apk --no-network add /tmp/x.apk \\\n' + HARDENING_LINE],
  [HARDENING_LINE, '    && ruby -e \'require %q{open-uri}; IO.copy_stream(URI.open(%q{dl-cdn.alpinelinux.org}), %q{/tmp/o})\' \\\n' + HARDENING_LINE],
  [HARDENING_LINE, '    && ruby -rnet/http -e \'Net::HTTP.get(%q{dl-cdn.alpinelinux.org}, %q{/x})\' \\\n' + HARDENING_LINE],
  [HARDENING_LINE, '    && wget -qO /tmp/o dl-cdn.alpinelinux.org/alpine \\\n' + HARDENING_LINE],
  [HARDENING_LINE, '    && ruby -e \'Kernel.open(%q{https://dl-cdn.alpinelinux.org/x}) { |input| input.read }\' \\\n' + HARDENING_LINE],
  [HARDENING_LINE, '    && curl -fsSo /tmp/o dl-cdn.alpinelinux.org/alpine \\\n' + HARDENING_LINE],
  // A differently named APK file, an unverified install, and apk under another path or a built-up name.
  [HARDENING_LINE, '    && apk add /tmp/renamed.apk \\\n' + HARDENING_LINE],
  [HARDENING_LINE, HARDENING_LINE + "    && apk add --no-cache 'openjpeg=2.5.4-r1' --allow-untrusted \\\n"],
  [HARDENING_LINE, HARDENING_LINE + "    && apk add --allow-untrusted --no-cache 'openjpeg=2.5.4-r1' \\\n"],
  [HARDENING_LINE, HARDENING_LINE + "    && /sbin/apk add --no-cache 'openjpeg=2.5.4-r1' \\\n"],
  [HARDENING_LINE, HARDENING_LINE + '    && tool=ap && "${tool}k" add --allow-untrusted /tmp/x \\\n'],
  [HARDENING_LINE, HARDENING_LINE + '    && tool=ap && "${tool}k" add --no-network /tmp/x \\\n'],
  // Another repository, an upgrade, an unreviewed request, and extra apk operations in the final stage.
  [HARDENING_LINE, HARDENING_LINE + "    && apk add --no-cache -X https://dl-cdn.alpinelinux.org/alpine/v3.22/main 'openjpeg=2.5.4-r1' \\\n"],
  [HARDENING_LINE, HARDENING_LINE + '    && tool=ap && "${tool}k" --repository=/tmp/repo add openjpeg \\\n'],
  [HARDENING_LINE, HARDENING_LINE + '    && tool=ap && "${tool}k" add -X /tmp/repo openjpeg \\\n'],
  [HARDENING_LINE, HARDENING_LINE + '    && tool=ap && "${tool}k" add -u openjpeg \\\n'],
  [HARDENING_LINE, HARDENING_LINE + "    && apk add --no-cache 'openjpeg=2.5.4-r1' -u \\\n"],
  [HARDENING_LINE, HARDENING_LINE + "    && apk add --no-cache 'openjpeg=2.5.4-r1' \\\n"],
  [FINAL_LINE, FINAL_LINE + "    && apk add --no-cache --upgrade 'musl=1.2.5-r13' \\\n"],
  [FINAL_LINE, FINAL_LINE + '    && apk fix \\\n'],
  [FINAL_LINE, FINAL_LINE + '    && sh -c "apk add brotli" \\\n'],
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
  const at = buildInputs[0].lastIndexOf('\nFROM runtime-app\n');
  return `${buildInputs[0].slice(0, at)}\n${text}${buildInputs[0].slice(at)}`;
};
let bytePinNegatives = 0;
for (const mutated of [
  // #582 first review (Astra): dynamic names and options, RUN in other forms, other instructions.
  appendFinal(`RUN tool=ap; "\${tool}k" --allow-""untrusted add ${FOREIGN}`),
  appendFinal(`RUN eval "a""pk --allow-un""trusted add ${FOREIGN}"`),
  appendFinal(`RUN "$(printf '%s' ap)k" --allow-untrusted add ${FOREIGN}`),
  appendFinal('RUN c""url -fsSo /tmp/x dl-cdn.alpinelinux.org/alpine/v3.22/main/x86_64/openjpeg-2.5.4-r1.apk'),
  swapOnce(buildInputs[0], FINAL_LINE, `${FINAL_LINE}    && tool=ap && "\${tool}k" --allow-""untrusted add ${FOREIGN} \\\n`,
    FINAL_LINE),
  swapOnce(buildInputs[0], HARDENING_LINE, `${HARDENING_LINE}    && eval "a""pk add --allow-un""trusted ${FOREIGN}" \\\n`,
    HARDENING_LINE),
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
  swapOnce(buildInputs[0], FINAL_LINE, `${FINAL_LINE}\n`, FINAL_LINE),
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
  swapOnce(buildInputs[0], '    && test ! -e /usr/local/bin/npm \\\n', '    && test ! -e\\\n/usr/local/bin/npm \\\n',
    'test ! -e npm'),
  appendFinal(`COPY foreign.apk ${FOREIGN}`),
  swapOnce(buildInputs[0], FINAL_LINE, FINAL_LINE.replace(/\\\n$/, '\\ \n'), FINAL_LINE),
  appendFinal('RUN cat<<EOF > /tmp/x.rb\nsystem(%q{echo UNREVIEWED})\nEOF'),
  swapOnce(buildInputs[0], FINAL_LINE, FINAL_LINE.replace(/^ {4}/, '  '), FINAL_LINE),
  swapOnce(buildInputs[0], FINAL_LINE, FINAL_LINE.replace(/ \\\n$/, '\\\n'), FINAL_LINE),
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
// Node is not shipped (docs/chatwoot-runtime-os-policy.md): nothing in a stage that reaches the image names it except
// the final stage's two borrowed checks and the proof after them, and only the reviewed COPY --from lines cross stages.
// Like the stage closure these are readable reasons; the byte pin above is what binds the Dockerfile.
const SHIPPED_STAGE_COPIES = Object.freeze(['--from=gems /gems /gems', '--from=gems /opt/toybaco/ /opt/toybaco/',
  '--from=upstream /app /app', '--from=overlay-normalizer /toybaco-overlay/Gemfile /toybaco-overlay/Gemfile.lock /app/',
  '--from=runtime-hardening /toybaco-runtime-root/ /', '--from=overlay-normalizer /toybaco-overlay/ /app/']);
function validateNodeNotShipped(dockerfile) {
  const { final, shipped } = dockerStages(dockerfile);
  const finalRuns = final.filter(({ keyword }) => keyword === 'RUN');
  const reviewed = [...NODE_BUILD_CHECKS, NODE_ABSENT_CHECK].map(text => {
    const found = finalRuns.filter(instruction => instruction.text === text);
    assert.equal(found.length, 1, `Node contract: the final stage must run once: ${text}`);
    return found[0];
  });
  assert.ok(reviewed[0].line < reviewed[2].line && reviewed[1].line < reviewed[2].line,
    'Node contract: the absence check must follow the borrowed checks');
  for (const instruction of shipped) {
    const { keyword, line, text } = instruction;
    if (reviewed.includes(instruction)) continue;
    const where = `Node contract (Dockerfile line ${line})`;
    assert.doesNotMatch(text, /\bnode(?:js)?\b/i, `${where}: a stage that reaches the image names Node`);
    assert.doesNotMatch(text, /\bapk\b[^&|;]*\b(?:npm|yarn|pnpm)\b/, `${where}: an apk request that pulls in Node`);
    if (keyword === 'RUN') assert.doesNotMatch(text, /^--/, `${where}: RUN flags beyond the borrowed checks`);
    if (keyword === 'ADD' || (keyword === 'COPY' && /(?:^|\s)--from=/.test(text))) {
      assert.ok(keyword === 'COPY' && SHIPPED_STAGE_COPIES.includes(text), `${where}: unreviewed ${keyword} ${text}`);
    }
  }
  assert.ok(shipped.some(({ keyword, text }) => keyword === 'ENV' && /(?:^|\s)EXECJS_RUNTIME=Disabled(?:\s|$)/.test(text)),
    'Node contract: without EXECJS_RUNTIME=Disabled ExecJS looks for a JavaScript runtime');
}
validateNodeNotShipped(buildInputs[0]);
const RUNTIME_BASE_ANCHOR = '# Same Ruby 3.4.4, so the default/bundled gem hardening applies unchanged.\n';
const RUNTIME_BASE_PACKAGES = 'apk add --no-cache build-base openssl tzdata postgresql-client git vips';
const OVERLAY_TOUCH_RUN = 'RUN find /toybaco-overlay -exec touch -t 200001010000.00 {} +\n';
const [SDK_CHECK_RUN, SPROCKETS_CHECK_RUN, NODE_ABSENT_RUN] = [...NODE_BUILD_CHECKS.map(text => `RUN ${text}\n`),
  `RUN ${NODE_ABSENT_CHECK}\n`];
const atRuntimeBase = text => swapOnce(buildInputs[0], RUNTIME_BASE_ANCHOR, `${text}\n${RUNTIME_BASE_ANCHOR}`, 'runtime-base anchor');
let nodeNegatives = 0;
for (const [mutated, reason] of [
  // Node back in the runtime: the removed COPY, another path, its directory, another stage's copy, or after the proof.
  [atRuntimeBase('COPY --from=upstream /usr/local/bin/node /usr/local/bin/node'), /names Node/],
  [atRuntimeBase('COPY --from=upstream /usr/local/bin/node /opt/toybaco/node'), /names Node/],
  [atRuntimeBase('COPY --link --from=upstream /usr/local/bin/node /usr/bin/'), /names Node/],
  [atRuntimeBase('COPY --from=upstream /usr/local/bin/ /opt/toybaco/upstream-bin/'), /unreviewed COPY/],
  [atRuntimeBase('COPY --from=localized-assets /usr/local/bin/node /usr/local/bin/node'), /names Node/],
  [atRuntimeBase('COPY --from=bundled-gems /usr/local/ /opt/toybaco/upstream-local/'), /unreviewed COPY/],
  [atRuntimeBase('ADD https://nodejs.org/dist/v24.22.1/node-v24.22.1-linux-x64-musl.tar.xz /opt/toybaco/'), /names Node/],
  [atRuntimeBase('ADD https://example.invalid/runtime.tar.xz /opt/toybaco/'), /unreviewed ADD/],
  [appendFinal('COPY --from=upstream /usr/local/bin/node /usr/local/bin/node'), /names Node/],
  // Node from a package, in the runtime base and in the final stage.
  [swapOnce(buildInputs[0], RUNTIME_BASE_PACKAGES, `${RUNTIME_BASE_PACKAGES} nodejs`, 'packages'), /names Node/],
  [swapOnce(buildInputs[0], RUNTIME_BASE_PACKAGES, `${RUNTIME_BASE_PACKAGES} nodejs-current`, 'packages'), /names Node/],
  [swapOnce(buildInputs[0], RUNTIME_BASE_PACKAGES, `${RUNTIME_BASE_PACKAGES} npm`, 'packages'), /pulls in Node/],
  [swapOnce(buildInputs[0], FINAL_LINE, `${FINAL_LINE}    && apk add --no-cache nodejs \\\n`, FINAL_LINE), /names Node/],
  // Node carried through a stage the image copies from, or a mount used by another stage.
  [swapOnce(buildInputs[0], HARDENING_LINE, `${HARDENING_LINE}    && cp -a /usr/local/bin/node /toybaco-runtime-root/usr/local/bin/ \\\n`, HARDENING_LINE), /names Node/],
  [swapOnce(buildInputs[0], OVERLAY_TOUCH_RUN, `RUN cp /usr/local/bin/node /toybaco-overlay/node\n${OVERLAY_TOUCH_RUN}`, OVERLAY_TOUCH_RUN), /names Node/],
  [atRuntimeBase('RUN --mount=type=bind,from=upstream,source=/usr/local/bin,target=/opt/toybaco/upstream-bin true'), /RUN flags/],
  // The two checks and the proof: not borrowed any more, gone, or the proof gone, softened or before the checks.
  [swapOnce(buildInputs[0], SDK_CHECK_RUN, SDK_CHECK_RUN.replace(`${NODE_BUILD_MOUNT} /usr/local/bin/`, ''), SDK_CHECK_RUN), /must run once/],
  [swapOnce(buildInputs[0], SDK_CHECK_RUN, '', SDK_CHECK_RUN), /must run once/],
  [swapOnce(buildInputs[0], SPROCKETS_CHECK_RUN, '', SPROCKETS_CHECK_RUN), /must run once/],
  [swapOnce(buildInputs[0], SPROCKETS_CHECK_RUN, SPROCKETS_CHECK_RUN.replace(NODE_BUILD_MOUNT, `${NODE_BUILD_MOUNT},rw`), SPROCKETS_CHECK_RUN), /must run once/],
  [swapOnce(buildInputs[0], NODE_ABSENT_RUN, '', NODE_ABSENT_RUN), /must run once/],
  [swapOnce(buildInputs[0], NODE_ABSENT_RUN, NODE_ABSENT_RUN.replace('\n', ' || :\n'), NODE_ABSENT_RUN), /must run once/],
  [swapOnce(buildInputs[0], SDK_CHECK_RUN, NODE_ABSENT_RUN + SDK_CHECK_RUN, SDK_CHECK_RUN).replace(`${SPROCKETS_CHECK_RUN}${NODE_ABSENT_RUN}`, SPROCKETS_CHECK_RUN), /must follow/],
  // ExecJS would look for a JavaScript runtime.
  [swapOnce(buildInputs[0], '    EXECJS_RUNTIME=Disabled \\\n', '', 'EXECJS_RUNTIME'), /EXECJS_RUNTIME=Disabled/],
  [swapOnce(buildInputs[0], 'EXECJS_RUNTIME=Disabled', 'EXECJS_RUNTIME=Node', 'EXECJS_RUNTIME'), /names Node/],
  [swapOnce(buildInputs[0], 'EXECJS_RUNTIME=Disabled', 'EXECJS_RUNTIME=Bun', 'EXECJS_RUNTIME'), /EXECJS_RUNTIME=Disabled/],
]) {
  assert.notEqual(mutated, buildInputs[0]);
  assert.throws(() => validateNodeNotShipped(mutated), reason, 'Node in the runtime must fail');
  assert.throws(() => validateDockerfileBytes(Buffer.from(mutated, 'utf8')), /Dockerfile bytes changed/);
  nodeNegatives++;
}
// RUN flags stay closed: only the exact borrowed checks in the final stage, not a writable, wider or other mount.
for (const mutated of [
  appendFinal('RUN --network=host true'),
  appendFinal('RUN --security=insecure true'),
  appendFinal(`RUN ${NODE_BUILD_MOUNT},rw /usr/local/bin/node /opt/toybaco/tests/verify_chatwoot_sdk_artifacts.mjs /app/public/packs/js`),
  appendFinal('RUN --mount=type=bind,from=upstream,source=/usr/local/bin,target=/opt/toybaco/upstream-bin true'),
  appendFinal('RUN --mount=type=cache,target=/tmp/x true'),
  appendFinal('RUN --mount=type=secret,id=x true'),
  appendFinal(`RUN ${NODE_BUILD_MOUNT} true`),
  swapOnce(buildInputs[0], '\nFROM ${CHATWOOT_IMAGE} AS upstream\n', `\nRUN ${NODE_BUILD_CHECKS[0]}\nFROM \${CHATWOOT_IMAGE} AS upstream\n`, 'upstream FROM'),
]) {
  assert.throws(() => validateStageClosure(mutated), /RUN exec form or RUN flags are not allowed/, 'a RUN flag beyond the borrowed checks must fail');
  nodeNegatives++;
}
// The gate's PATH probe, run for real under set -e as the gate's sh -c runs it: it must stop on a node on the PATH.
{
  const directory = mkdtempSync(join(tmpdir(), 'chatwoot-node-probe-'));
  try {
    const probe = path => spawnSync('/bin/sh', ['-c', `set -e\n${NODE_PATH_PROBE}\necho reached`], { encoding: 'utf8', env: { PATH: path } });
    const clean = probe(directory);
    assert.equal(clean.status, 0, 'the PATH probe must pass without a node');
    assert.equal(clean.stdout, 'reached\n');
    writeFileSync(join(directory, 'node'), '#!/bin/sh\n', { mode: 0o755 });
    const stopped = probe(directory);
    assert.notEqual(stopped.status, 0, 'the PATH probe must stop on a node on the PATH');
    assert.equal(stopped.stdout, '');
    nodeNegatives++;
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}
console.log(`Chatwoot runtime without Node: PASS (${nodeNegatives} negative controls)`);
// The shipped runtime: the pinned Alpine 3.22 base, alpine-release held at its own build before any upgrade, the
// reviewed package list verified in the runtime base and again on the final filesystem, and labels naming both images.
const RUNTIME_DOCKERFILE = Object.freeze([
  `ARG RUBY_RUNTIME_IMAGE=${RUNTIME_IMAGE}`,
  'FROM ${RUBY_RUNTIME_IMAGE} AS runtime-base',
  ...RUNTIME_APK_INPUTS.map(path => `COPY ${path} /opt/toybaco/${path}`),
  'COPY tests/verify_chatwoot_runtime_apk.rb /opt/toybaco/tests/verify_chatwoot_runtime_apk.rb',
  '    && apk add --no-cache "alpine-release=$alpine_release" \\',
  '    && apk upgrade --no-cache \\',
  '    && apk add --no-cache build-base openssl tzdata postgresql-client git vips \\',
  'FROM runtime-base AS gems',
  'FROM runtime-base AS runtime-app',
  'FROM runtime-app',
  `LABEL org.opencontainers.image.base.name="${RUNTIME_IMAGE}" \\`,
  `      jp.toybaco.upstream.image="${UPSTREAM_IMAGE}" \\`,
  // The whole overlay is copied exactly once, last, after the LABEL (the gate's control contract pins this line).
  'COPY --from=overlay-normalizer /toybaco-overlay/ /app/',
]);
function validateFinalRuntime(dockerfile) {
  const lines = dockerfile.split('\n');
  const at = RUNTIME_DOCKERFILE.map(line => {
    assert.equal(lines.filter(candidate => candidate === line).length, 1, 'shipped runtime contract missing: ' + line);
    return lines.indexOf(line);
  });
  assert.deepEqual([...at].sort((a, b) => a - b), at, 'shipped runtime stages out of order');
  assert.equal(dockerfile.split(RUNTIME_APK_VERIFY).length - 1, 2, 'runtime package list verified twice');
  const final = dockerfile.slice(dockerfile.lastIndexOf('\nFROM runtime-app\n'));
  assert.ok(final.includes(RUNTIME_APK_VERIFY), 'final filesystem must verify the runtime package list');
  // Only build-only stages and the code source come from the upstream (Alpine 3.21) image.
  assert.deepEqual(lines.filter(line => line.startsWith('FROM ${CHATWOOT_IMAGE}')),
    ['FROM ${CHATWOOT_IMAGE} AS overlay-normalizer', 'FROM ${CHATWOOT_IMAGE} AS bundled-gems', 'FROM ${CHATWOOT_IMAGE} AS upstream']);
  assert.doesNotMatch(final, /^FROM (?!runtime-app$)/m, 'the final stage builds on the Alpine 3.22 runtime only');
}
validateFinalRuntime(buildInputs[0]);
let runtimeNegativeCount = 0;
for (const required of [...RUNTIME_DOCKERFILE, RUNTIME_APK_VERIFY]) {
  assert.throws(() => validateFinalRuntime(buildInputs[0].replace(required, '# omitted runtime contract')),
    'omitted shipped runtime contract must fail: ' + required);
  runtimeNegativeCount++;
}
for (const mutated of [
  buildInputs[0].replace('    && apk add --no-cache "alpine-release=$alpine_release" \\\n    && apk upgrade --no-cache \\\n',
    '    && apk upgrade --no-cache \\\n    && apk add --no-cache "alpine-release=$alpine_release" \\\n'),
  buildInputs[0].replace('\nFROM runtime-app\n', '\nFROM bundled-gems\n'),
  buildInputs[0].replace('FROM ${CHATWOOT_IMAGE} AS upstream', 'FROM ${CHATWOOT_IMAGE} AS upstream\nFROM ${CHATWOOT_IMAGE} AS runtime-extra'),
]) {
  assert.notEqual(mutated, buildInputs[0]);
  assert.throws(() => validateFinalRuntime(mutated), 'reordered or upstream-based shipped runtime must fail');
  runtimeNegativeCount++;
}
console.log('Chatwoot shipped Alpine 3.22 runtime: PASS (' + runtimeNegativeCount + ' negative controls)');
// The verifier and its three inputs reach the build context: .dockerignore ignores the whole tree and lets each one back in.
const RUNTIME_APK_CONTEXT = [...RUNTIME_APK_INPUTS, 'tests/verify_chatwoot_runtime_apk.rb'];
function validateRuntimeApkContext(ignore) {
  const lines = ignore.split('\n');
  for (const path of RUNTIME_APK_CONTEXT) {
    assert.equal(lines.filter(line => line === `!${path}`).length, 1, `Docker context runtime package input missing: ${path}`);
  }
}
validateRuntimeApkContext(buildInputs[2]);
for (const path of RUNTIME_APK_CONTEXT) {
  assert.throws(() => validateRuntimeApkContext(swapOnce(buildInputs[2], `!${path}\n`, '', path)),
    `omitted Docker context runtime package input must fail: ${path}`);
}
console.log(`Chatwoot runtime package build context: PASS (${RUNTIME_APK_CONTEXT.length} omission controls)`);
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
  [0, 'COPY config/chatwoot-rails-backport.json'], [1, 'COPY scripts/harden-chatwoot-rails.rb'],
  [0, 'harden-chatwoot-rails.rb apply'], [1, 'harden-chatwoot-rails.rb apply'],
  [0, '    && bundle exec ruby /opt/toybaco/tests/verify_chatwoot_rails_backport.rb\n'],
  [1, 'bundle exec ruby /opt/toybaco/tests/verify_chatwoot_rails_backport.rb'],
  [2, '!config/chatwoot-rails-backport.json'], [2, '!tests/verify_chatwoot_rails_backport.rb'],
  [3, '"$TEST_IMAGE" bundle exec ruby /opt/toybaco/tests/verify_chatwoot_rails_backport.rb'],
  [3, '"$PRODUCTION_IMAGE" bundle exec ruby /opt/toybaco/tests/verify_chatwoot_rails_backport.rb'],
  [3, '"$TEST_IMAGE" bundle exec ruby /app/tests/chatwoot_rails_backport_test.rb'],
  [3, '    --tmpfs /tmp:rw,noexec,nosuid,size=16m \\\n    "$PRODUCTION_IMAGE" bundle exec ruby /opt/toybaco/tests/verify_chatwoot_rails_backport.rb'],
  [3, 'ActiveStorage.variant_processor == :vips'],
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
  [workflow.replace('/contract/tests/verify_chatwoot_rails_backport.rb /contract/config/chatwoot-rails-backport.json', '/contract/tests/not-run.rb'), gate],
  [workflow.replace('-rbundler/setup /contract/tests/verify_chatwoot_rails_backport.rb', '/contract/tests/verify_chatwoot_rails_backport.rb'), gate],
  [workflow.replace('            --tmpfs /tmp:rw,noexec,nosuid,size=16m \\\n', '            --tmpfs /tmp:rw,exec,size=16m \\\n'), gate],
  [workflow.replace('> "$security/installed-rails-proof.json"', '> /dev/null'), gate],
  [workflow.replace('"$security" config/chatwoot-ruby-llm-backport.json config/chatwoot-rails-backport.json\n\n',
    '"$security" config/chatwoot-ruby-llm-backport.json\n\n'), gate],
  [workflow.replace('"$security" config/chatwoot-ruby-llm-backport.json config/chatwoot-rails-backport.json\n          printf',
    '"$security" config/chatwoot-ruby-llm-backport.json\n          printf'), gate],
  [workflow.replace("      - 'config/chatwoot-rails-backport.json'\n", ''), gate],
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
  [workflow.replace(`--distro alpine/${ALPINE_RELEASE}`, '--distro alpine/3.22'), gate],
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
  // The Node proofs removed, softened, written in the form set -e ignores, or outside the production image's check.
  [workflow, gate.replace(NODE_FILE_PROBE, ':')],
  [workflow, gate.replace(`      ${NODE_FILE_PROBE}\n`, '')],
  [workflow, gate.replace(NODE_FILE_PROBE, `${NODE_FILE_PROBE} || :`)],
  [workflow, gate.replace(NODE_PATH_PROBE, ':')],
  [workflow, gate.replace(`      ${NODE_PATH_PROBE}\n`, '')],
  [workflow, gate.replace(NODE_PATH_PROBE, `${NODE_PATH_PROBE} || :`)],
  [workflow, gate.replace(NODE_PATH_PROBE, '! command -v node')],
  [workflow, gate.replace(`      ${NODE_FILE_PROBE}\n      ${NODE_PATH_PROBE}\n`, '').replace('smoke_production_image() {\n',
    `smoke_production_image() {\n      ${NODE_FILE_PROBE}\n      ${NODE_PATH_PROBE}\n`)],
  [workflow, gate.replace('Rails.version == %q{7.2.3.2}', 'Rails.version == %q{7.2.2.2}')],
  [workflow, gate.replace('version.to_s == %q{2.2.1}', 'version.to_s == %q{2.2.0}')],
  [workflow, gate.replace('-ractive_storage/vips', '')],
  [workflow, gate.replace('Vips::Image.csvload(csv)', 'Vips::Image.black(1, 1)')],
  [workflow, gate.replace('Vips::Image.openexrload(exr)', 'Vips::Image.black(1, 1)')],
  [workflow, gate.replace('Vips::Image.fitsload(fits)', 'Vips::Image.black(1, 1)')],
  [workflow, gate.replaceAll('"\\x76\\x2f\\x31\\x01".b', '"\\x00\\x00\\x00\\x00".b')],
  [workflow, gate.replace('"\\x76\\x2f\\x31\\x01".b + ("\\0" * 60).b)\n        begin\n          Vips::Image.openexrload(exr)',
    '"\\x00\\x00\\x00\\x00".b + ("\\0" * 60).b)\n        begin\n          Vips::Image.openexrload(exr)')],
  [workflow, gate.replace('"\\x76\\x2f\\x31\\x01".b + ("\\0" * 60).b)\n        begin\n          Vips::Image.new_from_file(exr)',
    '"\\x00\\x00\\x00\\x00".b + ("\\0" * 60).b)\n        begin\n          Vips::Image.new_from_file(exr)')],
  [workflow, gate.replace('.ljust(2880))\n        begin\n          Vips::Image.fitsload(fits)',
    '.ljust(5760))\n        begin\n          Vips::Image.fitsload(fits)')],
  [workflow, gate.replace('.ljust(2880))\n        begin\n          Vips::Image.new_from_file(fits)',
    '.ljust(5760))\n        begin\n          Vips::Image.new_from_file(fits)')],
  [workflow, gate.replace('env -u VIPS_BLOCK_UNTRUSTED bundle exec ruby -rruby-vips', 'bundle exec ruby -rruby-vips')],
  [workflow, gate.replace('abort unless error.message.start_with?("exr2vips: EXR error: ")', 'true')],
  [workflow, gate.replace('ENV.fetch(%q{VIPS_BLOCK_UNTRUSTED}) == %q{1}', 'true')],
  [workflow, gate.replace('ruby /contract/tests/verify_chatwoot_runtime_gems.rb', 'ruby /contract/tests/not-run.rb')],
  [workflow, gate.replace('assert_single_exact_line "$CONTROL_ROOT/.dockerignore" \'overlay/app/spec\'', ':')],
  [workflow, gate.replace('test ! -e /app/spec', ':')],
  [workflow, gate.replace(RUNTIME_APK_PROBE, 'true')],
  [workflow, gate.replace('ruby "$CONTROL_ROOT/tests/chatwoot_runtime_apk_test.rb"', 'true')],
  [workflow, gate.replace('ruby "$CONTROL_ROOT/tests/verify_chatwoot_runtime_apk.rb" --lint', 'true')],
  [workflow, gate.replace('[[ "$actual_base_label" == "$CHATWOOT_RUNTIME_IMAGE" ]]', '[[ "$actual_base_label" == "$CHATWOOT_IMAGE" ]]')],
  [workflow, gate.replace('"$CHATWOOT_RUNTIME_IMAGE" \\\n    | sed \'/^$/d\' > "$RUN_ROOT/base-layers"',
    '"$CHATWOOT_IMAGE" \\\n    | sed \'/^$/d\' > "$RUN_ROOT/base-layers"')],
  [workflow, gate.replace('--build-arg "CHATWOOT_IMAGE=$PRODUCTION_IMAGE"', '--build-arg "CHATWOOT_IMAGE=$CHATWOOT_IMAGE"')],
  [workflow, gate.replace('production imageに上流imageのENVがありません', 'ENV')],
  [workflow, gate.replace('  build_production_image\n  build_test_image\n', '  build_test_image\n  build_production_image\n')],
  [workflow, gate.replaceAll(RUNTIME_IMAGE, RUNTIME_IMAGE.replace('017bd0bf', '00000000'))],
  [workflow, gate.replace("    'config/chatwoot-runtime-apk.txt' \\\n", '')],
  [workflow, gate.replace("    'config/chatwoot-runtime-apk-cve-floors.tsv' \\\n", '')],
  [workflow, gate.replace("    'config/chatwoot-runtime-apk-unowned-files.tsv' \\\n", '')],
  [workflow, gate.replace(' "$CONTROL_ROOT/config/chatwoot-runtime-apk-unowned-files.tsv" || fail', ' || fail')],
  [workflow, gate.replace(' /contract/config/chatwoot-runtime-apk-unowned-files.tsv \\\n', ' \\\n')],
  [workflow.replace("      - 'config/chatwoot-runtime-apk-cve-floors.tsv'\n", ''), gate],
  [workflow.replace("      - 'config/chatwoot-runtime-apk-unowned-files.tsv'\n", ''), gate],
  [workflow.replace('--build-arg "RUBY_RUNTIME_IMAGE=$CHATWOOT_RUNTIME_IMAGE"', ''), gate],
  [workflow.replace('--arg base "$CHATWOOT_RUNTIME_IMAGE"', '--arg base "$CHATWOOT_BASE_IMAGE"'), gate],
  [workflow.replace('.config.Labels["jp.toybaco.upstream.image"] == $upstream and', ''), gate],
  [workflow.replaceAll(RUNTIME_IMAGE, RUNTIME_IMAGE.replace('017bd0bf', '00000000')), gate],
  [workflow.replace('grep -Fqx "ARG RUBY_RUNTIME_IMAGE=$CHATWOOT_RUNTIME_IMAGE" Dockerfile', 'true'), gate],
  [workflow.replaceAll(`alpine/${ALPINE_RELEASE}`, 'alpine/3.21.3').replaceAll(`alpine-${ALPINE_RELEASE}`, 'alpine-3.21.3')
    .replace(`eol --release ${ALPINE_RELEASE}`, 'eol --release 3.21.3'), gate],
  [workflow.replace(ALPINE_EOL_STEP, ''), gate],
  [workflow.replace(`eol --release ${ALPINE_RELEASE} || true`, `eol --release ${ALPINE_RELEASE}`), gate],
  [workflow.replace(`eol --release ${ALPINE_RELEASE}`, 'eol --release 3.22.6'), gate],
  [workflow.replace(`${ALPINE_EOL_STEP}\n`, '').replace('      - name: SPDX SBOMの形式と上限を確認\n',
    `${ALPINE_EOL_STEP}\n      - name: SPDX SBOMの形式と上限を確認\n`), gate],
  [workflow.replace(ALPINE_EOL_STEP, `${ALPINE_EOL_STEP}\n${ALPINE_EOL_STEP}`), gate],
  [workflow, gate.replace(ALPINE_EOL_GATE, '')],
  [workflow, gate.replace(ALPINE_EOL_GATE, ALPINE_EOL_GATE.replace(' || true', ''))],
  [workflow, gate.replace(ALPINE_RELEASE_GATE, `"$CHATWOOT_IMAGE" sh -c 'cat /etc/alpine-release')"\n`)],
  [workflow, gate.replace("    'scripts/chatwoot-alpine-status.py' \\\n", '')],
  // The raw scan input back to a plain copy or to the unsupplemented copy, the supplement tolerated, dropped, moved after the
  // scanner or outside the control snapshot.
  [workflow.replace(OS_SOURCE_LINE, 'cp "$security/sbom.spdx.json" "$security/scan-sbom.spdx.json"'), gate],
  [workflow.replace(SCAN_SBOM_MOUNT, '--mount "type=bind,src=$security/sbom.spdx.json,dst=/scan/sbom.spdx.json,readonly"'), gate],
  [workflow.replace(OS_SOURCE_LINE, `${OS_SOURCE_LINE} || true`), gate],
  [workflow.replace(`          ${OS_SOURCE_LINE}\n`, ''), gate],
  [workflow.replace(`          ${OS_SOURCE_LINE}\n`, '').replace('          scan_status=0\n', `          ${OS_SOURCE_LINE}\n          scan_status=0\n`), gate],
  [workflow.replace(BINDING_COPY_LINE, OS_SOURCE_LINE.replace('"$security/sbom.spdx.json"', '"$RUNNER_TEMP/toybaco-chatwoot.spdx.json"')
    .replace('"$security/scan-sbom.spdx.json"', '"$security/sbom.spdx.json"')), gate],
  [workflow.replace(`      - '${OS_SOURCE_SCRIPT}'\n`, ''), gate],
  [workflow, gate.replace(`    '${OS_SOURCE_SCRIPT}' \\\n`, '')],
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
  // The runner CLI check removed, moved after the OIDC session, tolerated, made conditional, or with other expectations.
  [workflow.replace(`${RUNNER_CLI_STEP_TEXT}\n`, ''), gate],
  [workflow.replace(`${RUNNER_CLI_STEP_TEXT}\n`, '')
    .replace('      - name: 固定ECR registryへlogin\n', `${RUNNER_CLI_STEP_TEXT}\n      - name: 固定ECR registryへlogin\n`), gate],
  [workflow.replace(`      - name: ${RUNNER_CLI_STEP}\n`, `      - name: ${RUNNER_CLI_STEP}\n        continue-on-error: true\n`), gate],
  [workflow.replace(`      - name: ${RUNNER_CLI_STEP}\n`, `      - name: ${RUNNER_CLI_STEP}\n        if: github.event_name == 'push'\n`), gate],
  [workflow.replace("          expected_docker_major='28'\n", "          expected_docker_major='29'\n"), gate],
  [workflow.replace('*io.containerd.snapshotter*', '*never-matches*'), gate],
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
  // The container runs this contract on the control snapshot only, and the publisher shell below calls the OS source script.
  const roster = postizGateSource.slice(postizGateSource.indexOf('CONTROL_STATIC_FILES=('),
    postizGateSource.indexOf('\nreadonly CONTROL_STATIC_FILES'));
  assert.equal(roster.split('\n').filter(line => line === `  ${OS_SOURCE_SCRIPT}`).length, 1,
    'the Postiz gate control snapshot must carry the OS source script this contract executes');
}
const postizGateNegatives = [];
if (mode === 'private') {
  const postizGate = readFileSync(resolve(root, 'bin/toybaco-postiz-gate'), 'utf8');
  validatePostizGateForwarding(postizGate);
  postizGateNegatives.push(
    postizGate.replace(POSTIZ_GATE_FORWARD, ''),
    postizGate.replace(`  ${OS_SOURCE_SCRIPT}\n`, ''),
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

const { classificationFixture, addObservedRailsAliases } = await import(join(root, 'tests/chatwoot-ruby-llm-classification.test.mjs'));
// The fixture's OS package as pinned Syft writes a renamed Alpine package: the source only as purl upstream= and its own
// provenance as sourceInfo. The supplement replaces that sourceInfo in the scanned copy only.
const SOURCE_SYFT_INFO = 'acquired package info from APK DB: /lib/apk/db/installed';
const SOURCE_PURL = 'pkg:apk/alpine/ssl_client@1.37.0-r19?arch=x86_64&distro=alpine-3.22.0&upstream=busybox';
const SOURCE_INFO = 'built package from: busybox 1.37.0-r19';
function executePolicy(label, change, expected) {
  const directory = mkdtempSync(join(tmpdir(), 'toybaco-cw-sbom-policy-'));
  try {
    const fixture = classificationFixture(), sbom = fixture.sbom, report = fixture.raw;
    Object.assign(sbom.packages[2], { name: 'ssl_client', versionInfo: '1.37.0-r19', sourceInfo: SOURCE_SYFT_INFO,
      externalRefs: [{ referenceCategory: 'PACKAGE-MANAGER', referenceType: 'purl', referenceLocator: SOURCE_PURL }] });
    const settings = { scannerExit: 1, changedDatabase: false, changedOriginal: false, changedMetadata: false, proofStartup: null,
      railsProofStartup: null, scanInput: null, sourceStop: false };
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
 const input = a.filter(value => value.endsWith(',dst=/scan/sbom.spdx.json,readonly'));
 if (input.length !== 1) process.exit(91);
 const scanned = JSON.parse(fs.readFileSync(input[0].slice('type=bind,src='.length, input[0].indexOf(',dst='))));
 if (!scanned.packages.some(item => item.sourceInfo === ${JSON.stringify(SOURCE_INFO)})) {
  process.stderr.write('UNSUPPLEMENTED_SCAN'); process.exit(92);
 }
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
if (a.includes('/contract/tests/verify_chatwoot_rails_backport.rb')) {
 const imageIndex = a.indexOf(process.env.ECR_REPOSITORY + '@' + process.env.IMAGE_DIGEST);
 const expected = ['-rbundler/setup', '/contract/tests/verify_chatwoot_rails_backport.rb', '/contract/config/chatwoot-rails-backport.json'];
 if (imageIndex < 0 || JSON.stringify(a.slice(imageIndex + 1)) !== JSON.stringify(expected)) {
  process.stderr.write('RAILS_BUNDLER_PRELOAD_REQUIRED'); process.exit(89);
 }
 if (!a.includes('--read-only') || !a.includes('/tmp:rw,noexec,nosuid,size=16m')) { process.stderr.write('RAILS_PROOF_TMP_REQUIRED'); process.exit(90); }
 process.stdout.write(fs.readFileSync(path.join(dir, 'fixture-rails-proof.json'))); process.exit(0);
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
      'fixture-image.json': fixture.imageInspect, 'fixture-proof.json': fixture.proof, 'fixture-rails-proof.json': fixture.railsProof,
      'fixture-db.json': fixture.before.metadata,
    })) writeFileSync(join(directory, name), JSON.stringify(data));
    let executedScan = scanRun;
    if (settings.scanInput === 'attested') {
      assert.equal(scanRun.split('src=$security/scan-sbom.spdx.json,').length - 1, 1);
      executedScan = scanRun.replace('src=$security/scan-sbom.spdx.json,', 'src=$security/sbom.spdx.json,');
    }
    if (settings.proofStartup) {
      const invocation = '-rbundler/setup /contract/tests/verify_chatwoot_ruby_llm_backport.rb /contract/config/chatwoot-ruby-llm-backport.json';
      assert.ok(scanRun.includes(invocation));
      const scriptArgs = invocation.slice('-rbundler/setup '.length);
      executedScan = scanRun.replace(invocation, settings.proofStartup === 'missing'
        ? scriptArgs : scriptArgs + ' -rbundler/setup');
    }
    if (settings.railsProofStartup) {
      const invocation = '-rbundler/setup /contract/tests/verify_chatwoot_rails_backport.rb /contract/config/chatwoot-rails-backport.json';
      assert.equal(executedScan.split(invocation).length - 1, 1);
      executedScan = executedScan.replace(invocation, settings.railsProofStartup === 'missing'
        ? invocation.slice('-rbundler/setup '.length) : invocation.slice('-rbundler/setup '.length) + ' -rbundler/setup');
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
    if (settings.railsProofStartup) assert.match(result.stderr, /RAILS_BUNDLER_PRELOAD_REQUIRED/, 'Rails startup regression fails at the actual Ruby invocation');
    if (settings.scanInput) assert.match(result.stderr, /UNSUPPLEMENTED_SCAN/, 'an unsupplemented copy fails at the actual scanner');
    if (settings.sourceStop) {
      assert.match(result.stdout, /^::error::TOYBACO_SPDX_OS_SOURCE=STOP /m, `${label}: the supplement must stop the step`);
      assert.ok(!existsSync(join(directory, 'chatwoot-source-backport/scan-sbom.spdx.json')), `${label}: no scanned copy`);
    }
    if (expected) {
      // The scanner read the supplemented copy; the attested SBOM and the copy the classification binds are unchanged bytes.
      const attested = readFileSync(join(directory, 'toybaco-chatwoot.spdx.json'));
      assert.equal(attested.toString(), JSON.stringify(sbom), 'the attested SBOM is unchanged');
      assert.deepEqual(readFileSync(join(directory, 'chatwoot-source-backport/sbom.spdx.json')), attested, 'binding copy is exact');
      const scanned = JSON.parse(readFileSync(join(directory, 'chatwoot-source-backport/scan-sbom.spdx.json'), 'utf8'));
      assert.deepEqual(scanned, { ...sbom, packages: sbom.packages.map(item => item.name === 'ssl_client' ? { ...item, sourceInfo: SOURCE_INFO } : item) });
      assert.match(result.stdout, /^TOYBACO_SPDX_OS_SOURCE=OK os_packages=1 source_added=1 source_kept=0 no_upstream=0$/m);
      const proof = JSON.parse(readFileSync(join(directory, 'chatwoot-source-backport/source-backport-classification.json')));
      assert.deepEqual(proof.raw_report, report, 'raw report is retained truthfully');
      assert.equal(proof.bindings.sbom, createHash('sha256').update(attested).digest('hex'), 'the classification binds the attested SBOM');
      assert.equal(proof.scanner_vex_filtering, false);
      assert.equal(proof.counts.raw_critical, 1);
      const rawCount = report.Results.flatMap(result => result.Vulnerabilities || []).length;
      assert.equal(proof.counts.raw_high, rawCount - 1);
      assert.equal(proof.counts.source_verified_fixed, rawCount);
      assert.ok(result.stdout.includes('RAW_CRITICAL=1 RAW_HIGH=' + (rawCount - 1) + ' SOURCE_VERIFIED_FIXED=' + rawCount));
      assert.deepEqual(proof.installed_rails_source_proof, fixture.railsProof, 'the classification carries the exact Rails proof');
      assert.equal(proof.bindings.installed_rails_proof,
        createHash('sha256').update(readFileSync(join(directory, 'chatwoot-source-backport/installed-rails-proof.json'))).digest('hex'));
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
        'verify-attestations', security, join(root, 'config/chatwoot-ruby-llm-backport.json'),
        join(root, 'config/chatwoot-rails-backport.json')];
      const verifiedResult = spawnSync(process.execPath, args, { encoding: 'utf8' });
      assert.equal(verifiedResult.status, 0, verifiedResult.stderr);
      const changed = structuredClone(report); changed.CreatedAt = 'tampered after classification';
      writeFileSync(join(security, 'raw-report.json'), JSON.stringify(changed));
      const changedResult = spawnSync(process.execPath, args, { encoding: 'utf8' });
      assert.notEqual(changedResult.status, 0, 'signed predicates cannot accept changed raw evidence');
      writeFileSync(join(security, 'raw-report.json'), JSON.stringify(report));
      assert.equal(spawnSync(process.execPath, args, { encoding: 'utf8' }).status, 0, 'restored raw evidence verifies again');
      const railsChanged = structuredClone(fixture.railsProof); railsChanged.tests['GHSA-8474-xrp6-wh69'].official_examples = 2;
      writeFileSync(join(security, 'installed-rails-proof.json'), JSON.stringify(railsChanged));
      assert.notEqual(spawnSync(process.execPath, args, { encoding: 'utf8' }).status, 0, 'signed predicates cannot accept a changed Rails proof');
      const withoutRails = spawnSync(process.execPath, args.slice(0, -1), { encoding: 'utf8' });
      assert.notEqual(withoutRails.status, 0, 'verification without the Rails catalog fails');
    }
  } finally { rmSync(directory, { recursive: true, force: true }); }
}
executePolicy('exact image, raw HIGH and complete source proof authorize only the backport classification', () => {}, true);
executePolicy('observed Rails CVE aliases retain raw evidence and verify both signed predicates',
  (_sbom, report) => addObservedRailsAliases(report), true);
executePolicy('alias cannot replace its required canonical finding', (_sbom, report) => {
  addObservedRailsAliases(report);
  report.Results[1].Vulnerabilities = report.Results[1].Vulnerabilities.filter(row => row.VulnerabilityID !== 'GHSA-8474-xrp6-wh69');
}, false);
executePolicy('alias cannot hide another HIGH finding', (_sbom, report) => {
  addObservedRailsAliases(report);
  report.Results[0].Vulnerabilities = [{ VulnerabilityID: 'CVE-2099-1', Severity: 'HIGH' }];
}, false);
for (const [label, change] of [
  ['wrong manifest checksum', sbom => { sbom.packages[0].checksums[0].checksumValue = 'c'.repeat(64); }],
  ['wrong requested digest', sbom => { sbom.packages[0].versionInfo = 'sha256:' + 'b'.repeat(64); }],
  ['version alone cannot bind manifest', sbom => { sbom.packages[0].checksums = []; }],
  ['wrong repository', sbom => { sbom.packages[0].name = 'other/image'; }],
  ['no described image', sbom => { sbom.relationships.shift(); }],
  ['ambiguous described image', sbom => { sbom.relationships.push({ ...sbom.relationships[0], relatedSpdxElement: 'other' }); }],
  ['wrong distro', sbom => { sbom.packages[2].externalRefs[0].referenceLocator = 'pkg:apk/alpine/a@1?distro=alpine-3.22'; }],
  ['distro prefix is not exact', sbom => { sbom.packages[2].externalRefs[0].referenceLocator = 'pkg:apk/alpine/a@1?distro=alpine-3.22.00'; }],
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
  ['Bundler preload missing before the Rails proof script', (_sbom, _report, settings) => { settings.railsProofStartup = 'missing'; }],
  ['Bundler preload after the Rails proof script', (_sbom, _report, settings) => { settings.railsProofStartup = 'late'; }],
  ['Rails source proof failure', (_sbom, _report, _settings, fixture) => { fixture.railsProof.files[0].sha256 = 'f'.repeat(64); }],
  ['Rails official examples missing', (_sbom, _report, _settings, fixture) => { delete fixture.railsProof.tests['GHSA-f3w6-w445-fwh9']; }],
  ['Rails advisory missing from the raw scan', (_sbom, report) => { report.Results[1].Vulnerabilities.splice(5, 1); }],
  ['extra HIGH on a backported Rails gem', (_sbom, report) => {
    report.Results[1].Vulnerabilities.push({ ...report.Results[1].Vulnerabilities[3], VulnerabilityID: 'GHSA-xxxx-xxxx-xxxx' });
  }],
  ['actual scanned copy DB changed during raw scan', (_sbom, _report, settings) => { settings.changedDatabase = true; }],
  ['original DB changed during raw scan', (_sbom, _report, settings) => { settings.changedOriginal = true; }],
  ['actual scanned copy metadata changed during raw scan', (_sbom, _report, settings) => { settings.changedMetadata = true; }],
  ['raw scan reads the unsupplemented copy', (_sbom, _report, settings) => { settings.scanInput = 'attested'; }],
  ['OS source qualifier outside the rules', (sbom, _report, settings) => {
    sbom.packages[2].externalRefs[0].referenceLocator = SOURCE_PURL.replace('upstream=busybox', 'upstream=bad%2Forigin');
    settings.sourceStop = true;
  }],
  ['no OS package to supplement', (sbom, _report, settings) => {
    sbom.packages[2].externalRefs[0].referenceLocator = SOURCE_PURL.replace('&upstream=busybox', ''); settings.sourceStop = true;
  }],
  ['another OS source already recorded', (sbom, _report, settings) => {
    sbom.packages[2].sourceInfo = 'built package from: openssl 1.37.0-r19'; settings.sourceStop = true;
  }],
]) executePolicy(label, change, false);
console.log('Chatwoot exact SBOM/raw-scan/proof shell: PASS (1 positive / 33 negative controls; Docker stand-in, no external calls)');

// Execute the exact runner CLI check with stand-in gh, aws and docker (and tee) as the only commands on PATH, so the
// runner's real tools are never reached. Only the expected majors and overlay2 pass; anything else stops with one
// fixed line that names what is unexpected, never echoing tool output.
const RUNNER_CLI_DOCKER_CLIENT = 'version --format {{.Client.Version}}';
const RUNNER_CLI_DOCKER_SERVER = 'version --format {{.Server.Version}}';
const RUNNER_CLI_DOCKER_DRIVER = 'info --format {{.Driver}}';
const RUNNER_CLI_DOCKER_STATUS = 'info --format {{json .DriverStatus}}';
const RUNNER_CLI_MARKER = 'ZZRUNNERCLIMARKER';
const runnerCliTool = name => {
  const located = spawnSync('/bin/sh', ['-c', `command -v ${name}`], { encoding: 'utf8' }).stdout.trim();
  assert.match(located, /^\//, `the runner CLI fixtures need ${name}`);
  return located;
};
const runnerCliTools = Object.freeze({ bash: runnerCliTool('bash'), cat: runnerCliTool('cat'), tee: runnerCliTool('tee') });
function runnerCliImageOutputs() {
  return {
    gh: { '--version': { stdout: 'gh version 2.102.0 (2026-10-01)\nhttps://github.com/cli/cli/releases/tag/v2.102.0\n' } },
    aws: { '--version': { stdout: 'aws-cli/2.37.13 Python/3.13.7 Linux/6.17.0-1022-azure exe/x86_64.ubuntu.24\n' } },
    docker: {
      [RUNNER_CLI_DOCKER_CLIENT]: { stdout: '28.0.4\n' },
      [RUNNER_CLI_DOCKER_SERVER]: { stdout: '28.0.4\n' },
      [RUNNER_CLI_DOCKER_DRIVER]: { stdout: 'overlay2\n' },
      [RUNNER_CLI_DOCKER_STATUS]: { stdout: '[["Backing Filesystem","extfs"],["Supports d_type","true"],["Using metacopy","false"],' +
        '["Native Overlay Diff","true"],["userxattr","false"]]\n' },
    },
  };
}
function runRunnerCli(script, change) {
  const outputs = runnerCliImageOutputs();
  const env = { ImageOS: 'ubuntu24', ImageVersion: '20261012.334.1' };
  change(outputs, env);
  const directory = mkdtempSync(join(tmpdir(), 'toybaco-cw-runner-cli-'));
  try {
    const bin = join(directory, 'bin');
    mkdirSync(bin);
    symlinkSync(runnerCliTools.tee, join(bin, 'tee'));
    const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
    for (const [tool, responses] of Object.entries(outputs)) {
      let fake = '#!/bin/sh\ncase "$*" in\n';
      for (const [args, { stdout = '', exit = 0 }] of Object.entries(responses)) {
        assert.ok(stdout === '' || (stdout.endsWith('\n') && !stdout.includes('TOYBACO_FAKE_OUTPUT')));
        fake += `  ${quote(args)})\n    ${quote(runnerCliTools.cat)} <<'TOYBACO_FAKE_OUTPUT'\n${stdout}TOYBACO_FAKE_OUTPUT\n    exit ${exit}\n    ;;\n`;
      }
      writeFileSync(join(bin, tool), `${fake}esac\nexit 97\n`, { mode: 0o755 });
    }
    const summary = join(directory, 'summary');
    writeFileSync(summary, '');
    const result = spawnSync(runnerCliTools.bash, ['--noprofile', '--norc', '-eo', 'pipefail', '-c', script], {
      encoding: 'utf8', timeout: 20000, env: { PATH: bin, GITHUB_STEP_SUMMARY: summary, ...env },
    });
    return { status: result.status, stdout: result.stdout, stderr: result.stderr, summary: readFileSync(summary, 'utf8') };
  } finally { rmSync(directory, { recursive: true, force: true }); }
}
function testRunnerCli(script) {
  const ok = (versions = {}) => {
    const value = { gh: '2.102.0', aws: '2.37.13', client: '28.0.4', server: '28.0.4', image: 'ubuntu24-20261012.334.1', ...versions };
    return `TOYBACO_RUNNER_CLI=OK gh=${value.gh} aws=${value.aws} docker_client=${value.client} docker_server=${value.server} ` +
      `docker_storage_driver=overlay2 runner_image=${value.image}\n`;
  };
  const stop = what => `::error::TOYBACO_RUNNER_CLI=UNEXPECTED ${what}\n`;
  const warn = (component, version) =>
    `::warning::TOYBACO_RUNNER_CLI=WARN docker_major=${version.split('.')[0]} component=${component} expected_major=28 version=${version}\n`;
  // The Step Summary keeps only the warnings (without ::warning::) and the passing line.
  const summaryOf = (stdout, status) => stdout.split(/(?<=\n)/)
    .filter(line => line.startsWith('::warning::') || (status === 0 && line.startsWith('TOYBACO_RUNNER_CLI=OK ')))
    .map(line => line.replace(/^::warning::/, '')).join('');
  const cases = [
    ['the 2026-10-12 runner image', () => {}, ok(), 0],
    ['newer minor versions in the same majors', outputs => {
      outputs.gh['--version'].stdout = 'gh version 2.140.3 (2027-03-01)\n';
      outputs.aws['--version'].stdout = 'aws-cli/2.41.0 Python/3.13.9 Linux/6.17.0-1030-azure exe/x86_64.ubuntu.24\n';
      outputs.docker[RUNNER_CLI_DOCKER_CLIENT].stdout = '28.5.2\n';
      outputs.docker[RUNNER_CLI_DOCKER_SERVER].stdout = '28.5.2+azure-1\n';
    }, ok({ gh: '2.140.3', aws: '2.41.0', client: '28.5.2', server: '28.5.2' }), 0],
    ['no runner image variables', (_outputs, env) => { delete env.ImageOS; delete env.ImageVersion; }, ok({ image: 'unknown-unknown' }), 0],
    ['gh 3', outputs => { outputs.gh['--version'].stdout = 'gh version 3.0.0 (2027-06-01)\n'; },
      stop('gh_major=3 expected_major=2 version=3.0.0'), 1],
    ['gh missing', outputs => { delete outputs.gh; }, stop('gh=missing'), 1],
    ['gh output carrying a workflow command', outputs => { outputs.gh['--version'].stdout = `::warning::${RUNNER_CLI_MARKER}\n`; },
      stop('gh=unparsable'), 1],
    ['AWS CLI v1', outputs => { outputs.aws['--version'].stdout = 'aws-cli/1.33.0 Python/3.12.3 Linux/6.8.0 botocore/1.34.0\n'; },
      stop('aws_major=1 expected_major=2 version=1.33.0'), 1],
    ['aws fails', outputs => { outputs.aws['--version'].exit = 255; }, stop('aws=failed'), 1],
    ['docker missing', outputs => { delete outputs.docker; }, stop('docker=missing'), 1],
    // docker の major の違いは警告だけで進む(image store が overlay2 のままなら)。
    ['Docker 29 client', outputs => { outputs.docker[RUNNER_CLI_DOCKER_CLIENT].stdout = '29.1.5\n'; },
      warn('client', '29.1.5') + ok({ client: '29.1.5' }), 0],
    ['Docker 29 on overlay2', outputs => {
      outputs.docker[RUNNER_CLI_DOCKER_CLIENT].stdout = '29.1.5\n';
      outputs.docker[RUNNER_CLI_DOCKER_SERVER].stdout = '29.1.5\n';
    }, warn('client', '29.1.5') + warn('server', '29.1.5') + ok({ client: '29.1.5', server: '29.1.5' }), 0],
    ['Docker 29 with the containerd image store (the 2026-02 runner)', outputs => {
      outputs.docker[RUNNER_CLI_DOCKER_CLIENT].stdout = '29.1.5\n';
      outputs.docker[RUNNER_CLI_DOCKER_SERVER].stdout = '29.1.5\n';
      outputs.docker[RUNNER_CLI_DOCKER_DRIVER].stdout = 'overlayfs\n';
      outputs.docker[RUNNER_CLI_DOCKER_STATUS].stdout = '[["driver-type","io.containerd.snapshotter.v1"]]\n';
    }, warn('client', '29.1.5') + warn('server', '29.1.5') + stop('docker_image_store=containerd-snapshotter'), 1],
    ['an unreachable Docker daemon', outputs => { outputs.docker[RUNNER_CLI_DOCKER_SERVER] = { stdout: '', exit: 1 }; },
      stop('docker_server=failed'), 1],
    ['docker info fails', outputs => { outputs.docker[RUNNER_CLI_DOCKER_STATUS] = { stdout: '', exit: 1 }; }, stop('docker_info=failed'), 1],
    ['the containerd image store (Docker 29 default)', outputs => {
      outputs.docker[RUNNER_CLI_DOCKER_DRIVER].stdout = 'overlayfs\n';
      outputs.docker[RUNNER_CLI_DOCKER_STATUS].stdout = '[["driver-type","io.containerd.snapshotter.v1"]]\n';
    }, stop('docker_image_store=containerd-snapshotter'), 1],
    ['a containerd snapshotter named overlay2', outputs => {
      outputs.docker[RUNNER_CLI_DOCKER_STATUS].stdout = '[["driver-type","io.containerd.snapshotter.v1"]]\n';
    }, stop('docker_image_store=containerd-snapshotter'), 1],
    ['the vfs graph driver', outputs => {
      outputs.docker[RUNNER_CLI_DOCKER_DRIVER].stdout = 'vfs\n';
      outputs.docker[RUNNER_CLI_DOCKER_STATUS].stdout = 'null\n';
    }, stop('docker_storage_driver=vfs expected=overlay2'), 1],
    ['a storage driver carrying a workflow command', outputs => {
      outputs.docker[RUNNER_CLI_DOCKER_DRIVER].stdout = `::warning::${RUNNER_CLI_MARKER}\n`;
    }, stop('docker_storage_driver=unparsable expected=overlay2'), 1],
  ];
  for (const [label, change, stdout, status] of cases) {
    const result = runRunnerCli(script, change);
    assert.equal(result.status, status, `${label} must ${status === 0 ? 'pass' : 'stop the publisher'}: ${result.stdout}${result.stderr}`);
    assert.equal(result.stdout, stdout, `${label} must print exactly its fixed line`);
    assert.equal(result.summary, summaryOf(stdout, status), `${label} must record only the warnings and a passing check`);
    assert.ok(!`${result.stdout}${result.summary}`.includes(RUNNER_CLI_MARKER), `${label} must not echo tool output`);
  }
  return cases.length;
}
const runnerCliRun = stepRun(workflow, RUNNER_CLI_STEP);
const runnerCliCases = testRunnerCli(runnerCliRun);
const runnerCliBehaviourMutations = [
  ["expected_docker_major='28'", "expected_docker_major='29'"],
  ["if [[ \"$docker_driver_status\" == *io.containerd.snapshotter* ]]; then\n  unexpected 'docker_image_store=containerd-snapshotter'\nfi\n", ''],
  ['  if [[ "$parsed_major" != "$2" ]]; then\n', '  if false; then\n'],
  ['require_major gh "$expected_gh_major"\n', ''],
  ['    echo "::warning::TOYBACO_RUNNER_CLI=WARN docker_major=',
    '    unexpected "docker_major=${parsed_major}"\n    echo "::warning::TOYBACO_RUNNER_CLI=WARN docker_major='],
  ['warn_docker_major client\n', ''],
  ['    unexpected "${1}=unparsable"\n', '    return 0\n'],
  ['    unexpected "${1}=unparsable"\n', '    unexpected "${1}=${2}"\n'],
];
for (const [from, to] of runnerCliBehaviourMutations) {
  assert.equal(runnerCliRun.split(from).length - 1, 1, `runner CLI behaviour mutation target: ${from}`);
  assert.throws(() => testRunnerCli(runnerCliRun.replace(from, to)), `runner CLI behaviour mutation was accepted: ${from}`);
}
console.log(`Chatwoot runner CLI check shell: PASS (${runnerCliCases} cases / ${runnerCliBehaviourMutations.length} behaviour negatives; ` +
  'stand-in gh, aws and docker, no external calls)');
