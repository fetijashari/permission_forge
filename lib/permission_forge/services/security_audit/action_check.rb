# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # Controller actions as permissions: managed actions nobody is permitted
      # to run, managed actions whose controller does not run the guard, rows
      # whose name can never be an action key, rows that match no controller
      # action, and discovery switched on while no controller includes the guard.
      class ActionCheck < BaseCheck
        # One action row in effect (PermissionForge::ResourceAction.in_effect).
        LiveRow = Struct.new(:tenant, :resource, :action, :permitted, :muting, :set) do
          def target = [tenant, resource, action]
          def key = [resource, action]
          def label = "#{resource} › #{action}"
          def grants? = permitted && !muting
          def valid_key? = action.match?(PermissionForge::ControllerActions::KEY_FORMAT)

          # 'Sales › Customer › "archive "' — quoted, so stray spaces show.
          def quoted_label = "#{set} › #{resource} › #{action.inspect}"
        end

        # @param catalog [PermissionForge::Admin::ControllerCatalog, nil] the
        #   app's controller actions; read from the routes on first use when nil
        def initialize(configuration:, environment:, catalog: nil)
          super(configuration: configuration, environment: environment)
          @catalog = catalog
        end

        def call
          [ungranted_actions, unguarded_actions, invalid_keys, unlinked_actions, guard_missing].compact
        end

        private

        def discovery?
          configuration.controller_action_discovery?
        end

        def catalog
          @catalog ||= PermissionForge::Admin::ControllerCatalog.new(configuration: configuration)
        end

        # { 'Customer' => { 'export' => [ControllerCatalog::Entry, ...] } }
        def endpoints
          @endpoints ||= Hash.new { |index, resource| index[resource] = catalog.for_resource(resource).group_by(&:key) }
        end

        # Managed, and reachable through a controller that does not run the
        # guard: there the row restricts nobody unless the code checks can?.
        # Covers a partial rollout, which guard_missing (no guard anywhere)
        # does not see.
        def unguarded_actions
          return unless discovery?

          items = live_rows.map(&:key).uniq.sort.filter_map { |resource, action| unguarded_item(resource, action) }
          return if items.empty?

          finding(:medium, :unguarded_actions, 'Managed actions on controllers that do not run the guard',
                  'A Permission Set manages these actions, but the listed controller actions run in a controller ' \
                  'that does not include PermissionForge::Concerns::ControllerActionGuard (or skips it for every ' \
                  'action). Through those routes everyone can still run the action, whatever the admin shows, ' \
                  'unless your code checks can?. Include the guard in those controllers.', items: items)
        end

        # "Customer › merge: customers/merges#create", or nil when every
        # controller action behind the key runs the guard (or none maps to it).
        def unguarded_item(resource, action)
          unguarded = endpoints[resource].fetch(action, []).reject(&:guarded?).map(&:endpoint).join(', ')
          "#{resource} › #{action}: #{unguarded}" unless unguarded.empty?
        end

        # Managed (a row is in effect) but permitted by no granting set: the
        # guard and can? refuse everyone.
        def ungranted_actions
          ungranted = live_rows.group_by(&:target).values.reject { |rows| rows.any?(&:grants?) }
          return if ungranted.empty?

          finding(:low, :ungranted_actions, 'Managed actions nobody is permitted to run',
                  'A row for these actions is in effect, so only people whose Permission Sets permit them can ' \
                  'run them — and no active granting set does. Permit each one in a set, or remove its rows to ' \
                  'stop managing it.', items: ungranted.map { |rows| ungranted_item(rows) }.uniq.sort)
        end

        def ungranted_item(rows)
          "#{rows.first.label}: only in #{rows.map(&:set).uniq.sort.join(', ')}"
        end

        # Rows in effect under a name that is not an action key. The admin and
        # the JSON API refuse such names; older rows, seeds and other apps
        # writing to these tables may still carry them. The guard only matches
        # one when a controller action is literally called that.
        def invalid_keys
          invalid = live_rows.reject(&:valid_key?)
          return if invalid.empty?

          finding(:low, :invalid_action_keys, 'Action rows whose name is not a valid action key',
                  'Action keys are lowercase letters, digits and underscores, starting with a letter. A row ' \
                  'under any other name is not the key of the action it looks like ("Export" does not cover ' \
                  '"export"), so that action stays unmanaged while the admin shows a row for it. The row only ' \
                  'takes effect where your code checks can? with exactly this name, or where a controller ' \
                  'action is literally called that. Rename each row to the key of the action it is for.',
                  items: invalid.map(&:quoted_label).uniq.sort)
        end

        def unlinked_actions
          return unless discovery?

          unlinked = configured_actions.reject { |resource, action| endpoints[resource].key?(action) }
          return if unlinked.empty?

          finding(:info, :unlinked_actions, 'Actions not linked to a controller action',
                  'No controller action maps to these keys. That is expected for an action your code checks ' \
                  'with can?. Otherwise the key is misspelled or its route is gone, and the row does nothing.',
                  items: unlinked.map { |resource, action| "#{resource} › #{action}" })
        end

        def guard_missing
          return unless discovery? && !catalog.any_guarded?

          finding(live_rows.any? ? :medium : :low, :action_guard_missing,
                  'Controller actions are listed, but no controller checks them',
                  'controller_action_discovery is on, yet no listed controller includes ' \
                  'PermissionForge::Concerns::ControllerActionGuard. Permitting or blocking an action in the ' \
                  'admin changes nothing at runtime unless your code checks can?. Include the guard in the ' \
                  'controllers you want checked.')
        end

        def live_rows
          @live_rows ||= PermissionForge::ResourceAction.in_effect.pluck(*live_columns).map { |values| LiveRow.new(*values) }
        end

        # "Managed" is per tenant, so rows of different tenants never cover each other.
        def live_columns
          [tenant_column, column(PermissionForge::Resource, :name), column(PermissionForge::ResourceAction, :name),
           column(PermissionForge::ResourceAction, :is_permitted), column(PermissionForge::PermissionSet, :is_muting),
           column(PermissionForge::PermissionSet, :name)]
        end

        def tenant_column
          name = configuration.resolved_tenant_column
          name ? column(PermissionForge::Resource, name) : Arel.sql('NULL')
        end

        def column(model, name)
          model.arel_table[name]
        end

        # [[resource name, action key], ...] for every action row, on or off.
        def configured_actions
          resource_name = column(PermissionForge::Resource, :name)
          PermissionForge::ResourceAction.joins(:resource).distinct.order(resource_name, :name).pluck(resource_name, :name)
        end
      end
    end
  end
end
