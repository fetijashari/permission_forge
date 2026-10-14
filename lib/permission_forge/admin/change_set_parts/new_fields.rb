# frozen_string_literal: true

module PermissionForge
  module Admin
    module ChangeSetParts
      # New fields: columns without a ResourceField row, picked one by one or
      # through a bulk selection.
      class NewFields < Base
        def call
          explicit = section('new_fields').flat_map { |resource_id, columns| explicit_new_fields(resource_id, columns) }
          explicit + bulk_new_fields
        end

        private

        def explicit_new_fields(resource_id, columns)
          resource = unlocked_resource(resource_id)
          return [] unless resource && columns.is_a?(Hash)

          existing = existing_names(resource)
          columns.filter_map do |column, attrs|
            name = column.to_s
            next if existing.include?(name) || !attrs.is_a?(Hash)

            build_new_field(resource, name, attrs['level'].to_s)
          end
        end

        def bulk_new_fields
          level = bulk['level'].to_s
          resource = unlocked_resource(bulk['resource_id'])
          return [] unless resource && valid_level?(level)

          bulk_columns(resource).filter_map { |column| build_new_field(resource, column, level) }
        end

        # Bulk-selected columns that have neither a field nor an explicit pick.
        def bulk_columns(resource)
          Array(bulk['keys']).map(&:to_s).uniq - existing_names(resource) - explicit_columns(resource)
        end

        def existing_names(resource)
          resource.resource_fields.map(&:name)
        end

        def explicit_columns(resource)
          (params.dig('new_fields', resource.id.to_s) || {}).keys.map(&:to_s)
        end

        def build_new_field(resource, column, level)
          return nil unless valid_level?(level) && level != 'leave'

          level = Values.effective_level(level, resource, muting: muting?)
          field = resource.resource_fields.build(name: column, label: column.humanize, is_active: true, is_editable: true)
          field.assign_attributes(flags_for(level))
          field.mask_strategy = sensitive.match(column)&.strategy || 'full'
          change(kind: :new_field, record: field, attribute: 'level', from: nil, to: [level, field.mask_strategy],
                 resource: resource)
        end
      end
    end
  end
end
