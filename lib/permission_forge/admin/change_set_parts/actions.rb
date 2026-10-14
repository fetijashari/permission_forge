# frozen_string_literal: true

module PermissionForge
  module Admin
    module ChangeSetParts
      # Custom action is_permitted toggles (actions of locked resources are ignored).
      class Actions < Base
        def call
          section('actions').filter_map do |id, attrs|
            action = action_index[id.to_s]
            next unless action && attrs.is_a?(Hash) && attrs.key?('is_permitted')

            assign_change(kind: :action, record: action, attribute: 'is_permitted', to: truthy?(attrs['is_permitted']),
                          resource: resource_of(action))
          end
        end

        private

        def action_index
          @action_index ||= resources.values.reject { |r| locked?(r) }.flat_map(&:resource_actions)
                                     .index_by { |action| action.id.to_s }
        end
      end
    end
  end
end
