ARG CHATWOOT_IMAGE=chatwoot/chatwoot@sha256:03a03a85a00f1d119367deb0d090a56e553468d0aa5e9194a57eba7c61deb7de
FROM ${CHATWOOT_IMAGE}

ARG CHATWOOT_SOURCE_COMMIT=9f920b549c14491a4e587687a3eed5d21c6ccc7d

# 公式production imageにはtest/development gemが無い。固定sourceへoverlayを
# 適用したGemfile/lockを先に渡し、本番と同じRails修正版でtest groupを追加する。
ENV BUNDLE_WITHOUT="" \
    RAILS_ENV=test

COPY Gemfile Gemfile.lock /app/
COPY config/chatwoot-ruby-llm-backport.json /opt/toybaco/config/
COPY scripts/harden-chatwoot-ruby-llm.rb /opt/toybaco/scripts/
COPY tests/verify_chatwoot_ruby_llm_backport.rb /opt/toybaco/tests/
RUN bundle config unset without \
    && bundle install --jobs 4 --retry 3 \
    && bundle exec ruby /opt/toybaco/scripts/harden-chatwoot-ruby-llm.rb apply \
    && bundle exec ruby /opt/toybaco/tests/verify_chatwoot_ruby_llm_backport.rb

# build contextは固定commitの隔離cloneへoverlayを適用したものだけ。
ARG TOYBACO_CONTROL_SHA256
COPY . /app/

LABEL org.opencontainers.image.revision="${CHATWOOT_SOURCE_COMMIT}" \
      jp.toybaco.gate.control-sha256="${TOYBACO_CONTROL_SHA256}"
