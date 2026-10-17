# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # Controller actions as permissions: guarded controller actions no
      # Permission Set manages (refused under the default strategy, open under
      # :allow), managed actions nobody is permitted to run, managed actions
      # whose controller does not run the guard, rows whose name can never be
      # an action key, rows that match no controller action, and discovery
      # switched on while no controller includes the guard.
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
          [unmanaged_actions, actions_not_checked, ungranted_actions, unguarded_actions, invalid_keys, unlinked_actions,
           guard_missing].compact
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

        # Mapped controller actions, in controllers that run the guard, that
        # some tenant's Permission Sets do not manage: the guard hands them to
        # unconfigured_action_strategy. Read from the routes whether or not
        # discovery is on, as the guard runs either way, so an app upgrading
        # past the :allow default sees what now answers 403 before it deploys.
        def unmanaged_actions
          items = UnmanagedActions.build(entries: catalog.mapped_entries, configuration: configuration).items
          return if items.empty?

          if configuration.allow_unconfigured_actions?
            finding(:info, :unmanaged_actions_allowed, 'Guarded actions no Permission Set manages run for everyone',
                    'unconfigured_action_strategy is :allow, so every signed-in user can run these controller ' \
                    'actions: no Permission Set manages them (unconfigured_actions_allowed rates the setting). ' \
                    'Manage each one in a Permission Set before you switch the strategy back to :block, the default.',
                    items: items)
          else
            finding(:low, :unmanaged_actions_refused, 'Guarded actions no Permission Set manages are refused',
                    'These controller actions map to a Resource and run the guard, but no Permission Set manages ' \
                    "them (with tenancy: in the tenants named), so the guard refuses them (403) #{UnmanagedActions.refused_to(configuration)} " \
                    '(unconfigured_action_strategy :block, the default since 0.15) — unless the controller skips ' \
                    'the guard for that action (skip_before_action :pf_authorize_action!, only: …), which the audit ' \
                    'does not see. Give each one a row in the Permission Sets that should run it; an action whose ' \
                    'name is not a valid action key needs a key first (permission_forge_actions actions: { ... }). ' \
                    'Or set unconfigured_action_strategy = :allow to let every signed-in user run them, as before 0.15.',
                    items: items)
          end
        end

        # The routes the catalog could not judge: the lists above may miss them.
        def actions_not_checked
          skipped = catalog.skipped
          count = skipped.size
          return if count.zero?

          finding(:low, :actions_not_checked, "#{count} #{'controller action'.pluralize(count)} could not be checked (see the log)",
                  'A controller failed to load, or the controller_action_resolver or the mapping raised, so the ' \
                  'audit could not tell whether these run the guard or what they map to. They are missing from ' \
                  'unmanaged_actions_refused (and the other action findings); at run time the same error fails the ' \
                  'request. Fix the error the log names and run the audit again.', items: skipped)
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
