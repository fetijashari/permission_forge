# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Audit
    # The seam the engine installs notification subscribers through.
    class SubscribersTest < ActiveSupport::TestCase
      teardown do
        Subscribers.uninstall!(:pf_test_probe)
        Subscribers.instance_variable_get(:@installers).delete(:pf_test_probe)
      end

      test 'install! calls each installer once with the configuration and keeps what it returns' do
        calls = []
        Subscribers.register(:pf_test_probe, lambda { |config|
          calls << config
          ActiveSupport::Notifications.subscribe('report.generated.permission_forge') { |*| nil }
        })
        Subscribers.install!
        Subscribers.install!
        assert_equal [PermissionForge.configuration], calls
        assert Subscribers.installed?(:pf_test_probe)
        assert ActiveSupport::Notifications.notifier.listening?('report.generated.permission_forge')
      end

      test 'an installer that returns nil (its option is off) is asked again next time' do
        calls = 0
        Subscribers.register(:pf_test_probe, ->(_config) { calls += 1 and nil })
        Subscribers.install!
        Subscribers.install!
        assert_equal 2, calls
        assert_not Subscribers.installed?(:pf_test_probe)
      end

      test 'uninstall! removes the subscriber' do
        Subscribers.register(:pf_test_probe, lambda { |_config|
          ActiveSupport::Notifications.subscribe('report.generated.permission_forge') { |*| nil }
        })
        Subscribers.install!
        Subscribers.uninstall!(:pf_test_probe)
        assert_not Subscribers.installed?(:pf_test_probe)
        assert_not ActiveSupport::Notifications.notifier.listening?('report.generated.permission_forge')
      end

      test 'the engine initializer is registered' do
        assert PermissionForge::Engine.initializers.map(&:name).include?('permission_forge.audit')
      end
    end
  end
end
