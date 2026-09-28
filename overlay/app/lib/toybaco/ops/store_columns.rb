# frozen_string_literal: true

require 'csv'

# 店舗一覧(S1-2)の列。画面(HTML)と CSV は同じ見出し・同じ値を出す。値は利用者名・メールアドレス・電話番号を含まない。
# 時刻は日本時間。CSV のセルが数式として解釈されうる文字(= + - @ | タブ CR LF)で始まる時は先頭に ' を付ける。
# 先頭の空白類(半角空白・タブ・NBSP・全角空白)を除いた最初の文字も同じく見る。
module Toybaco::Ops::StoreColumns
  HEADERS = ['店舗ID', '店舗名', '要確認', 'プラン', '契約版', '周期', 'Stripe 状態', '契約の状態', '担当者数', '担当者上限',
             '受信箱数', '受信箱内訳', '投稿', '投稿権限', 'AI', 'AI 使用', 'AI 上限', 'AI 残り', '最終活動', '開通日'].freeze
  ATTENTION_COLUMN = HEADERS.index('要確認')
  NONE = '—'
  ZONE = 'Asia/Tokyo'
  FORMULA_PREFIXES = ['=', '+', '-', '@', '|', "\t", "\r", "\n"].freeze
  LEADING_SPACE = /\A[ \t\u00A0\u3000]+/
  STATE_LABELS = [[:cancel_scheduled, '解約予約'], [:payment_pending, '支払保留'], [:billing_review, '請求確認中'],
                  [:suspended, '停止'], [:syncing, '照合中'], [:sync_attention, '照合要確認']].freeze
  AI_LABELS = { enabled: '有効', disabled: '無効', unissued: '未発行', invalid: '契約不正', review: '要確認' }.freeze

  module_function

  # 1 店舗分の値(文字列、HEADERS と同じ順)。
  def values(row)
    [row.id.to_s, row.name.to_s, row.attention_reasons.join('・'), *contract(row), *usage(row), *ai(row.ai),
     time(row.last_activity_at, '%Y-%m-%d %H:%M'), time(row.opened_at, '%Y-%m-%d')]
  end

  def contract(row)
    [row.plan, text(row.plan_version), text(row.cycle), text(row.subscription_status), states(row)]
  end

  def usage(row)
    [row.agents.to_s, text(row.agent_limit), row.inbox_total.to_s, inboxes(row), row.posting_enabled ? '有効' : '無効',
     text(row.posting_authority)]
  end

  # UTF-8 の BOM 付き(表計算ソフトで文字化けさせない)。行区切りは CRLF。
  def csv(rows)
    body = CSV.generate(row_sep: "\r\n", quote_empty: false) do |csv|
      csv << HEADERS
      rows.each { |row| csv << values(row).map { |value| safe(value.to_s) } }
    end
    "\uFEFF#{body}"
  end

  def safe(value)
    formula?(value) ? "'#{value}" : value
  end

  def formula?(value)
    value.start_with?(*FORMULA_PREFIXES) || value.sub(LEADING_SPACE, '').start_with?(*FORMULA_PREFIXES)
  end

  def text(value)
    value.nil? || value == '' ? NONE : value.to_s
  end

  def states(row)
    labels = STATE_LABELS.filter_map { |key, label| label if row.public_send(key) }
    labels.empty? ? NONE : labels.join('・')
  end

  def inboxes(row)
    row.inboxes.empty? ? NONE : row.inboxes.map { |label, count| "#{label} #{count}" }.join('・')
  end

  def ai(usage)
    numbers = [usage.used, usage.limit, usage.remaining].map { |value| text(value) }
    [AI_LABELS.fetch(usage.state), *numbers]
  end

  def time(value, format)
    value ? value.in_time_zone(ZONE).strftime(format) : NONE
  end
end
