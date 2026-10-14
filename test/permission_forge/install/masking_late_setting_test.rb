# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'json'

module PermissionForge
  module Install
    # A masking setting switched on after the engine's boot step: a host (or
    # another gem) registers an after_initialize from an initializer ordered
    # after the engine's own, so the boot step and every engine after_initialize
    # saw the old value. The executor check is what catches it: the first
    # request or job masks the models the Resource rows name. Boots test/dummy
    # in a child process (development, in-memory database).
    class MaskingLateSettingTest < ActiveSupport::TestCase
      APPLICATION = File.expand_path('../../dummy/config/application', __dir__)
      SCHEMA = File.expand_path('../../dummy/db/schema.rb', __dir__)
      CHILD_ENV = { 'DATABASE_URL' => 'sqlite3::memory:', 'RAILS_ENV' => 'development', 'DB' => nil }.freeze

      SCRIPT = <<~RUBY.freeze
        Rails.application.initializer('pf_late_masking_setting', after: :load_config_initializers) do |app|
          PermissionForge.configure { |config| config.auto_apply_masked_attributes = false }
          app.config.after_initialize { PermissionForge.configuration.auto_apply_masked_attributes = :auto }
        end
        Rails.application.initialize!
        ActiveRecord::Schema.verbose = false
        load #{SCHEMA.dump}
        config = PermissionForge.configuration
        setting = config.auto_apply_masked_attributes
        # The row was committed by a process that did not mask Customer here.
        config.auto_apply_masked_attributes = false
        set = PermissionForge::PermissionSet.create!(name: 'Late')
        PermissionForge::Resource.create!(permission_set: set, name: 'Customer', read_access: true)
        config.auto_apply_masked_attributes = setting
        before = PermissionForge::Concerns::MaskedAttributes.applied?(Customer)
        Rails.application.executor.wrap { nil }
        puts JSON.generate('setting' => setting.to_s, 'before' => before,
                           'after' => PermissionForge::Concerns::MaskedAttributes.applied?(Customer))
      RUBY

      test 'a setting switched on after the boot step masks at the first request or job' do
        output, status = Open3.capture2e(CHILD_ENV, RbConfig.ruby, '-e', "require #{APPLICATION.dump}\n#{SCRIPT}")
        assert status.success?, output.lines.last(25).join
        result = JSON.parse(output.lines.reverse.find { |line| line.start_with?('{') })

        assert_equal 'auto', result['setting'], 'precondition: the late after_initialize switched masking on'
        assert_not result['before'], 'precondition: the boot step ran with masking off'
        assert result['after'], 'the first executor run must mask the model a Resource row names'
      end
    end
  end
end
