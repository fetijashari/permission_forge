require 'test_helper'

module PermissionForge
  module Services
    class GdprFieldAuditorTextReportTest < ActiveSupport::TestCase
      test 'an empty report says everything is masked' do
        assert_equal 'All GDPR-sensitive fields are properly masked.', GdprFieldAuditor::TextReport.new([]).to_s
      end

      test 'prints one line per finding of every type the auditor reports' do
        masking = create_permission_set(name: 'Support')
        masked = create_resource(permission_set: masking, name: 'Customer', read_access: true)
        create_resource_field(resource: masked, name: 'email', mask_access: true, mask_strategy: 'email')

        open_set = create_permission_set(name: 'Managers')
        open_resource = create_resource(permission_set: open_set, name: 'Customer', read_access: true, view_all: true)
        create_resource_field(resource: open_resource, name: 'email', mask_access: false)

        report = GdprFieldAuditor.call
        types = report.map { |finding| finding[:type] }.uniq
        lines = GdprFieldAuditor::TextReport.new(report).to_s.lines.map(&:chomp)

        assert_equal GdprFieldAuditor::TextReport::LINES.keys.sort, types.sort,
                     'the fixture should produce every finding type, and every type needs a line'
        assert_equal "GDPR audit found #{report.size} issue(s):", lines.first
        assert_equal report.size, lines.size - 1, 'the count in the header is the number of lines below it'
      end

      test 'names the set, the resource and the bypass for view_all on a resource with sensitive fields' do
        text = GdprFieldAuditor::TextReport.new(
          [{ type: :view_all_on_pii_resource, resource_name: 'Customer', permission_set: 'Managers',
             bypasses: %w[view_all modify_all], pii_fields: %w[email phone] }]
        ).to_s

        assert_includes text, '  [VIEW ALL] Managers › Customer — view_all + modify_all skips row-level rules; ' \
                              'GDPR-sensitive fields on this resource: email, phone'
      end

      test 'names the set that unmasks a field another set masks' do
        text = GdprFieldAuditor::TextReport.new(
          [{ type: :cross_set_unmasking, field_name: 'email', resource_name: 'Customer', permission_set: 'Managers' }]
        ).to_s

        assert_includes text, '  [OVERRIDES MASK] Managers › Customer.email — unmasked here, masked in another ' \
                              'Permission Set; a person in both sees the full value'
      end

      # CI scripts count the old tags; a new tag must not be matched by them.
      test 'no new tag contains an old one' do
        old_tags = %w[UNMASKED UNMAPPED VIRTUAL]
        new_lines = GdprFieldAuditor::TextReport::LINES.slice(:view_all_on_pii_resource, :cross_set_unmasking)
        sample = { permission_set: 'S', resource_name: 'R', field_name: 'f', bypasses: [], pii_fields: [] }

        new_lines.each_value do |line|
          tag = line.call(sample)[/\A\[[^\]]+\]/]
          old_tags.each { |old| refute_includes tag, old }
        end
      end

      test 'keeps the lines existing CI output already had' do
        text = GdprFieldAuditor::TextReport.new(
          [{ type: :unmasked_field, resource_name: 'Customer', field_name: 'email', suggested_strategy: 'email' },
           { type: :unmapped_column, resource: 'Customer', column: 'phone', pattern_matched: 'last4' },
           { type: :implicit_virtual_grant, permission_set: 'Support', resource_name: 'Customer',
             field_name: 'full_address', suggested_strategy: 'full' }]
        ).to_s

        assert_includes text, "  [UNMASKED] Customer.email — matches pattern 'email'"
        assert_includes text, "  [UNMAPPED] Customer.phone — matches pattern 'last4', no active ResourceField"
        assert_includes text, "  [VIRTUAL] Support › Customer.full_address — matches a GDPR pattern (suggested mask: 'full'), " \
                              'no active ResourceField, readable and editable by default'
      end

      test 'a finding type without its own line is still printed' do
        text = GdprFieldAuditor::TextReport.new([{ type: :something_new, resource_name: 'Customer', detail: 'x' }]).to_s

        assert_equal "GDPR audit found 1 issue(s):\n  [SOMETHING NEW] resource_name: Customer, detail: x", text
      end
    end
  end
end
