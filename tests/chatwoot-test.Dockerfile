ARG CHATWOOT_IMAGE=chatwoot/chatwoot@sha256:0dcaaacc41ba5219b48af80b236f7707dbd5d58228320950af71a4309c349a7a
FROM ${CHATWOOT_IMAGE}

ARG CHATWOOT_SOURCE_COMMIT=b354a9550e1fb59fa537a9c384232cb076213e72

# 公式production imageにはtest/development gemが無い。固定image内の
# Gemfile.lockをそのまま使ってtest groupだけを追加し、可変Ruby imageを増やさない。
ENV BUNDLE_WITHOUT="" \
    RAILS_ENV=test

RUN bundle config unset without \
    && bundle install --jobs 4 --retry 3

# build contextは固定commitの隔離cloneへoverlayを適用したものだけ。
ARG TOYBACO_CONTROL_SHA256
COPY . /app/

LABEL org.opencontainers.image.revision="${CHATWOOT_SOURCE_COMMIT}" \
      jp.toybaco.gate.control-sha256="${TOYBACO_CONTROL_SHA256}"
