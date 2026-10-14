# frozen_string_literal: true

# The suite's base configuration, taken once (after test_helper's
# `PermissionForge.configure`) and put back at the end of every test, so no
# setting a test changes can reach the next one — whether the test set an
# option, mutated a Hash or Array option in place, swapped the cache store
# (`reset_cache_store!`) or replaced the whole object (`PermissionForge.reset!`).
#
# Every instance variable of the configuration is kept: an option added to
# `Configuration` later is covered without a line here. A value is copied
# deeply (Hashes, Arrays, Strings, Sets) so an in-place change cannot reach
# the snapshot; frozen values, lambdas, classes and the cache store are kept
# by identity. A value of a type not listed below raises when the snapshot is
# taken: decide whether it can be shared before adding it.
module ConfigurationSnapshot
  # The memoized cache store: put back by identity (a test that swapped it
  # leaves the suite's MemoryCache in place again).
  CACHE_STORE = :@cache_store

  # Values that cannot be changed in place, so the snapshot shares them.
  SHARED = [NilClass, TrueClass, FalseClass, Symbol, Numeric, Proc, Method, Module, Regexp,
            ActiveSupport::Duration, ActiveSupport::Cache::Store, PermissionForge::Cache::Base].freeze

  # How the values that can be changed in place are copied.
  COPIERS = {
    Hash => ->(hash) { hash.dup.transform_values! { |item| copy(item) } },
    Array => ->(array) { array.map { |item| copy(item) } },
    Set => ->(set) { Set.new(set.map { |item| copy(item) }) },
    String => lambda(&:dup)
  }.freeze

  class << self
    # @param configuration [PermissionForge::Configuration]
    def take!(configuration = PermissionForge.configuration)
      @configuration = configuration
      @values = configuration.instance_variables.to_h do |name|
        value = configuration.instance_variable_get(name)
        [name, name == CACHE_STORE ? value : copy(value)]
      end
      @cache_store = @values[CACHE_STORE]
    end

    # Makes the snapshot's object `PermissionForge.configuration` again and
    # gives it exactly the snapshot's values. When the cache store changed,
    # what the old one memoized or owed is forgotten (as
    # `reset_cache_store!` does).
    def restore!
      store_changed = store_changed?
      put_back(@configuration)
      forget_store! if store_changed
      # The setters of the observed options (on_rule_bypass, audit_runtime_events…) tell the gate; this did not
      # go through them.
      PermissionForge::Audit::Gate.changed!
    end

    private

    def store_changed?
      !PermissionForge.configuration.equal?(@configuration) ||
        !@configuration.instance_variable_get(CACHE_STORE).equal?(@cache_store)
    end

    def put_back(configuration)
      PermissionForge.instance_variable_set(:@configuration, configuration)
      (configuration.instance_variables - @values.keys).each { |name| configuration.remove_instance_variable(name) }
      @values.each do |name, value|
        configuration.instance_variable_set(name, name == CACHE_STORE ? value : copy(value))
      end
    end

    def forget_store!
      PermissionForge.bump_permissions_cache_version!
      PermissionForge::Cache::Invalidation.reset!
    end

    def copy(value)
      return value if value.frozen? || SHARED.any? { |type| value.is_a?(type) }

      copier = COPIERS.find { |type, _| value.is_a?(type) }&.last
      raise ArgumentError, "ConfigurationSnapshot cannot copy a #{value.class}: share it (SHARED) or copy it (COPIERS)" unless copier

      copier.call(value)
    end
  end
end
