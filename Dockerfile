# amd64本番で実行するChatwoot v4.17.1 manifestとsourceを不変値で固定する。
ARG CHATWOOT_IMAGE=chatwoot/chatwoot@sha256:0dcaaacc41ba5219b48af80b236f7707dbd5d58228320950af71a4309c349a7a

FROM ${CHATWOOT_IMAGE} AS overlay-normalizer
COPY overlay/app/ /toybaco-overlay/
RUN find /toybaco-overlay -exec touch -t 200001010000.00 {} +

FROM ${CHATWOOT_IMAGE} AS localized-assets
ENV HUSKY=0 \
    PNPM_HOME=/usr/local/share/pnpm \
    PATH=/usr/local/share/pnpm:/usr/local/bin:${PATH}
COPY --from=overlay-normalizer /toybaco-overlay/app/javascript/ /app/app/javascript/
RUN test "$(node --version)" = 'v24.19.0' \
    && ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && npm install --global --ignore-scripts 'pnpm@10.2.0' \
    && test "$(pnpm --version)" = '10.2.0' \
    && pnpm install --frozen-lockfile \
    && rm -rf /app/public/vite \
    && SECRET_KEY_BASE=precompile_placeholder RAILS_LOG_TO_STDOUT=enabled \
      NODE_OPTIONS=--max-old-space-size=4096 \
      bundle exec rake assets:precompile \
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
RUN apk add --no-cache --upgrade 'musl-utils=1.2.5-r11' 'zlib=1.3.2-r0' \
    && test "$(apk info -v | grep '^musl-utils-')" = 'musl-utils-1.2.5-r11' \
    && test "$(apk info -v | grep '^zlib-')" = 'zlib-1.3.2-r0' \
    && test "$(find /app/public/vite/assets -type f -name '*.js' \
      -exec grep -h -o -E '\.set\("cw_d_session_info",JSON\.stringify\([^)]*\.headers\),\{expires:[^}]+,secure:!0,sameSite:"Lax",path:"/"\}\)' {} + \
      | wc -l | tr -d ' ')" = '1' \
    && for path in \
      etc/apk/world \
      lib/apk/db/installed lib/apk/db/scripts.tar lib/apk/db/triggers \
      sbin/ldconfig \
      usr/bin/getconf usr/bin/getent usr/bin/iconv usr/bin/ldd; do \
      mkdir -p "/toybaco-runtime-root/$(dirname "$path")"; \
      cp -p "/$path" "/toybaco-runtime-root/$path"; \
    done \
    && mkdir -p /toybaco-runtime-root/usr/lib \
    && cp -a /usr/lib/libz.so.1 /usr/lib/libz.so.1.3.2 /toybaco-runtime-root/usr/lib/ \
    && mkdir -p /toybaco-runtime-root/app/public \
    && cp -a /app/public/vite /toybaco-runtime-root/app/public/vite \
    && find /toybaco-runtime-root -exec touch -t 200001010000.00 {} +

FROM ${CHATWOOT_IMAGE}
RUN rm -rf /app/public/vite
COPY --from=runtime-hardening /toybaco-runtime-root/ /
RUN rm -f /usr/lib/libz.so.1.3.1 \
    && test "$(apk info -v | grep '^zlib-')" = 'zlib-1.3.2-r0' \
    && test "$(readlink /usr/lib/libz.so.1)" = 'libz.so.1.3.2' \
    && test -f /usr/lib/libz.so.1.3.2 \
    && test ! -e /usr/lib/libz.so.1.3.1
ARG TOYBACO_CONTROL_SHA256
LABEL org.opencontainers.image.base.name="chatwoot/chatwoot@sha256:0dcaaacc41ba5219b48af80b236f7707dbd5d58228320950af71a4309c349a7a" \
      org.opencontainers.image.source="https://github.com/Cyber-relations/chatwoot" \
      org.opencontainers.image.revision="b354a9550e1fb59fa537a9c384232cb076213e72" \
      jp.toybaco.source.tree="9a17426900d328a6acc2bdaecba0533e8b401120" \
      jp.toybaco.gate.control-sha256="${TOYBACO_CONTROL_SHA256}"
COPY --from=overlay-normalizer /toybaco-overlay/ /app/
