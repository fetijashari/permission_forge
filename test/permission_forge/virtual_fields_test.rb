require 'test_helper'
require_relative 'virtual_field_models'

module PermissionForge
  # The one reader of a model's declared (extra) and discovered virtual fields.
  class VirtualFieldsTest < ActiveSupport::TestCase
    include VirtualFieldTestSupport

    setup { @config = PermissionForge.configuration }

    # --- VirtualFields.extra_names: what the engine reads -------------------

    test 'extra_names returns the declared names as Strings, columns included' do
      assert_equal %w[full_address], VirtualFields.extra_names(::PfVirtualAccount)

      with_extra_fields(::PfVirtualAccount, %i[full_address email]) do
        assert_equal %w[full_address email], VirtualFields.extra_names(::PfVirtualAccount)
      end
      with_extra_fields(::PfVirtualAccount, :full_address) do
        assert_equal %w[full_address], VirtualFields.extra_names(::PfVirtualAccount), 'a single name, not a list'
      end
    end

    test 'extra_names is empty for a class without the method, and for no class' do
      assert_empty VirtualFields.extra_names(::Supplier)
      assert_empty VirtualFields.extra_names(nil)
      assert_empty VirtualFields.extra_names(Object)
    end

    test 'extra_names reads the method the given configuration names' do
      custom = PermissionForge::Configuration.new
      custom.extra_fields_method = :column_names
      assert_equal ::Supplier.column_names, VirtualFields.extra_names(::Supplier, custom)

      custom.extra_fields_method = nil
      assert_empty VirtualFields.extra_names(::PfVirtualAccount, custom)
    end

    test 'extra_names raises what the model raises' do
      error = assert_raises(ArgumentError) { VirtualFields.extra_names(::PfVirtualBrokenProfile) }

      assert_equal 'extra fields are broken', error.message
    end

    # --- #extra: read models, audits and reader wrapping ----------------------

    test 'extra logs a warning that names the model and the error, and gives no names' do
      fields = VirtualFields.new(::PfVirtualBrokenProfile)
      log = captured_log { assert_empty fields.extra }

      assert_match(/\[PermissionForge\] PfVirtualBrokenProfile\.extra_fields_for_permissions raised ArgumentError: extra fields are broken/,
                   log)
      assert_kind_of ArgumentError, fields.extra_error
      assert_empty fields.declared
      assert_empty fields.implicit
      assert_not fields.implicit_grant?('display_name')
    end

    test 'extra reads and logs once per instance' do
      fields = VirtualFields.new(::PfVirtualBrokenProfile)
      log = captured_log { 3.times { fields.names } }

      assert_equal 1, log.scan('raised ArgumentError').size
    end

    test 'extra has no error for a model whose method works' do
      fields = VirtualFields.new(::PfVirtualAccount)

      assert_equal %w[full_address], fields.extra
      assert_nil fields.extra_error
    end

    # --- declared, discovered, names ------------------------------------------

    test 'declared names always, discovered names only while discovery is on' do
      fields = VirtualFields.new(::PfVirtualAccount)

      assert_equal %w[full_address], fields.declared
      assert_empty fields.discovered
      assert_equal %w[full_address], fields.names

      @config.virtual_field_discovery = true
      fields = VirtualFields.new(::PfVirtualAccount)

      assert_equal %w[nickname theme], fields.discovered
      assert_equal %w[full_address nickname theme], fields.names
    end

    test 'declared names never include a column or an ignored field, and a declared name is not discovered twice' do
      @config.virtual_field_discovery = true
      with_extra_fields(::PfVirtualAccount, %w[email full_address uuid shipping_note theme]) do
        fields = VirtualFields.new(::PfVirtualAccount)

        assert_equal %w[full_address shipping_note theme], fields.declared
        assert_equal %w[nickname], fields.discovered
        assert_equal %w[full_address shipping_note theme nickname], fields.names
      end
    end

    test 'takes an injected configuration' do
      discovering = PermissionForge::Configuration.new
      discovering.virtual_field_discovery = true
      discovering.extra_fields_default_access = :unconfigured
      fields = VirtualFields.new(::PfVirtualAccount, discovering)

      assert_equal %w[full_address nickname theme], fields.names
      assert_empty fields.implicit
    end

    # --- the implicit grant -----------------------------------------------------

    test 'implicit names are every declared name under :grant, columns included, and none otherwise' do
      @config.virtual_field_discovery = true
      with_extra_fields(::PfVirtualAccount, %i[full_address email]) do
        fields = VirtualFields.new(::PfVirtualAccount)

        assert_equal %w[full_address email], fields.implicit
        assert fields.implicit_grant?(:email)
        assert_not fields.implicit_grant?('nickname'), 'discovered names are never granted'

        [:unconfigured, 'unconfigured'].each do |mode|
          @config.extra_fields_default_access = mode
          assert_empty fields.implicit, "mode #{mode.inspect}"
          assert_not fields.implicit_grant?('full_address'), "mode #{mode.inspect}"
        end
      end
    end

    # --- include? ---------------------------------------------------------------

    test 'include? recognises a declared or discoverable name, listed or not, and never a column' do
      fields = VirtualFields.new(::PfVirtualAccount)

      assert fields.include?('full_address')
      assert fields.include?(:theme), 'discoverable while discovery is off'
      assert_not fields.include?('email')
      assert_not fields.include?('legacy_col')
    end
  end
end
