# Chatwoot RubyLLM source-backport release policy

This is a narrowly scoped release-policy change for three advisories in ruby_llm 1.15.0: CVE-2026-67987 (think-tag parsing ReDoS), CVE-2026-67989 (Mistral capability matching ReDoS) and CVE-2026-67991 (underscore naming ReDoS). Each is CVSS 7.5 with the fixed range >= 2.0.0.rc1, and the 2.x major breaks Chatwoot's acts_as API, so the gem is not upgraded. It does not assert raw Trivy HIGH/CRITICAL zero. The gem's version, Agents integration, and existing application capabilities remain unchanged, except the documented think-tag behavior below.

The only accepted outcome is raw CRITICAL=0, raw HIGH=3, source-verified fixed=3, unresolved CRITICAL=0, unresolved HIGH=0. The raw findings must be exactly CVE-2026-67987, CVE-2026-67989 and CVE-2026-67991, once each, on ruby_llm / 1.15.0 with the observed fixed range >= 2.0.0.rc1. Any other finding, a fourth finding, a duplicate occurrence, an absent expected finding, another package/version/fixed range, scanner error, incomplete inventory or proof fails. A future changed advisory/version requires a new review. The advisories describe polynomial time on Ruby 3.1.x; the pinned Ruby 3.4.4 is never used as an exemption, so every advisory is fixed in source.

## The three source backports

