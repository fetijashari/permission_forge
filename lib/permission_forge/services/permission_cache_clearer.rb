# frozen_string_literal: true

module PermissionForge
  module Services
    # Removes every cached permission hash — this version's entries, the
    # previous versions' (Cache::UserKeys.namespaces), and the per-context
    # variants — for every user, in every tenant. The step to run once the
    # last process of the previous release is gone (0.14: an invalidation
    # made by 0.13 cannot reach this version's entries, and one made after
    # the clear would miss them again), and the way to revoke everything
    # cached at once. Every user then rebuilds on their next request: a cold
    # cache, one rebuild each. Two strategies, the first that works:
    #
    #   :pattern — the store removes keys by pattern (Redis, memory and file
    #     stores: Cache::Base#clear_entries): one call per namespace, nothing
    #     enumerated. How many users or tenants that reached is not known
    #     (the result and the events say so). On a Redis store the
    #     invalidation stamps go with the bare keys — a rebuild writes a new
    #     one, one in flight is not kept.
    #   :enumerated — otherwise (Memcached, Solid Cache): every id of the
    #     user model, in slices of Cache::HolderInvalidation::SLICE, through
    #     the bulk invalidation (one stamp write and one removal per slice),
    #     or through each user's own invalidate_permissions where the bulk
    #     path must not be used (HolderInvalidation.by_id?: a host override,
    #     a listener, a snapshot transaction); then the per-context variants
    #     an invalidation leaves (Cache::VariantRemoval: one read of the
    #     slice's index entries, and a stamp write and a removal for the
    #     users who had a variant stored). With tenancy on: once per tenant of the
    #     tenant model, the users as the host scopes them under that tenant
    #     (a user model that is not tenant-scoped is visited under every
    #     tenant: users × tenants), and once more without a tenant for the
    #     tenant-agnostic keys and users of no tenant. A user a host default
    #     scope hides under a tenant keeps that tenant's key until cache_ttl.
    #
    # @example
    #   result = PermissionCacheClearer.call(actor: 'ops: TCK-12', reason: 'deploy 0.14')
    #   # => { strategy: :enumerated, users: 240, tenants: 2, unconfirmed: 0 }
    #   # => { strategy: :pattern, users: nil, tenants: 2, unconfirmed: 0 }
    #
    # `users` counts visits (a user once per tenant); `unconfirmed` the ones
    # the cache store did not confirm (each also reported through
    # `config.on_cache_failure`, and owed). The audit log: one `cache.cleared`
    # event per tenant, in that tenant with that tenant's counts, plus one
    # without a tenant with the totals (`across_tenants`); under :pattern
    # the counts are not known and the events say `counted: false`. Every
    # event says `process_local: true` when the store lives in this process
    # only (a memory store, Cache::Base#process_local?): the clear then did
    # not reach the web and job processes, and the audit log says so.
    # `actor:` and `reason:` as the other housekeeping services (rake:
    # ACTOR=, REASON=).
    #
    # @api public
    class PermissionCacheClearer
      include Concerns::AuditedOperation

      EVENT = 'cache.cleared'
      SLICE = Cache::HolderInvalidation::SLICE

      # Clears every cached permission hash (see the class comment).
      #
      # @param actor [Object, nil] who runs it, for the cache.cleared events
      # @param reason [String, nil] why
      # @return [Hash] strategy:, users:, tenants:, unconfirmed:
      def self.call(...) = new(...).call

      def initialize(actor: nil, reason: nil)
        @actor = actor
        @reason = reason
      end

      # @return [Hash] strategy:, users:, tenants:, unconfirmed:
      def call
        audited(actor: @actor, reason: @reason) { clear }
      end

      private

      def clear
        result = clear_by_pattern || clear_by_enumeration
        # retire every memo in this process, as an invalidation does
        PermissionForge.bump_permissions_cache_version!
        result
      end

      # @return [Hash, nil] nil when the store cannot remove by pattern
      def clear_by_pattern
        cache = PermissionForge.cache
        return unless Cache::UserKeys.namespaces.all? { |namespace| cache.clear_entries(namespace) }

        tenant_ids = tenants.map(&:id)
        tenant_ids.each { |tenant_id| record(tenant_id, strategy: :pattern, counted: false, unconfirmed: 0) }
        record_without_tenant(strategy: :pattern, counted: false, unconfirmed: 0, tenants: tenant_ids.size)
        { strategy: :pattern, users: nil, tenants: tenant_ids.size, unconfirmed: 0 }
      end

      def clear_by_enumeration
        totals = { strategy: :enumerated, users: 0, tenants: 0, unconfirmed: 0 }
        tenants.each { |tenant| add_counts(totals, clear_tenant(tenant), tenants: 1) }
        add_counts(totals, without_tenant { invalidate_everyone(nil) })
        record_without_tenant(**totals)
        totals
      end

      # One tenant's users, under that tenant, and its event.
      def clear_tenant(tenant)
        counts = PermissionForge.with_ambient_tenant(tenant) { invalidate_everyone(tenant.id) }
        record(tenant.id, strategy: :enumerated, **counts)
        counts
      end

      def add_counts(totals, counts, **more)
        totals.merge!(counts, more) { |_key, total, count| total + count }
      end

      # Every user the model lists here, in slices, by id where that is
      # allowed and through each user's invalidate_permissions where not.
      #
      # @return [Hash] users:, unconfirmed:
      def invalidate_everyone(tenant_id)
        model = PermissionForge.configuration.user_model
        by_id = Cache::HolderInvalidation.by_id?(model)
        counts = { users: 0, unconfirmed: 0 }
        users_scope(model, tenant_id).in_batches(of: SLICE) do |batch|
          ids = batch.pluck(model.primary_key)
          counts[:users] += ids.size
          counts[:unconfirmed] += by_id ? by_id(ids, tenant_id).size : one_by_one(batch, tenant_id)
        end
        counts
      end

      # The invalidation leaves the variants to their TTL; they hold the
      # profile, so the clear removes them too.
      #
      # @return [Array] the ids the store did not confirm
      def by_id(ids, tenant_id)
        Cache::HolderInvalidation.call(user_ids: ids, tenant_id: tenant_id) | Cache::VariantRemoval.call(user_ids: ids, tenant_id: tenant_id)
      end

      # @return [Integer] how many the store did not confirm
      def one_by_one(batch, tenant_id)
        batch.reject do |user|
          Cache::Failure.none? do
            user.invalidate_permissions(tenant_id: tenant_id)
            Cache::VariantRemoval.call(user_ids: [user.id], tenant_id: tenant_id, ambient_key: user.permission_cache_key)
          end
        end.size
      end

      # Under a tenant: the users as the host scopes them (a tenant-scoped
      # user model lists that tenant's). Without one: everyone.
      def users_scope(model, tenant_id)
        PermissionForge::Concerns::AutoPermissionScoping.internally_suspended { tenant_id ? model.all : model.unscoped }
      end

      # The tenants of the tenant model, when tenancy is on; none otherwise.
      def tenants
        return [] unless PermissionForge.configuration.tenant_enabled?

        @tenants ||= PermissionForge.configuration.tenant_model.constantize.unscoped.to_a
      end

      def without_tenant(&)
        defined?(ActsAsTenant) ? ActsAsTenant.without_tenant(&) : yield
      end

      # `process_local`: the store lives in this process only (a memory
      # store), so the clear did not reach the web and job processes.
      def record(tenant_id, **data)
        data = data.transform_keys(&:to_s).merge('operation' => 'cache_clear', 'process_local' => process_local?)
        PermissionForge::Audit.record(EVENT, tenant_id: tenant_id, data: data)
      end

      def process_local?
        @process_local = PermissionForge.cache.process_local? if @process_local.nil?
        @process_local
      end

      # The event without a tenant — recorded with none ambient, so it is one.
      def record_without_tenant(**data)
        without_tenant { record(nil, **data, across_tenants: true) }
      end
    end
  end
end
