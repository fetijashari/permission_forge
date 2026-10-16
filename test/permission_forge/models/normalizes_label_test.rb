# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # A blank label is "no label", from one definition (Concerns::NormalizesLabel),
  # on create and on update: a field or action row stores its name (what the
  # gem writes for a row it generates, and what GeneratedText reads as no
  # label), a Resource stores nil. Field test round 8 (D#25): a field label
  # `null` was refused with "can't be blank" while `""` was stored, and an
  # action row stored either as sent.
  class NormalizesLabelTest < ActiveSupport::TestCase
    BLANKS = [nil, '', '   ', "\t"].freeze

    setup do
      @set = create_permission_set
      @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
    end

    test 'a blank field or action label is stored as the name, on create and on update' do
      BLANKS.each_with_index do |blank, index|
        field = ResourceField.create!(resource: @resource, name: "col_#{index}", label: blank)
        action = ResourceAction.create!(resource: @resource, name: "act_#{index}", label: blank)
        assert_equal ["col_#{index}", "act_#{index}"], [field.reload.label, action.reload.label], "create #{blank.inspect}"

        field.update!(label: 'Written')
        action.update!(label: 'Written')
        assert field.update(label: blank), field.errors.to_hash.inspect
        assert action.update(label: blank), action.errors.to_hash.inspect
        assert_equal ["col_#{index}", "act_#{index}"], [field.reload.label, action.reload.label], "update #{blank.inspect}"
      end
    end

    test 'a blank Resource label is stored as nil' do
      BLANKS.each do |blank|
        @resource.update!(label: 'Clients')
        @resource.update!(label: blank)
        assert_nil @resource.reload.label, blank.inspect
      end
    end

    test 'a label someone wrote is stored as written' do
      field = ResourceField.create!(resource: @resource, name: 'domain', label: ' Web address ')
      action = ResourceAction.create!(resource: @resource, name: 'export', label: 'Export CSV')

      assert_equal [' Web address ', 'Export CSV'], [field.reload.label, action.reload.label]
    end

    test 'a rename relabels a row whose label was generated, and keeps one someone wrote' do
      generated = create_resource_field(resource: @resource, name: 'owner_id', label: 'Owner')
      written = create_resource_action(resource: @resource, name: 'sync', label: 'Push to CRM')
      plain = create_resource_action(resource: @resource, name: 'export', label: 'export')

      generated.update!(name: 'seller_id')
      written.update!(name: 'push')
      plain.update!(name: 'export_csv', label: 'Export everything')

      assert_equal(['seller_id', 'Push to CRM', 'Export everything'], [generated, written, plain].map { |row| row.reload.label })
    end
  end
end
