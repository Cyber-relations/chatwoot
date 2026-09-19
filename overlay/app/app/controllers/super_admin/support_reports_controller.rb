# frozen_string_literal: true

require_relative '../../../lib/toybaco/support/reports'

class SuperAdmin::SupportReportsController < SuperAdmin::ApplicationController
  before_action :require_support_owner
  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }

  def index
    cursor = params[:before].presence
    return head :bad_request if cursor && !cursor.to_s.match?(/\A[1-9]\d{0,17}\z/)

    scope = cursor ? report_scope.where('id < ?', cursor.to_i) : report_scope
    rows = scope.order(id: :desc).limit(101).to_a
    @reports = rows.first(100)
    @next_cursor = @reports.last.id if rows.length > 100
  end

  def update
    record = report_scope.find(params[:id])
    record.with_lock do
      return head :forbidden unless Toybaco::Support::Reports.owner(record.category)&.id == current_super_admin.id

      case params[:state]
      when 'reviewing'
        return head :conflict unless record.state == 'received'

        record.update!(state: 'reviewing', assignee_id: current_super_admin.id)
      when 'resolved'
        return head :conflict if record.state == 'resolved'

        resolve_report(record)
      else
        return head :unprocessable_entity
      end
    end
    redirect_to '/super_admin/toybaco_support'
  end

  private

  def resolve_report(record)
    resolution = { 'product' => 'fixed', 'billing' => 'billing_checked', 'identity' => 'identity_checked', 'security' => 'security_checked' }
    record.update!(state: 'resolved', resolution: resolution.fetch(record.category), assignee_id: current_super_admin.id)
  end

  def require_support_owner
    @categories = Toybaco::Support::Reports::CATEGORIES.keys.select do |category|
      Toybaco::Support::Reports.owner(category)&.id == current_super_admin.id
    end
    head :forbidden if @categories.empty?
  end

  def report_scope
    Toybaco::SupportReport.where(category: @categories).where('expires_at > ?', Time.now.utc)
  end
end