| Advisory | Upstream fix | 1.15.0 source changed | Loaded method proved |
|---|---|---|---|
| CVE-2026-67987 | [5e88411f](https://github.com/crmne/ruby_llm/commit/5e88411f171721b381853fa77d254e266dcf6ad8) | `lib/ruby_llm/providers/openai/chat.rb` (`extract_think_tag_content`, the two `%r{<think>…</think>}m` scans at :213-214 and its call at :176), `lib/ruby_llm/stream_accumulator.rb` (the streaming tag machinery at :18-19, :122-137 and :147-201) | `RubyLLM::Providers::OpenAI::Chat.extract_content_and_thinking` (:175), `RubyLLM::StreamAccumulator#handle_chunk_content` (:120 after the backport) |
| CVE-2026-67989 | [dd3c8481](https://github.com/crmne/ruby_llm/commit/dd3c84812598def03d4aff77b5447c41d8f5c34e) | `lib/ruby_llm/providers/mistral/capabilities.rb` (`when /voxtral.*transcribe/` at :100 in `capabilities_for`) | `RubyLLM::Providers::Mistral::Capabilities.capabilities_for` (:106 after the backport) |
| CVE-2026-67991 | [9d75b033](https://github.com/crmne/ruby_llm/commit/9d75b033d7d00c4e1baa9b0afb4828faa8bd6602) | `lib/ruby_llm/agent.rb`, `lib/ruby_llm/tool.rb` (the two pre-extraction underscore call sites) | `RubyLLM::Agent.prompt_agent_path` (:324), `RubyLLM::Tool#name` (:68) |

The hardener applies the upstream edits inline and verbatim: CVE-2026-67987 deletes the non-streaming scanner and the streaming accumulator's tag machinery, so string content passes through; CVE-2026-67989 adds the upstream `VOXTRAL` constant and `voxtral_followed_by?` (a String#index walk from the first `voxtral`) and turns `capabilities_for` into the upstream guard clauses with `match?`. 1.15.0 has no voxtral `modalities_for` cases (the upstream fix also rewrote `/voxtral.*tts/` there), so only the transcribe check exists to replace. Every edit is an exact block that must occur once in the archive-pinned original, and every original and patched file hash, the complete 130-file Ruby inventory and the per-advisory vulnerable/fixed expression counts are pinned in `config/chatwoot-ruby-llm-backport.json` (schema 2, one entry per advisory).

Behavior notes. Think tags are no longer separated: `<think>…</think>` in assistant content stays in the content and no thinking is extracted from it, exactly as upstream 2.0. The scanner existed for Perplexity sonar-reasoning; providers return reasoning in separate fields, which is unchanged. Non-streamed string content without `<think>` is identical to 1.15.0 (the proof compares it), and streamed content is the plain concatenation of the chunks (1.15.0 also held back a trailing partial `<think>` prefix such as a final `<`, which no longer happens). For Mistral the walk is identical to the regex for model ids; it ignores line breaks, so an id with a newline between `voxtral` and `transcribe` is now classified as transcription, as upstream. Model ids from the provider have no newlines.

## Evidence and ordering

The existing source, quality, digest, ECR OS scan, pinned Syft SPDX and signature gates remain. The private publisher stays disabled. Trivy stays at the pinned 0.67.2 image, scans both OS and library packages at HIGH/CRITICAL including unfixed findings, and never receives --vex, --ignorefile or --ignore-policy.

A new empty cache downloads the DB once into an original source directory that is never mounted into the scanner. A private copy is mounted writable because pinned Trivy opens bbolt read/write even with skip-update. The existing signed database snapshots cover this actual scanned copy. Original and copy database bytes and metadata must match before and after the scan; any difference fails. The scan runs with network disabled, skip-update/offline flags, and complete package listing. DownloadedAt must belong to this run and UpdatedAt must be within 48 hours. The raw exit code and complete JSON report are retained without mutation. There is no effective Trivy scan.

The trusted checkout verifier runs against the exact published image digest with network disabled and filesystem read-only. It checks the unique actual installed ruby_llm and Agents specs, the real method source paths/lines of all five patched methods, all 130 installed Ruby source files, the five patched complete-file hashes, the absence of every vulnerable expression and the presence of every fix, the unchanged entrypoint/version/license, and per advisory: equivalence with the 1.15.0 behavior (20,020 names for CVE-2026-67991; 5,000 strings without `<think>` and 2,000 streams for CVE-2026-67987; the 72 Mistral catalog ids plus 20,000 generated ids for CVE-2026-67989), the official upstream examples, adversarial inputs bounded at 2 seconds (100,000 capitals; 50,000 unclosed `<think>`; `voxtral` repeated 50,000 times) and negative checks. The image's public revision file and control label bind this to reviewed source. No model request is made.

The independent Node evaluator validates that proof against the reviewed manifest, the SPDX DESCRIBES root and image checksum, an exact versioned OCI purl, exactly one ruby_llm purl/version, its dependency path from the image, the scanner inventory/finding identity and optional package path. It emits:
- three OpenVEX 0.2.0 statements, one per advisory, each with status fixed, one exact digest-qualified image product and one versioned gem subcomponent;
- a source-backport classification predicate containing the full raw report, raw report hash, installed proof, source/control/SBOM/config/evaluator/DB hashes, exact finding and truthful counts.

Both are signed as predicates for the same image digest using the existing pinned actions/attest action. SLSA and SPDX signatures remain required. All four use the exact workflow/main source and GitHub issuer checks. Verified VEX/classification predicate contents and exact subject are compared to the freshly recomputed local evidence; a signature by itself is insufficient.

OpenVEX describes a fixed product, not absent or unreachable code. The Ruby interpreter version is not used as a vulnerability exemption. Source proof is mandatory because a package version alone cannot express this backport.

## Why Trivy does not consume the VEX

Pinned Trivy 0.67.2 marks SBOM input as SPDX, then its VEX filter forces BOM regeneration. The regeneration creates a filesystem root without the original OCI purl. Correctly image-scoped OpenVEX cannot match that path. Broadening the statement to a gem-only product would lose the chosen scope. Therefore OpenVEX is signed for downstream consumers and the independent evaluator explicitly owns classification; no scanner-filtered result is claimed.

## Verification and limits

Tests execute the actual publisher shell with a Docker stand-in and exercise missing/modified proof, wrong image/source/file hashes, a reviewed patched hash equal to the official source, moved methods, a missing or extra advisory in the config or proof, duplicate specs/packages/findings, a missing expected finding, a fourth finding, another package/version/fixed range, wrong roots/purls/relationships, changed/stale DB, new/unfixed HIGH and CRITICAL findings, arbitrary VEX, a missing/extra/other statement, extra products/subcomponents, and wrong attestation subjects/predicates. These deterministic tests are not image acceptance. Exact-source CI, real image boot/proof, scanner output and signed-predicate verification are required for each publication.

The pinned Syft code constructs its OCI purl from the full source name and manifest digest with an architecture qualifier; it adds a tag only for a tagged input. An actual SPDX document from the same pinned registry-digest publisher recorded an empty architecture qualifier. The evaluator therefore accepts exactly one `arch=` or `arch=amd64` qualifier. Empty SBOM metadata means the CPU is unknown in that field; it does not establish image architecture. Independent inspection of the exact image must still prove Linux/amd64, and the loaded Ruby proof must still prove x86_64-linux-musl. Missing, duplicate, extra or other architecture qualifiers fail. The original observed purl remains bound to the exact image name, digest, checksum and image-to-gem relationship; it is not rewritten. The first actual candidate must satisfy all guards; no acceptance receipt is prefilled.

## Primary source references

- CVE-2026-67987: [official fix](https://github.com/crmne/ruby_llm/commit/5e88411f171721b381853fa77d254e266dcf6ad8), [RubySec advisory](https://github.com/rubysec/ruby-advisory-db/blob/master/gems/ruby_llm/CVE-2026-67987.yml), [OSV GHSA-5m38-526f-3498](https://osv.dev/vulnerability/GHSA-5m38-526f-3498)
- CVE-2026-67989: [official fix](https://github.com/crmne/ruby_llm/commit/dd3c84812598def03d4aff77b5447c41d8f5c34e), [RubySec advisory](https://github.com/rubysec/ruby-advisory-db/blob/master/gems/ruby_llm/CVE-2026-67989.yml), [OSV GHSA-57hg-jgw4-wcqw](https://osv.dev/vulnerability/GHSA-57hg-jgw4-wcqw)
- CVE-2026-67991: [official fix](https://github.com/crmne/ruby_llm/commit/9d75b033d7d00c4e1baa9b0afb4828faa8bd6602), [RubySec advisory](https://github.com/rubysec/ruby-advisory-db/blob/master/gems/ruby_llm/CVE-2026-67991.yml), [OSV GHSA-42r3-x6vx-x49x](https://osv.dev/vulnerability/GHSA-42r3-x6vx-x49x)
- [Pinned Syft image metadata](https://github.com/anchore/syft/blob/v1.51.1/syft/source/stereoscopesource/image_source.go#L132)
- [Pinned Syft root/purl construction](https://github.com/anchore/syft/blob/v1.51.1/syft/format/common/spdxhelpers/to_format_model.go#L178)
- [Pinned Trivy SBOM type](https://github.com/aquasecurity/trivy/blob/v0.67.2/pkg/fanal/artifact/sbom/sbom.go#L78)
- [Pinned Trivy VEX regeneration](https://github.com/aquasecurity/trivy/blob/v0.67.2/pkg/vex/vex.go#L102)
- [Pinned Trivy root reconstruction](https://github.com/aquasecurity/trivy/blob/v0.67.2/pkg/sbom/io/encode.go#L135)
- [OpenVEX 0.2 specification](https://github.com/openvex/spec/blob/main/OPENVEX-SPEC.md)
- [Pinned generic attestation inputs](https://github.com/actions/attest/blob/1e69f48acb82d1966a394da916b4c1698aa569d6/action.yml)
- [Pinned vulnerability DB open mode](https://github.com/aquasecurity/trivy-db/blob/eba1ced2340a/pkg/db/db.go#L78)
- [Pinned bbolt default read/write open](https://github.com/etcd-io/bbolt/blob/v1.4.3/db.go#L200)
