require 'test_helper'

module PermissionForge
  module Concerns
    class PermissionScopedFindableTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @permission_set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @permission_set)
        @resource = create_resource(
          permission_set: @permission_set,
          name: 'Customer',
          read_access: true
        )
        @customer = create_customer(supplier_id: @user.id)
      end

      # --- No rules / no user ---

      test 'returns the record without permission checks when no current user' do
        Current.user = nil
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'returns the record when no rules exist' do
        @user.regenerate_permissions
        Current.user = @user
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      # A Rails whose Relation#find_by went through the class's find_by (under
      # scoping) would send the override round in circles if the override
      # found its record with a relation's find_by: it uses where(...).take.
      module RelationFindByThroughClass
        class << self
          attr_accessor :on
        end

        def find_by(*args)
          return super unless RelationFindByThroughClass.on

          scoping { klass.find_by(*args) }
        end
      end
      Customer.relation_delegate_class(ActiveRecord::Relation).prepend(RelationFindByThroughClass)

      test 'find_by and find_by! do not rely on a relation\'s find_by staying away from the class\'s' do
        Current.user = nil
        RelationFindByThroughClass.on = true

        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
        assert_equal @customer, Customer.find_by!(uuid: @customer.uuid)
        assert_raises(ActiveRecord::RecordNotFound) { Customer.find_by!(uuid: 'missing') }
      ensure
        RelationFindByThroughClass.on = false
      end

      test 'find_by with no arguments raises ArgumentError, as Rails\' does' do
        assert_raises(ArgumentError) { Customer.find_by }
      end

      # --- Equal operator ---

      test 'equal operator with include_nulls true matches record' do
        create_rule(operator: 'equal', field_value: 'current_user', include_nulls: true)
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'equal operator with include_nulls false matches record' do
        create_rule(operator: 'equal', field_value: 'current_user', include_nulls: false)
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'equal operator allows null when include_nulls true' do
        create_rule(operator: 'equal', field_value: 'current_user', include_nulls: true)
        null_customer = create_customer(supplier_id: nil)
        setup_permissions
        assert_equal null_customer, Customer.find_by(uuid: null_customer.uuid)
      end

      test 'equal operator raises NotAuthorizedError when denied' do
        create_rule(operator: 'equal', field_value: 'current_user', include_nulls: true)
        setup_permissions

        other = create_customer(supplier_id: @user.id + 999)
        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do
          Customer.find_by(uuid: other.uuid)
        end
      end

      # --- Not-equal operator ---

      test 'not_equal operator allows non-matching records' do
        create_rule(operator: 'not_equal', field_value: '99999', include_nulls: false)
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'not_equal operator with include_nulls true allows null values' do
        create_rule(operator: 'not_equal', field_value: '99999', include_nulls: true)
        null_customer = create_customer(supplier_id: nil)
        setup_permissions
        assert_equal null_customer, Customer.find_by(uuid: null_customer.uuid)
      end

      # --- Comparison operators ---

      test 'greater_than operator' do
        create_rule(operator: 'greater_than', field_value: '0', include_nulls: false)
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'less_than operator' do
        create_rule(operator: 'less_than', field_value: '999999', include_nulls: false)
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'greater_than_or_equal operator' do
        create_rule(operator: 'greater_than_or_equal', field_value: @user.id.to_s, include_nulls: false)
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'less_than_or_equal operator' do
        create_rule(operator: 'less_than_or_equal', field_value: @user.id.to_s, include_nulls: false)
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      # --- Join-based rules ---

      test 'joins rule scopes through association' do
        supplier = create_supplier(owner_id: @user.id)
        @customer.update!(supplier: supplier)

        create_join_rule(join_type: 'joins', field_accessor_path: 'supplier',
                         field_name: 'owner_id', field_value: 'current_user')
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'left_joins rule scopes through association' do
        supplier = create_supplier(owner_id: @user.id)
        @customer.update!(supplier: supplier)

        create_join_rule(join_type: 'left_joins', field_accessor_path: 'supplier',
                         field_name: 'owner_id', field_value: 'current_user', include_nulls: true)
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'join rule raises NotAuthorizedError when denied' do
        supplier = create_supplier(owner_id: @user.id + 999)
        @customer.update!(supplier: supplier)

        create_join_rule(join_type: 'joins', field_accessor_path: 'supplier',
                         field_name: 'owner_id', field_value: 'current_user', include_nulls: false)
        setup_permissions

        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do
          Customer.find_by(uuid: @customer.uuid)
        end
      end

      test 'join rule without field_accessor_path uses own table' do
        create_join_rule(join_type: 'joins', field_accessor_path: nil,
                         field_name: 'supplier_id', field_value: 'current_user', include_nulls: false)
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'nested join path scopes through multi-level association' do
        supplier = create_supplier(owner_id: @user.id)
        @customer.update!(supplier: supplier)

        # field_accessor_path with multiple segments: supplier.owner
        create_join_rule(join_type: 'left_joins', field_accessor_path: 'supplier.owner',
                         field_name: 'id', field_value: 'current_user', include_nulls: false)
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      # The failure messages stay in #details; #message (and so #to_s and
      # #full_message) is the String every error reporter expects.
      test 'NotAuthorizedError#message is the failure messages as a String, #details keeps the Array' do
        create_rule(operator: 'equal', field_value: 'current_user', include_nulls: false)
        setup_permissions

        other = create_customer(supplier_id: @user.id + 999)
        error = assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do
          Customer.find_by(uuid: other.uuid)
        end
        assert_kind_of Array, error.details
        assert_equal error.details.join(', '), error.message
        assert_equal error.message, error.to_s
        assert_includes error.full_message, error.details.first
      end

      # A host's `new(user: u, record: r)` must not put the user's inspect
      # (email included) into the message error trackers store (review MINOR-6).
      test 'NotAuthorizedError built with keywords only never puts the user or record into the message' do
        klass = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError
        victim = create_customer(email: 'victim@example.com')
        error = klass.new(user: @user, record: victim, record_id: victim.id)

        assert_equal klass.name, error.message
        assert_not_includes error.full_message, 'victim@example.com'
        assert_not_includes error.full_message, @user.email
        assert_equal({ user: @user, record: victim, record_id: victim.id }, error.details)
        assert_equal 'x', klass.new(user: @user, message: 'x').message
      end

      test 'NotAuthorizedError#message is a String whatever the details are' do
        klass = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError

        assert_equal 'a, b', klass.new(%w[a b]).message
        assert_equal 'no user', klass.new({ message: 'no user' }).message
        assert_equal 'no user', klass.new(message: 'no user').message
        assert_equal 'plain', klass.new('plain').message
        assert_equal klass.name, klass.new.message, 'no details reads as the class name, as a bare StandardError does'
        assert_equal({ reason: :odd }.to_s, klass.new({ reason: :odd }).message)
        assert_equal({ reason: :odd }, klass.new({ reason: :odd }).details)
      end

      test 'field_value is not coerced to an integer: one that is no number denies' do
        # No magic coercion: "<id>_id" is not a value an integer column can hold,
        # so the rule denies access on every database (it was once silently
        # .to_i'd, and MySQL would still read it as <id>).
        create_rule(operator: 'equal', field_value: "#{@user.id}_id", include_nulls: false)
        setup_permissions
        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do
          Customer.find_by(uuid: @customer.uuid)
        end
      end

      # --- In operator ---

      test 'in operator matches record in comma-separated list' do
        create_rule(operator: 'in', field_value: "#{@user.id},999,888", include_nulls: false)
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'in operator with include_nulls allows null values' do
        create_rule(operator: 'in', field_value: '999,888', include_nulls: true)
        null_customer = create_customer(supplier_id: nil)
        setup_permissions
        assert_equal null_customer, Customer.find_by(uuid: null_customer.uuid)
      end

      test 'in operator denies non-matching record' do
        create_rule(operator: 'in', field_value: '999,888', include_nulls: false)
        setup_permissions
        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do
          Customer.find_by(uuid: @customer.uuid)
        end
      end

      # --- Not-in operator ---

      test 'not_in operator allows non-matching records' do
        create_rule(operator: 'not_in', field_value: '999,888', include_nulls: false)
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'not_in operator with include_nulls allows null values' do
        create_rule(operator: 'not_in', field_value: @user.id.to_s, include_nulls: true)
        null_customer = create_customer(supplier_id: nil)
        setup_permissions
        assert_equal null_customer, Customer.find_by(uuid: null_customer.uuid)
      end

      # --- Contains operator ---

      test 'contains operator matches substring' do
        create_string_rule(operator: 'contains', field_value: 'Test', field_name: 'name')
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'contains operator denies non-matching' do
        create_string_rule(operator: 'contains', field_value: 'ZZZZZ', field_name: 'name')
        setup_permissions
        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do
          Customer.find_by(uuid: @customer.uuid)
        end
      end

      # --- Not-contains operator ---

      test 'not_contains operator allows non-matching' do
        create_string_rule(operator: 'not_contains', field_value: 'ZZZZZ', field_name: 'name')
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      # --- Starts-with operator ---

      test 'starts_with operator matches prefix' do
        create_string_rule(operator: 'starts_with', field_value: 'Test', field_name: 'name')
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'starts_with operator denies non-matching prefix' do
        create_string_rule(operator: 'starts_with', field_value: 'ZZZZZ', field_name: 'name')
        setup_permissions
        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do
          Customer.find_by(uuid: @customer.uuid)
        end
      end

      # --- Ends-with operator ---

      test 'ends_with operator matches suffix' do
        create_string_rule(operator: 'ends_with', field_value: 'Customer', field_name: 'name')
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      # --- Between operator ---

      test 'between operator matches value in range' do
        low = @user.id - 1
        high = @user.id + 1
        create_rule(operator: 'between', field_value: "#{low},#{high}", include_nulls: false)
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'between operator denies value out of range' do
        create_rule(operator: 'between', field_value: '999998,999999', include_nulls: false)
        setup_permissions
        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do
          Customer.find_by(uuid: @customer.uuid)
        end
      end

      # --- Is-null operator ---

      test 'is_null operator matches null records' do
        null_customer = create_customer(supplier_id: nil)
        create_rule(operator: 'is_null', field_value: '', include_nulls: false)
        setup_permissions
        assert_equal null_customer, Customer.find_by(uuid: null_customer.uuid)
      end

      test 'is_null operator denies non-null records' do
        create_rule(operator: 'is_null', field_value: '', include_nulls: false)
        setup_permissions
        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do
          Customer.find_by(uuid: @customer.uuid)
        end
      end

      # --- Is-not-null operator ---

      test 'is_not_null operator matches non-null records' do
        create_rule(operator: 'is_not_null', field_value: '', include_nulls: false)
        setup_permissions
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end

      test 'is_not_null operator denies null records' do
        null_customer = create_customer(supplier_id: nil)
        create_rule(operator: 'is_not_null', field_value: '', include_nulls: false)
        setup_permissions
        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do
          Customer.find_by(uuid: null_customer.uuid)
        end
      end

      # --- ViewAll / ModifyAll bypass ---

      test 'view_all bypasses row-level rules' do
        create_rule(operator: 'equal', field_value: 'current_user', include_nulls: false)
        @resource.update!(view_all: true)
        setup_permissions

        other = create_customer(supplier_id: @user.id + 999)
        assert_equal other, Customer.find_by(uuid: other.uuid)
      end

      test 'modify_all bypasses row-level rules' do
        create_rule(operator: 'equal', field_value: 'current_user', include_nulls: false)
        @resource.update!(view_all: true, modify_all: true)
        setup_permissions

        other = create_customer(supplier_id: @user.id + 999)
        assert_equal other, Customer.find_by(uuid: other.uuid)
      end

      test 'view_all false still enforces rules' do
        create_rule(operator: 'equal', field_value: 'current_user', include_nulls: false)
        @resource.update!(view_all: false)
        setup_permissions

        other = create_customer(supplier_id: @user.id + 999)
        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do
          Customer.find_by(uuid: other.uuid)
        end
      end

      # --- find_by! ---

      test 'find_by! returns the record when rules allow' do
        create_rule(operator: 'equal', field_value: 'current_user', include_nulls: true)
        setup_permissions
        assert_equal @customer, Customer.find_by!(uuid: @customer.uuid)
      end

      test 'find_by! raises NotAuthorizedError when a rule denies an existing record' do
        create_rule(operator: 'equal', field_value: 'current_user', include_nulls: false)
        setup_permissions
        other = create_customer(supplier_id: @user.id + 999)
        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do
          Customer.find_by!(uuid: other.uuid)
        end
      end

      test 'find_by! raises RecordNotFound when no record matches' do
        setup_permissions
        assert_raises(ActiveRecord::RecordNotFound) do
          Customer.find_by!(uuid: 'does-not-exist')
        end
      end

      # --- permission_scoped relation ---

      test 'permission_scoped constrains a chainable relation' do
        mine = @customer
        other = create_customer(supplier_id: @user.id + 999)
        create_rule(operator: 'equal', field_value: 'current_user', include_nulls: false)
        setup_permissions

        uuids = Customer.permission_scoped.pluck(:uuid)
        assert_includes uuids, mine.uuid
        assert_not_includes uuids, other.uuid
      end

      test 'permission_scoped composes with further where/first' do
        create_customer(supplier_id: @user.id + 999)
        create_rule(operator: 'equal', field_value: 'current_user', include_nulls: false)
        setup_permissions

        assert_equal @customer, Customer.permission_scoped.where(uuid: @customer.uuid).first
      end

      test 'permission_scoped returns unscoped relation when view_all is set' do
        other = create_customer(supplier_id: @user.id + 999)
        create_rule(operator: 'equal', field_value: 'current_user', include_nulls: false)
        @resource.update!(view_all: true)
        setup_permissions

        assert_includes Customer.permission_scoped.pluck(:uuid), other.uuid
      end

      test 'permission_scoped denies all under nil_user_strategy :deny' do
        create_rule(operator: 'equal', field_value: 'current_user', include_nulls: false)
        setup_permissions
        Current.user = nil
        PermissionForge.configuration.nil_user_strategy = :deny

        assert_empty Customer.permission_scoped
      ensure
        PermissionForge.configuration.nil_user_strategy = :bypass
      end

      # --- Error details ---

      test 'NotAuthorizedError contains failure details' do
        create_rule(operator: 'equal', field_value: 'current_user', include_nulls: false,
                    name: 'Supplier Rule', failure_message: 'Not your supplier')
        setup_permissions

        other = create_customer(supplier_id: @user.id + 999)
        error = assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do
          Customer.find_by(uuid: other.uuid)
        end
        assert_kind_of Array, error.details
        assert error.details.first.include?('Supplier Rule')
        assert error.details.first.include?('Not your supplier')
      end

      private

      def setup_permissions
        @user.regenerate_permissions
        Current.user = @user
      end

      def create_rule(operator:, field_value:, include_nulls:, name: 'Test Rule', failure_message: 'Access denied')
        create_permission_set_rule(
          permission_set: @permission_set,
          resource: @resource,
          field_name: 'supplier_id',
          field_value: field_value,
          operator: operator,
          include_nulls: include_nulls,
          name: name,
          failure_message: failure_message
        )
      end

      def create_string_rule(operator:, field_value:, field_name:)
        create_permission_set_rule(
          permission_set: @permission_set,
          resource: @resource,
          field_name: field_name,
          field_value: field_value,
          operator: operator,
          include_nulls: false,
          name: 'String Rule',
          failure_message: 'String match failed'
        )
      end

      def create_join_rule(**attrs)
        create_permission_set_rule(
          permission_set: @permission_set,
          resource: @resource,
          operator: 'equal',
          include_nulls: false,
          **attrs
        )
      end
    end
  end
end
