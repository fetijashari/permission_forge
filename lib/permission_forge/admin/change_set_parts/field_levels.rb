# frozen_string_literal: true

module PermissionForge
  module Admin
    module ChangeSetParts
      # Existing fields: explicit edits and bulk level selections (see
      # FieldEdit), plus the Edit-off cascade to Read-only.
      class FieldLevels < Base
        def call
          requested = requested_field_attrs
          changes = requested.flat_map { |id, attrs| changes_for_field(field_index[id], attrs) }
          changes + cascaded_field_changes(requested.keys)
        end

        private

        def field_index
          @field_index ||= resources.values.flat_map(&:resource_fields).index_by { |field| field.id.to_s }
        end

        # Merges explicit field params with bulk selections.
        def requested_field_attrs
          out = explicit_field_attrs
          level = bulk['level'].to_s
          return out unless valid_level?(level)

          bulk_fields.each { |field| (out[field.id.to_s] ||= {})['level'] = level }
          out
        end

        def explicit_field_attrs
          section('fields').select { |id, attrs| field_index.key?(id.to_s) && attrs.is_a?(Hash) }.transform_keys(&:to_s)
        end

        def bulk_fields
          resource = resources[bulk['resource_id'].to_s]
          return [] unless resource

          fields = Array(bulk['keys']).filter_map { |key| resource.resource_fields.find { |field| field.name == key.to_s } }
          fields.reject { |field| field.is_editable == false }
        end

        def changes_for_field(field, attrs)
          return [] if field.nil? || locked?(field) || locked?(resource_of(field))

          field_edit(field).changes(attrs)
        end

        # Editable fields on resources whose Edit (or Read) was just turned off
        # are downgraded to Read-only so field and resource stay consistent.
        def cascaded_field_changes(already)
          return [] if muting?

          resources.values.reject(&:edit_access).flat_map(&:resource_fields).filter_map do |field|
            field_edit(field).downgrade_to_read if cascadable?(field, already)
          end
        end

        # A locked field, or a field of a locked Resource, keeps its level.
        def cascadable?(field, already)
          !already.include?(field.id.to_s) && !locked?(field) && !locked?(resource_of(field)) &&
            FieldLevel.level_of(field, muting: false) == 'edit'
        end

        def field_edit(field)
          FieldEdit.new(field, resource_of(field), muting: muting?)
        end
      end
    end
  end
end
