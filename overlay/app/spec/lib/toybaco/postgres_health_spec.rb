# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::PostgresHealth do
  def stale_connection(verify_reopens: true, reconnect_reopens: true, verify_error: nil)
    alive = false
    connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter)
    allow(connection).to receive(:active?) { alive }
    allow(connection).to receive(:verify!) do
      raise verify_error if verify_error

      alive = true if verify_reopens
    end
    allow(connection).to receive(:reconnect!) { alive = true if reconnect_reopens }
    connection
  end

  describe '.verify_or_reconnect!' do
    it 'active? が false でも verify! で張り直して通す' do
      connection = stale_connection(verify_reopens: true)

      expect(described_class.verify_or_reconnect!(connection)).to be(true)
      expect(connection).to have_received(:verify!)
      expect(connection).not_to have_received(:reconnect!)
    end

    it 'verify! 後も死んでいれば同じ接続を reconnect! する' do
      connection = stale_connection(verify_reopens: false, reconnect_reopens: true)

      expect(described_class.verify_or_reconnect!(connection)).to be(true)
      expect(connection).to have_received(:verify!)
      expect(connection).to have_received(:reconnect!)
    end

    it '張り直せなければ ConnectionNotEstablished で fail-closed する' do
      connection = stale_connection(verify_reopens: false, reconnect_reopens: false)

      expect { described_class.verify_or_reconnect!(connection) }
        .to raise_error(ActiveRecord::ConnectionNotEstablished)
    end
  end

  describe 'ApiControllerOverride#postgres_status' do
    let(:controller) do
      Class.new do
        def postgres_status
          raise 'upstream active? path should not run'
        end
        prepend Toybaco::PostgresHealth::ApiControllerOverride
      end.new
    end

    it '張り直せる stale 接続は ok にする' do
      allow(described_class).to receive(:verify_or_reconnect!).and_return(true)

      expect(controller.send(:postgres_status)).to eq('ok')
    end

    it '張り直せない接続は failing のままにする' do
      allow(described_class).to receive(:verify_or_reconnect!)
        .and_raise(ActiveRecord::ConnectionNotEstablished)

      expect(controller.send(:postgres_status)).to eq('failing')
    end
  end

  describe '.install!' do
    it 'ApiController の postgres_status に張り直しを一度だけ載せる' do
      described_class.install!
      described_class.install!

      expect(ApiController < Toybaco::PostgresHealth::ApiControllerOverride).to be(true)
      expect(ApiController.ancestors.count { |mod| mod == Toybaco::PostgresHealth::ApiControllerOverride }).to eq(1)
    end
  end
end
