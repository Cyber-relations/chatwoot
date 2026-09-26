# frozen_string_literal: true

require_relative 'connection_handoff_sessions_controller'
require_relative '../../../lib/toybaco/connections/handoff/line_presentation'

class Toybaco::ConnectionHandoffLineController < Toybaco::ConnectionHandoffSessionsController
  rescue_from Toybaco::Connections::LineSetupApi::Error, ActiveRecord::ActiveRecordError, with: :line_unavailable
  rescue_from Toybaco::Connections::Handoff::LineSetup::LimitReached, with: :inbox_limit

  def show
    @record.account.with_lock do
      @record.with_lock do
        Handoff::Access.receipt!(@record, required_nonce)
        render json: Handoff::Presentation.recipient(@record).merge(Handoff::LinePresentation.read(@record))
      end
    end
  end

  def create
    input = params.require(:fields)
    raise Handoff::Invalid unless input.is_a?(ActionController::Parameters) && input.keys.sort == Handoff::LineSetup::FIELDS

    Handoff::LineSetup.new(@record).save!(browser_nonce: required_nonce, fields: input.permit(*Handoff::LineSetup::FIELDS).to_h)
    render json: Handoff::Presentation.recipient(@record.reload).merge(Handoff::LinePresentation.read(@record))
  rescue ActionController::ParameterMissing
    line_unavailable
  end

  private

  def inbox_limit(error)
    limits = Toybaco::Connections::InboxLimit
    render json: { error: limits.notice(error.limit, error.count, free: limits.free_plan?(@record.account)) }, status: :conflict
  end

  def line_unavailable(_error = nil)
    render json: { error: '設定を保存できませんでした。チャネルIDと長期のアクセストークンを確認してください。' }, status: :unprocessable_entity
  end
end
