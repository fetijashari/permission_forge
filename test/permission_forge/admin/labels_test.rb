# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Admin
    # The one definition of every label of a stored name (FieldLabel,
    # ModelLabel, ActionLabel), of a validation sentence (ErrorSentence) and
    # of what a new-record form pre-fills (Prefill): the host's translation
    # first, never Rails' English fallback, the stored name verbatim last.
    class LabelsTest < ActiveSupport::TestCase
      HOST = { activerecord: { attributes: { customer: { full_address: 'Adresa e plotë' } },
                               models: { supplier: { one: 'Furnitori', other: 'Furnitorët' } } } }.freeze

      teardown do
        I18n.backend.store_translations(:sq, activerecord: { attributes: { customer: nil }, models: { supplier: nil } })
      end

      def with_host_translations(&)
        I18n.backend.store_translations(:sq, HOST)
        I18n.with_locale(:sq, &)
      end

      # --- FieldLabel ---------------------------------------------------------------

      test 'a field is labelled by the host translation, else the row label, else the name verbatim' do
        set = create_permission_set
        row = create_resource_field(resource: create_resource(permission_set: set), name: 'full_address', label: 'Full address')

        with_host_translations do
          assert_equal ['Adresa e plotë', false], FieldLabel.for(Customer, 'full_address', row: row).to_h.values
          assert_equal ['Full address', false], FieldLabel.for(Customer, 'domain', row: row).to_h.values, 'the row label when the host has none'
          assert_equal ['domain', true], FieldLabel.for('Customer', 'domain').to_h.values, 'verbatim, never "Domain"'
          assert_equal ['email', true], FieldLabel.for(nil, 'email').to_h.values
        end
      end

      test 'a blank or dotted name, an unloadable model and a ModelInfo are handled' do
        assert_equal ['', true], FieldLabel.for(Customer, '').to_h.values
        assert_equal ['zzz', true], FieldLabel.for('NoSuchModelHere', 'zzz').to_h.values
        info = ModelCatalog.new.find('Customer')
        assert_equal 'name', FieldLabel.for(info, 'name').text
        assert_nil FieldLabel.host_translation(Customer, 'name'), 'Rails\' humanize is not a translation'
      end

      # --- ModelLabel ---------------------------------------------------------------

      test 'a model is labelled by the Resource row, else the host translation, else the constant name; the plural likewise' do
        set = create_permission_set
        resource = create_resource(permission_set: set, name: 'Supplier', label: 'Vendors')

        with_host_translations do
          assert_equal 'Vendors', ModelLabel.for(resource).text
          assert_equal 'Furnitori', ModelLabel.for('Supplier').text
          assert_equal 'Furnitorët', ModelLabel.plural('Supplier')
          assert_equal ['Customer', true], ModelLabel.for(Customer).to_h.values, 'never "Customers" from pluralize'
          assert_equal I18n.t('permission_forge.ui.resource_plural', name: 'Customer', count: 2), ModelLabel.plural('Customer')
        end
        assert_equal 'Customer records', ModelLabel.plural(Customer)
        assert_equal ['Billing::Invoice', true], ModelLabel.for('Billing::Invoice').to_h.values, 'the constant path, never titleized'
      end

      # --- ActionLabel ---------------------------------------------------------------

      test 'an action is labelled by its row, else its key verbatim' do
        set = create_permission_set
        action = create_resource_action(resource: create_resource(permission_set: set), name: 'export_csv', label: 'Export to CSV')

        assert_equal ['Export to CSV', false], ActionLabel.for(action).to_h.values
        action.label = ' '
        assert_equal ['export_csv', true], ActionLabel.for(action).to_h.values
        assert_equal ['sync_now', true], ActionLabel.for(nil, :sync_now).to_h.values
        assert_equal 'export_csv', action.display_name, 'ResourceAction#display_name is the same definition'
      end

      # --- ErrorSentence -------------------------------------------------------------

      test 'a validation sentence names the attribute from the gem\'s keys, in the locale' do
        resource = PermissionForge::Resource.new(permission_set: create_permission_set, name: '')
        resource.validate

        assert_equal 'Name can\'t be blank', ErrorSentence.first(resource.errors)
        I18n.with_locale(:mk) do
          resource.validate
          assert_equal "Име #{I18n.t('permission_forge.validations.name_blank')}", ErrorSentence.first(resource.errors)
        end
        assert_equal 'zzz is odd', ErrorSentence.sentence(:zzz, 'is odd'), 'an attribute without a key is named as stored'
        assert_equal 'is odd', ErrorSentence.sentence(:base, 'is odd')
      end

      # --- Prefill -------------------------------------------------------------------

      test 'a new record shows a blank for a column default; a saved record shows what it holds' do
        rule = PermissionForge::PermissionSetRule.new
        assert_nil rule.failure_message, 'the model declares none (an earlier install migration gave the column an English default)'
        assert_equal '', Prefill.text(rule, :failure_message)
        assert_equal '', Prefill.text(rule, :name)

        rule.name = 'Own orders'
        assert_equal 'Own orders', Prefill.text(rule, :name)
        saved = create_permission_set_rule(permission_set: (set = create_permission_set), resource: create_resource(permission_set: set),
                                           failure_message: 'You do not have permission to perform this action.')
        assert_equal 'You do not have permission to perform this action.', Prefill.text(saved, :failure_message), 'stored on purpose'
      end

      test 'a rule left without a message denies with the gem\'s sentence in the locale' do
        assert_equal 'Only yours', Services::PermissionRuleApplier.failure_message_for({ failure_message: 'Only yours' })
        assert_equal I18n.t('permission_forge.denials.rule_default'), Services::PermissionRuleApplier.failure_message_for({ failure_message: ' ' })
        I18n.with_locale(:sq) do
          assert_equal 'Nuk keni leje për të kryer këtë veprim.', Services::PermissionRuleApplier.failure_message_for({})
        end
      end
    end
  end
end
