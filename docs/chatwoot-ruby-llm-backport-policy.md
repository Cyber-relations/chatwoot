# Chatwoot RubyLLM source-backport release policy

This is a narrowly scoped release-policy change for CVE-2026-67991 in ruby_llm 1.15.0. It does not assert raw Trivy HIGH/CRITICAL zero. The gem's version, Agents integration, and existing application capabilities remain unchanged.

The only accepted outcome is raw CRITICAL=0, raw HIGH=1, source-verified fixed=1, unresolved CRITICAL=0, unresolved HIGH=0. The sole raw finding must be CVE-2026-67991 / ruby_llm / 1.15.0 with the observed fixed range >= 2.0.0.rc1. Any other finding, duplicate occurrence, absent expected finding, scanner error, incomplete inventory or proof fails. A future changed advisory/version requires a new review.

## Evidence and ordering

The existing source, quality, digest, ECR OS scan, pinned Syft SPDX and signature gates remain. The private publisher stays disabled. Trivy stays at the pinned 0.67.2 image, scans both OS and library packages at HIGH/CRITICAL including unfixed findings, and never receives --vex, --ignorefile or --ignore-policy.

A new empty cache downloads the DB once into an original source directory that is never mounted into the scanner. A private copy is mounted writable because pinned Trivy opens bbolt read/write even with skip-update. The existing signed database snapshots cover this actual scanned copy. Original and copy database bytes and metadata must match before and after the scan; any difference fails. The scan runs with network disabled, skip-update/offline flags, and complete package listing. DownloadedAt must belong to this run and UpdatedAt must be within 48 hours. The raw exit code and complete JSON report are retained without mutation. There is no effective Trivy scan.

The trusted checkout verifier runs against the exact published image digest with network disabled and filesystem read-only. It checks the unique actual installed ruby_llm and Agents specs, the real method source paths/lines, all 130 installed Ruby source files, the two patched complete-file hashes, the unchanged entrypoint/version/license, naming equivalence, adversarial-length bounds and negative checks. The image's public revision file and control label bind this to reviewed source. No model request is made.

The independent Node evaluator validates that proof against the reviewed manifest, the SPDX DESCRIBES root and image checksum, an exact versioned OCI purl, exactly one ruby_llm purl/version, its dependency path from the image, the scanner inventory/finding identity and optional package path. It emits:
- one OpenVEX 0.2.0 statement with status fixed, one exact digest-qualified image product and one versioned gem subcomponent;
- a source-backport classification predicate containing the full raw report, raw report hash, installed proof, source/control/SBOM/config/evaluator/DB hashes, exact finding and truthful counts.

Both are signed as predicates for the same image digest using the existing pinned actions/attest action. SLSA and SPDX signatures remain required. All four use the exact workflow/main source and GitHub issuer checks. Verified VEX/classification predicate contents and exact subject are compared to the freshly recomputed local evidence; a signature by itself is insufficient.

OpenVEX describes a fixed product, not absent or unreachable code. The Ruby interpreter version is not used as a vulnerability exemption. Source proof is mandatory because a package version alone cannot express this backport.

## Why Trivy does not consume the VEX

Pinned Trivy 0.67.2 marks SBOM input as SPDX, then its VEX filter forces BOM regeneration. The regeneration creates a filesystem root without the original OCI purl. Correctly image-scoped OpenVEX cannot match that path. Broadening the statement to a gem-only product would lose the chosen scope. Therefore OpenVEX is signed for downstream consumers and the independent evaluator explicitly owns classification; no scanner-filtered result is claimed.

## Verification and limits

Tests execute the actual publisher shell with a Docker stand-in and exercise missing/modified proof, wrong image/source/file hashes, moved methods, duplicate specs/packages/findings, wrong roots/purls/relationships, changed/stale DB, new/unfixed HIGH and CRITICAL findings, arbitrary VEX, extra statements/products/subcomponents, and wrong attestation subjects/predicates. These deterministic tests are not image acceptance. Exact-source CI, real image boot/proof, scanner output and signed-predicate verification are required for each publication.

The pinned Syft code constructs its OCI purl from the full source name and manifest digest with an architecture qualifier; it adds a tag only for a tagged input. An actual SPDX document from the same pinned registry-digest publisher recorded an empty architecture qualifier. The evaluator therefore accepts exactly one `arch=` or `arch=amd64` qualifier. Empty SBOM metadata means the CPU is unknown in that field; it does not establish image architecture. Independent inspection of the exact image must still prove Linux/amd64, and the loaded Ruby proof must still prove x86_64-linux-musl. Missing, duplicate, extra or other architecture qualifiers fail. The original observed purl remains bound to the exact image name, digest, checksum and image-to-gem relationship; it is not rewritten. The first actual candidate must satisfy all guards; no acceptance receipt is prefilled.

## Primary source references

- [Official fix](https://github.com/crmne/ruby_llm/commit/9d75b033d7d00c4e1baa9b0afb4828faa8bd6602)
- [RubySec advisory](https://github.com/rubysec/ruby-advisory-db/blob/master/gems/ruby_llm/CVE-2026-67991.yml)
- [Pinned Syft image metadata](https://github.com/anchore/syft/blob/v1.51.1/syft/source/stereoscopesource/image_source.go#L132)
- [Pinned Syft root/purl construction](https://github.com/anchore/syft/blob/v1.51.1/syft/format/common/spdxhelpers/to_format_model.go#L178)
- [Pinned Trivy SBOM type](https://github.com/aquasecurity/trivy/blob/v0.67.2/pkg/fanal/artifact/sbom/sbom.go#L78)
- [Pinned Trivy VEX regeneration](https://github.com/aquasecurity/trivy/blob/v0.67.2/pkg/vex/vex.go#L102)
- [Pinned Trivy root reconstruction](https://github.com/aquasecurity/trivy/blob/v0.67.2/pkg/sbom/io/encode.go#L135)
- [OpenVEX 0.2 specification](https://github.com/openvex/spec/blob/main/OPENVEX-SPEC.md)
- [Pinned generic attestation inputs](https://github.com/actions/attest/blob/1e69f48acb82d1966a394da916b4c1698aa569d6/action.yml)
- [Pinned vulnerability DB open mode](https://github.com/aquasecurity/trivy-db/blob/eba1ced2340a/pkg/db/db.go#L78)
- [Pinned bbolt default read/write open](https://github.com/etcd-io/bbolt/blob/v1.4.3/db.go#L200)
