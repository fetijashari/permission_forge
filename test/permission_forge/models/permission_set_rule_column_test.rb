# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # A rule's field_name has to be a column of its table. A rule naming one the
  # table does not have was saved (201 through the API), and then every
  # find_by / permission_scoped of its holders raised
  # ActiveRecord::StatementInvalid — a 500 in the host app. It is refused when
  # it is written, and one written before (or past the model) denies.
  class PermissionSetRuleColumnTest < ActiveSupport::TestCase
    NotAuthorizedError = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError
    POSTGRES = ActiveRecord::Base.connection.adapter_name.match?(/postgresql/i)

    # A model whose table does not exist (yet).
    class TablelessRecord < ActiveRecord::Base
      self.table_name = 'pf_rule_column_no_such_table'
    end

    setup do
      @permission_set = create_permission_set(name: 'Sales')
      @resource = create_resource(permission_set: @permission_set, name: 'Customer', read_access: true)
    end

    teardown do
      Current.user = nil
    end

    # --- refused at save ---

    test 'a field name that is no column of the model is refused on field_name' do
      rule = build_rule(field_name: 'onwer_id')

      assert_not rule.valid?
      assert_equal ['is not a column of Customer'], rule.errors[:field_name]
      assert_equal ['Field name is not a column of Customer'], rule.errors.full_messages
      assert_not build_rule(field_name: 'customers.onwer_id').valid?
    end

    test 'the message is translated' do
      { sq: 'nuk është kolonë e Customer', mk: 'не е колона на Customer' }.each do |locale, message|
        I18n.with_locale(locale) do
          rule = build_rule(field_name: 'onwer_id')

          assert_not rule.valid?
          assert_equal [message], rule.errors[:field_name], locale
        end
      end
    end

    test 'a column of the model, in any notation the database resolves, is accepted' do
      %w[supplier_id customers.supplier_id created_at id].each do |name|
        rule = build_rule(field_name: name)

        assert rule.valid?, "#{name}: #{rule.errors.full_messages}"
      end
      other_case = build_rule(field_name: 'Supplier_ID')

      # PostgreSQL tells the case of a quoted name apart; MySQL and SQLite do not.
      assert_equal !POSTGRES, other_case.valid?, other_case.errors.full_messages.inspect
    end

    test 'a join rule names a column of the table at the end of its path' do
      join = { join_type: 'joins', field_accessor_path: 'supplier' }

      assert build_rule(field_name: 'owner_id', **join).valid?
      assert build_rule(field_name: 'suppliers.owner_id', **join).valid?
      assert build_rule(field_name: 'deactivated', join_type: 'left_joins', field_accessor_path: 'supplier.owner').valid?

      on_path = build_rule(field_name: 'domain', **join)

      assert_not on_path.valid?
      assert_equal ['is not a column of Supplier'], on_path.errors[:field_name]
      assert_equal ['is not a column of Customer'], build_rule(field_name: 'customers.nope', **join).tap(&:valid?).errors[:field_name]
    end

    test 'a filter rule is checked against its own model, whatever path it carries' do
      assert build_rule(field_name: 'domain', field_accessor_path: 'supplier').valid?
      assert_not build_rule(field_name: 'owner_id', field_accessor_path: 'supplier').valid?
    end

    # What the check cannot tell is left to the query, as before.
    test 'where the columns cannot be told, the rule is not refused for its column' do
      assert build_rule(field_name: 'elsewhere.anything').valid?, 'a table that is none of the rule\'s (an alias the query joins)'
      assert build_rule(field_name: 'anything', join_type: 'joins', field_accessor_path: 'nowhere').valid?, 'a path it cannot follow'
      assert build_rule(field_name: 'anything', join_type: 'joins', field_accessor_path: 'supplier.nowhere').valid?

      { 'FreightCost' => 'no model', TablelessRecord.name => 'no table', 'PermissionForge' => 'not a model' }.each do |name, why|
        @resource.update_columns(name: name)

        assert build_rule(field_name: 'anything').valid?, why
      end
    end

    test 'a model that cannot be loaded is skipped, not an error' do
      @resource.update_columns(name: 'PfRuleColumnBroken')
      Object.const_set(:PfRuleColumnBroken, Class.new(ActiveRecord::Base) { self.abstract_class = true })

      assert build_rule(field_name: 'anything').valid?
    ensure
      Object.send(:remove_const, :PfRuleColumnBroken) if Object.const_defined?(:PfRuleColumnBroken)
    end

    test 'an existing row is checked only when what it names changes' do
      rule = create_permission_set_rule(permission_set: @permission_set, resource: @resource)
      rule.update_columns(field_name: 'onwer_id')

      assert rule.reload.update(field_value: '5', is_active: false, name: 'Renamed'), rule.errors.full_messages.inspect
      assert_not rule.update(field_name: 'onwer')
      assert_equal ['is not a column of Customer'], rule.errors[:field_name]

      rule.reload
      assert_not rule.update(join_type: 'joins', field_accessor_path: 'supplier'), 'onwer_id is no column of Supplier either'
      assert rule.reload.update(field_name: 'supplier_id')
    end

    # The admin's rule form writes join_type nil for a filter; a legacy row
    # stored 'filter'. Editing only its message is no change of column.
    test "a filter rule stored as 'filter' stays editable when the form writes nil" do
      rule = create_permission_set_rule(permission_set: @permission_set, resource: @resource)
      rule.update_columns(field_name: 'onwer_id', join_type: 'filter')

      assert rule.reload.update(join_type: nil, failure_message: 'Only your own'), rule.errors.full_messages.inspect
    end

    test "a copy moved onto another model's Resource is checked" do
      rule = create_permission_set_rule(permission_set: @permission_set, resource: @resource)
      rule.update_columns(field_name: 'domain')
      supplier = create_resource(permission_set: @permission_set, name: 'Supplier', read_access: true)
      copy = rule.reload.dup
      copy.assign_attributes(uuid: SecureRandom.uuid, resource: supplier)

      assert_not copy.valid?, 'domain is a column of Customer, not of Supplier'
      assert_equal ['is not a column of Supplier'], copy.errors[:field_name]
    end

    # A column a migration added after the schema cache was read (a running
    # server, an old process in a rolling deploy) is found at save.
    test 'a column added after the schema cache was read is accepted' do
      Customer.columns_hash # warm the cache
      ActiveRecord::Base.connection.add_column(:customers, :pf_region, :string)

      assert build_rule(field_name: 'pf_region').valid?
    ensure
      ActiveRecord::Base.connection.remove_column(:customers, :pf_region) if Customer.connection.column_exists?(:customers, :pf_region)
      Customer.reset_column_information
    end

    # --- a rule saved before: it denies, it does not raise ---

    test 'a holder of a rule naming a missing column is denied every record, never a 500' do
      user = create_user
      create_permission_set_user(user: user, permission_set: @permission_set)
      customer = create_customer(supplier_id: user.id)
      rule = create_permission_set_rule(permission_set: @permission_set, resource: @resource, name: 'Owner',
                                        failure_message: 'Not yours', include_nulls: false)
      rule.update_columns(field_name: 'onwer_id')
      Current.user = user

      assert_empty Customer.permission_scoped
      error = assert_raises(NotAuthorizedError) { Customer.find_by(uuid: customer.uuid) }
      assert_equal ['Not yours'], error.failure_messages
      assert_raises(NotAuthorizedError) { Customer.find_by!(uuid: customer.uuid) }
      assert_nil Customer.find_by(uuid: 'missing'), 'a record that does not exist is still not found'

      PermissionForge.configuration.auto_query_scoping = :filter_only

      assert_equal 0, Customer.where(uuid: customer.uuid).count, 'every query, under auto_query_scoping'
    end

    # --- copies ---

    test 'cloning a set copies a rule naming a missing column as it is' do
      good = create_permission_set_rule(permission_set: @permission_set, resource: @resource, name: 'Good')
      bad = create_permission_set_rule(permission_set: @permission_set, resource: @resource, name: 'Bad')
      bad.update_columns(field_name: 'onwer_id')

      copy = Services::PermissionSetCloner.call(permission_set: @permission_set.reload, attrs: { name: 'Sales copy' })
      rules = copy.resources.first.permission_set_rules.order(:name)

      assert_equal [%w[Bad onwer_id], %w[Good supplier_id]], rules.pluck(:name, :field_name)
      assert_not_equal [good.id, bad.id].sort, rules.ids.sort

      copied = rules.find_by(name: 'Bad')

      assert_not copied.update(field_name: 'onwer'), 'the copy is checked like any rule once its name changes'
    end

    test 'a copy whose name differs from its original is checked' do
      rule = create_permission_set_rule(permission_set: @permission_set, resource: @resource)
      copy = rule.dup
      copy.assign_attributes(uuid: SecureRandom.uuid, field_name: 'onwer_id')

      assert_not copy.valid?
    end

    private

    def build_rule(**attrs)
      PermissionForge::PermissionSetRule.new({
        uuid: SecureRandom.uuid, name: 'Rule', field_name: 'supplier_id', field_value: '5', operator: 'equal',
        permission_set: @permission_set, resource: @resource
      }.merge(attrs))
    end
  end
end
