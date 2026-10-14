# frozen_string_literal: true

module PermissionForge
  module Services
    # @api private
    module SecurityAuditChecks
      # Shared plumbing for SecurityAudit checks: subclasses implement #call
      # and build findings with #finding.
      class BaseCheck
        ITEM_LIMIT = 50

        def initialize(configuration:, environment:)
          @configuration = configuration
          @environment = environment
        end

        private

        attr_reader :configuration

        def production?
          @environment == 'production'
        end

        def finding(severity, code, title, detail, items: [])
          SecurityAudit::Finding.new(check: check_name, severity: severity, code: code, title: title,
                                     detail: detail, items: capped(items))
        end

        def capped(items)
          extra = items.size - ITEM_LIMIT
          extra.positive? ? items.first(ITEM_LIMIT) << "… and #{extra} more" : items
        end

        def check_name
          self.class.name.demodulize.delete_suffix('Check').underscore
        end

        def active_granting_sets
          PermissionForge::PermissionSet.active.granting
        end

        def people_counts
          @people_counts ||= PermissionForge::PermissionSetUser.active_assignments.group(:permission_set_id).count
        end

        def people(set_id)
          people_label(people_counts.fetch(set_id, 0))
        end

        def people_label(count)
          "#{count} #{count == 1 ? 'person' : 'people'}"
        end
      end
    end
  end
end
