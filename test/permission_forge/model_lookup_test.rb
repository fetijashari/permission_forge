# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # "This name is a model with a table" has one definition: ModelLookup.model_for.
  # A Resource named `Kernel` (a valid constant path, no model) made the field
  # generator and the API's generate_fields raise NoMethodError.
  class ModelLookupTest < ActiveSupport::TestCase
    class TablelessRecord < ActiveRecord::Base
      self.table_name = 'pf_model_lookup_no_such_table'
    end

    class AbstractRecord < ActiveRecord::Base
      self.abstract_class = true
    end

    test 'a model with a table is found by its name, as a String or a Symbol' do
      assert_equal Customer, ModelLookup.model_for('Customer')
      assert_equal Customer, ModelLookup.model_for(:Customer)
      assert_equal PermissionForge::PermissionSet, ModelLookup.model_for('PermissionForge::PermissionSet')
    end

    test 'anything that is not a model with a table is nil' do
      { 'Kernel' => 'a module', 'String' => 'a class that is no model', 'Comparable' => 'a module',
        'PermissionForge' => 'the gem', TablelessRecord.name => 'a model without a table',
        AbstractRecord.name => 'an abstract model', 'Nope::Nope' => 'no constant', '' => 'blank', nil => 'nil',
        'customer' => 'not a constant path' }.each do |name, why|
        assert_nil ModelLookup.model_for(name), why
      end
    end

    test 'a name whose constant raises as it loads is nil, never an error' do
      Object.const_set(:PfModelLookupBroken, Module.new)
      PfModelLookupBroken.define_singleton_method(:const_missing) { |_name| raise SyntaxError, 'broken model file' }

      assert_nil ModelLookup.model_for('PfModelLookupBroken::Record')
    ensure
      Object.send(:remove_const, :PfModelLookupBroken) if Object.const_defined?(:PfModelLookupBroken)
    end

    test 'model? is the predicate' do
      assert ModelLookup.model?('Customer')
      assert_not ModelLookup.model?('Kernel')
    end
  end
end
