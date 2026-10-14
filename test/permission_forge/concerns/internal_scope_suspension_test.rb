# frozen_string_literal: true

require 'test_helper'

# A user model whose callback looks a protected record up: host code the
# gem's own queries run (InvalidatesInBatch loads the holders of an
# assignment).
class PfLookupUser < ApplicationRecord
  self.table_name = 'users'

  class << self
    attr_accessor :lookup_id

    def lookups = (@lookups ||= [])
  end

  after_find { self.class.lookups << Customer.find_by(id: self.class.lookup_id) if self.class.lookup_id }
end

module PermissionForge
  module Concerns
    # The gem suspends the scoping for queries it makes for itself (find_by
    # and permission_scoped bodies, the holders an invalidation loads, the
    # users a cache clear walks, the records an audit event names). Those are
    # not the host's PermissionForge.without_permission_scope: host code they
    # run (callbacks, default scopes) gets no nobody-signed-in bypass, and
    # nothing is reported as scope_suspended.
    class InternalScopeSuspensionTest < ActiveSupport::TestCase
      ALLOWED_HOST_SUSPENSIONS = %w[
        lib/permission_forge/concerns/auto_permission_scoping.rb
        app/controllers/permission_forge/application_controller.rb
        app/controllers/permission_forge/audit_events_controller.rb
      ].freeze

      setup do
        Current.user = nil
        @customer = create_customer
        PermissionForge.configuration.nil_user_strategy = :deny
      end

      teardown do
        PfLookupUser.lookup_id = nil
        PfLookupUser.lookups.clear
      end

      test 'inside the gem suspension nobody signed in is not trusted' do
        AutoPermissionScoping.internally_suspended do
          assert PermissionForge.scope_suspended?
          assert AutoPermissionScoping.internally_suspended?
          assert_not AutoPermissionScoping.host_suspended?
          assert_nil Customer.find_by(id: @customer.id)
        end
      end

      test 'the gem suspension inside the host block, and the host block again after it' do
        PermissionForge.without_permission_scope do
          assert AutoPermissionScoping.host_suspended?
          AutoPermissionScoping.internally_suspended { assert_not AutoPermissionScoping.host_suspended? }
          assert AutoPermissionScoping.host_suspended?
          assert_equal @customer, Customer.find_by(id: @customer.id)
        end
      end

      test 'host code run while an invalidation loads the holders gets no bypass' do
        user = create_user
        PermissionForge.configuration.user_class = 'PfLookupUser'
        PfLookupUser.lookup_id = @customer.id

        create_permission_set.send(:assigned_users, [user.id])

        assert_equal [nil], PfLookupUser.lookups
      end

      # Both flags live in the same storage: a new fiber (Enumerator#next, a
      # fiber scheduler) sees neither, which fails closed.
      test 'a new fiber sees neither suspension' do
        PermissionForge.without_permission_scope do
          AutoPermissionScoping.internally_suspended do
            seen = Fiber.new do
              [PermissionForge.scope_suspended?, AutoPermissionScoping.internally_suspended?,
               AutoPermissionScoping.host_suspended?]
            end.resume
            assert_equal [false, false, false], seen
          end
        end
      end

      test 'the gem suspends the scoping only through the internal helper' do
        root = File.expand_path('../../..', __dir__)
        callers = Dir[File.join(root, '{app,lib}/**/*.rb')].select do |path|
          File.read(path).match?(/^[^#'"\n]*PermissionForge\.without_permission_scope[ ({]/) # code, not comments or strings
        end
        assert_empty callers.map { |path| path.delete_prefix("#{root}/") } - ALLOWED_HOST_SUSPENSIONS
      end
    end
  end
end
