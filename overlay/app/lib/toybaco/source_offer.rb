# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # Public build metadata only. No request parameter, cookie or account lookup.
  class SourceOffer
    REVISION_PATH = File.expand_path('../../TOYBACO_PUBLIC_REVISION', __dir__).freeze
    HEADERS = { 'cache-control' => 'no-store', 'content-type' => 'text/plain; charset=utf-8' }.freeze

    def initialize(app, revision_path: REVISION_PATH)
      @app = app
      @revision_path = revision_path
    end

    def call(env)
      return @app.call(env) unless env['PATH_INFO'] == '/toybaco/source' && %w[GET HEAD].include?(env['REQUEST_METHOD'])

      revision = File.read(@revision_path).strip if File.file?(@revision_path)
      if revision&.match?(/\A[0-9a-f]{40}\z/)
        return [302, HEADERS.merge('location' => "https://github.com/Cyber-relations/chatwoot/tree/#{revision}"), []]
      end

      body = env['REQUEST_METHOD'] == 'HEAD' ? [] : ['対応ソースを確認できません。時間をおいて再度お試しください。']
      [503, HEADERS.dup, body]
    end
  end
end
