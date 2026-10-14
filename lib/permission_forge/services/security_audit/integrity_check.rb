# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # Rows the models' validations would refuse but the database holds
      # anyway (written by SQL, an older version, or another app).
      class IntegrityCheck < BaseCheck
        RESOURCE_RULES = {
          'edit without read' => ->(r) { r.edit_access && !r.read_access },
          'delete without read' => ->(r) { r.delete_access && !r.read_access },
          'Modify All without View All' => ->(r) { r.modify_all && !r.view_all }
        }.freeze

        FIELD_RULES = {
          'edit without read' => ->(field) { field.edit_access && !field.read_access },
          'masked without read' => ->(field) { field.mask_access && !field.read_access }
        }.freeze

        def call
          [duplicate_fields, duplicate_actions, dependency_violations, unknown_models].compact
        end

        private

        def duplicate_fields
          groups = PermissionForge::ResourceField.group(:resource_id, :name).having('COUNT(*) > 1').count
          return if groups.empty?

          names = PermissionForge::Resource.where(id: groups.keys.map(&:first)).pluck(:id, :name).to_h
          finding(:high, :duplicate_fields, 'Duplicate field rows',
                  'Two rows for one field merge with mask AND-logic, so an unmasked duplicate unmasks the field. ' \
                  'Run `bin/rails generate permission_forge:upgrade` to de-duplicate and add the unique index.',
                  items: groups.map { |(resource_id, name), count| "#{names[resource_id]}.#{name}: #{count} rows" })
        end

        def duplicate_actions
          groups = PermissionForge::ResourceAction.group(:resource_id, :name).having('COUNT(*) > 1').count
          return if groups.empty?

          resources = PermissionForge::Resource.where(id: groups.keys.map(&:first)).includes(:permission_set).index_by(&:id)
          finding(:medium, :duplicate_actions, 'Duplicate action rows',
                  'Two rows for one action are OR-ed, so a permitting duplicate permits what the other row blocks. ' \
                  'Remove the extra row; a unique index on (resource, name) keeps new ones out ' \
                  '(the install migration creates idx_pf_resource_actions_unique).',
                  items: groups.map do |(resource_id, name), count|
                    resource = resources[resource_id]
                    "#{resource&.permission_set&.name} › #{resource&.name}.#{name}: #{count} rows"
                  end)
        end

        def dependency_violations
          items = resource_violations + field_violations
          return if items.empty?

          finding(:low, :dependency_violations, 'Grants that skip a required permission',
                  'Validations require read before edit / delete / mask, and View All before Modify All. ' \
                  'Fix these rows in the admin so they mean what they say.', items: items)
        end

        def resource_violations
          granting_resources.flat_map do |resource|
            violations(RESOURCE_RULES, resource).map { |what| "#{resource.permission_set.name} › #{resource.name}: #{what}" }
          end
        end

        def field_violations
          fields = PermissionForge::ResourceField.where(resource_id: granting_resources.map(&:id))
                                                 .where('edit_access = ? OR mask_access = ?', true, true)
                                                 .where(read_access: false).includes(resource: :permission_set)
          fields.flat_map do |field|
            resource = field.resource
            violations(FIELD_RULES, field).map do |what|
              "#{resource.permission_set.name} › #{resource.name}.#{field.name}: #{what}"
            end
          end
        end

        def violations(rules, record)
          rules.select { |_, broken| broken.call(record) }.keys
        end

        def granting_resources
          @granting_resources ||= PermissionForge::Resource.where(
            permission_set_id: PermissionForge::PermissionSet.granting.select(:id)
          ).includes(:permission_set).to_a
        end

        def unknown_models
          names = PermissionForge::Resource.distinct.order(:name).pluck(:name).reject { |name| model?(name) }
          return if names.empty?

          finding(:low, :unknown_models, 'Resources for models this app does not have',
                  'No ActiveRecord class matches these names, so the grants do nothing here. If another app ' \
                  'shares these tables it may still use them — check there before deleting.', items: names)
        end

        def model?(name)
          klass = name.safe_constantize
          klass.is_a?(Class) && klass < ActiveRecord::Base
        end
      end
    end
  end
end
