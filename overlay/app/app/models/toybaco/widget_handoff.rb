# frozen_string_literal: true

class Toybaco::WidgetHandoff < ApplicationRecord
  self.table_name = 'toybaco_widget_handoffs'
  belongs_to :widget_session_record, class_name: 'Toybaco::WidgetSessionRecord'
end
