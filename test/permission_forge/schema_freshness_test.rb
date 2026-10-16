# frozen_string_literal: true

require 'test_helper'

# The model of the schema-freshness test: its table is created and dropped
# by the test itself (a migration that runs while the process is up). A
# top-level name, as the admin resolves models by constant; never give it a
# Resource row outside this file.
class PfSchemaFreshRecord < ApplicationRecord
  self.table_name = 'pf_schema_fresh_records'

  # A declared virtual field that a migration later turns into a column.
  def self.extra_fields_for_permissions = %w[pf_declared]
end

module PermissionForge
  # G6 (plan-final.md §2 SF): a schema read that decides "no" — a missing
  # column, a field that is not there, a row not generated, a "missing" flag
  # — reads the table again once before it answers. A migration that runs
  # while the process is up (development, a rolling deploy) is seen without
  # anyone calling reset_column_information; a column it removes is missing
  # after exactly one re-read (counted on PermissionForge::SchemaRead).
  #
  # Serial: the table is created and altered outside the fixture
  # transaction (DDL commits it on MySQL), and what the test wrote is removed.
  class SchemaFreshnessTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    MODEL = PfSchemaFreshRecord
    TABLE = :pf_schema_fresh_records
    # What the migration adds: a timestamp, a column that looks like personal
    # data, the tenant column and a declared virtual field becoming a column.
    ADDED = { updated_at: :datetime, email: :string, account_id: :bigint, pf_declared: :string }.freeze

    # Every reader of a model's columns, as "does it see what the migration
    # added". A new reader of the schema gets a line here.
    READERS = {
      'Operators::RuleColumn.find' => ->(_t) { Operators::RuleColumn.find('updated_at', [MODEL]).column&.name == 'updated_at' },
      'Operators::RuleColumn.names_for' => ->(_t) { Operators::RuleColumn.names_for(MODEL).include?('updated_at') },
      'FieldNames#include?' => ->(_t) { FieldNames.for(MODEL.name).include?('updated_at') },
      'FieldVariants#call' => ->(_t) { FieldVariants.new(MODEL.name).call('pf_stamp') == ['updated_at'] },
      'FieldNames.declares?' => ->(_t) { FieldNames.declares?(MODEL, 'updated_at') },
      'TimestampFields.names' => ->(_t) { TimestampFields.names(MODEL).include?('updated_at') },
      'VirtualFields#include? (a column is no virtual field)' => ->(_t) { !VirtualFields.new(MODEL).include?('pf_declared') },
      'VirtualFields#declared' => ->(_t) { VirtualFields.new(MODEL).declared.exclude?('pf_declared') },
      'Admin::ModelCatalog columns' => ->(_t) { Admin::ModelCatalog.new.find(MODEL.name).managed_column_names.include?('updated_at') },
      'Admin::ModelCatalog#column' => ->(_t) { !Admin::ModelCatalog.new.find(MODEL.name).column('updated_at').virtual? },
      'Admin::FieldRows missing flag' => ->(t) { !Admin::FieldRows.new(t.resource.reload).row('updated_at').missing },
      'Services::ResourceFieldGenerator' => ->(t) { t.generated_names.include?('updated_at') },
      'Services::GdprFieldAuditor unmapped columns' => lambda { |_t|
        Services::GdprFieldAuditor.call.any? { |f| f[:type] == :unmapped_column && f[:resource] == MODEL.name && f[:column] == 'email' }
      },
      'Services::RlsPolicyGenerator tenant predicate' => lambda { |_t|
        Services::RlsPolicyGenerator.call(model_class: MODEL)[:statements].join.include?("r.#{MODEL.connection.quote_column_name('account_id')}")
      }
    }.freeze

    attr_reader :resource

    setup do
      @audit_floor = AuditEvent.unscoped.maximum(:id).to_i
      @config = PermissionForge.configuration
      @config.auto_apply_masked_attributes = false
      @config.field_variant_mappings = { /\Apf_stamp\z/ => ->(_name) { 'updated_at' } }
      @sets = []
      SchemaRead.reset!
      connection.drop_table(TABLE, if_exists: true)
      connection.create_table(TABLE) { |t| t.string :label }
      MODEL.reset_column_information
      MODEL.columns_hash # the process has read the schema
      @resource = create_resource(permission_set: new_set, name: MODEL.name)
      create_resource_field(resource: @resource, name: 'updated_at', read_access: true)
    end

    teardown do
      connection.drop_table(TABLE, if_exists: true)
      MODEL.reset_column_information
      ResourceField.unscoped.where(resource_id: Resource.unscoped.where(permission_set_id: @sets.map(&:id)).select(:id)).delete_all
      Resource.unscoped.where(permission_set_id: @sets.map(&:id)).delete_all
      PermissionSet.unscoped.where(id: @sets.map(&:id)).delete_all
      AuditEvent.unscoped.where(id: (@audit_floor + 1)..).delete_all
      SchemaRead.reset!
    end

    # Each reader on a schema of its own: the first re-read would refresh
    # the cache for every reader after it.
    test 'every reader sees a column a migration added after the schema was read, without a reset' do
      blind = READERS.reject { |_name, reader| columns_added_after_the_read { reader.call(self) } }.keys

      assert_empty blind, 'readers that answered from the schema as it was before the migration'
    end

    test 'a removed column is missing after exactly one re-read' do
      ADDED.each { |name, type| connection.add_column(TABLE, name, type) }
      MODEL.reset_column_information
      READERS.each { |name, reader| assert reader.call(self), "#{name} sees the columns before the migration removes them" }
      before = SchemaRead.rereads

      ADDED.each_key { |name| connection.remove_column(TABLE, name) }
      SchemaRead.columns(MODEL, verify: true) # the next read that compares with the database (Sync fields, the audit)

      seeing = READERS.select { |_name, reader| reader.call(self) }.keys
      assert_empty seeing, 'readers that still see a removed column'
      assert_equal 1, SchemaRead.rereads - before, 'one re-read for the removal; no reader reads the table again'
    end

    test 'a name confirmed missing is not read again until the table is' do
      before = SchemaRead.rereads

      3.times { assert_not SchemaRead.column?(MODEL, 'pf_nowhere') }
      assert_equal 1, SchemaRead.rereads - before, 'a missing name reads the table once'

      assert SchemaRead.column?(MODEL, 'label')
      assert_equal 1, SchemaRead.rereads - before, 'a column that is there costs no re-read'

      MODEL.reset_column_information # something else read the table again (a reload)
      assert_not SchemaRead.column?(MODEL, 'pf_nowhere')
      assert_equal 2, SchemaRead.rereads - before
    end

    # The builder asks for every `_id` field's `_uuid` variant: on a schema
    # that did not change, the database is asked (one metadata query) and
    # the model is never reset on the request path — a reset drops its
    # generated attribute methods while other threads use it.
    test 'a missing name on an unchanged schema never resets the model' do
      resets = 0
      original = MODEL.method(:reset_column_information)
      replace_singleton_method(MODEL, :reset_column_information) { (resets += 1) && original.call }
      before = SchemaRead.rereads

      assert_not SchemaRead.column?(MODEL, 'supplier_uuid')
      assert_not SchemaRead.columns(MODEL, verify: true).key?('supplier_uuid')
      assert_equal 0, resets
      assert_equal 1, SchemaRead.rereads - before

      connection.add_column(TABLE, :supplier_uuid, :string)
      assert SchemaRead.columns(MODEL, verify: true).key?('supplier_uuid'), 'a changed schema is read again'
      assert_equal 1, resets
    ensure
      MODEL.singleton_class.send(:remove_method, :reset_column_information)
    end

    test 'a table created after the schema cache said it is not there is found' do
      connection.drop_table(:pf_schema_fresh_late, if_exists: true)
      assert_not connection.schema_cache.data_source_exists?('pf_schema_fresh_late'), 'the schema cache remembers "no"'
      connection.create_table(:pf_schema_fresh_late) { |t| t.string :label }

      assert SchemaRead.table?(MODEL, 'pf_schema_fresh_late')
    ensure
      connection.drop_table(:pf_schema_fresh_late, if_exists: true)
      connection.schema_cache.clear_data_source_cache!('pf_schema_fresh_late')
    end

    # What ResourceFieldGenerator creates for the model in a Permission Set
    # of its own, removed again so no other reader sees its rows.
    def generated_names
      generated = create_resource(permission_set: new_set, name: MODEL.name, read_access: false)
      Services::ResourceFieldGenerator.call(resource: generated).map(&:name)
    ensure
      if generated
        ResourceField.unscoped.where(resource_id: generated.id).delete_all
        Resource.unscoped.where(id: generated.id).delete_all
      end
    end

    private

    def connection = ActiveRecord::Base.connection

    # The table as it was when the process read it, then the migration.
    def columns_added_after_the_read
      connection.drop_table(TABLE, if_exists: true)
      connection.create_table(TABLE) { |t| t.string :label }
      MODEL.reset_column_information
      MODEL.columns_hash
      SchemaRead.reset!
      ADDED.each { |name, type| connection.add_column(TABLE, name, type) }
      yield
    end

    def new_set
      create_permission_set.tap { |set| @sets << set }
    end
  end
end
