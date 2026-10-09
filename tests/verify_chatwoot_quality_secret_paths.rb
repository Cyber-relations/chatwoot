# frozen_string_literal: true

require 'digest'
require 'find'
require 'openssl'

# The only reviewed public certificate file in the quality snapshot. This
# independent pin does not rely on the product verifier accepting its own input.
module QualitySecretPaths
  PUBLIC_ROOT_PATH = 'overlay/app/config/rds-ca/ap-northeast-1-bundle.pem'
  PUBLIC_ROOT_SHA256 = 'd1df75221341812a657d7c7b070ff61ce78824fbf05acf499f7e394f5ff58d50'
  DENIED_NAME = /\A(?:\.env(?:\..*)?|.*\.(?:pem|key)|id_rsa|.*credential.*)\z/i

  def self.verify!(directory)
    directory = File.realpath(directory)
    Find.find(directory) do |path|
      next if File.directory?(path) && !File.symlink?(path)
      next unless File.basename(path).match?(DENIED_NAME)

      relative_path = path.delete_prefix("#{directory}/")
      raise 'secret-like file name is not permitted' unless relative_path == PUBLIC_ROOT_PATH

      verify_public_root!(path)
    end
    true
  end

  def self.verify_public_root!(path)
    raise 'public root must be a regular non-symlink path' unless
      File.file?(path) && File.realpath(path) == File.expand_path(path)
    raise 'public root must not be group/world writable' unless (File.stat(path).mode & 0o022).zero?

    bytes = File.binread(path)
    raise 'public root checksum mismatch' unless Digest::SHA256.hexdigest(bytes) == PUBLIC_ROOT_SHA256

    roots = bytes.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m).map do |pem|
      OpenSSL::X509::Certificate.new(pem)
    end
    raise 'public root certificate count mismatch' unless roots.length == 3

    roots.each do |root|
      ca = root.extensions.any? { |extension| extension.oid == 'basicConstraints' && extension.value.include?('CA:TRUE') }
      raise 'public root must be a self-signed CA' unless root.subject == root.issuer && root.verify(root.public_key) && ca
    end
  end
end

if $PROGRAM_NAME == __FILE__
  QualitySecretPaths.verify!(ARGV.fetch(0))
  puts 'TOYBACO_QUALITY_SECRET_PATHS=PASS'
end
