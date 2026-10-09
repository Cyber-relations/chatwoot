# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative 'verify_chatwoot_quality_secret_paths'

class QualitySecretPathsTest < Minitest::Test
  def setup
    @directory = File.realpath(Dir.mktmpdir('quality-public-root-'))
    @path = File.join(@directory, QualitySecretPaths::PUBLIC_ROOT_PATH)
    FileUtils.mkdir_p(File.dirname(@path))
    @bytes = File.binread(File.expand_path("../#{QualitySecretPaths::PUBLIC_ROOT_PATH}", __dir__))
    File.write(@path, @bytes, mode: 'wb', perm: 0o644)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def verify
    QualitySecretPaths.verify!(@directory)
  end

  def test_only_the_reviewed_public_root_is_accepted
    assert verify
  end

  def test_all_other_secret_like_names_remain_denied
    %w[other.pem other.key id_rsa .env .env.local credentials.json ROOT.PEM].each do |name|
      path = File.join(@directory, name)
      File.binwrite(path, @bytes)
      assert_raises(RuntimeError) { verify }
      File.unlink(path)
    end
  end

  def test_same_name_in_another_directory_remains_denied
    File.binwrite(File.join(@directory, File.basename(@path)), @bytes)
    assert_raises(RuntimeError) { verify }
  end

  def test_changed_or_appended_public_root_is_denied
    [@bytes.sub('CERTIFICATE', 'CERTIFICATX'), "#{@bytes}\n"].each do |bytes|
      File.binwrite(@path, bytes)
      assert_raises(RuntimeError) { verify }
    end
  end

  def test_private_key_at_the_allowed_path_is_denied
    File.binwrite(@path, ['-----BEGIN ', 'PRIVATE KEY-----\nsynthetic\n'].join)
    assert_raises(RuntimeError) { verify }
  end

  def test_symlink_at_allowed_path_is_denied
    alternate = File.join(@directory, 'roots.txt')
    File.binwrite(alternate, @bytes)
    File.unlink(@path)
    File.symlink(alternate, @path)
    assert_raises(RuntimeError) { verify }
  end

  def test_group_or_world_writable_roots_are_denied
    [0o664, 0o646].each do |mode|
      File.chmod(mode, @path)
      assert_raises(RuntimeError) { verify }
    end
  end

  def test_safe_nonsecret_files_remain_accepted
    File.binwrite(File.join(@directory, 'configuration.json'), '{}')
    assert verify
  end
end
