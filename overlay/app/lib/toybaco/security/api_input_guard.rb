# frozen_string_literal: true

# ダッシュボードの API で、上流が例外(500)にする入力の誤りを 4xx で返す(staging の DAST、2026-11-03 の窓の 500 の分類)。
# 正しい要求の振る舞いは変えない。ArgumentError・NoMethodError などを広く rescue せず、上流が例外にする入力を先に照らす。
# 応答と log に入力の値を映さない。
# - NullBytes: ダッシュボードの API(Api::V1::Accounts::BaseController の子。/api/v1/accounts/… と /api/v2/accounts/… の
#   reports)と、その外の profile・店舗の作成と更新(v1・v2)・widget の API・公開 API の params(query・form・JSON の本文・
#   path)の文字列と鍵に NUL があれば 400。PG は text の NUL を ArgumentError(string contains null byte)、jsonb の \u0000 を
#   UntranslatableCharacter で拒むので、callback の先頭で DB に触る前に止める。multipart の file(UploadedFile)の中身は
#   照らさない。webhook・受信のメール・Stripe・各 channel の callback・active_storage の direct upload は対象の外。
# - CustomAttributeDefinitions・Conversations: enum の外の値は、Rails の enum の代入(EnumType#assert_valid_value)が
#   ArgumentError にする。同じ条件で照らして 422(RecordInvalid と同じ形)。値が空の時は上流のまま。上流が例外にする
#   形(配列の id、Hash でない属性、toggle_status の読めない snoozed_until)も 422。
# - Reports・SummaryReports: reports の各 action と summary_reports の type・since・until・id・page・timezone_offset・
#   days_before を builder に渡す前に照らして 422。live_reports は上流が 4xx・200 で受けるので照らさない。
# - AuditLogs: DISABLE_ENTERPRISE の build の Account には associated_audits(enterprise の has_associated_audits)が無い。
#   上流の fetch_audit は NoMethodError になるので、機能が無い build では 404。
module Toybaco::Security::ApiInputGuard
  NULL_BYTE = "\0"

  # NUL を照らす controller(子を含む)。webhook・SES・Stripe・channel の callback・direct upload はこの子ではない。
  NULL_BYTE_CONTROLLERS = %w[Api::V1::Accounts::BaseController Api::V1::ProfilesController Api::V1::AccountsController
                             Api::V2::AccountsController Api::V1::Widget::BaseController Public::Api::V1::InboxesController].freeze

  def self.install!
    NULL_BYTE_CONTROLLERS.map(&:constantize).each { |base| base.include(NullBytes) unless base < NullBytes }
    [[Api::V1::Accounts::CustomAttributeDefinitionsController, CustomAttributeDefinitions],
     [Api::V1::Accounts::ConversationsController, Conversations],
     [Api::V2::Accounts::ReportsController, Reports],
     [Api::V2::Accounts::SummaryReportsController, SummaryReports],
     [Api::V1::Accounts::AuditLogsController, AuditLogs]].each do |controller, guard|
      controller.prepend(guard) unless controller < guard
    end
  end

  # Hash の鍵と値、Array の要素をたどる。UploadedFile・数・真偽・nil は照らさない。
  def self.null_byte?(value)
    case value
    when String then value.include?(NULL_BYTE)
    when Hash then value.any? { |key, item| null_byte?(key) || null_byte?(item) }
    when Array then value.any? { |item| null_byte?(item) }
    else false
    end
  end

  # EnumType#assert_valid_value が ArgumentError にする条件(空でも、鍵でも、値でもない)。
  def self.invalid_enum?(mapping, value)
    !(value.blank? || mapping.key?(value) || mapping.value?(value))
  end

  # 上流と同じ DateTime.strptime(value, '%s')(DateRangeHelper#parse_date_time)で読む。文字列でない値と読めない値は
  # :format(上流は TypeError・Date::Error)、PostgreSQL に渡せない日時は :range。
  def self.epoch_error(value)
    return :format unless value.is_a?(String)

    Reports::EPOCH_RANGE.cover?(DateTime.strptime(value, '%s').to_i) ? nil : :range
  rescue Date::Error
    :format
  end

  # 1 つの値(文字列・数・nil)か。配列・Hash は上流の to_f・to_i・find が例外にする。
  def self.scalar?(value)
    value.nil? || value.is_a?(String) || value.is_a?(Numeric)
  end

  module NullBytes
    MESSAGE = '入力に使えない文字(NUL)が含まれています。'

    def self.included(base)
      base.prepend_before_action :toybaco_reject_null_bytes
    end

    private

    def toybaco_reject_null_bytes
      return unless Toybaco::Security::ApiInputGuard.null_byte?(request.parameters)

      render json: { error: MESSAGE }, status: :bad_request
    end
  end

  module EnumErrors
    private

    def toybaco_invalid_enum_rendered?(attribute, mapping, value)
      return false unless Toybaco::Security::ApiInputGuard.invalid_enum?(mapping, value)

      render json: { message: "#{attribute} は #{mapping.keys.join('・')} のいずれかを指定してください。", attributes: [attribute] },
             status: :unprocessable_entity
      true
    end
  end

  module CustomAttributeDefinitions
    include EnumErrors

    ATTRIBUTES = %w[attribute_model attribute_display_type].freeze

    def create
      super unless toybaco_invalid_definition_rendered?
    end

    def update
      super unless toybaco_invalid_definition_rendered?
    end

    private

    # 上流が model に渡すのと同じ permitted_payload の値を照らす。Hash でない custom_attribute_definition は、上流の
    # permit が NoMethodError にする(無い時は上流の ParameterMissing の 422 のまま)。
    def toybaco_invalid_definition_rendered?
      definition = params[:custom_attribute_definition]
      # require は false をそのまま返し、空の値は ParameterMissing にする。
      if definition == false || (definition.present? && !definition.is_a?(ActionController::Parameters))
        render json: { error: 'custom_attribute_definition の形が正しくありません。' }, status: :unprocessable_entity
        return true
      end

      payload = permitted_payload
      ATTRIBUTES.any? do |attribute|
        toybaco_invalid_enum_rendered?(attribute, CustomAttributeDefinition.defined_enums.fetch(attribute), payload[attribute])
      end
    end
  end

  module Conversations
    include EnumErrors

    SNOOZE_MESSAGE = 'snoozed_until は UNIX 時刻(秒)で、0001-01-01 から 9999-12-31 の間を指定してください。'
    # create で上流が例外にする形。中身のある配列の id は、inbox の callback の authorize(Pundit が配列を名前空間として読む)と
    # ContactInboxBuilder が例外にする(空の配列は上流が無い値として読み、Hash の id は上流の find の 404 のまま)。
    # additional_attributes・custom_attributes は、ConversationBuilder が nil 以外に permit! を呼ぶ(空の配列・空文字・false も)。
    # message は、上流が空の時は読まず、中身があれば MessageBuilder が Hash として読む。
    ARRAY_IDS = %w[inbox_id contact_id].freeze
    HASH_ATTRIBUTES = %w[additional_attributes custom_attributes].freeze

    def toggle_status
      super unless toybaco_invalid_status_rendered? || toybaco_invalid_snooze_rendered?
    end

    private

    # create の配列の id は、店舗の認証の後、上流の inbox の callback の find・authorize の前に照らす。
    def inbox
      super unless toybaco_invalid_array_ids_rendered?
    end

    # create は、連絡先の受信箱を作る before_action(contact_inbox)の前に照らす(行を作ってから 500 にしない)。
    def contact_inbox
      super unless toybaco_invalid_status_rendered? || toybaco_invalid_create_shape_rendered?
    end

    def toybaco_invalid_status_rendered?
      toybaco_invalid_enum_rendered?('status', Conversation.defined_enums.fetch('status'), params[:status])
    end

    # 上流は status がある時だけ parse_date_time(params[:snoozed_until].to_s) で読む(bot の引き継ぎの時は読まない)。
    def toybaco_invalid_snooze_rendered?
      value = params[:snoozed_until]
      return false if !value || params[:status].blank? || bot_handoff?
      return false unless Toybaco::Security::ApiInputGuard.epoch_error(value.to_s)

      toybaco_render_shape_error('snoozed_until', SNOOZE_MESSAGE)
    end

    def toybaco_invalid_array_ids_rendered?
      name = ARRAY_IDS.find { |key| params[key].is_a?(Array) && params[key].present? }
      name ? toybaco_render_shape_error(name, "#{name} の形が正しくありません。") : false
    end

    def toybaco_invalid_create_shape_rendered?
      name = HASH_ATTRIBUTES.find { |key| !params[key].nil? && !params[key].is_a?(ActionController::Parameters) }
      name ||= 'message' if params[:message].present? && !params[:message].is_a?(ActionController::Parameters)
      name ? toybaco_render_shape_error(name, "#{name} の形が正しくありません。") : false
    end

    def toybaco_render_shape_error(attribute, message)
      render json: { message: message, attributes: [attribute] }, status: :unprocessable_entity
      true
    end
  end

  module ReportErrors
    FORMAT_MESSAGE = 'since・until は UNIX 時刻(秒)で指定してください。'
    RANGE_MESSAGE = 'since・until と、比べる前の期間は 0001-01-01 から 9999-12-31 の間にしてください。'

    private

    def toybaco_report_error_rendered?(message)
      return false unless message

      render json: { error: message }, status: :unprocessable_entity
      true
    end

    # 無い値と空の文字列は上流も読まない。文字列でない値(配列・Hash)は上流の strptime・to_i が TypeError・NoMethodError にする。
    def toybaco_epoch_message(values)
      given = values.reject { |value| value.nil? || (value.is_a?(String) && value.blank?) }
      errors = given.map { |value| Toybaco::Security::ApiInputGuard.epoch_error(value) }
      return FORMAT_MESSAGE if errors.include?(:format)

      RANGE_MESSAGE if errors.include?(:range)
    end
  end

  module Reports
    include ReportErrors

    TYPES = %w[account inbox agent label team].freeze
    # UNIX 秒で 0001-01-01T00:00:00Z〜9999-12-31T23:59:59Z(上限は上流の AuditLogsController::MAX_EPOCH と同じ)。
    # PostgreSQL の timestamp(4713 BC〜294276 AD)の内側で、時差と週・月・年の区切りへの丸めでも外に出ない。
    EPOCH_RANGE = (-62_135_596_800..253_402_300_799)
    TYPE_MESSAGE = "type は #{TYPES.join('・')} のいずれかを指定してください。".freeze
    FORMAT_MESSAGE = ReportErrors::FORMAT_MESSAGE
    RANGE_MESSAGE = ReportErrors::RANGE_MESSAGE
    TIMEZONE_MESSAGE = 'timezone_offset を 1 つの値で指定してください。'
    PAGE_MESSAGE = 'page は 1 つの値で、大きすぎない数を指定してください。'
    ID_MESSAGE = 'id は 1 つの値で指定してください。'
    DAYS_MESSAGE = 'days_before は 1 つの値で、期間が 0001-01-01 から 9999-12-31 の間に収まる日数を指定してください。'
    # reports/conversations の 1 ページの件数(V2::ReportBuilder::AGENT_RESULTS_PER_PAGE)と、PostgreSQL の bigint の上限。
    PER_PAGE = 25
    MAX_OFFSET = (2**63) - 1
    CSV_ACTIONS = %i[agents inboxes labels teams conversations_summary].freeze

    def index
      super unless toybaco_report_error_rendered?(toybaco_timeseries_error || toybaco_timezone_error)
    end

    def summary
      super unless toybaco_report_error_rendered?(toybaco_summary_error)
    end

    def bot_summary
      super unless toybaco_report_error_rendered?(toybaco_summary_error)
    end

    def conversations
      super unless toybaco_report_error_rendered?(toybaco_conversations_type_error || toybaco_page_error)
    end

    CSV_ACTIONS.each do |action|
      define_method(action) { super() unless toybaco_report_error_rendered?(toybaco_period_error) }
    end

    def conversation_traffic
      super unless toybaco_report_error_rendered?(toybaco_traffic_error)
    end

    private

    def toybaco_timeseries_error
      toybaco_timeseries_type_error || toybaco_id_error || toybaco_period_error
    end

    def toybaco_summary_error
      toybaco_timeseries_error || toybaco_previous_period_error
    end

    # 上流は type を to_sym し(無い時は NoMethodError)、空の文字列は account として読む。それ以外は builder の scope が nil になる。
    def toybaco_timeseries_type_error
      type = params[:type]
      TYPE_MESSAGE unless type.is_a?(String) && (type.empty? || TYPES.include?(type))
    end

    # type が空の時は上流が 422 を返す。それ以外は ReportHelper#scope が nil になる。
    def toybaco_conversations_type_error
      type = params[:type]
      TYPE_MESSAGE unless type.blank? || TYPES.include?(type)
    end

    # account 以外の type では、配列の id を find が配列で返し、scope の conversations が NoMethodError になる
    # (Hash の id は上流の find の 404 のまま)。
    def toybaco_id_error
      ID_MESSAGE if params[:id].is_a?(Array) && params[:type].present? && params[:type] != 'account'
    end

    # 時系列の builder は timezone_offset を to_f する。
    def toybaco_timezone_error
      TIMEZONE_MESSAGE unless Toybaco::Security::ApiInputGuard.scalar?(params[:timezone_offset])
    end

    # 上流は page を Kaminari の page(to_i)に渡す。配列は NoMethodError、大きすぎる数は OFFSET が bigint を超える。
    def toybaco_page_error
      page = params[:page]
      return PAGE_MESSAGE unless Toybaco::Security::ApiInputGuard.scalar?(page)

      PAGE_MESSAGE if page.present? && (page.to_i - 1) * PER_PAGE > MAX_OFFSET
    end

    def toybaco_period_error
      toybaco_epoch_message([params[:since], params[:until]])
    end

    # summary は前の期間(since - (until - since) から since まで)も数える(Api::V2::Accounts::ReportsController#range)。
    def toybaco_previous_period_error
      return if params[:since].blank?

      previous_since = params[:since].to_i - (params[:until].to_i - params[:since].to_i)
      RANGE_MESSAGE unless EPOCH_RANGE.cover?(previous_since)
    end

    # 上流は TimeZone[timezone_offset] を引く(無い時・配列の時は ArgumentError)。期間は今日から days_before.to_i 日前まで。
    def toybaco_traffic_error
      offset = params[:timezone_offset]
      return TIMEZONE_MESSAGE if offset.nil? || !Toybaco::Security::ApiInputGuard.scalar?(offset)

      days = params[:days_before]
      return DAYS_MESSAGE unless Toybaco::Security::ApiInputGuard.scalar?(days)

      DAYS_MESSAGE if days.present? && !EPOCH_RANGE.cover?(Time.current.to_i - (days.to_i * 86_400))
    end
  end

  module SummaryReports
    include ReportErrors

    ACTIONS = %i[agent team inbox label channel].freeze

    ACTIONS.each do |action|
      define_method(action) { super() unless toybaco_report_error_rendered?(toybaco_summary_period_error) }
    end

    private

    # 上流と同じ permit した値(配列・Hash は上流の permit が落として nil のまま読む)を照らす。
    def toybaco_summary_period_error
      toybaco_epoch_message(params.permit(:since, :until).values_at(:since, :until))
    end
  end

  module AuditLogs
    MESSAGE = '監査ログはこの環境では使えません。'

    private

    def fetch_audit
      return super if Account.method_defined?(:associated_audits)

      render_not_found_error(MESSAGE)
    end
  end
end
