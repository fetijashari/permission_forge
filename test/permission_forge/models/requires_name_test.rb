# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/static_guard'

module PermissionForge
  # A Permission Set, a group and a rule all need a name, and they need it
  # from one definition (Concerns::RequiresName): field test round 8 found a
  # rule saved with name "" or "   " — in code and through the API (201,
  # PATCH 200) — while sets and groups refused the same input, because only
  # those two declared the presence rule. Checked for a new row and on a
  # rename only, so a row stored blank before stays editable in its other
  # attributes; the admin shows such a name as "Untitled …" in the page's
  # language (Admin::RecordName).
  class RequiresNameTest < ActiveSupport::TestCase
    # The three free-text names the field test reported, then the three identifiers (a model, a
    # column, an action key) that keep their own format checks beside the shared presence rule.
    NAMED = [PermissionSet, PermissionSetGroup, PermissionSetRule].freeze
    IDENTIFIERS = [Resource, ResourceField, ResourceAction].freeze
    BLANKS = [nil, '', '   ', "\t"].freeze

    setup do
      @set = create_permission_set
      @resource = create_resource(permission_set: @set, name: 'Customer')
    end

    def build(model, name)
      case model.name.demodulize
      when 'PermissionSet' then PermissionSet.new(name: name, is_active: true)
      when 'PermissionSetGroup' then PermissionSetGroup.new(name: name, is_active: true)
      else PermissionSetRule.new(permission_set: @set, resource: @resource, name: name, field_name: 'name',
                                 operator: 'equal', field_value: 'x')
      end
    end

    def stored(model)
      record = build(model, 'Named')
      record.save!
      record
    end

    test 'every named model shares the one name rule' do
      (NAMED + IDENTIFIERS).each { |model| assert_includes model.ancestors, Concerns::RequiresName, model.name }
    end

    test 'a Resource, a field row and an action row with a blank name are refused too' do
      [Resource.new(permission_set: @set, name: ' '), ResourceField.new(resource: @resource, name: ''),
       ResourceAction.new(resource: @resource, name: "\t")].each do |record|
        assert_not record.valid?, record.class.name
        assert_includes record.errors[:name], I18n.t('permission_forge.validations.name_blank'), record.class.name
      end
    end

    test 'a new record with a blank name is refused, with one message' do
      NAMED.each do |model|
        BLANKS.each do |blank|
          record = build(model, blank)

          assert_not record.valid?, "#{model.name} #{blank.inspect}"
          assert_equal [I18n.t('permission_forge.validations.name_blank')], record.errors[:name], "#{model.name} #{blank.inspect}"
        end
      end
    end

    test 'renaming to a blank name is refused' do
      NAMED.each do |model|
        record = stored(model)
        BLANKS.each do |blank|
          record.name = blank

          assert_not record.valid?, "#{model.name} #{blank.inspect}"
          record.restore_attributes
        end
      end
    end

    test 'a row stored blank before stays editable in its other attributes' do
      NAMED.each do |model|
        record = stored(model)
        record.update_column(:name, '')

        record.reload.is_active = !record.is_active

        assert record.save, "#{model.name}: #{record.errors.full_messages.inspect}"
      end
    end

    test 'the admin shows a blank stored name as untitled, in the page language' do
      %w[en sq mk].each do |locale|
        I18n.with_locale(locale) do
          assert_equal I18n.t('permission_forge.ui.untitled.permission_set_rule'),
                       Admin::RecordName.text('   ', :permission_set_rule), locale
        end
      end
      assert_equal 'Own customers', Admin::RecordName.text('Own customers', :permission_set_rule)
    end

    test 'no model declares the name presence rule outside the concern' do
      hits = StaticGuard.scan(globs: %w[app/models/**/*.rb lib/permission_forge/**/*.rb], needle: /validates :name, presence/,
                              canonical: %w[lib/permission_forge/concerns/requires_name.rb])

      assert_empty hits.map(&:to_s)
    end
  end
end
