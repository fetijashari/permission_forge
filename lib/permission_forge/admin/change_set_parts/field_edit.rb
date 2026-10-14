# frozen_string_literal: true

module PermissionForge
  module Admin
    module ChangeSetParts
      # Edits to one existing field: level (+ mask strategy), then
      # label/description/active. `resource` is the in-memory resource with
      # this change set's flag edits already applied.
      class FieldEdit
        ATTRS = %w[label description is_active].freeze
        MASK_LEVELS = %w[masked mask].freeze
        CASTS = {
          'label' => ->(value, field) { value.to_s.strip.presence || field.name.humanize },
          'is_active' => ->(value, _field) { Values.truthy?(value) }
        }.freeze
        TEXT_CAST = ->(value, _field) { value.to_s.strip.presence }

        def initialize(field, resource, muting:)
          @field = field
          @resource = resource
          @muting = muting
        end

        def changes(attrs)
          level_change(attrs) + attr_changes(attrs.slice(*ATTRS))
        end

        # Cascade: Editable => Read-only. Returns the (cascaded) change or nil.
        def downgrade_to_read
          assign_level('read').first&.tap { |change| change.cascaded = true }
        end

        private

        def level_change(attrs)
          level = attrs['level'].to_s
          return [] unless FieldLevel.valid?(level, muting: @muting)

          assign_level(Values.effective_level(level, @resource, muting: @muting), attrs['mask_strategy'])
        end

        def assign_level(level, strategy = nil)
          from = [FieldLevel.level_of(@field, muting: @muting), @field.mask_strategy]
          write_level(level, strategy)
          return [] if from.first == level && !@field.mask_strategy_changed?

          [change('level', [level, @field.mask_strategy], kind: :field_level, from: from)]
        end

        def write_level(level, strategy)
          @field.assign_attributes(FieldLevel.flags_for(level, muting: @muting))
          @field.mask_strategy = strategy if strategy.present? && MASK_LEVELS.include?(level)
        end

        def attr_changes(attrs)
          attrs.filter_map do |attr, value|
            change(attr, CASTS.fetch(attr, TEXT_CAST).call(value, @field), kind: :field_attr).assign
          end
        end

        def change(attribute, to, **attrs)
          ChangeSet::Change.new(record: @field, resource: @resource, attribute: attribute, to: to, **attrs)
        end
      end
    end
  end
end
