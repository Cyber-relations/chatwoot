# RDS client certificate verification

The public Tokyo RDS CA bundle is pinned by its bytes and three root certificate
fingerprints in `ToybacoRdsTrust`. The final Chatwoot image carries it at
`/app/config/rds-ca/ap-northeast-1-bundle.pem`; both the final Dockerfile step and
the required runtime gate verify that artifact. It comes from
[AWS's regional trust store](https://truststore.pki.rds.amazonaws.com/ap-northeast-1/ap-northeast-1-bundle.pem).
Only roots are included, following the [RDS TLS guidance](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html).

Before publishing a certificate artifact, check the quality snapshot filename
policy as well as the product verifier. The snapshot permits only this exact
public path with an independently pinned checksum and three self-signed CA
certificates. Other PEM/key/environment/credential paths, symlinks, writable or
modified bundles remain denied; the existing private-key/content scan remains
enabled. Run the focused secret-path regression with the artifact tests before
pushing. A generic PEM denial is corrected through that reviewed public-artifact
contract, never by renaming files or disabling secret checks.

This preparation does not enable client TLS verification or change the system
trust store, DB addresses, secrets, roles or resources. It is not evidence that
deployed clients verify certificates. The remaining rollout must configure and
accept each client separately:

- Rails, Ruby Postiz sync, schema preflight, DB initialization and grants: libpq
  `verify-full` with the actual bundle path, keeping existing credentials and
  read-only/privilege boundaries. Update staging fixtures that bind the exact
  sync query together with that connection contract.
- Postiz pg and Prisma: carry roots into the final Postiz image and configure
  both native clients and schema checks. In the inspected pg 8.20 / Prisma 6.5
  fixture, `sslrootcert` alone did not establish Prisma trust; the tested strict
  configuration used `sslcert` as well. Recheck the shipped version and preserve
  trusted-host acceptance and wrong-CA/host refusal.
- Temporal server, setup and schema CLI: carry roots to each consumer. The
  inspected server template uses `SQL_CA` and `SQL_HOST_VERIFICATION=true`;
  setup uses `POSTGRES_TLS_CA_FILE`, and schema CLI uses `SQL_TLS_CA_FILE`.
  `SQL_TLS_DISABLE_HOST_VERIFICATION=false` alone did not make the inspected
  server template verify hosts.

Normal source, required CI, public control, signed image, staging and production
receipts remain separate. Live pool, worker and schema/preflight acceptance must
precede a CASA claim of complete internal TLS verification. RDS `force_ssl=1`,
synthetic native fixtures and public CA artifact checks remain supporting evidence.
