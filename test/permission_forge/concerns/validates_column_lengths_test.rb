require 'test_helper'

# Created when the file loads, never in a test: DDL commits the fixture
# transaction on MySQL. Limits every database reports for the column.
ActiveRecord::Schema.define do
  create_table :pf_length_probes, force: true do |t|
    t.string :code, limit: 8
    t.string :free
  end
end

class PfLengthProbe < ActiveRecord::Base
  include PermissionForge::Concerns::ValidatesColumnLengths

  self.table_name = 'pf_length_probes'
end

class PfLengthProbeWithOwnRule < ActiveRecord::Base
  include PermissionForge::Concerns::ValidatesColumnLengths

  self.table_name = 'pf_length_probes'
  validates :code, length: { maximum: 4 }
end

class PfLengthProbeWithLooseRule < ActiveRecord::Base
  include PermissionForge::Concerns::ValidatesColumnLengths

  self.table_name = 'pf_length_probes'
  validates :code, length: { maximum: 20 }
end

module PermissionForge
  module Concerns
    # A string longer than its column is a validation error (422), never the
    # database's ValueTooLong (a 500 on a strict MySQL).
    class ValidatesColumnLengthsTest < ActiveSupport::TestCase
      test 'a value within the column limit is valid, one character more is not' do
        assert_predicate PfLengthProbe.new(code: 'a' * 8), :valid?

        probe = PfLengthProbe.new(code: 'ü' * 9)

        refute_predicate probe, :valid?
        assert_equal [I18n.t('permission_forge.validations.too_long', count: 8)], probe.errors[:code]
      end

      test 'the limit is counted in characters, not bytes, for a string column' do
        assert_predicate PfLengthProbe.new(code: "#{'ü' * 7}\u{1F600}"), :valid?
      end

      test 'the message is the locale of the moment it is read' do
        probe = PfLengthProbe.new(code: 'a' * 9)
        probe.valid?

        I18n.with_locale(:sq) do
          assert_equal [I18n.t('permission_forge.validations.too_long', count: 8)], probe.errors[:code]
        end
      end

      test 'a longer value stored before leaves the other attributes editable' do
        probe = PfLengthProbe.create!(code: 'short')
        probe.code = 'a' * 9
        probe.save!(validate: false) # held by the database? not on MySQL strict
      rescue ActiveRecord::ValueTooLong
        skip 'MySQL cannot hold the value: nothing longer is ever stored there'
      else
        probe.reload.free = 'edited'

        assert_predicate probe, :valid?
      end

      test 'an attribute with a length rule of its own keeps that rule alone' do
        probe = PfLengthProbeWithOwnRule.new(code: 'a' * 9)

        refute_predicate probe, :valid?
        assert_equal 1, probe.errors[:code].size, probe.errors.full_messages.inspect
      end

      # A rule that allows more than the column holds does not stand in for it.
      test 'an own length rule looser than the column still gets the column limit' do
        probe = PfLengthProbeWithLooseRule.new(code: 'a' * 9)

        refute_predicate probe, :valid?
        assert_equal 1, probe.errors[:code].size, probe.errors.full_messages.inspect
      end

      test 'a column without a declared limit is not checked here' do
        column = PfLengthProbe.columns_hash['free']
        skip "#{column.sql_type} declares a limit on this database" if column.limit

        assert_predicate PfLengthProbe.new(free: 'a' * 300), :valid?
      end

      # On MySQL every `t.string` column of the install migration holds 255.
      test 'a permission model answers a too-long name with a validation error' do
        column = PermissionSetGroup.columns_hash['name']
        skip "#{column.sql_type} declares no limit on this database" unless column.limit

        group = PermissionSetGroup.new(name: "#{'ü' * column.limit}x", is_active: true)

        refute_predicate group, :valid?
        assert_includes group.errors[:name], I18n.t('permission_forge.validations.too_long', count: column.limit)
      end
    end
  end
end
