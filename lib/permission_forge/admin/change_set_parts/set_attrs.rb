# frozen_string_literal: true

module PermissionForge
  module Admin
    module ChangeSetParts
      # Set header: name, description, active, group.
      class SetAttrs < Base
        SET_ATTRS = %w[name description is_active permission_set_group_id].freeze
        # A group id that is neither blank (no group) nor digits.
        NOT_A_GROUP = Object.new.freeze
        TEXT_CAST = ->(value) { value.to_s.strip.presence if value.is_a?(String) || value.is_a?(Numeric) }
        CASTS = {
          'is_active' => ->(value) { Values.truthy?(value) },
          'permission_set_group_id' => lambda { |value|
            next nil if value.blank?

            RecordId.cast(value) || NOT_A_GROUP
          }
        }.freeze

        def call
          section('set').slice(*SET_ATTRS).filter_map do |attr, value|
            to = cast(attr, value)
            next if to.equal?(NOT_A_GROUP)
            next if attr == 'permission_set_group_id' && locked_group_move?(to)

            assign_change(kind: :set_attr, record: permission_set, attribute: attr, to: to)
          end
        end

        private

        # A move into or out of a locked Permission Set Group is skipped
        # (the controller refuses it first).
        def locked_group_move?(group_id)
          EditableLock.locked_group_for_move(from: permission_set.permission_set_group_id, to: group_id).present?
        end

        def cast(attr, value)
          CASTS.fetch(attr, TEXT_CAST).call(value)
        end
      end
    end
  end
end
