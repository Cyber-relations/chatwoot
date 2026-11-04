# amd64本番で実行するChatwoot v4.18.0 manifestとsourceを不変値で固定する。
ARG CHATWOOT_IMAGE=chatwoot/chatwoot@sha256:03a03a85a00f1d119367deb0d090a56e553468d0aa5e9194a57eba7c61deb7de
# The shipped runtime is Alpine 3.22 with the same Ruby 3.4.4 as upstream (the Gemfile pins ruby '3.4.4'; this is the
# newest official 3.4.4 image). The upstream image above only supplies the code and every build-only stage.
ARG RUBY_RUNTIME_IMAGE=ruby:3.4.4-alpine3.22@sha256:017bd0bf72da696261a11a1575ab04d65b3340def62ce39219e8862fc0aa13d1

FROM ${CHATWOOT_IMAGE} AS overlay-normalizer
COPY overlay/app/ /toybaco-overlay/
COPY scripts/verify-chatwoot-ee-view-twins.sh /opt/toybaco/verify-ee-view-twins.sh
RUN sh /opt/toybaco/verify-ee-view-twins.sh /app/enterprise/app/views /toybaco-overlay
RUN find /toybaco-overlay -exec touch -t 200001010000.00 {} +

FROM ${CHATWOOT_IMAGE} AS bundled-gems
COPY config/chatwoot-runtime-gems.json /opt/toybaco/runtime-gems.json
COPY scripts/harden-chatwoot-runtime-gems.rb /opt/toybaco/harden-runtime-gems.rb
COPY tests/verify_chatwoot_runtime_gems.rb /opt/toybaco/verify-runtime-gems.rb
RUN apk add --no-cache --virtual .toybaco-gem-build build-base zlib-dev \
    && ruby /opt/toybaco/harden-runtime-gems.rb /opt/toybaco/runtime-gems.json \
    && apk del .toybaco-gem-build \
    && ruby /opt/toybaco/verify-runtime-gems.rb /opt/toybaco/runtime-gems.json
COPY --from=overlay-normalizer /toybaco-overlay/Gemfile /toybaco-overlay/Gemfile.lock /app/
COPY config/chatwoot-ruby-llm-backport.json /opt/toybaco/config/
COPY scripts/harden-chatwoot-ruby-llm.rb /opt/toybaco/scripts/
COPY tests/verify_chatwoot_ruby_llm_backport.rb /opt/toybaco/tests/
RUN BUNDLE_FROZEN=true bundle install --jobs 4 --retry 3 \
    && bundle clean --force \
    && bundle exec ruby /opt/toybaco/scripts/harden-chatwoot-ruby-llm.rb apply \
    && bundle exec ruby /opt/toybaco/tests/verify_chatwoot_ruby_llm_backport.rb \
    && bundle exec ruby -rrails -e 'abort unless Rails.version == "7.2.3.2"'

FROM bundled-gems AS localized-assets
COPY tests/verify_chatwoot_sdk_artifacts.mjs /opt/toybaco/tests/
COPY tests/verify_chatwoot_sprockets_artifacts.mjs /opt/toybaco/tests/
ENV HUSKY=0 \
    PNPM_HOME=/usr/local/share/pnpm \
    PATH=/usr/local/share/pnpm:/usr/local/bin:${PATH}
