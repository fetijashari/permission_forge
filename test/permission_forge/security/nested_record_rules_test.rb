require 'test_helper'
require_relative '../nested_attribute_models'

module PermissionForge
  module Security
    # WS1 review MAJOR-1: a nested record keeps its `id` (without it a nested
    # payload can only create), and Rails refuses an id of another parent —
    # but it loads the rows of the SAME parent through the association, which
    # is not rule-scoped, so a user could overwrite a child row the child
    # model's row-level rules deny. A nested record with an id now survives
    # only when the child model includes PermissionScopedFindable and the id is
    # inside `child.permission_scoped` for the current user (one query per
    # payload); otherwise the whole record is dropped (dropping just the id
    # would turn it into a create). A child without the concern keeps today's
    # behaviour.
    class NestedRecordRulesTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @set)
        @customers = create_resource(permission_set: @set, name: 'Customer', read_access: true, edit_access: true)
        create_resource_field(resource: @customers, name: 'name', read_access: true, edit_access: true)
        @rule = create_permission_set_rule(permission_set: @set, resource: @customers, name: 'Own domain', field_name: 'domain',
                                           operator: 'equal', field_value: 'mine.com', include_nulls: false)
        suppliers = create_resource(permission_set: @set, name: 'Supplier', read_access: true, edit_access: true)
        create_resource_field(resource: suppliers, name: 'name', read_access: true, edit_access: true)

        @supplier = create_supplier
        @mine = create_customer(name: 'Mine', domain: 'mine.com', supplier_id: @supplier.id)
        @theirs = create_customer(name: 'Theirs', domain: 'theirs.com', supplier_id: @supplier.id)
        @user.regenerate_permissions
        Current.user = @user
      end

      def permit(params, resource:)
        PermissionForge::Services::PermitsAttributes.call(resource: resource, permitted_params: params)
      end

      # SELECT statements on the customers table while the block runs.
      def customer_selects
        count = 0
        subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
          count += 1 if payload[:name] != 'SCHEMA' && payload[:sql].match?(/SELECT .* FROM .customers./im)
        end
        yield
        count
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      test 'has_many: a record whose id the child rules deny is dropped whole; an allowed one keeps its id; a new one is kept' do
        payload = [{ 'id' => @mine.id, 'name' => 'a' }, { 'id' => @theirs.id, 'name' => 'b' }, { 'name' => 'new' }]

        assert_equal({ 'customers_attributes' => [{ 'id' => @mine.id, 'name' => 'a' }, { 'name' => 'new' }] },
                     permit({ 'customers_attributes' => payload }, resource: PfNestedSupplier))
        assert_equal({ 'customers_attributes' => { '1' => { 'name' => 'n' } } },
                     permit({ 'customers_attributes' => { '0' => { 'id' => @theirs.id.to_s, 'name' => 'x' }, '1' => { 'name' => 'n' } } },
                            resource: PfNestedSupplier), 'the index form, with a String id')
        assert_equal({}, permit({ 'customers_attributes' => { 'id' => @theirs.id, 'name' => 'x' } }, resource: PfNestedSupplier),
                     'a collection Hash with an id is one record')
      end

      test 'the ids of a collection are checked in one query, whatever the record count' do
        payload = [{ 'id' => @mine.id, 'name' => 'a' }, { 'id' => @theirs.id, 'name' => 'b' }, { 'id' => 0, 'name' => 'c' }]
        selects = customer_selects { permit({ 'customers_attributes' => payload }, resource: PfNestedSupplier) }

        assert_equal 1, selects
        assert_equal 0, customer_selects { permit({ 'customers_attributes' => [{ 'name' => 'new' }] }, resource: PfNestedSupplier) },
                     'no id, no query'
      end

      test 'has_one and belongs_to: the one record is dropped when its id is denied' do
        denied = { 'id' => @theirs.id, 'name' => 'x' }
        allowed = { 'id' => @mine.id, 'name' => 'x' }

        assert_equal({}, permit({ 'primary_customer_attributes' => denied }, resource: PfNestedSupplier))
        assert_equal({ 'primary_customer_attributes' => allowed }, permit({ 'primary_customer_attributes' => allowed }, resource: PfNestedSupplier))
        assert_equal({}, permit({ 'sibling_attributes' => denied }, resource: PfNestedCustomer))
        assert_equal({ 'sibling_attributes' => allowed }, permit({ 'sibling_attributes' => allowed }, resource: PfNestedCustomer))
      end

      test 'an id that names no row is denied too' do
        assert_equal({}, permit({ 'primary_customer_attributes' => { 'id' => 0, 'name' => 'x' } }, resource: PfNestedSupplier))
      end

      test 'a child model without row rules keeps the id, as before' do
        assert_equal({ 'supplier_attributes' => { 'id' => 999, 'name' => 'x' } },
                     permit({ 'supplier_attributes' => { 'id' => 999, 'name' => 'x' } }, resource: PfNestedCustomer),
                     'Supplier has no PermissionScopedFindable: left to Rails')

        @rule.destroy!
        @user.regenerate_permissions
        assert_equal({ 'customers_attributes' => [{ 'id' => @theirs.id, 'name' => 'b' }] },
                     permit({ 'customers_attributes' => [{ 'id' => @theirs.id, 'name' => 'b' }] }, resource: PfNestedSupplier),
                     'the concern without rules: every row')
      end

      test 'view_all on the child resource lets every id through' do
        @customers.update!(view_all: true)
        @user.regenerate_permissions

        assert_equal({ 'customers_attributes' => [{ 'id' => @theirs.id, 'name' => 'b' }] },
                     permit({ 'customers_attributes' => [{ 'id' => @theirs.id, 'name' => 'b' }] }, resource: PfNestedSupplier))
      end

      # A plain Hash may carry both 'id' and :id. Rails reads the record with
      # indifferent access (the last key wins); the guard must not check one
      # id while Rails applies another (review round 2, MINOR-R2-2).
      test 'a record carrying both "id" and :id keeps one when they agree and is dropped when they differ' do
        agree = { 'id' => @mine.id, :id => @mine.id.to_s, 'name' => 'x' }
        differ = { 'id' => @mine.id, :id => @theirs.id, 'name' => 'x' }

        assert_equal({ 'customers_attributes' => [{ 'id' => @mine.id, 'name' => 'x' }] },
                     permit({ 'customers_attributes' => [agree] }, resource: PfNestedSupplier))
        assert_equal({ 'customers_attributes' => [] }, permit({ 'customers_attributes' => [differ] }, resource: PfNestedSupplier),
                     'the allowed id must not vouch for the denied one')
        assert_equal({}, permit({ 'primary_customer_attributes' => differ }, resource: PfNestedSupplier))
        assert_equal({ 'supplier_attributes' => { 'id' => 5, 'name' => 'x' } },
                     permit({ 'supplier_attributes' => { 'id' => 5, :id => '5', 'name' => 'x' } }, resource: PfNestedCustomer),
                     'a child without row rules: one key too')
        assert_equal({}, permit({ 'supplier_attributes' => { 'id' => 5, :id => 6, 'name' => 'x' } }, resource: PfNestedCustomer))
      end

      # Rails reads a blank id as a new record (fields built by JavaScript
      # often submit one): it names no row to check.
      test 'a blank id is a new record, not a denied one' do
        assert_equal({ 'customers_attributes' => [{ 'id' => '', 'name' => 'new' }] },
                     permit({ 'customers_attributes' => [{ 'id' => '', 'name' => 'new' }] }, resource: PfNestedSupplier))
        assert_equal({ 'primary_customer_attributes' => { 'id' => nil, 'name' => 'new' } },
                     permit({ 'primary_customer_attributes' => { 'id' => nil, 'name' => 'new' } }, resource: PfNestedSupplier))
        selects = customer_selects { permit({ 'customers_attributes' => [{ 'id' => '', 'name' => 'new' }] }, resource: PfNestedSupplier) }
        assert_equal 0, selects, 'nothing to check'
      end

      test 'end to end: the denied child of the same parent is not overwritten, the allowed one is updated' do
        supplier = PfNestedSupplier.find(@supplier.id)
        filtered = permit({ 'customers_attributes' => [{ 'id' => @theirs.id, 'name' => 'overwritten' },
                                                       { 'id' => @mine.id, 'name' => 'renamed' }] }, resource: supplier)
        supplier.update!(filtered)

        assert_equal 'Theirs', Customer.unscoped.find(@theirs.id).read_attribute_before_type_cast(:name)
        assert_equal 'renamed', Customer.unscoped.find(@mine.id).read_attribute_before_type_cast(:name)
      end
    end
  end
end
