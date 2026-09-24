# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'

class ToybacoDurableAcceptanceLoadingTest < Minitest::Test
  def test_migration_require_then_eager_load
    assert_loads('migration_first')
  end

  def test_fresh_eager_load
    assert_loads('eager_first')
  end

  private

  def assert_loads(order)
    source = ENV.fetch('TOYBACO_DURABLE_LIBRARY', '/app/lib/toybaco')
    Dir.mktmpdir('toybaco-durable-loading-') do |directory|
      directory = File.realpath(directory)
      FileUtils.mkdir_p(File.join(directory, 'toybaco'))
      %w[durable_acceptance durable_acceptance_definition durable_acceptance_catalog durable_acceptance_expansion].each do |name|
        FileUtils.cp(File.join(source, "#{name}.rb"), File.join(directory, 'toybaco', "#{name}.rb"))
      end
      output, status = Open3.capture2e(RbConfig.ruby, '-rzeitwerk', '-e', <<~RUBY, directory, order)
        loader = Zeitwerk::Loader.new
        loader.push_dir(ARGV.fetch(0))
        loader.setup
        require File.join(ARGV.fetch(0), 'toybaco/durable_acceptance') if ARGV.fetch(1) == 'migration_first'
        loader.eager_load
        abort 'expansion constant missing' unless Toybaco::DurableAcceptanceExpansion.is_a?(Module)
        %w[renewal-ingress-v1 posting-renewal-v1 posting-paid-upgrade-v1 renewal-settlement-v1 scheduled-downgrade-grace-v1 renewal-provider-settlement-v1 scheduled-grant-upgrade-v1 renewal-dispatch-v1].each do |capability|
          statements = []
          Toybaco::DurableAcceptance.add_capability(capability) { |sql| statements << sql }
          abort 'migration helper missing' unless statements.any? { |sql| sql.include?('CREATE TRIGGER') }
        end
        puts 'PASS'
      RUBY
      assert status.success?, output
      assert_equal "PASS\n", output
    end
  end
end