COPY --from=overlay-normalizer /toybaco-overlay/app/javascript/ /app/app/javascript/
COPY --from=overlay-normalizer /toybaco-overlay/app/assets/javascripts/ /app/app/assets/javascripts/
COPY --from=overlay-normalizer /toybaco-overlay/vite.config.ts /app/vite.config.ts
COPY tests/chatwoot-csp-build.test.mjs /opt/toybaco/tests/csp-build.test.mjs
COPY tests/chatwoot-cache-upgrade.test.mjs /opt/toybaco/tests/cache-upgrade.test.mjs
COPY tests/chatwoot-logout-cleanup.test.mjs /opt/toybaco/tests/logout-cleanup.test.mjs
COPY tests/chatwoot-browser-session.test.mjs /opt/toybaco/tests/browser-session.test.mjs
# The capture step discards generated assets but preserves all 54 pinned upstream static images.
RUN node /opt/toybaco/tests/verify_chatwoot_sprockets_artifacts.mjs --capture-legacy /app/public/assets /opt/toybaco/legacy-admin-asset.js
RUN node --version \
    && test "$(node --version)" = 'v24.21.0' \
    && ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && npm install --global --ignore-scripts 'pnpm@10.2.0' \
    && test "$(pnpm --version)" = '10.2.0' \
    && pnpm install --frozen-lockfile \
    && node /opt/toybaco/tests/csp-build.test.mjs /app \
    && node /opt/toybaco/tests/cache-upgrade.test.mjs /app /app /app \
    && node /opt/toybaco/tests/logout-cleanup.test.mjs /app /app /app \
    && node /opt/toybaco/tests/browser-session.test.mjs /app \
    && rm -rf /app/public/vite \
    && SECRET_KEY_BASE=precompile_placeholder RAILS_LOG_TO_STDOUT=enabled \
      NODE_OPTIONS=--max-old-space-size=4096 \
      bundle exec rake assets:precompile \
    && node /opt/toybaco/tests/verify_chatwoot_sprockets_artifacts.mjs --verify-build /app/public/assets /opt/toybaco/legacy-admin-asset.js \
    && node /opt/toybaco/tests/verify_chatwoot_sdk_artifacts.mjs /app/public/packs/js \
    && test -s /app/public/vite/.vite/manifest.json \
    && test -s /app/public/vite/.vite/manifest-assets.json \
    && for sentinel in \
      'トイバコサーバー' \
      'AIアシスタント' \
      'この機能はベータ版であり、改善のたびに変更される可能性があります。' \
      '新しいチャットを開始する' \
      '評価のご協力ありがとうございます。'; do \
      test "$(find /app/public/vite/assets -type f -name '*.js' \
        -exec grep -h -o -F "$sentinel" {} + | wc -l | tr -d ' ')" -ge 1; \
    done \
    && test "$(find /app/public/vite/assets -type f -name '*.js' \
      -exec grep -h -o -E 'Woot[[:space:]]*サーバー|Chatwootにログイン' {} + \
      | wc -l | tr -d ' ')" = '0' \
    && rm -rf /app/node_modules /root/.cache /root/.local/share/pnpm/store

FROM localized-assets AS runtime-hardening
# Collect the localized served assets for the runtime. The shipped OS and gems come from the Alpine 3.22 stages below.
RUN mkdir -p /toybaco-runtime-root/app/public \
    && test "$(find /app/public/vite/assets -type f -name '*.js' \
      -exec grep -h -o -E '\.set\("cw_d_session_info",' {} + \
      | wc -l | tr -d ' ')" = '0' \
    && cp -a /app/public/vite /toybaco-runtime-root/app/public/vite \
    && cp -a /app/public/assets /toybaco-runtime-root/app/public/assets \
    && mkdir -p /toybaco-runtime-root/app/public/packs/js \
    && cp -a /app/public/packs/js/sdk.js /app/public/packs/js/sdk.js.gz /app/public/packs/js/sdk.js.br /toybaco-runtime-root/app/public/packs/js/ \
    && find /toybaco-runtime-root -exec touch -t 200001010000.00 {} +

FROM ${CHATWOOT_IMAGE} AS upstream

FROM ${RUBY_RUNTIME_IMAGE} AS runtime-base
# Package policy (docs/chatwoot-runtime-os-policy.md): config/chatwoot-runtime-apk.txt is the reviewed package list.
# alpine-release stays at the pinned base image's own build, so the distro that the SBOM, Trivy and the evaluator
# bind to moves only with a reviewed base change, not with Alpine point releases. Every other package takes the
# branch's current signed build (security rebuilds need no pin bump); the verifier then requires exactly the reviewed
# package names and no version older than reviewed or than the CVE floors, and reports newer ones. Every regular file
# and symlink under /lib and /usr/lib must match its apk record (Z:) or the reviewed unowned-file list, except the
# apk database itself and the gdk-pixbuf loader cache (checked against gdk-pixbuf-query-loaders). The package set is
# the upstream final stage's without ImageMagick (Active Storage processes variants with libvips; see the policy),
# plus Bundler as upstream.
COPY config/chatwoot-runtime-apk.txt /opt/toybaco/config/chatwoot-runtime-apk.txt
COPY config/chatwoot-runtime-apk-cve-floors.tsv /opt/toybaco/config/chatwoot-runtime-apk-cve-floors.tsv
COPY config/chatwoot-runtime-apk-unowned-files.tsv /opt/toybaco/config/chatwoot-runtime-apk-unowned-files.tsv
COPY tests/verify_chatwoot_runtime_apk.rb /opt/toybaco/tests/verify_chatwoot_runtime_apk.rb
RUN alpine_release="$(sed -n 's/^alpine-release=//p' /opt/toybaco/config/chatwoot-runtime-apk.txt)" \
    && test -n "$alpine_release" \
    && apk add --no-cache "alpine-release=$alpine_release" \
    && apk upgrade --no-cache \
    && apk add --no-cache build-base openssl tzdata postgresql-client git vips \
    # Same-ABI official signed stable APK from another branch: v3.24 libexif 0.6.26-r0 fixes CVE-2026-32775,
    # CVE-2026-40385 and CVE-2026-40386 (Alpine secdb v3.23, not in v3.22) with the same SONAME as 0.6.25-r0.
    # libvips links libexif and reads EXIF of received JPEGs. Do not switch repositories or permit untrusted APKs.
    && ruby -ropen-uri -e 'URI.open("https://dl-cdn.alpinelinux.org/alpine/v3.24/community/x86_64/libexif-0.6.26-r0.apk") { |input| File.open("/tmp/toybaco-libexif.apk", "wb") { |output| IO.copy_stream(input, output) } }' \
    && echo '9fcc1b2c7f9a28aa7c310fe1ee215be4ece70e4b27f5cf079b3b56bf4ba683ae  /tmp/toybaco-libexif.apk' | sha256sum -c - \
    && apk --no-network verify /tmp/toybaco-libexif.apk \
    && apk add --no-network --upgrade /tmp/toybaco-libexif.apk \
    && rm /tmp/toybaco-libexif.apk \
    && test "$(apk info -v | grep '^libexif-')" = 'libexif-0.6.26-r0' \
    && gem install bundler -v 2.5.16 \
    && ruby /opt/toybaco/tests/verify_chatwoot_runtime_apk.rb /opt/toybaco/config/chatwoot-runtime-apk.txt /opt/toybaco/config/chatwoot-runtime-apk-cve-floors.tsv /opt/toybaco/config/chatwoot-runtime-apk-unowned-files.tsv
