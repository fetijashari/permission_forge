# frozen_string_literal: true

module PermissionForge
  module Admin
    module ChangeSetParts
      # New actions: controller actions that discovery lists for a resource and
      # that have no ResourceAction row in this set yet — picked one by one
      # (`new_actions`), or all at once (`bulk_actions`).
      #
      # Only keys the controller catalog lists for the resource are created;
      # free-text keys go through ResourceActionsController. Nothing is created
      # while controller_action_discovery is off, in a locked set, in a locked
      # resource, or for a key that already has a row. A blank is_permitted
      # means "don't add". In a muting set is_permitted means "block".
      class NewActions < Base
        def call
          return [] unless creatable?

          explicit = hash_section('new_actions').flat_map { |resource_id, keys| explicit_new_actions(resource_id, keys) }
          explicit + bulk_new_actions
        end

        private

        delegate :controller_catalog, to: :@context

        def creatable?
          PermissionForge.configuration.controller_action_discovery? && !locked?(permission_set)
        end

        # A params section, or {} when the request sent something else there.
        def hash_section(key)
          value = section(key)
          value.is_a?(Hash) ? value : {}
        end

        # The route table is only read once a row actually asks to be added.
        def explicit_new_actions(resource_id, keys)
          resource = unlocked_resource(resource_id)
          chosen = chosen_keys(keys)
          return [] unless resource && chosen.any?

          addable = addable_keys(resource)
          chosen.filter_map { |key, permitted| build_new_action(resource, key, permitted) if addable.include?(key) }
        end

        # { 'export' => '1' } for the keys with a non-blank choice.
        def chosen_keys(keys)
          return {} unless keys.is_a?(Hash)

          keys.each_with_object({}) do |(key, attrs), chosen|
            permitted = attrs.is_a?(Hash) ? attrs['is_permitted'].to_s.strip : ''
            chosen[key.to_s] = permitted unless permitted.empty?
          end
        end

        # Every discovered key that neither has a row nor an explicit pick.
        def bulk_new_actions
          bulk = hash_section('bulk_actions')
          permitted = bulk['is_permitted'].to_s.strip
          resource = unlocked_resource(bulk['resource_id']) unless permitted.empty?
          return [] unless resource

          addable_keys(resource).map { |key| build_new_action(resource, key, permitted) }
        end

        # Discovered keys for the resource without a row — including the rows
        # this change set has already built.
        def addable_keys(resource)
          discovered_keys(resource.name) - existing_names(resource)
        end

        # The catalog only lists valid keys; the grep is defence in depth.
        def discovered_keys(resource_name)
          controller_catalog.keys_for(resource_name).grep(PermissionForge::ControllerActions::KEY_FORMAT)
        end

        def existing_names(resource)
          resource.resource_actions.map(&:name)
        end

        def build_new_action(resource, key, permitted)
          action = resource.resource_actions.build(name: key, label: key.humanize, is_active: true,
                                                   is_permitted: truthy?(permitted))
          change(kind: :new_action, record: action, attribute: 'is_permitted', from: nil, to: action.is_permitted,
                 resource: resource)
        end
      end
    end
  end
end
