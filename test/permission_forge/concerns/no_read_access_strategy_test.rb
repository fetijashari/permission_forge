# frozen_string_literal: true

require 'test_helper'
require_relative '../sti_models'

module PermissionForge
  module Concerns
    # config.no_read_access_strategy: what the record reads (find_by,
    # find_by!, permission_scoped, the default scope under
    # auto_query_scoping) do for a signed-in user whose entries for the
    # model's Resource chain do not grant read_access. :rules_only (the
    # default) applies the rules alone — no rules, every row; :deny (the
    # strict preset) answers no rows, and find_by / find_by! raise
    # NotAuthorizedError for an existing record. One definition:
    # PermissionForge::RecordReadAccess.
    class NoReadAccessStrategyTest < ActiveSupport::TestCase
      NotAuthorized = PermissionScopedFindable::NotAuthorizedError
      NO_READ_MESSAGE = 'You do not have permission to read Customer records.'

      setup do
        @owner = create_user
        @mine = create_customer(supplier_id: @owner.id)
        @theirs = create_customer(supplier_id: @owner.id + 999)
        @all_ids = [@mine.id, @theirs.id].sort
      end

      def strategy!(value)
        PermissionForge.configuration.no_read_access_strategy = value
      end

      # A user holding one set with a Customer Resource of these flags and
      # the "own customers" rule; nil flags: no Customer Resource at all
      # (the set has a Supplier one, so the user holds something).
      def user_with(customer: nil, rule: true, user: @owner)
        set = create_permission_set
        create_permission_set_user(user: user, permission_set: set)
        if customer
          resource = create_resource(permission_set: set, name: 'Customer', **customer)
          if rule
            create_permission_set_rule(permission_set: set, resource: resource, name: 'Own customers', field_name: 'supplier_id',
                                       operator: 'equal', field_value: 'current_user', include_nulls: false)
          end
        else
          create_resource(permission_set: set, name: 'Supplier', read_access: true)
        end
        user.regenerate_permissions
        Current.user = User.find(user.id)
      end

      def scoped_ids = Customer.permission_scoped.pluck(:id).sort

      def filter_only
        PermissionForge.configuration.auto_query_scoping = :filter_only
        yield
      ensure
        PermissionForge.configuration.auto_query_scoping = :off
      end

      def denied_by_find_by(record)
        error = assert_raises(NotAuthorized) { Customer.find_by(id: record.id) }
        assert_raises(NotAuthorized) { Customer.find_by!(id: record.id) }
        error
      end

      # --- the option ---------------------------------------------------------

      test 'the library default is :rules_only, the strict preset :deny' do
        assert_equal :rules_only, Configuration.new.no_read_access_strategy
        assert_not Configuration.new.deny_record_reads_without_read_access?

        strict = Configuration.new
        strict.preset = :strict
        assert_equal :deny, strict.no_read_access_strategy
        assert_predicate strict, :deny_record_reads_without_read_access?
      end

      # --- a user with no entry for the model ------------------------------------

      test 'no entry, :rules_only: every read returns every row, as before' do
        user_with(customer: nil)

        assert_equal @all_ids, scoped_ids
        assert_equal @theirs, Customer.find_by(id: @theirs.id)
        assert_equal @theirs, Customer.find_by!(id: @theirs.id)
        filter_only { assert_equal @all_ids, Customer.pluck(:id).sort }
      end

      test 'no entry, :deny: no rows, find_by raises with the locale message, a missing record is still missing' do
        strategy!(:deny)
        user_with(customer: nil)

        assert_empty scoped_ids
        error = denied_by_find_by(@theirs)
        assert_equal [NO_READ_MESSAGE], error.failure_messages
        assert_equal NO_READ_MESSAGE, error.message
        assert_equal @theirs.id, error.record_id
        assert_equal Current.user, error.user
        assert_nil Customer.find_by(id: -1)
        assert_raises(ActiveRecord::RecordNotFound) { Customer.find_by!(id: -1) }
      end

      test 'the denial message follows the locale' do
        strategy!(:deny)
        user_with(customer: nil)

        %i[sq mk].each do |locale|
          I18n.with_locale(locale) do
            expected = I18n.t('permission_forge.denials.no_read_access', resource: 'Customer')
            assert_not_equal NO_READ_MESSAGE, expected, locale
            assert_equal [expected], denied_by_find_by(@mine).failure_messages
          end
        end
      end

      test 'a denial is access.denied with reason no_read_access, on every path' do
        strategy!(:deny)
        user_with(customer: nil)

        denied_by_find_by(@theirs)
        assert_audit_event('access.denied', record_id: @theirs.id.to_s,
                                            data: { 'reason' => 'no_read_access', 'via' => 'find_by', 'messages' => [NO_READ_MESSAGE] })
        Customer.permission_scoped.to_a
        assert_audit_event('access.denied', data: { 'reason' => 'no_read_access', 'via' => 'permission_scoped' })
        filter_only { Customer.count }
        assert_audit_event('access.denied', data: { 'reason' => 'no_read_access', 'via' => 'auto_scope' })
      end

      # --- an entry without read --------------------------------------------------

      test 'an entry without read, :rules_only: its rules apply, nothing more' do
        user_with(customer: { read_access: false })

        assert_not Current.user.can_read?(:Customer)
        assert_equal [@mine.id], scoped_ids
        assert_equal @mine, Customer.find_by(id: @mine.id)
      end

      test 'an entry without read, :deny: no rows, even the ones its rules allow' do
        strategy!(:deny)
        user_with(customer: { read_access: false })

        assert_empty scoped_ids
        assert_equal [NO_READ_MESSAGE], denied_by_find_by(@mine).failure_messages
        filter_only { assert_empty Customer.all.to_a }
      end

      test 'read taken away by a Muting Permission Set counts as no read under :deny' do
        strategy!(:deny)
        muting = create_permission_set(name: 'Lockdown', is_muting: true)
        create_resource(permission_set: muting, name: 'Customer', read_access: true)
        create_permission_set_user(user: @owner, permission_set: muting)
        user_with(customer: { read_access: true })

        assert_not Current.user.can_read?(:Customer)
        assert_empty scoped_ids
      end

      # --- a user with read: unchanged ----------------------------------------------

      %i[rules_only deny].each do |value|
        test "a user with read gets what the rules allow under :#{value}" do
          strategy!(value)
          user_with(customer: { read_access: true })

          assert_equal [@mine.id], scoped_ids
          assert_equal @mine, Customer.find_by(id: @mine.id)
          error = assert_raises(NotAuthorized) { Customer.find_by(id: @theirs.id) }
          assert_not_includes error.failure_messages, NO_READ_MESSAGE
          filter_only { assert_equal [@mine.id], Customer.pluck(:id) }
        end

        test "View All with read skips the rules under :#{value}" do
          strategy!(value)
          user_with(customer: { read_access: true, view_all: true })

          assert_equal @all_ids, scoped_ids
          assert_equal @theirs, Customer.find_by(id: @theirs.id)
          filter_only { assert_equal @all_ids, Customer.pluck(:id).sort }
        end
      end

      test 'View All or Modify All without read gives no bypass under :deny' do
        strategy!(:deny)
        user_with(customer: { read_access: true, view_all: true, modify_all: true })
        PermissionForge::Resource.find_by!(name: 'Customer').update_columns(read_access: false)
        @owner.invalidate_permissions
        Current.user = User.find(@owner.id)

        assert_empty scoped_ids
        denied_by_find_by(@theirs)
      end

      # --- nobody signed in: nil_user_strategy, unchanged -----------------------------

      test 'with nobody signed in nil_user_strategy decides, whatever this option says' do
        strategy!(:deny)
        Current.user = nil

        assert_equal @all_ids, scoped_ids
        assert_equal @theirs, Customer.find_by(id: @theirs.id)
        filter_only { assert_equal @all_ids, Customer.pluck(:id).sort }

        PermissionForge.configuration.nil_user_strategy = :deny
        assert_empty scoped_ids
        assert_nil Customer.find_by(id: @theirs.id)
      end

      # --- where the rules are lifted ---------------------------------------------------

      test 'without_permission_scope lifts the default scope; a signed-in find_by and permission_scoped keep the check, as the rules' do
        strategy!(:deny)
        user_with(customer: nil)

        filter_only do
          PermissionForge.without_permission_scope do
            assert_equal @all_ids, Customer.pluck(:id).sort
            assert_empty scoped_ids
            denied_by_find_by(@theirs)
          end
        end
      end

      test 'without_permission_scope with nobody signed in finds every row under :deny' do
        strategy!(:deny)
        PermissionForge.configuration.nil_user_strategy = :deny
        Current.user = nil

        PermissionForge.without_permission_scope do
          assert_equal @all_ids, scoped_ids
          assert_equal @theirs, Customer.find_by(id: @theirs.id)
        end
      end

      test "the gem's own suspension lifts the default scope" do
        strategy!(:deny)
        user_with(customer: nil)

        filter_only do
          assert_empty Customer.pluck(:id)
          AutoPermissionScoping.internally_suspended { assert_equal @all_ids, Customer.pluck(:id).sort }
        end
      end

      # --- the default scope under :filter_only ---------------------------------------------

      test 'the default scope: every relation of a user without read is empty under :deny, unscoped under :rules_only' do
        user_with(customer: nil)
        filter_only do
          assert_equal 2, Customer.count
          assert Customer.where(id: @theirs.id).exists?

          strategy!(:deny)
          assert_equal 0, Customer.count
          assert_not Customer.where(id: @theirs.id).exists?
          assert_raises(ActiveRecord::RecordNotFound) { Customer.find(@theirs.id) }
        end
      end

      # --- single-table inheritance ---------------------------------------------------------

      test 'STI: a subclass reads as its base without an entry of its own, and an unreadable entry along the chain denies' do
        strategy!(:deny)
        set = create_permission_set
        create_permission_set_user(user: @owner, permission_set: set)
        create_resource(permission_set: set, name: 'PfStiTicket', read_access: true)
        bug = PfStiBugTicket.create!(title: 'Bug', owner: @owner)
        @owner.regenerate_permissions
        Current.user = User.find(@owner.id)

        assert_equal [bug.id], PfStiTicket.permission_scoped.pluck(:id)
        assert_equal [bug.id], PfStiBugTicket.permission_scoped.pluck(:id), 'no entry of its own: its base decides'

        create_resource(permission_set: set, name: 'PfStiBugTicket', read_access: false)
        @owner.regenerate_permissions
        Current.user = User.find(@owner.id)

        assert_empty PfStiBugTicket.permission_scoped.pluck(:id)
        assert_empty PfStiUrgentBugTicket.permission_scoped.pluck(:id), 'the grandchild answers to the unreadable entry too'
        assert_raises(NotAuthorized) { PfStiBugTicket.find_by(id: bug.id) }
        assert_equal [bug.id], PfStiTicket.permission_scoped.pluck(:id), 'the base keeps its own read'
      end

      test 'STI: an unreadable base denies the subclass that grants read itself' do
        strategy!(:deny)
        set = create_permission_set
        create_permission_set_user(user: @owner, permission_set: set)
        create_resource(permission_set: set, name: 'PfStiTicket', read_access: false)
        create_resource(permission_set: set, name: 'PfStiBugTicket', read_access: true)
        PfStiBugTicket.create!(title: 'Bug', owner: @owner)
        @owner.regenerate_permissions
        Current.user = User.find(@owner.id)

        assert Current.user.can_read?(:PfStiBugTicket)
        assert_empty PfStiBugTicket.permission_scoped.pluck(:id), 'a class is never more readable than an entry it answers to'
      end

      # --- the one definition ------------------------------------------------------------------

      test 'RecordReadAccess.denied? is the one predicate: the strategy, then the chain' do
        user_with(customer: nil)
        user = Current.user

        assert_not RecordReadAccess.denied?(user, Customer)
        strategy!(:deny)
        assert RecordReadAccess.denied?(user, Customer)
        assert_not RecordReadAccess.denied?(user, Supplier)
        assert_not ResourceChain.readable?(user, ResourceChain.names(Customer))
      end
    end
  end
end
