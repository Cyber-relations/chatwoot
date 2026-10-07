# frozen_string_literal: true

require 'rails_helper'

# super_admin の設定更新(installation_config[value])の秘密の値がログに平文で残らないことを確かめる。
RSpec.describe ActiveSupport::ParameterFilter do # rubocop:disable RSpec/SpecFilePathFormat
  it 'アプリの filter_parameters は installation_config の値を [FILTERED] にし、設定名は残す' do
    filter = described_class.new(Rails.application.config.filter_parameters)
    filtered = filter.filter('installation_config' => { 'name' => 'HCAPTCHA_SERVER_KEY', 'value' => 'secret-value' })

    expect(filtered.dig('installation_config', 'value')).to eq('[FILTERED]')
    expect(filtered.dig('installation_config', 'name')).to eq('HCAPTCHA_SERVER_KEY')
  end
end
