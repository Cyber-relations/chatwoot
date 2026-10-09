# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../overlay/app/lib/toybaco_rds_trust'

class RdsTrustTest < Minitest::Test
  def setup
    @directory = File.realpath(Dir.mktmpdir('rds-public-trust-'))
    @path = File.join(@directory, 'roots.pem')
    @bytes = File.binread(ToybacoRdsTrust::DEFAULT_PATH)
    File.write(@path, @bytes, mode: 'wb', perm: 0o644)
    @at = Time.utc(2026, 10, 9)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def verify(path = @path, at: @at)
    ToybacoRdsTrust.verify!(path, at: at)
  end

  def test_reviewed_three_root_bundle_is_accepted
    assert_equal 3, verify.fetch(:roots)
    assert_equal ToybacoRdsTrust::BUNDLE_SHA256, verify.fetch(:bundle_sha256)
  end

  def test_missing_bundle_is_rejected
    assert_raises(RuntimeError) { verify(File.join(@directory, 'missing.pem')) }
  end

  def test_symlink_and_symlink_parent_are_rejected
    link = File.join(@directory, 'link.pem')
    File.symlink(@path, link)
    assert_raises(RuntimeError) { verify(link) }
    parent = File.join(@directory, 'parent')
    File.symlink(@directory, parent)
    assert_raises(RuntimeError) { verify(File.join(parent, 'roots.pem')) }
  end

  def test_mutated_and_appended_bytes_are_rejected
    [@bytes.sub('CERTIFICATE', 'CERTIFICATX'), "#{@bytes}\n"].each do |bytes|
      File.binwrite(@path, bytes)
      assert_raises(RuntimeError) { verify }
    end
  end

  def test_missing_duplicated_and_reordered_roots_are_rejected
    roots = @bytes.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
    [roots.take(2), roots + [roots.first], roots.reverse].each do |entries|
      File.binwrite(@path, "#{entries.join("\n")}\n")
      assert_raises(RuntimeError) { verify }
    end
  end

  def test_group_or_world_writable_bundle_is_rejected
    [0o664, 0o646].each do |mode|
      File.chmod(mode, @path)
      assert_raises(RuntimeError) { verify }
    end
  end

  def test_not_yet_valid_or_expired_roots_are_rejected
    [Time.utc(2020, 1, 1), Time.utc(2062, 1, 1)].each do |at|
      assert_raises(RuntimeError) { verify(at: at) }
    end
  end
end
