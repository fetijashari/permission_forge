require 'test_helper'

module PermissionForge
  module Admin
    # One set's Resources by model family or one by one (Admin::SetOverview).
    class SetOverviewTest < ActiveSupport::TestCase
      def entry(name, view_all: false, rules: 0, masked: 0)
        flags = SetSummaries::FLAGS.index_with(false).merge(read_access: true, view_all: view_all)
        SetSummaries::Entry.new(id: name.hash, set_id: 1, name: name, active: true, muting: false, flags: flags,
                                rules: rules, masked: masked, hidden: 0)
      end

      def family_names(names) = SetOverview.families(names.map { |name| entry(name) }).map { |f| [f.name, f.entries.map(&:name)] }

      test 'a family is the namespace; a model joins the namespace that is its name plus a plural ending' do
        families = family_names(%w[Invoices::Line Invoice Invoices::Payment Address Addresses::Geo Category Categories::Tag
                                   RFQ Rfqs::File Ledger Ledgers2::Entry])

        assert_equal [['Invoices', %w[Invoice Invoices::Line Invoices::Payment]], ['Addresses', %w[Address Addresses::Geo]],
                      ['Categories', %w[Categories::Tag Category]], ['Rfqs', %w[RFQ Rfqs::File]],
                      ['Ledgers2', %w[Ledgers2::Entry]], [nil, %w[Ledger]]], families
      end

      test 'models of no family come last, whatever their number' do
        families = family_names(%w[Alpha Beta Gamma Billing::Invoice])
        assert_equal ['Billing', nil], families.map(&:first)
      end

      test 'only: narrowed, View All, a family, the models of no family; anything else shows everything' do
        set = create_permission_set(name: 'Warehouse staff')
        bin = create_resource(permission_set: set, name: 'Warehouses::Bin', read_access: true)
        create_resource(permission_set: set, name: 'Warehouses::Shelf', read_access: true, view_all: true)
        create_resource(permission_set: set, name: 'Ledger', read_access: true)
        create_permission_set_rule(permission_set: set, resource: bin, field_name: 'name', field_value: 'x')

        shown = ->(only) { SetOverview.new(set, view: 'resources', only: only).families.flat_map(&:entries).map(&:name) }
        assert_equal %w[Warehouses::Bin], shown.call('narrowed')
        assert_equal %w[Warehouses::Shelf], shown.call('view_all')
        assert_equal %w[Warehouses::Bin Warehouses::Shelf], shown.call('Warehouses')
        assert_equal %w[Ledger], shown.call(SetOverview::NO_FAMILY)
        assert_equal 3, shown.call('Nope').size
        assert_equal 3, shown.call('').size

        overview = SetOverview.new(set, view: 'groups', only: 'narrowed')
        assert overview.groups?
        assert_equal 2, overview.families.size, 'the groups view lists every family'
        assert_equal 'resources', SetOverview.new(set, view: 'nope', only: '').view
      end
    end
  end
end
