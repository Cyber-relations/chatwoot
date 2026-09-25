# frozen_string_literal: true

require 'time'
require_relative 'entitlements'
require_relative 'growth_terms'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # 公開中の利用規約の版と、アプリ内で取得した規約同意の記録。
  # VERSION は site/terms/index.html の <meta name="toybaco-terms-version"> と同値に保つ
  # (tests/test_legal_terms_version.py)。記録は追記だけで、既存の契約キーの意味を変えない。
  module LegalTerms
    VERSION = '2026-09-25.1'
    TERMS_URL = 'https://toybaco.jp/terms/'
    TOKUSHOHO_URL = 'https://toybaco.jp/tokushoho/'
    PRIVACY_URL = 'https://toybaco.jp/privacy/'
    KEY = 'toybaco_legal_consents'
    ROUTES = %w[opening_checkout growth_purchase free_registration managed_auto trial].freeze
    DETAILS = %i[terms_version user_id session_id stripe_consent].freeze
    VERSION_FORMAT = /\A\d{4}-\d{2}-\d{2}\.[1-9]\d*\z/
    SESSION_FORMAT = /\Acs_(?:test_|live_)?[A-Za-z0-9]{1,200}\z/
    # Stripe Checkout の同意欄と支払いボタン横の文言(Markdown リンク可・各1200字以内)。
    TOS_MESSAGE = "[利用規約](#{TERMS_URL})と[特定商取引法に基づく表記](#{TOKUSHOHO_URL})に同意します。".freeze
    SUBMIT_MESSAGE = '解約するまで同じ金額で自動更新します。解約は「ご契約内容」からでき、契約期間末に無料プランへ移ります。期間途中の日割り返金はありません。'
    # 期間末に無料プランへ移らない旧版の契約には、事実と異なる一文を除いた同じ案内を出す。
    LEGACY_SUBMIT_MESSAGE = '解約するまで同じ金額で自動更新します。解約は「ご契約内容」からできます。期間途中の日割り返金はありません。'

    module_function

    # 解約・更新失敗の後に無料プランへ移るのは新料金版だけ。旧版の契約に無料プランを案内しない。
    def returns_to_free?(terms)
      terms.is_a?(Hash) && terms.dig('entitlements', 'ai_meter') == GrowthTerms::METER
    end

    def submit_message(terms)
      returns_to_free?(terms) ? SUBMIT_MESSAGE : LEGACY_SUBMIT_MESSAGE
    end

    # アプリ内の確認で同意を得た時点。Checkout Session の metadata に載せ、開通時に同じ値を記録する。
    def consent(accepted_at = Time.now.utc)
      { 'terms_version' => VERSION, 'accepted_at' => timestamp!(accepted_at) }
    end

    def metadata(consent)
      return { 'toybaco_terms_version' => VERSION } unless consent

      { 'toybaco_terms_version' => version!(consent.fetch('terms_version')),
        'toybaco_terms_accepted_at' => timestamp!(consent.fetch('accepted_at')) }
    end

    # Stripe の metadata に残したアプリ内同意。同意欄を導入する前の Session は nil。
    def accepted_in(metadata)
      return unless metadata.is_a?(Hash) && metadata.key?('toybaco_terms_accepted_at')

      { terms_version: metadata['toybaco_terms_version'], accepted_at: metadata['toybaco_terms_accepted_at'] }
    end

    # 同じ経路の同じ Session(Session が無ければ同じ同意日時)は二重に追記しない。
    def record!(account, route:, accepted_at:, **details)
      entry = entry(route, accepted_at, details)
      account.with_lock do
        attrs = Entitlements.attributes(account)
        consents = history(attrs)
        next if consents.any? { |saved| duplicate?(saved, entry) }

        account.update!(internal_attributes: attrs.merge(KEY => consents + [entry]))
      end
      entry
    end

    def records(account)
      history(Entitlements.attributes(account))
    end

    def entry(route, accepted_at, details)
      raise ArgumentError, 'unknown consent route' unless ROUTES.include?(route)
      raise ArgumentError, 'unknown consent detail' unless (details.keys - DETAILS).empty?

      { 'route' => route, 'terms_version' => version!(details.fetch(:terms_version, VERSION)),
        'accepted_at' => timestamp!(accepted_at), 'user_id' => user!(details[:user_id]),
        'session_id' => session!(details[:session_id]), 'stripe_consent' => stripe_consent!(details[:stripe_consent]) }
    end

    def history(attrs)
      value = attrs.fetch(KEY, [])
      raise ArgumentError, 'invalid consent history' unless value.is_a?(Array)

      value
    end

    def duplicate?(saved, entry)
      key = entry['session_id'] ? 'session_id' : 'accepted_at'
      saved.is_a?(Hash) && saved['route'] == entry['route'] && saved[key] == entry[key]
    end

    def version!(value)
      raise ArgumentError, 'invalid terms version' unless value.is_a?(String) && value.match?(VERSION_FORMAT)

      value
    end

    def timestamp!(value)
      time = value.is_a?(String) ? Time.iso8601(value) : value
      raise ArgumentError, 'invalid acceptance time' unless time.is_a?(Time)

      time.utc.iso8601
    end

    def user!(value)
      raise ArgumentError, 'invalid consent user' unless value.nil? || (value.is_a?(Integer) && value.positive?)

      value
    end

    def session!(value)
      raise ArgumentError, 'invalid consent session' unless value.nil? || (value.is_a?(String) && value.match?(SESSION_FORMAT))

      value
    end

    def stripe_consent!(value)
      raise ArgumentError, 'invalid Stripe consent' unless [nil, 'accepted'].include?(value)

      value
    end
  end
end
