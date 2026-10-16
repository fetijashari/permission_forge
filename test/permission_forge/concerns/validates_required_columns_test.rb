require 'test_helper'

# Created when the file loads, never in a test: DDL commits the fixture
# transaction on MySQL.
ActiveRecord::Schema.define do
  create_table :pf_required_probes, force: true do |t|
    t.string :uuid, null: false
    t.string :code, null: false, default: 'x'
    t.boolean :flag, null: false, default: false
    t.string :named, null: false
    t.string :free
    t.bigint :pf_required_owner_id, null: false
    t.timestamps
  end
end

class PfRequiredProbe < ActiveRecord::Base
  include PermissionForge::Concerns::ValidatesRequiredColumns

  self.table_name = 'pf_required_probes'
  belongs_to :pf_required_owner, class_name: 'PfRequiredProbe', optional: false
  validates :named, presence: true
  before_create { self.uuid ||= SecureRandom.uuid }
end

class PfRequiredProbeOptionalOwner < ActiveRecord::Base
  include PermissionForge::Concerns::ValidatesRequiredColumns

  self.table_name = 'pf_required_probes'
  belongs_to :pf_required_owner, class_name: 'PfRequiredProbe', optional: true
end

module PermissionForge
  module Concerns
    # nil in a NOT NULL column is a validation error keyed by the attribute
    # (422 / the form again), never the database's NotNullViolation (a 500).
    class ValidatesRequiredColumnsTest < ActiveSupport::TestCase
      def owner
        @owner ||= PfRequiredProbe.new(id: 1, named: 'owner', pf_required_owner_id: 1).tap { |probe| probe.save!(validate: false) }
      end

      test 'nil in a NOT NULL column with a default is refused, keyed by the attribute' do
        probe = PfRequiredProbe.new(named: 'a', pf_required_owner: owner, code: nil, flag: nil)

        refute_predicate probe, :valid?
        assert_equal [I18n.t('permission_forge.validations.blank')], probe.errors[:code]
        assert_equal [I18n.t('permission_forge.validations.blank')], probe.errors[:flag]
      end

      test 'a boolean column refuses the blank a form sends' do
        probe = PfRequiredProbe.new(named: 'a', pf_required_owner: owner, flag: '')

        refute_predicate probe, :valid?
        assert_predicate probe.errors[:flag], :present?
      end

      test 'the primary key, the timestamps and uuid are filled on create, not refused' do
        probe = PfRequiredProbe.new(named: 'a', pf_required_owner: owner)

        assert_predicate probe, :valid?, probe.errors.full_messages.inspect
        probe.save!

        assert probe.uuid.present?
      end

      test 'a persisted row refuses a uuid or a timestamp set to nil' do
        probe = PfRequiredProbe.create!(named: 'a', pf_required_owner: owner)
        probe.uuid = nil
        probe.created_at = nil

        refute_predicate probe, :valid?
        assert_equal %i[uuid created_at], probe.errors.attribute_names & %i[uuid created_at]
      end

      test 'a column with a presence rule of its own, or of a required belongs_to, keeps that message alone' do
        probe = PfRequiredProbe.new(named: nil, pf_required_owner_id: nil)

        refute_predicate probe, :valid?
        assert_equal 1, probe.errors[:named].size
        assert_empty probe.errors[:pf_required_owner_id]
        assert_predicate probe.errors[:pf_required_owner], :present?
      end

      test 'the foreign key of an optional belongs_to is refused by the column' do
        probe = PfRequiredProbeOptionalOwner.new(named: 'a')

        refute_predicate probe, :valid?
        assert_equal [I18n.t('permission_forge.validations.blank')], probe.errors[:pf_required_owner_id]
      end

      test 'the message is the locale of the moment it is read' do
        probe = PfRequiredProbe.new(named: 'a', pf_required_owner: owner, code: nil)
        probe.valid?

        I18n.with_locale(:sq) do
          assert_equal [I18n.t('permission_forge.validations.blank')], probe.errors[:code]
        end
      end

      test 'every permission model refuses nil in each of its NOT NULL columns' do
        set = create_permission_set(name: 'Sales')
        resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
        records = [set, resource, create_resource_field(resource: resource, name: 'email', read_access: true),
                   create_resource_action(resource: resource), create_permission_set_rule(permission_set: set, resource: resource),
                   create_permission_set_group(name: 'Team')]
        missing = records.flat_map do |record|
          record.class.columns.reject(&:null).filter_map do |column|
            name = column.name
            next if name == record.class.primary_key

            record.reload.public_send(:write_attribute, name, nil)
            "#{record.class.name}##{name}" if record.valid? || record.errors[name].empty? && covered_elsewhere(record, name).empty?
          end
        end

        assert_empty missing
      end

      private

      # The errors of a required belongs_to that names `name` as its foreign key.
      def covered_elsewhere(record, name)
        record.class.reflect_on_all_associations(:belongs_to).select { |reflection| reflection.foreign_key.to_s == name }
              .flat_map { |reflection| record.errors[reflection.name] }
      end
    end
  end
end
