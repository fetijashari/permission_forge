# frozen_string_literal: true

# The local Redis the cache tests write to (database 15; PF_TEST_REDIS_URL
# names another), or a skip when there is none — as in CI, which runs no
# Redis.
#
# The skip is raised outside any rescue. A skip raised inside one carries
# the error being rescued as its cause, and a forked worker's result
# reaches the parent process by Marshal: when the parent has not loaded the
# class of that error (Redis::CannotConnectError — the redis gem is
# required here, in the worker, and Rails 8.2's Redis store no longer
# requires it), DRb cannot load the result, and Rails reports the skip as
# an error (DRb::DRbRemoteError: ... (Minitest::Skip)).
module LocalRedis
  URL = ENV.fetch('PF_TEST_REDIS_URL', 'redis://127.0.0.1:6379/15')

  # Why the Redis at `url` cannot be used; nil when it answers.
  #
  # @return [String, nil]
  def self.unavailable(url = URL)
    require 'redis'
    redis = Redis.new(url: url)
    redis.ping
    nil
  rescue LoadError
    'the redis gem is not in this bundle'
  rescue StandardError => e
    "no Redis at #{url}: #{e.class}"
  ensure
    redis&.close
  end

  # Skips the test unless a Redis answers at `url`.
  def require_local_redis!(url = URL)
    reason = LocalRedis.unavailable(url)
    skip reason if reason
  end
end
