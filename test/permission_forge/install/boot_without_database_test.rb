require 'test_helper'
require 'open3'

module PermissionForge
  module Install
    # A Docker build runs `assets:precompile` with no database, a worker can
    # start while the database fails over: the app must boot anyway. Since
    # Rails 7.2 `ActiveRecord::Base.connection` no longer connects, so a check
    # built on it answered "available" and the first boot query raised
    # ActiveRecord::DatabaseConnectionError out of the engine's
    # after_initialize. This boots test/dummy in a child process against a
    # PostgreSQL URL on a closed port (nothing ever listens on port 1, so no
    # database is used) and expects a clean exit.
    class BootWithoutDatabaseTest < ActiveSupport::TestCase
      DUMMY_ENVIRONMENT = File.expand_path('../../dummy/config/environment', __dir__)
      UNREACHABLE_URL = 'postgresql://pf:pf@127.0.0.1:1/permission_forge_unreachable'.freeze

      BOOT = <<~RUBY.freeze
        require #{DUMMY_ENVIRONMENT.dump}
        Rails.application.eager_load!
        puts "BOOTED adapter=\#{ActiveRecord::Base.connection_db_config.adapter}"
      RUBY

      test 'the app boots and eager-loads when the database cannot be reached' do
        output, status = boot(UNREACHABLE_URL)

        assert status.success?, "boot aborted (exit #{status.exitstatus}):\n#{output.lines.last(25).join}"
        assert_includes output, 'BOOTED adapter=postgresql'
      end

      test 'the skipped boot checks are logged once' do
        output, = boot(UNREACHABLE_URL, 'PF_BOOT_LOG_TO_STDOUT' => '1')

        assert_equal 1, output.scan('[PermissionForge] The database could not be reached at boot').size, output
      end

      private

      def boot(url, extra_env = {})
        env = { 'DATABASE_URL' => url, 'RAILS_ENV' => 'development', 'DB' => nil }.merge(extra_env)
        Open3.capture2e(env, RbConfig.ruby, '-e', boot_script(extra_env))
      end

      # The dummy logs to log/development.log; the second test reads the
      # boot log from standard output instead.
      def boot_script(extra_env)
        return BOOT unless extra_env.key?('PF_BOOT_LOG_TO_STDOUT')

        <<~RUBY
          require #{File.expand_path('../../dummy/config/application', __dir__).dump}
          Rails.application.config.logger = ActiveSupport::Logger.new($stdout)
          Rails.application.initialize!
        RUBY
      end
    end
  end
end
