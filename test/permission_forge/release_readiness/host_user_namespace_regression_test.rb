# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module ReleaseReadiness
    # Pre-release review, code-quality lane, CQ-N1: the PermissionedUser
    # concerns put their private helpers into the host's User class, where a
    # host method of the same name wins over the gem's. With names such as
    # `read_permissions` or `context_hash` a host helper broke every cache
    # hit, or made an MFA-gated set apply without the flag. Every private
    # method the gem adds to the User class is `pf_`-prefixed now.
    class HostUserNamespaceRegressionTest < ActiveSupport::TestCase
      # Unprefixed private methods the gem still defines, and why. The gem
      # never calls these itself, so a host method of the same name cannot
      # change what it does.
      ALLOWED = {
        # 0.13 name, called with `send` by host code; delegates to
        # pf_active_non_expired_permission_sets. Drop in 1.0.
        active_non_expired_permission_sets: 'compatibility alias'
      }.freeze

      # The private helpers of 0.14 before the rename (the review's list).
      FORMER_NAMES = %i[
        build_permission_entry check_resource_permission clear_permissions_memo conditional_set_ttl context_hash
        destroy_in_own_tenant destroy_permission_rows_in_other_tenants guarding_permission_build invalidation_stamp_key
        kept_permissions_memo memoize_permissions memoize_selected_permissions memoized_permissions
        memoized_permissions_for_context permission_cache_ttl read_permissions read_shared_permissions read_through_build
        rebuild_permission_entry rebuild_permissions rebuild_permissions_read_through rebuild_variant_read_through
        report_rebuilt resolve_request_context resource_name_permissions resource_permissions select_shared_permissions
        settle_permissions_after_commit shared_or_rebuilt_permissions soonest_expiry_ttl withhold_permissions_in
        withholding_permissions?
      ].freeze

      teardown do
        PermissionForge.configuration.request_context_resolver = -> { {} }
      end

      # The concerns of any protected model, which a test may have applied to
      # User as to any model: not PermissionedUser's.
      MODEL_CONCERNS = /\APermissionForge::Concerns::(MaskedAttributes|PermissionScopedFindable|AutoPermissionScoping)\b/

      # The modules PermissionedUser brings into the User class.
      def gem_modules
        User.ancestors.select { |mod| mod.name.to_s.start_with?('PermissionForge::') && !mod.name.match?(MODEL_CONCERNS) }
      end

      # A User whose own methods carry every name the gem used to call: any
      # of them reached from the gem raises.
      def colliding_user_class
        Class.new(User) do
          def self.name = 'User'

          FORMER_NAMES.each do |name|
            define_method(name) { |*| raise "the gem called the host's #{name}" }
          end
          define_method(:active_non_expired_permission_sets) { |*| raise 'the gem called the compatibility alias' }
        end
      end

      test 'CQ-N1 every private method the PermissionedUser concerns add to the User class is pf_-prefixed' do
        assert_includes gem_modules, PermissionForge::Concerns::PermissionCacheAccessor

        private_methods = gem_modules.flat_map { |mod| mod.private_instance_methods(false) + mod.protected_instance_methods(false) }
        unprefixed = private_methods.uniq.reject { |name| name.start_with?('pf_') } - ALLOWED.keys

        assert_empty unprefixed.sort, 'a private gem method without the pf_ prefix lands in the host User class'
      end

      # The documented public API, exactly: a helper that lost its
      # `private` would be a new unprefixed method on the host User.
      PUBLIC_API = %i[
        permissions_hash regenerate_permissions invalidate_permissions permission_cache_key permission_invalidation_stamp
        can? can_read? can_show? has_read_access? can_create? can_create_new? has_create_access? can_edit? can_update?
        has_edit_access? can_delete? can_destroy? has_delete_access? can_view_all? can_modify_all?
        permissions_for permissions_hash_for masked_field? mask_strategy_for field_permissions reload
      ].freeze

      test 'CQ-N1 the public methods the concerns add are exactly the documented API' do
        public_methods = gem_modules.flat_map { |mod| mod.public_instance_methods(false) }.uniq

        assert_equal PUBLIC_API.sort, public_methods.sort
      end

      test 'CQ-N1 host methods named like the former private helpers change nothing, built or read from the cache' do
        person = create_user
        set = create_permission_set
        create_permission_set_user(user: person, permission_set: set)
        create_resource(permission_set: set, name: 'Customer', read_access: true)
        klass = colliding_user_class

        assert klass.find(person.id).can_read?(:Customer), 'built'
        assert klass.find(person.id).can_read?(:Customer), 'read from the cache'
        assert_not klass.find(person.id).can_delete?(:Customer)
        assert klass.find(person.id).invalidate_permissions
      end

      test 'CQ-N1 a host context_hash does not make an MFA-gated set apply without the flag' do
        person = create_user
        set = create_permission_set(requires_session_flag: 'mfa_verified')
        create_permission_set_user(user: person, permission_set: set)
        create_resource(permission_set: set, name: 'Customer', read_access: true, delete_access: true)
        PermissionForge.configuration.request_context_resolver = -> { { ip: '203.0.113.9', session_flags: [] } }
        klass = Class.new(User) do
          def self.name = 'User'

          def context_hash(*) = {}
        end

        assert_not klass.find(person.id).can_delete?(:Customer)
        PermissionForge.configuration.request_context_resolver = -> { { ip: '203.0.113.9', session_flags: ['mfa_verified'] } }
        assert klass.find(person.id).can_delete?(:Customer)
      end

      test 'CQ-N1 destroying a user with host methods of the former names still removes their rows' do
        person = create_user
        create_permission_set_user(user: person, permission_set: create_permission_set)

        colliding_user_class.find(person.id).destroy!

        assert_not PermissionForge::PermissionSetUser.unscoped.exists?(user_id: person.id)
      end

      test 'CQ-N1 the compatibility alias answers what the gem builds from' do
        person = create_user
        set = create_permission_set
        create_permission_set_user(user: person, permission_set: set)

        assert_equal [set.id], person.send(:active_non_expired_permission_sets).map(&:id)
      end
    end
  end
end
