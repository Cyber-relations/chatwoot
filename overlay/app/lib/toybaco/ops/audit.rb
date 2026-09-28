# frozen_string_literal: true

require 'digest'
require 'json'

# 運営操作の監査ログ(toybaco_operator_actions)の書き込み口(S1-1)。
# - 引数(params)は canonical JSON(ネストしたキーも並べ替えた JSON.generate)の SHA-256 だけを保存し、生値は残さない。
# - 例外を握りつぶさない。監査を書けない操作は失敗させる(fail-closed)。
# - record! は呼び出し元の接続・トランザクションで書く(操作と監査行が同じトランザクションで確定する)。
# - record_isolated! と around は、呼び出し元とは別の DB セッションで 1 行ずつ確定させる(呼び出し元がロールバックしても残る)。
#   Rails 7.2 の connection_pool.with_connection は同じ thread がすでに持つ接続を返し、transactional test では
#   checkout も固定の接続を返すため、pool の外で接続を開き(db_config.new_connection)、書いたら必ず閉じる。
module Toybaco::Ops::Audit
  TABLE = 'toybaco_operator_actions'
  COLUMNS = %w[actor_kind actor_id action target_type target_id params_digest result source].freeze
  JST = '+09:00'
  # Rails が振る request_id(UUID)。X-Request-Id は利用者が任意の値を渡せるため、UUID の形でなければ source に使わない
  # (英数字を残すだけでは氏名・電話番号などの識別子が入り得る)。
  REQUEST_ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  module_function

  # キーワード引数は監査行の列に 1 対 1 で対応させる(target は AR レコード、params は digest にする Hash / Array)。
  def record!(actor_kind:, actor_id:, action:, result:, target: nil, params: nil, source: nil) # rubocop:disable Metrics/ParameterLists
    context = { actor_kind: actor_kind, actor_id: actor_id, action: action, target: target, params: params, source: source }
    Toybaco::OperatorAction.create!(attributes(context).merge(result: result))
  end

  def record_isolated!(actor_kind:, actor_id:, action:, result:, target: nil, params: nil, source: nil) # rubocop:disable Metrics/ParameterLists
    context = { actor_kind: actor_kind, actor_id: actor_id, action: action, target: target, params: params, source: source }
    insert_isolated!(attributes(context).merge(result: result))
  end

  # ブロックの前に started、成功で ok、例外で failed を 1 行ずつ書き、例外は再送出する。3 行とも呼び出し元とは別の DB セッション。
  # rake の exit 0(SystemExit の成功)は ok とし、abort など失敗の終了は failed とする。
  def around(actor_kind:, actor_id:, action:, target: nil, params: nil, source: nil) # rubocop:disable Metrics/ParameterLists
    base = attributes({ actor_kind: actor_kind, actor_id: actor_id, action: action, target: target, params: params, source: source })
    insert_isolated!(base.merge(result: 'started'))
    failure = nil
    begin
      yield
    rescue Exception => e # rubocop:disable Lint/RescueException
      failure = e unless e.is_a?(SystemExit) && e.success?
      raise
    ensure
      insert_isolated!(base.merge(result: failure ? 'failed' : 'ok'))
    end
  end

  # 行が別セッション(pool の外の接続)から見えるか。呼び出し元のトランザクションが commit 済みかを確かめる。
  def committed?(id)
    with_isolated_connection do |connection|
      connection.select_value("SELECT 1 FROM #{TABLE} WHERE id = #{Integer(id)}").present?
    end
  end

  def web_source(request)
    request_id = request.request_id.to_s
    request_id.match?(REQUEST_ID) ? request_id : nil
  end

  def params_digest(params)
    return if params.nil?
    raise ArgumentError, 'params は Hash か Array で渡してください' unless params.is_a?(Hash) || params.is_a?(Array)

    Digest::SHA256.hexdigest(JSON.generate(canonical(params)))
  end

  # toybaco:audit_tail の 1 行。固定順の key=value で、空白・制御文字は _、値が無ければ - にする。
  def tail_line(row)
    target = row.target_type && "#{row.target_type}##{row.target_id}"
    fields = [['id', row.id], ['created_at', row.created_at.getlocal(JST).iso8601], ['actor_kind', row.actor_kind],
              ['actor_id', row.actor_id], ['action', row.action], ['target', target], ['result', row.result],
              ['source', row.source], ['params_digest', row.params_digest]]
    fields.map { |key, value| "#{key}=#{tail_value(value)}" }.join(' ')
  end

  def attributes(context)
    target = context.fetch(:target)
    { actor_kind: context.fetch(:actor_kind), actor_id: context.fetch(:actor_id), action: context.fetch(:action),
      target_type: target&.class&.name, target_id: target&.id, params_digest: params_digest(context.fetch(:params)),
      source: context.fetch(:source) }
  end

  def insert_isolated!(values)
    row = Toybaco::OperatorAction.new(values)
    row.validate!
    with_isolated_connection do |connection|
      quoted = COLUMNS.map { |column| connection.quote(row[column]) }
      connection.execute("INSERT INTO #{TABLE} (#{COLUMNS.join(', ')}) VALUES (#{quoted.join(', ')})")
    end
    nil
  end

  # 呼び出し元とは別の DB セッション。pool の外で開き、使い終わったら必ず閉じる。切断の失敗は握り、
  # INSERT などの本来の結果と例外だけを呼び出し元へ返す(二次例外で元の例外を消さない)。
  def with_isolated_connection
    connection = Toybaco::OperatorAction.connection_db_config.new_connection
    yield connection
  ensure
    begin
      connection&.disconnect!
    rescue StandardError
      nil # 切断できなくても接続は GC で閉じる。監査の成否は INSERT の結果で決まる。
    end
  end

  def canonical(value)
    case value
    when Hash then value.map { |key, item| [key.to_s, canonical(item)] }.sort_by(&:first).to_h
    when Array then value.map { |item| canonical(item) }
    when String, Integer, Float, true, false, nil then value
    else value.to_s
    end
  end

  def tail_value(value)
    text = value.to_s.gsub(/[^[:graph:]]/, '_')
    text.empty? ? '-' : text
  end

  private_class_method :attributes, :insert_isolated!, :with_isolated_connection, :canonical, :tail_value
end