# The upstream final image's environment.
ENV NODE_VERSION=24.13.0 \
    PNPM_VERSION=10.2.0 \
    BUNDLE_WITHOUT=development:test \
    BUNDLER_VERSION=2.5.16 \
    EXECJS_RUNTIME=Disabled \
    RAILS_SERVE_STATIC_FILES=true \
    BUNDLE_FORCE_RUBY_PLATFORM=1 \
    RAILS_ENV=production \
    BUNDLE_PATH=/gems \
    VIPS_BLOCK_UNTRUSTED=1 \
    CW_EDITION=ee
# Same Ruby 3.4.4, so the default/bundled gem hardening applies unchanged.
COPY config/chatwoot-runtime-gems.json /opt/toybaco/runtime-gems.json
COPY scripts/harden-chatwoot-runtime-gems.rb /opt/toybaco/harden-runtime-gems.rb
COPY tests/verify_chatwoot_runtime_gems.rb /opt/toybaco/verify-runtime-gems.rb
RUN apk add --no-cache --virtual .toybaco-gem-build zlib-dev \
    && ruby /opt/toybaco/harden-runtime-gems.rb /opt/toybaco/runtime-gems.json \
    && apk del .toybaco-gem-build \
    && ruby /opt/toybaco/verify-runtime-gems.rb /opt/toybaco/runtime-gems.json
WORKDIR /app

FROM runtime-base AS gems
# Build parallelism only; grpc's extconf reads GRPC_RUBY_BUILD_PROCS.
ARG BUNDLE_JOBS=4
ARG GRPC_RUBY_BUILD_PROCS=4
COPY --from=overlay-normalizer /toybaco-overlay/Gemfile /toybaco-overlay/Gemfile.lock /app/
COPY config/chatwoot-ruby-llm-backport.json /opt/toybaco/config/
COPY scripts/harden-chatwoot-ruby-llm.rb /opt/toybaco/scripts/
COPY tests/verify_chatwoot_ruby_llm_backport.rb /opt/toybaco/tests/
# Every gem, native extensions included, is compiled here against the shipped Alpine 3.22 libraries
# (BUNDLE_FORCE_RUBY_PLATFORM=1 as upstream). The headers are the upstream pre-builder's and stay in this stage; only
# /gems and /opt/toybaco are copied out. Bundler follows the lock's BUNDLED WITH (2.5.16).
RUN apk add --no-cache --virtual .toybaco-gem-native postgresql-dev openssl-dev linux-headers musl-dev xz \
    && test "$(bundle --version)" = 'Bundler version 2.5.16' \
    && BUNDLE_FROZEN=true bundle install --jobs "$BUNDLE_JOBS" --retry 3 \
    && bundle clean --force \
    && rm -rf /gems/ruby/3.4.0/cache \
    && find /gems/ruby/3.4.0/gems/ \( -name '*.c' -o -name '*.o' \) -delete \
    && bundle exec ruby /opt/toybaco/scripts/harden-chatwoot-ruby-llm.rb apply \
    && bundle exec ruby /opt/toybaco/tests/verify_chatwoot_ruby_llm_backport.rb \
    && bundle exec ruby -rrails -e 'abort unless Rails.version == "7.2.3.2"'

