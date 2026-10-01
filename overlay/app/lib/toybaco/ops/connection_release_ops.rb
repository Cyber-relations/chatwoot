# frozen_string_literal: true

require_relative '../connection_release'
require_relative 'ops_flag'

# メール接続(Gmail / Microsoft)の開放を運営 rake で進める実装(lib/tasks/toybaco_ops.rake の toybaco:connection_release_* と
# toybaco:connection_handoff_mail)。開放の読み手は Toybaco::ConnectionRelease(各接続の public_decision)と
# Toybaco::Connections::Handoff::MailGateway で、書き込みの読み直しは読み手と同じ関数・同じ DB 直読で、同じ transaction の中で行う。
# 記録は運営が審査・評価・実測で確かめた項目だけを書き、既定値で埋めない。application_id と scope_digest は現在の設定と実装の定数から
# 計算し、引数では受けない。出力に client secret・client ID・scope digest は出さない。行は呼び出し側(rake)が出力する。
# rake は Rails の初期化前にこのファイルを読むため、モジュールは入れ子で定義し、InstallationConfig などは呼び出し時に参照する。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Ops
    module ConnectionReleaseOps
      CONFIG = Toybaco::ConnectionRelease::CONFIG_NAME
      CHECKS = Toybaco::ConnectionRelease::REQUIRED_CHECKS
      ENVIRONMENTS = Toybaco::ConnectionRelease::ENVIRONMENTS
      HANDOFF_CONFIG = 'TOYBACO_CONNECTION_HANDOFF_MAIL'
      HANDOFF_ENABLED = 'TOYBACO_CONNECTION_HANDOFF_ENABLED'
      # 開放判定の provider キー(ConnectionRelease)と、client ID の設定名。担当者依頼メールは MailGateway の provider キーを使う。
      PROVIDERS = %w[gmail_rest microsoft_graph].freeze
      CLIENT_KEYS = { 'gmail_rest' => 'TOYBACO_GMAIL_CLIENT_ID', 'microsoft_graph' => 'TOYBACO_MICROSOFT_CLIENT_ID' }.freeze
      HANDOFF_PROVIDERS = %w[gmail microsoft].freeze
      HANDOFF_MODES = %w[enable keep disable].freeze
      KINDS = %w[approval qualification].freeze
      # ops-rake workflow の引数の形と同じ(証跡の参照と、UTC の時刻)。
      EVIDENCE_FORMAT = /\A[A-Za-z0-9_.:-]{1,80}\z/
      TIME_FORMAT = /\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/
      # 担当者依頼の callback の origin は環境ごとに 1 つ(MailGateway が許す 2 つの origin を環境と組にする)。
      ORIGINS = { 'staging' => 'https://app.staging.toybaco.jp', 'production' => 'https://app.toybaco.jp' }.freeze
      # 判定が記録を読む前の設定の不足で止まる理由(ConnectionRelease の configuration_error と public_decision の未設定)。
      CONFIGURATION_REASONS = %w[environment_unknown implementation_unavailable application_unconfigured scope_unconfigured].freeze

      # 引数の検査。通すのは形に合う文字列だけで、合わなければ abort する(書き込みの前に止める)。
      module Input
        module_function

        def provider!(value)
          choice!(value, PROVIDERS, "provider は #{PROVIDERS.join(' / ')} のいずれかを指定してください。")
        end

        # 検査と代入を同じ判定にする(通すのは許可一覧にある文字列だけで、Symbol などは通さない)。
        def choice!(value, allowed, message)
          abort message unless value.is_a?(String) && allowed.include?(value)
          value
        end

        def extras!(args, expected)
          abort "引数は #{expected}だけを指定してください。" unless args.extras.empty?
        end

        # approval / qualification の受領記録(status は approved だけ)。qualification は期限の記録が必須。
        def receipt!(args, kind)
          receipt = { 'status' => 'approved', 'evidence_ref' => evidence!(args[:evidence_ref]), 'observed_at' => observed!(args[:observed_at]) }
          expires = expires!(args[:expires_at])
          return receipt.merge('expires_at' => expires) unless expires == 'none'

          abort 'qualification(セキュリティ評価)は期限の記録が必要です。expires_at を YYYY-MM-DDTHH:MM:SSZ で指定してください。' if kind == 'qualification'
          receipt
        end

        def evidence!(value)
          return value if value.is_a?(String) && value.match?(EVIDENCE_FORMAT)

          abort 'evidence_ref は承認通知・評価報告・実測記録の ID を、英数字と _ . : - の 1〜80 文字で指定してください。'
        end

        def observed!(value)
          time = utc_time(value)
          return value if time && time <= Time.now.utc

          abort 'observed_at は現在以前の UTC 時刻を YYYY-MM-DDTHH:MM:SSZ で指定してください。'
        end

        def expires!(value)
          time = value == 'none' ? nil : utc_time(value)
          return value if value == 'none' || (time && time > Time.now.utc)

          abort 'expires_at は未来の UTC 時刻を YYYY-MM-DDTHH:MM:SSZ で指定するか、期限が無ければ none を指定してください。'
        end

        # 実測で合格した項目。正規の順(REQUIRED_CHECKS の順)で各 1 回まで、1 つ以上(ops-rake workflow の形と同じ)。
        def checks!(value)
          names = value.is_a?(String) ? value.split('.', -1) : []
          return names if names.any? && names == CHECKS.select { |name| names.include?(name) }

          abort "checks は #{CHECKS.join(' / ')} のうち実測で合格した項目だけを、この順に各 1 回まで . で区切って指定してください。"
        end

        # 形(YYYY-MM-DDTHH:MM:SSZ)に合い、暦の上でも正しい時刻だけを Time にする(2 月 30 日や 24 時は繰り上がるので通さない)。
        def utc_time(value)
          return unless value.is_a?(String) && value.match?(TIME_FORMAT)

          time = Time.iso8601(value)
          time if time.utc.iso8601 == value
        rescue ArgumentError
          nil
        end

        def staging?
          ENV.fetch('TOYBACO_DEPLOYMENT_ENVIRONMENT', nil) == 'staging'
        end

        def environment!
          environment = ENV.fetch('TOYBACO_DEPLOYMENT_ENVIRONMENT', nil)
          abort 'TOYBACO_DEPLOYMENT_ENVIRONMENT が staging / production ではないため記録しません。' unless ENVIRONMENTS.include?(environment)

          environment
        end
      end

      # provider ごとの実装(読み手の接続モジュールと API 定数)と、読み手の判定・記録と照合する組。
      module Provider
        module_function

        def implementation(provider)
          provider == 'gmail_rest' ? Toybaco::Connections::Gmail : Toybaco::Connections::Microsoft
        end

        def api(provider)
          provider == 'gmail_rest' ? Toybaco::Connections::GmailApi : Toybaco::Connections::MicrosoftApi
        end

        # 開放の読み手の判定(Gmail / Microsoft の public_decision)。記録は ConnectionRelease.current が DB から直接読む。
        def decision(provider)
          implementation(provider).public_decision
        end

        # 現在の設定と実装の定数から計算した application_id と scope_digest(記録と照合する組)。
        def identity(provider)
          { 'application_id' => implementation(provider).client_id,
            'scope_digest' => Toybaco::ConnectionRelease.scope_digest(api(provider)::SCOPES) }
        end

        def identity!(provider)
          Input.environment!
          abort "#{provider} の client ID(#{CLIENT_KEYS.fetch(provider)})が未設定のため記録しません。" if implementation(provider).client_id.empty?

          identity(provider)
        end

        # 実測の記録。列挙した項目だけを true、ほかを false にする。environment と implementation_revision は現在の値。
        def smoke_record(provider, evidence, observed, passed)
          identity!(provider).merge('environment' => Input.environment!, 'implementation_revision' => api(provider)::REVISION,
                                    'evidence_ref' => evidence, 'observed_at' => observed,
                                    'checks' => CHECKS.index_with { |name| passed.include?(name) })
        end

        # 読み直しの判定が reached のどれかか、available なら合格にする。
        def reached_check(reached, available: true)
          ->(decision) { (available && decision['available'] == true) || reached.include?(decision['reason']) }
        end

        # 判定が記録を読む前の設定の不足で止まっていて、開放されていない。
        def configuration_stop?(decision)
          decision['available'] != true && CONFIGURATION_REASONS.include?(decision['reason'])
        end
      end

      # 記録の書き込みと、同じ transaction の中での読み直し。
      module Records
        module_function

        # 対象環境・provider の記録を、設定名の行をロックした 1 つの transaction の中で「最新の値の読み取り → block での書き換え →
        # 保存 → 読み手と同じ DB 直読での読み直し」の順に行う。記録は全環境・全 provider で 1 行なので、運営 rake が同時に動いても
        # 行ロックで直列になり、ほかの provider・環境の記録(緊急停止を含む)を古い値で上書きしない。
        # 保存した値が書いた値と違うか、判定が期待どおりに進まなければ abort(SystemExit)で rollback して保存しない(監査は failed)。
        # block が nil を返すと provider の記録を消す。
        def save_release!(provider, expected, check)
          environment = Input.environment!
          InstallationConfig.transaction do
            config = locked_row(CONFIG)
            records = object!(plain(config.value), CONFIG)
            scope = object!(records.fetch(environment, {}), "#{CONFIG} の #{environment}")
            record = yield object!(scope.fetch(provider, {}), "#{CONFIG} の #{environment}.#{provider}")
            record.nil? ? scope.delete(provider) : scope.store(provider, record)
            scope.empty? ? records.delete(environment) : records.store(environment, scope)
            store!(config, records)
            decision = Provider.decision(provider)
            next if check.call(decision)

            abort "#{provider} の読み直しの判定が #{expected} になりません(reason=#{decision['reason'] || 'none'})。保存しません。" \
                  "#{CONFIG} と記録の順(approval → qualification → smoke)を確認してください。"
          end
        end

        # 受領記録を書き、上書き前の状態を返す。失効(revoked)の記録は上書きしない(失効の解除は DB の記録を確かめてから行う別の作業)。
        # approval の後は qualification_pending 以降、qualification の後は connection_check_pending 以降(available を含む)へ進む。
        def record_receipt!(provider, kind, receipt)
          reached = kind == 'approval' ? %w[qualification_pending connection_check_pending] : %w[connection_check_pending]
          previous = nil
          save_release!(provider, "#{reached.join(' / ')} か available", Provider.reached_check(reached)) do |record|
            previous = receipt_state(record[kind])
            if previous == 'revoked'
              abort "#{provider} の #{kind} は失効(revoked)として記録されているため上書きしません。" \
                    '失効の扱いは DB の記録を確かめてから別に行ってください。'
            end
            record.merge(kind => receipt)
          end
          previous
        end

        # 上書きする前の受領記録の状態。記録が無ければ absent、status が approved / revoked ならその値、それ以外は non_conforming。
        def receipt_state(receipt)
          return 'absent' if receipt.nil?

          receipt.is_a?(Hash) && %w[approved revoked].include?(receipt['status']) ? receipt['status'] : 'non_conforming'
        end

        # 設定名の行を行ロック(SELECT … FOR UPDATE)付きで読む。transaction の中で呼ぶ。行が無ければ空の値で作り、別の実行が
        # 同時に作った時は unique index の違反を savepoint で受けて、相手の commit 後の行をロックして読む(create_or_find_by)。
        def locked_row(name)
          InstallationConfig.lock.find_by(name: name) ||
            InstallationConfig.create_or_find_by!(name: name) { |row| row.assign_attributes(value: {}, locked: true) }.lock!
        end

        # ロック中の行へ値を書いて保存し、同じ transaction の中で DB から読み直す。合わなければ abort で rollback する。
        # SuperAdmin の installation_configs 画面は locked: false の行を一覧・編集でき、画面で保存すると文字列に化けるため隠す。
        def store!(row, value)
          row.assign_attributes(value: value, locked: true)
          row.save!
          stored = InstallationConfig.find_by(name: row.name)
          return if stored&.locked == true && plain(stored.value) == plain(value)

          abort "#{row.name} の読み直しが書いた値と一致しないか、画面から隠れていない(locked でない)ため保存しません。" \
                'installation_configs を確認してください。'
        end

        # InstallationConfig の値(HashWithIndifferentAccess)を、JSON の値だけから成る素の Hash にする。nil は空の記録。
        def plain(value)
          return {} if value.nil?

          value.is_a?(Hash) ? JSON.parse(JSON.generate(value)) : value
        end

        def object!(value, label)
          return value if value.is_a?(Hash)

          abort "#{label} が JSON のオブジェクトではないため書き換えません。installation_configs を確認してください。"
        end
      end

      # 担当者依頼メールの登録と、依頼の有効化(TOYBACO_CONNECTION_HANDOFF_ENABLED。担当者依頼の全媒体で共通)の書き込み。
      module HandoffMail
        module_function

        # 担当者依頼メールの登録(と enable なら依頼メールの有効化)を、行をロックした transaction の中で最新の値に重ねて保存し、
        # MailGateway の登録一致判定と DB の生値、有効化は読み手(Handoff::Access.enabled?)でも読み直す。どれかが合わなければ
        # abort で rollback し、登録も有効化も保存しない。ロックは登録の行、有効化の行の順に取る(同じ順で取り合って止まらない)。
        def save!(gateway, environment, entries, enable:)
          InstallationConfig.transaction do
            mail = Records.locked_row(HANDOFF_CONFIG)
            records = Records.object!(Records.plain(mail.value), HANDOFF_CONFIG)
            records[environment] = Records.object!(records.fetch(environment, {}), "#{HANDOFF_CONFIG} の #{environment}").merge(entries)
            Records.store!(mail, records)
            Records.store!(Records.locked_row(HANDOFF_ENABLED), true) if enable
            abort "#{entries.keys.first} の担当者依頼の登録を読み直せないため保存しません。#{HANDOFF_CONFIG} を確認してください。" unless saved?(gateway, enable)
            confirm_flag!(true) if enable
          end
        ensure
          GlobalConfig.clear_cache if enable
        end

        # 依頼メールの有効化を戻す(JSON の boolean false)。登録は変えない。読み手が無効と読むまで確かめてから commit する。
        def disable!
          InstallationConfig.transaction do
            Records.store!(Records.locked_row(HANDOFF_ENABLED), false)
            confirm_flag!(false)
          end
        ensure
          GlobalConfig.clear_cache
        end

        # 依頼の読み手(Handoff::Access.enabled?)は GlobalConfig の cache を読む。transaction の中で cache を消して読み手で確かめ、
        # 合わなければ abort で rollback する。rollback の後は呼び出し側の ensure で cache を消し、未確定の値を cache に残さない。
        def confirm_flag!(expected)
          GlobalConfig.clear_cache
          return if Toybaco::Connections::Handoff::Access.enabled? == expected

          abort "#{HANDOFF_ENABLED} を#{expected ? '有効' : '無効'}にしても、読み手(GlobalConfigService)がそう読めないため保存しません。" \
                "#{HANDOFF_ENABLED} の行と cache を確認してください。"
        end

        # 登録の一致は MailGateway の判定そのもので、有効化は cache を経由しない DB の生値(JSON の boolean true)で確かめる。
        def saved?(gateway, enable)
          gateway.send(:registered_callback?) && (!enable || enabled_value.equal?(true))
        end

        def entry!(gateway, provider, environment)
          abort "#{provider} の client ID が未設定のため担当者依頼を登録しません。" if gateway.send(:implementation).client_id.empty?

          { 'application_id' => gateway.send(:implementation).client_id, 'callback_url' => callback_url!(gateway, environment),
            'implementation_revision' => gateway.send(:revision) }
        end

        # callback_url は MailGateway と同じ関数で FRONTEND_URL から作り、その origin が対象環境の origin と一致する時だけ使う。
        def callback_url!(gateway, environment)
          url = gateway.send(:callback_url)
          return url if url.start_with?("#{ORIGINS.fetch(environment)}/")

          abort "FRONTEND_URL の origin が #{environment} の #{ORIGINS.fetch(environment)} と一致しないため登録しません。"
        rescue KeyError, Toybaco::Connections::Handoff::Unavailable
          abort 'FRONTEND_URL が https://app.toybaco.jp / https://app.staging.toybaco.jp ではないため登録しません。'
        end

        # 依頼メールの有効化フラグの DB の生値(行が無ければ nil)。読み手の cache は経由しない。
        def enabled_value
          InstallationConfig.find_by(name: HANDOFF_ENABLED)&.value
        end
      end

      # 出力の行。判定の 1 行と、記録(approval / qualification / smoke / disabled)の有無を 1 行ずつ。
      module Lines
        module_function

        def state(provider)
          decision = Provider.decision(provider)
          environment = ENV.fetch('TOYBACO_DEPLOYMENT_ENVIRONMENT', nil)
          record = release_record(provider, environment)
          identity = Provider.identity(provider)
          smoke = identity.merge('environment' => environment, 'implementation_revision' => Provider.api(provider)::REVISION)
          ["TOYBACO_CONNECTION_RELEASE provider=#{provider} environment=#{ENVIRONMENTS.include?(environment) ? environment : 'unknown'} " \
           "available=#{decision['available'] == true} reason=#{decision['reason'] || 'none'}",
           *KINDS.map { |kind| receipt_line(provider, kind, record[kind], identity) },
           smoke_line(provider, record['smoke'], smoke),
           "TOYBACO_CONNECTION_RELEASE_RECORD provider=#{provider} kind=disabled value=#{Toybaco::Ops::OpsFlag.state(record['disabled'])}"]
        end

        def receipt_line(provider, kind, receipt, identity)
          head = "TOYBACO_CONNECTION_RELEASE_RECORD provider=#{provider} kind=#{kind}"
          return "#{head} recorded=false" unless receipt.is_a?(Hash)

          expires = receipt.key?('expires_at') ? time_text(receipt['expires_at']) : 'none'
          "#{head} recorded=true status=#{text(receipt['status'], /\A[a-z_]{1,32}\z/)} " \
            "evidence_ref=#{text(receipt['evidence_ref'], EVIDENCE_FORMAT)} observed_at=#{time_text(receipt['observed_at'])} " \
            "expires_at=#{expires} identity=#{matches?(receipt, identity) ? 'match' : 'mismatch'}"
        end

        def smoke_line(provider, smoke, expected)
          head = "TOYBACO_CONNECTION_RELEASE_RECORD provider=#{provider} kind=smoke"
          return "#{head} recorded=false" unless smoke.is_a?(Hash)

          missing = CHECKS.reject { |name| smoke['checks'].is_a?(Hash) && smoke['checks'][name] == true }
          "#{head} recorded=true evidence_ref=#{text(smoke['evidence_ref'], EVIDENCE_FORMAT)} " \
            "observed_at=#{time_text(smoke['observed_at'])} checks=#{CHECKS.size - missing.size}/#{CHECKS.size} " \
            "missing=#{missing.empty? ? '-' : missing.join('.')} identity=#{matches?(smoke, expected) ? 'match' : 'mismatch'}"
        end

        def release_record(provider, environment)
          records = Records.plain(InstallationConfig.find_by(name: CONFIG)&.value)
          record = records.is_a?(Hash) && records[environment].is_a?(Hash) ? records[environment][provider] : nil
          record.is_a?(Hash) ? record : {}
        end

        # 記録の時刻は ISO 8601 として読めれば UTC に揃えて出し、読めなければ中身を出さず invalid にする。
        def time_text(value)
          Time.iso8601(value.to_s).utc.iso8601
        rescue ArgumentError
          'invalid'
        end

        # 形に合う文字列だけを出し、それ以外(手で書かれた任意の値)は中身も長さも出さない。
        def text(value, format)
          value.is_a?(String) && value.match?(format) ? value : 'non_conforming'
        end

        def matches?(value, expected)
          expected.all? { |key, item| value[key] == item }
        end
      end

      module_function

      # toybaco:connection_release_show[provider]。読み手の判定と、記録の有無。
      def show(args)
        provider = Input.provider!(args[:provider])
        Input.extras!(args, 'provider の 1 つ')
        Lines.state(provider)
      end

      # toybaco:connection_release_approve[provider,kind,evidence_ref,observed_at,expires_at]。
      def approve(args)
        provider = Input.provider!(args[:provider])
        kind = Input.choice!(args[:kind], KINDS, "kind は #{KINDS.join(' / ')} のいずれかを指定してください。")
        receipt = Input.receipt!(args, kind)
        Input.extras!(args, 'provider,kind,evidence_ref,observed_at,expires_at の 5 つ')
        receipt = Provider.identity!(provider).merge(receipt)
        previous = Records.record_receipt!(provider, kind, receipt)
        ["TOYBACO_CONNECTION_RELEASE_APPROVE provider=#{provider} environment=#{Input.environment!} kind=#{kind} previous=#{previous} " \
         "evidence_ref=#{receipt['evidence_ref']} observed_at=#{receipt['observed_at']} expires_at=#{receipt.fetch('expires_at', 'none')}",
         *Lines.state(provider)]
      end

      # toybaco:connection_release_smoke[provider,evidence_ref,observed_at,checks]。checks は実測で合格した項目名を . で区切る。
      # 列挙した項目だけを true、ほかを false で書く。全項目が true の時だけ判定が available になる。
      def smoke(args)
        provider = Input.provider!(args[:provider])
        evidence = Input.evidence!(args[:evidence_ref])
        observed = Input.observed!(args[:observed_at])
        passed = Input.checks!(args[:checks])
        Input.extras!(args, 'provider,evidence_ref,observed_at,checks の 4 つ')
        record = Provider.smoke_record(provider, evidence, observed, passed)
        complete = passed.size == CHECKS.size
        check = Provider.reached_check(complete ? [] : %w[connection_check_pending], available: complete)
        Records.save_release!(provider, complete ? 'available' : 'connection_check_pending', check) { |current| current.merge('smoke' => record) }
        ["TOYBACO_CONNECTION_RELEASE_SMOKE provider=#{provider} environment=#{Input.environment!} evidence_ref=#{evidence} " \
         "observed_at=#{observed} checks=#{passed.size}/#{CHECKS.size}", *Lines.state(provider)]
      end

      # toybaco:connection_release_disable[provider,on|off]。on は緊急停止(disabled: true)、off は解除(disabled: false)。
      # 設定の不足(client ID 未設定など)で判定が記録より前に止まる時も、停止は開放されていないことを確かめて書く。
      def disable(args)
        provider = Input.provider!(args[:provider])
        disabled = Input.choice!(args[:state], %w[on off], '2 つ目の引数は on(停止)か off(解除)を指定してください。') == 'on'
        Input.extras!(args, 'provider,on|off の 2 つ')
        check = lambda do |decision|
          disabled ? decision['reason'] == 'disabled' || Provider.configuration_stop?(decision) : decision['reason'] != 'disabled'
        end
        previous = nil
        Records.save_release!(provider, disabled ? 'disabled' : 'disabled 以外', check) do |record|
          previous = record['disabled']
          record.merge('disabled' => disabled)
        end
        ["TOYBACO_CONNECTION_RELEASE_DISABLE provider=#{provider} environment=#{Input.environment!} disabled=#{disabled} " \
         "previous=#{Toybaco::Ops::OpsFlag.state(previous)}", *Lines.state(provider)]
      end

      # toybaco:connection_release_clear[provider]。staging の fixture の後片付け専用。production の証跡は消さない(停止は disable)。
      def clear(args)
        provider = Input.provider!(args[:provider])
        Input.extras!(args, 'provider の 1 つ')
        abort 'clear は staging 専用です。production の記録は消さず、停止は disable で行ってください。' unless Input.staging?

        previous = nil
        Records.save_release!(provider, '開放されていない状態', ->(decision) { decision['available'] != true }) do |record|
          previous = record.empty? ? 'absent' : 'present'
          nil
        end
        ["TOYBACO_CONNECTION_RELEASE_CLEAR provider=#{provider} environment=staging previous=#{previous}", *Lines.state(provider)]
      end

      # toybaco:connection_handoff_mail[provider,enable|keep|disable]。provider は MailGateway のキー(gmail / microsoft)。
      # 担当者依頼メールの登録(application_id・callback_url・implementation_revision)を書き、enable なら依頼メールも有効にする。
      # disable は有効化だけを戻す(登録は変えない)。有効化(TOYBACO_CONNECTION_HANDOFF_ENABLED)は担当者依頼の全媒体で共通。
      def handoff_mail(args)
        provider = Input.choice!(args[:provider], HANDOFF_PROVIDERS, "provider は #{HANDOFF_PROVIDERS.join(' / ')} のいずれかを指定してください。")
        mode = Input.choice!(args[:mode], HANDOFF_MODES, '2 つ目の引数は enable(依頼メールも有効にする)・keep(有効・無効を変えない)・' \
                                                         'disable(有効化だけを戻す)のいずれかを指定してください。')
        Input.extras!(args, 'provider,enable|keep|disable の 2 つ')
        return handoff_disable(provider) if mode == 'disable'

        environment = Input.environment!
        gateway = Toybaco::Connections::Handoff::MailGateway.new(provider)
        entry = HandoffMail.entry!(gateway, provider, environment)
        HandoffMail.save!(gateway, environment, { provider => entry }, enable: mode == 'enable')
        ["TOYBACO_CONNECTION_HANDOFF_MAIL provider=#{provider} environment=#{environment} registered=true " \
         "callback_url=#{entry['callback_url']} implementation_revision=#{entry['implementation_revision']} " \
         "enabled=#{Toybaco::Ops::OpsFlag.state(HandoffMail.enabled_value)}"]
      end

      def handoff_disable(provider)
        HandoffMail.disable!
        environment = ENV.fetch('TOYBACO_DEPLOYMENT_ENVIRONMENT', nil)
        ["TOYBACO_CONNECTION_HANDOFF_MAIL provider=#{provider} environment=#{ENVIRONMENTS.include?(environment) ? environment : 'unknown'} " \
         "action=disable enabled=#{Toybaco::Ops::OpsFlag.state(HandoffMail.enabled_value)}"]
      end
    end
  end
end
