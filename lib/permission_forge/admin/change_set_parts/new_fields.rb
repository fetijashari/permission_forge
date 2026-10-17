# frozen_string_literal: true

module PermissionForge
  module Admin
    module ChangeSetParts
      # New fields: columns without a ResourceField row, picked one by one or
      # through a bulk selection. Only the model's managed fields
      # (PermissionForge::ManagedFields — the names the presets, Sync and the
      # generator write rows for) can be added: a posted `id`, an ignored
      # field or a name the model does not have is no row.
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
            next if existing.include?(name) || !attrs.is_a?(Hash) || !addable?(resource, name)

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
          (Array(bulk['keys']).map(&:to_s).uniq & addable_names(resource)) - existing_names(resource) - explicit_columns(resource)
        end

        def addable?(resource, name)
          addable_names(resource).include?(name)
        end

        # The model's managed fields; none when the Resource names no model
        # this app can load.
        def addable_names(resource)
          @addable_names ||= {}
          @addable_names[resource.id] ||= begin
            model = PermissionForge::ModelLookup.model_for(resource.name)
            model ? PermissionForge::ManagedFields.new(model).names : []
          end
        end

        def existing_names(resource)
          resource.resource_fields.map(&:name)
        end

        def explicit_columns(resource)
          (params.dig('new_fields', resource.id.to_s) || {}).keys.map(&:to_s)
        end

        # The row comes from the one row builder (ResourceFieldGenerator::
        # RowBuilder: privacy defaults, timestamps, the recommended strategy),
        # so the change records the level the row really gets — Masked for a
        # sensitive column added Read-only under gdpr_defaults, Read-only for
        # a timestamp added Editable. A blank name is no row.
        def build_new_field(resource, column, level)
          return nil unless valid_level?(level) && FieldLevel.row?(level, muting: muting?)

          attrs = rows_of(resource).attrs(column, level)
          return nil unless attrs

          field = resource.resource_fields.build(attrs)
          change(kind: :new_field, record: field, attribute: 'level', from: nil,
                 to: [FieldLevel.level_of(field, muting: muting?), field.mask_strategy], resource: resource)
        end

        def rows_of(resource)
          @rows_of ||= {}
          @rows_of[resource.id] ||= Services::ResourceFieldGenerator.rows(resource, muting: muting?, sensitive: sensitive)
        end
      end
    end
  end
end
