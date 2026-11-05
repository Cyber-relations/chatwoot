# frozen_string_literal: true

# HTTP code verification enters through Mfa::AuthenticationService, including enrollment.
# The user lock serializes the budget check, reservation and code verification
# across workers, challenges and HTTP endpoints. Reserve before verifying so a
# write outage never permits uncounted guesses. Success removes only its reservation:
# previous failures stay, and verifier errors keep the reservation. Only
# failures older than WINDOW stop counting, including after an exhausted window.
# A sliding window avoids allowing two full budgets at a fixed-window boundary.
module Toybaco::Security::MfaLoginAttempts
  LIMIT = 10
  WINDOW = 15.minutes
  LimitExceeded = Class.new(StandardError)

  module_function

  def verify(user)
    user.with_lock do
      raise LimitExceeded if limited?(user)

      reservation = reserve!(user)
      authenticated = yield
      Redis::Alfred.with { |redis| redis.zrem(key(user), reservation) } if authenticated
      authenticated
    end
  end

  def limited?(user)
    Redis::Alfred.zcount(key(user), "(#{(Time.current - WINDOW).to_f}", '+inf') >= LIMIT
  end

  def reserve!(user)
    reservation = SecureRandom.uuid
    Redis::Alfred.zremrangebyscore(key(user), '-inf', (Time.current - WINDOW).to_f)
    added = Redis::Alfred.zadd(key(user), Time.current.to_f, reservation)
    raise Redis::BaseError, 'MFA attempt reservation failed' unless added == 1
    raise Redis::BaseError, 'MFA attempt expiry failed' unless Redis::Alfred.expire(key(user), WINDOW.to_i)

    reservation
  end

  def key(user)
    "toybaco:mfa-login-failures:v1:#{user.id}"
  end
end
