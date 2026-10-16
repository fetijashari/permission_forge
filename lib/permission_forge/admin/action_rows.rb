# frozen_string_literal: true

module PermissionForge
  module Admin
    # One row per action on a Resource page: configured ResourceActions and —
    # while controller_action_discovery is on — the app's controller actions
    # that map to the resource but have no row in this set yet.
    #
    # Each row carries where the action runs (endpoints, with whether that
    # controller runs the action guard) and what the saved configuration
    # means right now for people with this set (effect).
    #
    # @example
    #   rows = ActionRows.new(resource)
    #   rows.configured_rows.map(&:name)  # => ['export']
    #   rows.discovered_rows.map(&:name)  # => ['archive', 'merge']
    #   rows.row('archive').effect        # => :unmanaged_allowed
    class ActionRows
      # endpoints: ControllerCatalog::Entry list (empty while discovery is off).
      # unlinked:  configured, but no controller action maps to it — normal for
      #            an action the app checks in code with can?.
      # standing:  what the row means right now (see Standing).
      Row = Struct.new(:name, :label, :action, :endpoints, :unlinked, :standing, keyword_init: true) do
        delegate :effect, :permitted_by, to: :standing

        def configured? = !action.nil?
        # The label is the key itself (ActionLabel): drawn once, in <code>.
        def verbatim? = label == name
      end

      # What one action means right now for people with this set, and which
      # sets permit it. The other Permission Sets are only read when a row is
      # asked for it: the Actions tab shows it only while discovery is on.
      #
      # effect:
      #   :permitted          this set permits it
      #   :not_permitted      this set has a row that does not permit it
      #   :blocked            this muting set blocks it
      #   :unchanged          this muting set has a row that does not block it
      #   :managed_elsewhere  no row in effect here, and another set manages it
      #   :unmanaged_allowed  no set manages it — everyone can run it
      #   :unmanaged_blocked  no set manages it — blocked until a set permits it
      class Standing
        # @param action [PermissionForge::ResourceAction, nil] this set's row
        def initialize(key, action, across:, configuration:)
          @key = key
          @action = action
          @across = across
          @configuration = configuration
        end

        def effect
          @effect ||= @action&.in_effect? ? row_effect : effect_without_row
        end

        # @return [Array<PermissionForge::PermissionSet>] granting sets that
        #   permit the action right now
        def permitted_by
          @permitted_by ||= @across.permitting_sets(@key)
        end

        private

        # This set's row is in effect. In a muting set is_permitted means "block".
        def row_effect
          flagged = @action.is_permitted
          if @action.resource.permission_set.is_muting
            flagged ? :blocked : :unchanged
          else
            flagged ? :permitted : :not_permitted
          end
        end

        # No row in effect here: another set manages it, or nobody does.
        def effect_without_row
          return :managed_elsewhere if @across.managed?(@key)

          @configuration.allow_unconfigured_actions? ? :unmanaged_allowed : :unmanaged_blocked
        end
      end

      def initialize(resource, catalog: nil, configuration: PermissionForge.configuration,
                     across: ActionAcrossSets.new(resource.name))
        @resource = resource
        @catalog = catalog
        @configuration = configuration
        @across = across
      end

      # @return [Boolean] whether the app's controller actions are listed
      def discovery?
        @configuration.controller_action_discovery?
      end

      # @return [Array<Row>] configured rows, then discovered ones, each by key
      def rows
        @rows ||= configured_rows + discovered_rows
      end

      def configured_rows
        @configured_rows ||= saved_actions.sort_by(&:name).map { |action| build_row(action.name, action) }
      end

      # Controller actions that map to the resource and have no row in this set.
      def discovered_rows
        @discovered_rows ||= (endpoints_by_key.keys - configured_names).sort.map { |key| build_row(key, nil) }
      end

      def row(name)
        key = name.to_s
        rows.find { |row| row.name == key }
      end

      # Discovered keys with no row yet, offered on the free-text "new action" form.
      def suggestions
        discovered_rows.map(&:name)
      end

      # @return [Boolean] whether any of the app's listed controllers runs the
      #   action guard (false: nothing here is enforced at runtime)
      def any_guarded?
        catalog.any_guarded?
      end

      # This action (by key) in every Permission Set containing the resource.
      def across_sets(key)
        @across.rows(key)
      end

      private

      def catalog
        @catalog ||= ControllerCatalog.new(configuration: @configuration)
      end

      # Rows a form built on the association but has not saved are not configured.
      def saved_actions
        @resource.resource_actions.select(&:persisted?)
      end

      def configured_names
        saved_actions.map(&:name)
      end

      # { 'export' => [ControllerCatalog::Entry, ...] }; empty while discovery is off.
      def endpoints_by_key
        @endpoints_by_key ||= discovery? ? catalog.for_resource(@resource.name).group_by(&:key) : {}
      end

      def build_row(key, action)
        endpoints = endpoints_by_key.fetch(key, [])
        Row.new(name: key, label: ActionLabel.for(action, key).text, action: action, endpoints: endpoints,
                unlinked: discovery? && endpoints.empty?,
                standing: Standing.new(key, action, across: @across, configuration: @configuration))
      end
    end
  end
end
