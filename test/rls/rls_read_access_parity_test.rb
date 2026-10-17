# frozen_string_literal: true

require 'test_helper'
require_relative '../permission_forge/sti_models'

# Level 3 — the read-access gate of an RLS policy follows
# config.no_read_access_strategy, as RecordReadAccess does in the app layer.
#
# Runs ONLY against PostgreSQL (`DB=postgres bundle exec rake test:rls`). Each
# case is played under both values: the rows the app layer's
# permission_scoped returns are compared with the rows a plain role reads
# through the synced policy (`RLS.with_user`). Under :rules_only the policy
# applies the rules alone (a user without read gets every row, as in the app
# layer); under :deny a session user without read access to the model's
# Resource chain sees no row. The STI family (PfStiTicket > PfStiBugTicket >
# PfStiUrgentBugTicket) shares one table: a policy is per table, so a read
# through the base class can be wider in the app layer than in the policy,
# never the other way round.
class RlsReadAccessParityTest < ActiveSupport::TestCase
  APP_ROLE = 'permission_forge_app'
  STRATEGIES = %i[rules_only deny].freeze
  ALL = %w[bug plain urgent].freeze

  setup do
    skip 'PostgreSQL-only enforcement suite (DB=postgres rake test:rls)' unless self.class.postgres?

    @user = create_user
    @other = create_user
    PfStiTicket.create!(title: 'plain', owner: @user)
    PfStiBugTicket.create!(title: 'bug', owner: @other)
    PfStiUrgentBugTicket.create!(title: 'urgent', owner: @user)
  end

  teardown do
    connection.execute('RESET ROLE') if self.class.postgres?
  end

  def self.postgres?
    ActiveRecord::Base.connection.adapter_name.match?(/postgresql/i)
  end

  test 'a user with no entry for the model: every row under :rules_only, none under :deny, in both layers' do
    holds(name: 'Customer', read_access: true)

    assert_both_layers(rules_only: ALL, deny: [])
  end

  test 'an entry without read: every row under :rules_only, none under :deny, in both layers' do
    holds(name: 'PfStiTicket', read_access: false)

    assert_both_layers(rules_only: ALL, deny: [])
  end

  test 'View All never stands in for read: an entry with View All and no read sees nothing under :deny, in both layers' do
    holds(name: 'PfStiTicket', read_access: false, view_all: true)

    assert_both_layers(rules_only: ALL, deny: [])
  end

  test 'read removed by a Muting Permission Set: none under :deny, in both layers' do
    holds(name: 'PfStiTicket', read_access: true)
    holds(name: 'PfStiTicket', read_access: true, muting: true)

    assert_both_layers(rules_only: ALL, deny: [])
  end

  test 'a user with read: the rows the rules select under both values, in both layers' do
    resource = holds(name: 'PfStiTicket', read_access: true)
    create_permission_set_rule(permission_set: resource.permission_set, resource: resource, name: 'Own tickets',
                               field_name: 'owner_id', operator: 'equal', field_value: 'current_user', include_nulls: false)

    assert_both_layers(rules_only: %w[plain urgent], deny: %w[plain urgent])
  end

  test 'read granted only by a conditional set: the policy, which cannot judge the condition, is never the wider' do
    holds(name: 'PfStiTicket', read_access: true, set: { allowed_ips: '10.0.0.0/8' })

    each_strategy do |strategy|
      app, policy = layers(PfStiTicket)

      assert_equal(strategy == :deny ? [] : ALL, policy, strategy.to_s)
      assert_empty policy - app, "#{strategy}: never wider than the app layer"
    end
  end

  # The subclass's own entry takes read away: the app layer refuses the
  # subclass reads and keeps the base class's; the policy hides the
  # subclass's rows, which a read through the base class shows.
  test 'STI: a subclass entry without read hides its rows (and its subclasses) under :deny' do
    holds(name: 'PfStiTicket', read_access: true, others: [{ name: 'PfStiBugTicket', read_access: false }])

    each_strategy do |strategy|
      if strategy == :deny
        assert_sti_layers(base: [ALL, %w[plain]], bug: [[], []], urgent: [[], []])
      else
        assert_sti_layers(base: [ALL, ALL], bug: [%w[bug urgent], %w[bug urgent]], urgent: [%w[urgent], %w[urgent]])
      end
    end
  end

  test 'STI: an unreadable base denies the subclass that grants read itself, in both layers' do
    holds(name: 'PfStiTicket', read_access: false, others: [{ name: 'PfStiBugTicket', read_access: true }])

    each_strategy do |strategy|
      if strategy == :deny
        assert_sti_layers(base: [[], []], bug: [[], []], urgent: [[], []])
      else
        assert_sti_layers(base: [ALL, ALL], bug: [%w[bug urgent], %w[bug urgent]], urgent: [%w[urgent], %w[urgent]])
      end
    end
  end

  test 'STI: a muted base reaches the subclass entries, in both layers' do
    holds(name: 'PfStiTicket', read_access: true, others: [{ name: 'PfStiBugTicket', read_access: true }])
    holds(name: 'PfStiTicket', read_access: true, muting: true)

    each_strategy do |strategy|
      if strategy == :deny
        assert_sti_layers(base: [[], []], bug: [[], []], urgent: [[], []])
      else
        assert_sti_layers(base: [ALL, ALL], bug: [%w[bug urgent], %w[bug urgent]], urgent: [%w[urgent], %w[urgent]])
      end
    end
  end

  # A muting row naming the subclass reaches the subclass's entries only: with
  # no entry of its own the subclass reads as its base in both layers.
  test 'STI: a muted subclass without an entry of its own reads as its base, in both layers' do
    holds(name: 'PfStiTicket', read_access: true)
    holds(name: 'PfStiBugTicket', read_access: true, muting: true)

    each_strategy do
      assert_sti_layers(base: [ALL, ALL], bug: [%w[bug urgent], %w[bug urgent]], urgent: [%w[urgent], %w[urgent]])
    end
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  # A set holding @user with a Resource row of these flags (and other rows).
  def holds(name:, muting: false, set: {}, others: [], **flags)
    permission_set = create_permission_set(name: "Set #{SecureRandom.hex(3)}", is_muting: muting, **set)
    create_permission_set_user(user: @user, permission_set: permission_set)
    others.each { |attrs| create_resource(permission_set: permission_set, **attrs) }
    create_resource(permission_set: permission_set, name: name, **flags)
  end

  # Syncs the policies under each value and yields it.
  def each_strategy
    STRATEGIES.each do |strategy|
      PermissionForge.configuration.no_read_access_strategy = strategy
      PermissionForge::RLS.sync!
      grant_app_role
      yield strategy
    end
  end

  def assert_both_layers(expected)
    each_strategy do |strategy|
      app, policy = layers(PfStiTicket)

      assert_equal expected.fetch(strategy), app, "#{strategy}: the app layer"
      assert_equal app, policy, "#{strategy}: the policy selects what the app layer selects"
    end
  end

  # Per class: [app layer, policy]; the policy is never wider than the app
  # layer read through the same class.
  def assert_sti_layers(base:, bug:, urgent:)
    { PfStiTicket => base, PfStiBugTicket => bug, PfStiUrgentBugTicket => urgent }.each do |klass, expected|
      app, policy = layers(klass)

      assert_equal expected, [app, policy], klass.name
      assert_empty policy - app, "#{klass.name}: never wider than the app layer"
    end
  end

  # [what permission_scoped returns, what a plain role reads through the policy]
  def layers(klass)
    User.find(@user.id).regenerate_permissions
    Current.user = User.find(@user.id)
    app = klass.permission_scoped.pluck(:title).sort
    policy = as_app_role { PermissionForge::RLS.with_user(@user) { klass.unscoped.pluck(:title) } }.sort
    [app, policy]
  end

  def grant_app_role
    connection.execute(<<~SQL)
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{APP_ROLE}') THEN
          CREATE ROLE #{APP_ROLE};
        END IF;
      END
      $$;
    SQL
    connection.execute("GRANT USAGE ON SCHEMA public TO #{APP_ROLE}")
    connection.execute("GRANT SELECT ON ALL TABLES IN SCHEMA public TO #{APP_ROLE}")
  end

  # Policies do not apply to a superuser, so the rows are read as a plain role.
  def as_app_role
    connection.execute("SET ROLE #{APP_ROLE}")
    yield
  ensure
    connection.execute('RESET ROLE')
  end
end
