# frozen_string_literal: true

require 'test_helper'

# A model that has MaskedAttributes before a migration adds a column to its
# table. Its own table, created and dropped by the test (never a Resource row).
class PfLateColumnRecord < ApplicationRecord
  self.table_name = 'pf_late_column_records'
end

# Its single-table-inheritance subclass, loaded with the parent.
class PfLateColumnChild < PfLateColumnRecord
end

module PermissionForge
  # The getters MaskedAttributes guards are the columns the model has when
  # Rails defines its attribute methods — at include time, and again each
  # time Rails defines them after the schema was read again
  # (reset_column_information, as PermissionForge::SchemaRead does when the
  # database's columns changed). A column a migration added while the process
  # was up is guarded by its getter as by `[]` and `as_json`: before, its
  # getter (`record.late_note`) answered the raw value while the others hid it.
  #
  # Serial (DDL outside the fixture transaction); with nobody signed in and
  # masked_attributes_nil_user_strategy = :hide every guarded attribute is
  # hidden, so no permission rows are needed.
  class MaskedLateColumnsTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    TABLE = :pf_late_column_records

    setup do
      connection.drop_table(TABLE, if_exists: true)
      connection.create_table(TABLE) do |t|
        t.string :type
        t.string :title
      end
      PfLateColumnRecord.reset_column_information
      PfLateColumnRecord.include(PermissionForge::Concerns::MaskedAttributes) unless Concerns::MaskedAttributes.applied?(PfLateColumnRecord)
      PermissionForge.configuration.masked_attributes_nil_user_strategy = :hide
    end

    teardown do
      connection.drop_table(TABLE, if_exists: true)
      PfLateColumnRecord.reset_column_information
    end

    def connection = ActiveRecord::Base.connection

    def record(klass = PfLateColumnRecord)
      klass.instantiate('id' => 1, 'type' => klass == PfLateColumnRecord ? nil : klass.name, 'title' => 'Title',
                        'late_note' => 'raw secret')
    end

    test 'a column added after the concern arrived is guarded by its getter, as by [] and as_json' do
      assert_nil record.title, 'the include-time column is hidden'
      connection.add_column(TABLE, :late_note, :string)
      PfLateColumnRecord.reset_column_information

      [PfLateColumnRecord, PfLateColumnChild].each do |klass|
        late = record(klass)
        assert_nil late[:late_note], "#{klass}[]"
        assert_nil late.as_json['late_note'], "#{klass}#as_json"
        assert_nil late.late_note, "#{klass}#late_note answers what [] answers"
        assert_nil late.title
      end
    end

    test 'the write-back guard covers the late column too' do
      connection.add_column(TABLE, :late_note, :string)
      PfLateColumnRecord.reset_column_information
      late = record

      assert_includes PfLateColumnRecord::MaskedAttributeReaders.instance_methods(false), :late_note=
      late.late_note = 'changed'
      assert_equal 'changed', late.read_attribute_before_type_cast('late_note')
    end
  end
end
