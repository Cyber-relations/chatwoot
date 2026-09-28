# frozen_string_literal: true

require_relative '../../../lib/toybaco/ops/console'
require_relative '../../../lib/toybaco/ops/store_index'
require_relative '../../../lib/toybaco/ops/store_columns'

# 運営の店舗一覧(S1-2)。サインイン済みの SuperAdmin 全員が読める(未サインインは SuperAdmin 共通の before_action が
# サインイン画面へ送る)。DB flag が無効の間は 404。読み取り専用で、店舗名や数値をログに出さない。
# 契約・利用状況を含むので、HTML と CSV のどちらもブラウザ・中継のキャッシュに残さない(Cache-Control: private, no-store)。
# HTML と CSV 以外の形式(.json など)は 404。
class SuperAdmin::ToybacoStoresController < SuperAdmin::ApplicationController
  before_action :require_ops_console
  rescue_from Toybaco::Ops::StoreIndex::Invalid, with: -> { head :bad_request }

  def index
    @index = Toybaco::Ops::StoreIndex.new(plan: params[:plan], state: params[:state], sort: params[:sort], page: params[:page])
    response.cache_control.merge!(private: true, no_store: true)
    respond_to do |format|
      format.html
      format.csv { send_stores_csv }
      format.any { head :not_found }
    end
  end

  private

  def require_ops_console
    head :not_found unless Toybaco::Ops::Console.enabled?
  end

  def send_stores_csv
    date = Time.now.utc.in_time_zone('Asia/Tokyo').strftime('%Y%m%d')
    response.headers['Content-Disposition'] = %(attachment; filename="toybaco-stores-#{date}.csv")
    send_data Toybaco::Ops::StoreColumns.csv(@index.rows), type: 'text/csv; charset=utf-8', disposition: nil
  end
end
