# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Admin
    # Field test round 7, the display side of S4 (A#127, B#26): a label, a
    # name or a blocked message the gem generated (PermissionForge::GeneratedText)
    # is shown as nothing an admin wrote. A field or action label falls back
    # to the host's translation, then — on an English page — to Rails' own
    # English for the name (what an English host saw before: "Created at"),
    # then to the name verbatim (<code>); an admin's own label still wins. A
    # set, group or rule stored under the install migration's English name
    # is named in the page's language (Admin::RecordName). A form never
    # pre-fills generated text (Admin::Prefill).
    class GeneratedTextDisplayTest < ActiveSupport::TestCase
      HOST = { activerecord: { attributes: { customer: { domain: 'Domeni' } } } }.freeze

      setup do
        @set = create_permission_set(name: 'Display set')
        @resource = create_resource(permission_set: @set)
      end

      teardown do
        I18n.backend.store_translations(:sq, activerecord: { attributes: { customer: nil } })
      end

      def field(name, label)
        create_resource_field(resource: @resource, name: name).tap { |row| row.update_columns(label: label) }
      end

      # --- FieldLabel ---------------------------------------------------------------

      test 'a generated field label is no label: Rails English on an English page, the name verbatim elsewhere' do
        row = field('created_at', 'Created at')
        ['created_at', 'Created at', 'Untitled Field', ''].each do |stored|
          row.update_columns(label: stored)

          I18n.with_locale(:en) { assert_equal ['Created at', false], FieldLabel.for(Customer, 'created_at', row: row).to_h.values, stored }
          %i[sq mk].each do |locale|
            I18n.with_locale(locale) do
              assert_equal ['created_at', true], FieldLabel.for(Customer, 'created_at', row: row).to_h.values, "#{locale} #{stored}"
            end
          end
        end
      end

      test 'an admin label and a host translation still win, in every language' do
        written = field('email', 'Billing contact')
        I18n.backend.store_translations(:sq, HOST)

        %i[en sq mk].each do |locale|
          I18n.with_locale(locale) do
            assert_equal ['Billing contact', false], FieldLabel.for(Customer, 'email', row: written).to_h.values, locale.to_s
          end
        end
        I18n.with_locale(:sq) { assert_equal ['Domeni', false], FieldLabel.for(Customer, 'domain', row: field('domain', 'Domain')).to_h.values }
      end

      test 'a column with no row reads as one with a generated label (B#26: one name per column)' do
        row = field('owner_id', 'Owner')

        %i[en sq mk].each do |locale|
          I18n.with_locale(locale) do
            assert_equal FieldLabel.for(Customer, 'owner_id').to_h, FieldLabel.for(Customer, 'owner_id', row: row).to_h, locale.to_s
          end
        end
        I18n.with_locale(:en) { assert_equal 'Owner', FieldLabel.for(Customer, 'owner_id').text }
        I18n.with_locale(:en) { assert_equal ['email', true], FieldLabel.for(nil, 'email').to_h.values, 'no model: the name verbatim' }
      end

      # --- ActionLabel ---------------------------------------------------------------

      test 'a generated action label is no label: Rails English on an English page, the key verbatim elsewhere' do
        action = create_resource_action(resource: @resource, name: 'export_csv', label: 'Export csv')

        I18n.with_locale(:en) do
          assert_equal ['Export csv', false], ActionLabel.for(action).to_h.values
          assert_equal ['Export csv', false], ActionLabel.for(nil, 'export_csv').to_h.values, 'no row reads the same'
        end
        I18n.with_locale(:mk) do
          assert_equal ['export_csv', true], ActionLabel.for(action).to_h.values
          assert_equal ['export_csv', true], ActionLabel.for(nil, :export_csv).to_h.values
        end
        action.update_columns(label: 'Export to the accounting system')
        I18n.with_locale(:sq) { assert_equal ['Export to the accounting system', false], ActionLabel.for(action).to_h.values }
      end

      # --- Prefill -------------------------------------------------------------------

      test 'a form pre-fills nothing generated: a label, a blocked message or a name; an admin text stays' do
        assert_equal '', Prefill.text(field('owner_id', 'Owner'), :label)
        assert_equal 'Account owner', Prefill.text(field('domain', 'Account owner'), :label)
        assert_equal '', Prefill.text(create_resource_action(resource: @resource, name: 'sync', label: 'Sync'), :label)

        rule = create_permission_set_rule(permission_set: @set, resource: @resource)
        rule.update_columns(name: 'Untitled Rule', failure_message: 'You do not have permission to perform this action.')
        assert_equal '', Prefill.text(rule, :name)
        assert_equal '', Prefill.text(rule, :failure_message)
        @set.update_columns(name: 'Untitled Permission Set')
        assert_equal '', Prefill.text(@set, :name)
        assert_equal 'Own orders', Prefill.text(rule.tap { |r| r.name = 'Own orders' }, :name)
      end

      # --- RecordName ----------------------------------------------------------------

      test 'a set, group or rule stored under an install default name is named in the page language' do
        @set.update_columns(name: 'Untitled Permission Set')
        group = create_permission_set_group(name: 'Ops').tap { |g| g.update_columns(name: 'Untitled Permission Set Group') }
        rule = create_permission_set_rule(permission_set: @set, resource: @resource).tap { |r| r.update_columns(name: 'Untitled Rule') }

        %i[en sq mk].each do |locale|
          I18n.with_locale(locale) do
            { @set => :permission_set, group => :permission_set_group, rule => :permission_set_rule }.each do |record, kind|
              assert_equal I18n.t("permission_forge.ui.untitled.#{kind}"), RecordName.for(record), "#{locale} #{kind}"
            end
          end
        end
        I18n.with_locale(:sq) { assert_not_equal 'Untitled Rule', RecordName.for(rule) }
        assert_equal 'Sales', RecordName.for(group.tap { |g| g.name = 'Sales' }), 'a name an admin wrote is shown as written'
        assert_equal 'Untitled Rule', RecordName.for(@set.tap { |s| s.name = 'Untitled Rule' }), 'only the default of its own kind'
      end
    end
  end
end
