require 'test_helper'
require 'rake'

module PermissionForge
  # The rake task itself: what it prints and how it exits.
  class AuditMasksTaskTest < ActiveSupport::TestCase
    setup do
      @previous_rake = Rake.application
      Rake.application = Rake::Application.new
      Rake::Task.define_task(:environment)
      load PermissionForge::Engine.root.join('lib/tasks/permission_forge.rake').to_s
    end

    teardown do
      Rake.application = @previous_rake
    end

    test 'prints the all-clear and does not exit when there is nothing to report' do
      output, status = run_task

      assert_nil status
      assert_equal "All GDPR-sensitive fields are properly masked.\n", output
    end

    test 'prints one line per finding and exits 1' do
      resource = create_resource(permission_set: create_permission_set(name: 'Support'), name: 'Customer',
                                 read_access: true)
      create_resource_field(resource: resource, name: 'email', mask_access: false)
      expected = PermissionForge::Services::GdprFieldAuditor.call.size

      output, status = run_task

      assert_equal 1, status
      assert_equal "GDPR audit found #{expected} issue(s):", output.lines.first.chomp
      assert_equal expected, output.lines.size - 1
      assert_includes output, "  [UNMASKED] Customer.email — matches pattern 'email'"
    end

    private

    # [what the task printed, its exit status (nil when it did not exit)]
    def run_task
      status = nil
      output, = capture_io do
        Rake::Task['permission_forge:audit_masks'].invoke
      rescue SystemExit => e
        status = e.status
      end
      [output, status]
    end
  end
end
