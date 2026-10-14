require 'test_helper'

# Test-local stand-ins for host controllers, found by constant name
# ("pf_stub_guarded" → PfStubGuardedController) — the one set every test that
# needs a controller catalog uses, so no test depends on what the dummy app's
# own controllers include.
#
# Guard detection (ControllerActions.guarded?) reads the class's
# pf_action_guard_options and its before_action chain: a real controller.
class PfStubGuardedController < ActionController::Base
  include PermissionForge::Concerns::ControllerActionGuard

  permission_forge_actions resource: 'Customer', actions: { refresh: :sync }
end

PfStubPlainController = Class.new

# Includes the guard, then switches it off for every action: not guarded.
class PfStubSkippingController < ActionController::Base
  include PermissionForge::Concerns::ControllerActionGuard

  skip_before_action :pf_authorize_action!
end

module PermissionForge
  module Admin
    module ActionCatalogSupport
      STUB_RESOLVER = ->(path, _action) { %w[Customer merge] if path == 'pf_stub_plain' }

      # A catalog over three routes that map to Customer: `export` and
      # `archive` on a guarded controller, `merge` on one without the guard.
      # guarded: false leaves only the unguarded controller.
      def stub_catalog(guarded: true)
        catalog_over do
          if guarded
            get 'stub/export', to: 'pf_stub_guarded#export'
            post 'stub/:id/archive', to: 'pf_stub_guarded#archive'
          end
          post 'stub/:id/merge', to: 'pf_stub_plain#create'
        end
      end

      # A catalog over the routes drawn in the block, mapped by `resolver`.
      def catalog_over(resolver: STUB_RESOLVER, &)
        PermissionForge.configuration.controller_action_resolver = resolver
        ControllerCatalog.new(routes: ActionDispatch::Routing::RouteSet.new.tap { |set| set.draw(&) })
      end

      # Makes every ControllerCatalog.new inside the block answer `catalog`
      # (the admin controllers build their own).
      def with_catalog(catalog)
        ControllerCatalog.define_singleton_method(:new) { |**| catalog }
        yield
      ensure
        ControllerCatalog.singleton_class.send(:remove_method, :new)
      end

      def discovery_on!
        PermissionForge.configuration.controller_action_discovery = true
      end

      # Runs the block and returns how many SQL statements it asked for. Schema
      # lookups and transaction control are not counted; statements answered
      # from the query cache are, so the count does not depend on what an
      # earlier request left in the cache.
      def count_sql(&)
        count = 0
        counter = lambda do |_name, _start, _finish, _id, payload|
          count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name])
        end
        ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
        count
      end
    end
  end
end
