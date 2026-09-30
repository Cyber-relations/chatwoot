# frozen_string_literal: true

require 'find'

action, *arguments = ARGV
abort 'usage: verify_chatwoot_auth_cookie.rb source AUTH_SOURCE POST_ENTRY | production ROOT' unless
  %w[source production].include?(action)

def regular_file!(path)
  abort "auth-cookie contract path is a symlink: #{path}" if File.symlink?(path)
  abort "auth-cookie contract path is not a regular file: #{path}" unless File.file?(path)

  File.binread(path)
end

if action == 'source'
  auth_source_path, post_entry_path = arguments
  abort 'source action requires AUTH_SOURCE and POST_ENTRY' unless auth_source_path && post_entry_path

  auth_source = regular_file!(auth_source_path)
  post_entry = regular_file!(post_entry_path)
  root_remove = "Cookies.remove('cw_d_session_info', { path: '/' });"

  abort 'browser JavaScript must not write authentication credentials' if
    auth_source.match?(/Cookies\.set\(['"]cw_d_session_info/) || auth_source.include?('JSON.stringify(response.headers)')
  abort 'source must remove the auth cookie from the root path exactly once' unless auth_source.scan(root_remove).length == 1
  abort 'source contains an insecure auth-cookie option' if auth_source.match?(/secure:\s*false/)
  abort 'post-entry must not rely on a delayed auth-cookie repair timer' if
    post_entry.include?('hardenAuthCookie') || post_entry.include?('cw_d_session_info=')

  puts 'TOYBACO_CHATWOOT_AUTH_COOKIE_SOURCE=PASS creation=server_only root_path=fixed delayed_repair=absent'
  exit 0
end

root = arguments.first
abort 'production action requires ROOT' unless root

assets_root = File.join(root, 'app/public/vite/assets')
abort 'production Vite asset directory is a symlink' if File.symlink?(assets_root)
abort 'production Vite asset directory is missing' unless File.directory?(assets_root)

javascript_assets = []
Find.find(assets_root) do |path|
  abort "production Vite asset path is a symlink: #{path}" if File.symlink?(path)
  javascript_assets << path if File.file?(path) && path.end_with?('.js')
end
abort 'production Vite JavaScript assets are missing' if javascript_assets.empty?

auth_cookie_write = /\.set\(["']cw_d_session_info["']/
write_count = javascript_assets.sum { |path| regular_file!(path).scan(auth_cookie_write).length }
abort "production bundle must not write the authentication cookie (found #{write_count})" unless write_count.zero?

puts "TOYBACO_CHATWOOT_AUTH_COOKIE_PRODUCTION=PASS creation=server_only assets=#{javascript_assets.length}"