FROM runtime-base AS runtime-app
COPY --from=gems /gems /gems
COPY --from=gems /opt/toybaco/ /opt/toybaco/
COPY --from=upstream /app /app
# Only the Gemfile and lock here, for the bundle check. The whole overlay is copied once, last, after the LABEL in
# the final stage (the gate pins that single COPY), so no later layer can shadow an overlay file.
COPY --from=overlay-normalizer /toybaco-overlay/Gemfile /toybaco-overlay/Gemfile.lock /app/
RUN rm -rf /app/tests/playwright \
    && test ! -e /app/node_modules \
    && bundle exec ruby -rrails -e 'abort unless Rails.version == "7.2.3.2"'
EXPOSE 3000
CMD ["irb"]

FROM runtime-app
RUN rm -rf /app/public/vite
RUN rm -rf /app/public/assets
COPY --from=runtime-hardening /toybaco-runtime-root/ /
COPY tests/verify_chatwoot_sdk_artifacts.mjs /opt/toybaco/tests/
COPY tests/verify_chatwoot_sprockets_artifacts.mjs /opt/toybaco/tests/
# Re-check the final filesystem: the reviewed package set and versions, the CVE floors, the bytes under /lib and
# /usr/lib, the actually loaded OpenSSL, expat, TIFF, OpenJPEG, zlib and musl, and the hardened Ruby default gems.
RUN test ! -e /usr/local/lib/node_modules/npm \
    && test ! -e /usr/local/bin/npm \
    && test ! -e /usr/local/bin/npx \
    && test ! -e /app/tests/playwright \
    && ruby /opt/toybaco/tests/verify_chatwoot_runtime_apk.rb /opt/toybaco/config/chatwoot-runtime-apk.txt /opt/toybaco/config/chatwoot-runtime-apk-cve-floors.tsv /opt/toybaco/config/chatwoot-runtime-apk-unowned-files.tsv \
    && ruby /opt/toybaco/verify-runtime-gems.rb /opt/toybaco/runtime-gems.json
ARG TOYBACO_CONTROL_SHA256
LABEL org.opencontainers.image.base.name="ruby:3.4.4-alpine3.22@sha256:017bd0bf72da696261a11a1575ab04d65b3340def62ce39219e8862fc0aa13d1" \
      org.opencontainers.image.source="https://github.com/Cyber-relations/chatwoot" \
      org.opencontainers.image.revision="9f920b549c14491a4e587687a3eed5d21c6ccc7d" \
      jp.toybaco.upstream.image="chatwoot/chatwoot@sha256:03a03a85a00f1d119367deb0d090a56e553468d0aa5e9194a57eba7c61deb7de" \
      jp.toybaco.source.tree="16432eeeef9153f7aff66be382e04a20e6f5683a" \
      jp.toybaco.gate.control-sha256="${TOYBACO_CONTROL_SHA256}"
COPY --from=overlay-normalizer /toybaco-overlay/ /app/
# The publisher supplies its checked-out public source revision. Local/non-public
# builds leave this empty and the public source route returns an explicit 503.
ARG TOYBACO_PUBLIC_REVISION=""
RUN if [ -n "$TOYBACO_PUBLIC_REVISION" ]; then \
      test "${#TOYBACO_PUBLIC_REVISION}" -eq 40 \
      && ! printf '%s' "$TOYBACO_PUBLIC_REVISION" | grep -q '[^0-9a-f]'; \
    fi \
    && printf '%s\n' "$TOYBACO_PUBLIC_REVISION" > /app/TOYBACO_PUBLIC_REVISION \
    && bundle exec ruby /opt/toybaco/tests/verify_chatwoot_ruby_llm_backport.rb
# Node is not shipped (docs/chatwoot-runtime-os-policy.md). These two checks borrow the upstream binary for their own
# RUN only, read-only through a BuildKit bind mount; the next RUN proves that neither Node nor a mount stub is left.
RUN --mount=type=bind,from=upstream,source=/usr/local/bin/node,target=/usr/local/bin/node /usr/local/bin/node /opt/toybaco/tests/verify_chatwoot_sdk_artifacts.mjs /app/public/packs/js
RUN --mount=type=bind,from=upstream,source=/usr/local/bin/node,target=/usr/local/bin/node /usr/local/bin/node /opt/toybaco/tests/verify_chatwoot_sprockets_artifacts.mjs --verify-final /app/public/assets
RUN test ! -e /usr/local/bin/node && test -z "$(command -v node || :)"
# Inspect the public trust artifact after every final filesystem write.
# Enabling each client's certificate verification is a separate change.
RUN ruby -r /app/lib/toybaco_rds_trust.rb -e 'ToybacoRdsTrust.verify!'
