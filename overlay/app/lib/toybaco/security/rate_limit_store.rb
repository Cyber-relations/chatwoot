# frozen_string_literal: true

# Rails 7.2's EXPIRE NX optimization calls pipeline.call. Redis::Namespace does
# not implement that API. Use Rails' supported INCRBY/TTL/EXPIRE fallback while
# retaining the existing pooled, namespaced Redis and counter expiration.
class Toybaco::Security::RateLimitStore < ActiveSupport::Cache::RedisCacheStore
  private

  def supports_expire_nx?
    false
  end
end
