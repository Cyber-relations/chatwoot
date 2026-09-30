# Administrative device MFA rollout

Password or SSO possession alone no longer grants an administrator a usable dashboard device session. An unenrolled administrator receives a five-minute setup session. A real OTP enables the device; the proof is bound to the user and device, expires after twelve hours, and changes with password or MFA settings. Existing Authenticator enrollment is preserved. Old administrator device records without proof require a new login.

Enrollment mutations require same-origin CSRF verification and have a per-user verification limit. MFA login challenges have a distinct purpose, a five-minute server-side nonce and single-use consumption. Account creation inherits existing valid MFA proof without extending its original timestamp. Enrollment flags alone do not count as proof.

The dedicated staging login shortcut is not an MFA exception: a token created without MFA proof cannot authenticate an administrator. Release E2E must use the normal password and OTP flow. API integration credentials remain a separate authentication mechanism and need inventory/assessor scope confirmation; this change does not claim that every API credential is MFA-bound.

## Staging sequence

Complete the browser-session prerequisite release first. Prepare two independent seeds for the existing `toybaco-staging-e2e-v1` fixtures `admin_a` and `downgrade_admin` in Secrets Manager and the matching protected GitHub staging secrets `TOYBACO_E2E_ADMIN_A_MFA_SEED` and `TOYBACO_E2E_DOWNGRADE_ADMIN_MFA_SEED`. Never put these values in commands, logs, PRs or review evidence.

The private repository's `scripts/staging-mfa-fixture.rb` accepts only a Secrets Manager-injected JSON value. It rejects production, unmarked users, duplicate fixtures, additional memberships and differing existing enrollment. Both updates use one transaction. Repeated execution preserves matching enrollment. Do not run it until the staging runner supports MFA; earlier runners cannot log in after fixture enrollment.

Use the normal signed-image release and full staging E2E. The runner generates only a current OTP into a mode-0600 temporary file, suppresses CLI source echoes, writes only an allowlisted success receipt and removes the temporary input/output. No seed is sent to browser storage. Failed or incomplete MFA login fails the release test.

After staging passes, recheck production's existing enrollment aggregates, exact running digests, flags and rollback conditions before the standard production plan/apply. Do not change public feature flags just because the authentication checks pass. Review accounts follow the same enrollment requirement; agree on a safe reviewer MFA handoff rather than creating an exception.

## Evidence boundary

Local synthetic regression: 383 RSpec examples passed; 591 integration Ruby files passed lint; Linux control preflight passed. Private staging fixture tests cover transaction rollback and scope restrictions (five examples). RFC6238 code generation and non-disclosure tests pass. These results do not establish deployed acceptance, CASA evaluation completion, an LoV or Google approval.
