require 'test_helper'
require_relative '../virtual_field_models'

module PermissionForge
  class VirtualFields
    class DiscoveryTest < ActiveSupport::TestCase
      test 'finds attribute-API attributes and store accessors by reader name' do
        names = Discovery.call(::PfVirtualProfile)

        assert_equal %w[domain_color nickname size_domain theme], names.sort
      end

      test 'never returns a column, the store column included' do
        names = Discovery.call(::PfVirtualProfile)

        assert_empty names & ::PfVirtualProfile.column_names
        assert_not_includes names, 'domain'
      end

      test 'a store accessor with a custom prefix is not found' do
        assert_respond_to ::PfVirtualProfile.new, :custom_shade
        assert_not_includes Discovery.call(::PfVirtualProfile), 'custom_shade'
        assert_not_includes Discovery.call(::PfVirtualProfile), 'shade'
      end

      test 'does not report plain methods or nested-attribute names' do
        klass = Class.new(::Supplier) do
          accepts_nested_attributes_for :customers

          def self.name = 'Supplier'
          def nickname = 'not an attribute'
        end

        assert_empty Discovery.call(klass)
        assert_respond_to klass.new, :customers_attributes=
      end

      test 'a model with nothing virtual gives an empty list' do
        assert_empty Discovery.call(::Customer)
      end

      test 'a class that cannot be reflected gives an empty list instead of raising' do
        assert_empty Discovery.call(Class.new)
        assert_empty Discovery.call(nil)
      end
    end
  end
end
