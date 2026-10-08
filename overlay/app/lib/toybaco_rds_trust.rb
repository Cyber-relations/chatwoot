# frozen_string_literal: true

require 'digest'
require 'openssl'

# Reviewed public RDS roots, separate from general HTTPS/system trust. Each
# client still needs explicit TLS configuration and live acceptance.
module ToybacoRdsTrust
  BUNDLE_SHA256 = 'd1df75221341812a657d7c7b070ff61ce78824fbf05acf499f7e394f5ff58d50'
  ROOT_SHA256 = %w[
    dc4bd074909909f9e5288408f2a148261aa506711307ae0a6561df152e07e04c
    1cb5dcfb2e4db29fdb966e31c5da9f620bf06a10f5880205131a0e6a5bdf80d7
    08544470dfa4c9dc25c481a8908d2958f90b9c1d23f275696f341d71f2f1539e
  ].freeze
  DEFAULT_PATH = File.expand_path('../config/rds-ca/ap-northeast-1-bundle.pem', __dir__)

  def self.verify!(path = DEFAULT_PATH, at: Time.now.utc)
    verify_path!(path)
    bytes = File.binread(path)
    raise 'RDS trust bundle checksum mismatch' unless Digest::SHA256.hexdigest(bytes) == BUNDLE_SHA256

    roots = bytes.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m).map do |pem|
      OpenSSL::X509::Certificate.new(pem)
    end
    raise 'RDS trust root fingerprint mismatch' unless roots.map { |root| Digest::SHA256.hexdigest(root.to_der) } == ROOT_SHA256

    roots.each { |root| verify_root!(root, at) }
    { bundle_sha256: BUNDLE_SHA256, roots: roots.length }
  end

  def self.verify_path!(path)
    raise 'RDS trust bundle must be a regular non-symlink path' unless
      File.file?(path) && File.realpath(path) == File.expand_path(path)
    raise 'RDS trust bundle must not be group/world writable' unless File.stat(path).mode.nobits?(0o022)
  end

  def self.verify_root!(root, at)
    raise 'RDS trust requires self-signed CA roots' unless self_signed_ca?(root)
    raise 'RDS trust root outside validity period' unless root.not_before <= at && at < root.not_after
  end

  def self.self_signed_ca?(root)
    ca = root.extensions.any? { |extension| extension.oid == 'basicConstraints' && extension.value.include?('CA:TRUE') }
    root.subject == root.issuer && root.verify(root.public_key) && ca
  end
end
