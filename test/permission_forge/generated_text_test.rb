# frozen_string_literal: true

require 'test_helper'
require_relative 'admin/action_catalog_support'

module PermissionForge
  # Field test round 7 (A#127, D#47, B#26): the gem stored English it had
  # generated — `name.humanize` as a field or action label, the install
  # migration's "You do not have permission to perform this action." as a
  # rule's blocked message, "Untitled Rule" as a name — and showed it as if
  # an admin had written it, on every Albanian or Macedonian page and in
  # NotAuthorizedError#failure_messages. PermissionForge::GeneratedText is
  # the one definition of "this stored text is a generated default"; the
  # gem's writers store the name itself, and the models store nothing for
  # what nobody wrote. Stored data stays as written: no migration rewrites it.
  class GeneratedTextTest < ActiveSupport::TestCase
    include Admin::ActionCatalogSupport

    INSTALL_MESSAGE = 'You do not have permission to perform this action.'

    test 'a label is generated when it is blank, the name, the name humanized or the install default' do
      ['', '  ', 'owner_id', 'Owner', ' Owner ', 'Untitled Field'].each do |label|
        assert GeneratedText.label?(label, 'owner_id'), label.inspect
      end
      assert GeneratedText.label?(nil, 'email')
      ['Account owner', 'owner', 'E-mail'].each { |label| assert_not GeneratedText.label?(label, 'owner_id'), label }
      assert GeneratedText.label?('Billing email', :billing_email), 'a Symbol name'
    end

    test 'a failure message is generated when it is the install default' do
      assert GeneratedText.failure_message?(INSTALL_MESSAGE)
      assert GeneratedText.failure_message?(" #{INSTALL_MESSAGE} ")
      assert_not GeneratedText.failure_message?('You can only open your own customers')
      assert_not GeneratedText.failure_message?(nil)
    end

    test 'a name is generated when it is the install default of its kind' do
      assert GeneratedText.name?('Untitled Permission Set', :permission_set)
      assert GeneratedText.name?('Untitled Permission Set Group', PermissionSetGroup)
      assert GeneratedText.name?('Untitled Rule', PermissionSetRule.new)
      assert_not GeneratedText.name?('Untitled Rule', :permission_set)
      assert_not GeneratedText.name?('Sales rep', :permission_set)
    end

    test 'the install defaults are every text the install migration gave a column' do
      template = File.read(File.expand_path('../../lib/generators/permission_forge/install/templates/migration.rb.tt', __dir__))
      stated = template.scan(/default:\s*'([^']*)'/).flatten

      # A value of an enumerated column (operator, mask strategy) is a choice;
      # a Resource's and a field row's names are names (a Resource's must be
      # a model: 'Untitled Resource' is refused; 'untitled_field' is shown as stored).
      not_text = ['equal', 'full', 'Untitled Resource', 'untitled_field']

      assert_empty stated - GeneratedText.install_defaults - not_text, 'a text default the template states is a generated default'
      assert_includes GeneratedText.install_defaults, INSTALL_MESSAGE, 'kept for the installs made before 0.15'
    end

    test 'the install migration gives no name of a set, group or rule and no blocked message an English default' do
      template = File.read(File.expand_path('../../lib/generators/permission_forge/install/templates/migration.rb.tt', __dir__))

      assert_no_match(/:failure_message,[^\n]*default:/, template)
      assert_no_match(/default: 'Untitled (?:Permission Set|Permission Set Group|Rule)'/, template)
      assert_no_match(/default: 'Untitled (?:Permission Set|Permission Set Group|Rule)'/, File.read(Rails.root.join('db/schema.rb')),
                      'the dummy schema is what a new install has')
    end

    # --- what the gem writes ---------------------------------------------------

    test 'a rule created without a blocked message stores none, and denies with the sentence of the locale' do
      set = create_permission_set
      resource = create_resource(permission_set: set)
      rule = PermissionSetRule.create!(permission_set: set, resource: resource, name: 'Own', field_name: 'name', field_value: 'x')

      assert_nil rule.reload.failure_message
      assert_nil PermissionSetRule.new.failure_message, 'the model declares no default'
    end

    test 'a stored install default denies with the sentence of the current locale' do
      I18n.with_locale(:sq) do
        assert_equal I18n.t('permission_forge.denials.rule_default'),
                     Services::PermissionRuleApplier.failure_message_for({ failure_message: INSTALL_MESSAGE })
      end
      assert_equal 'Own customers only', Services::PermissionRuleApplier.failure_message_for({ failure_message: 'Own customers only' })
    end

    test 'a Permission Set, a group or a rule created without a name is refused, in every locale' do
      set = create_permission_set
      resource = create_resource(permission_set: set)
      records = [PermissionSet.new(uuid: SecureRandom.uuid), PermissionSetGroup.new(uuid: SecureRandom.uuid),
                 PermissionSetRule.new(permission_set: set, resource: resource, field_name: 'name', field_value: 'x')]

      records.each do |record|
        assert_nil record.name, "#{record.class}: no column default"
        assert_not record.valid?, record.class.name
        assert record.errors[:name].any?, "#{record.class}: #{record.errors.to_hash}"
        I18n.with_locale(:sq) do
          record.valid?
          assert_not_includes record.errors[:name].join, 'blank', "#{record.class}: translated"
        end
      end
    end

    test 'a generated field row is labelled with its name' do
      set = create_permission_set
      resource = create_resource(permission_set: set)
      attrs = Services::ResourceFieldGenerator.build(resource: resource, column: 'owner_id', level: 'read')

      assert_equal 'owner_id', attrs[:label]
    end

    test 'an action row made from a controller action key is labelled with the key' do
      discovery_on!
      set = create_permission_set
      resource = create_resource(permission_set: set)
      catalog = Struct.new(:keys) { def keys_for(_name) = keys }.new(%w[bulk_export])
      Admin::ChangeSet.new(permission_set: set, params: { new_actions: { resource.id.to_s => { 'bulk_export' => { is_permitted: '1' } } } },
                           catalog: catalog).apply!

      assert_equal 'bulk_export', resource.resource_actions.find_by!(name: 'bulk_export').label
    end

    test 'a field label an admin blanks is stored as the name' do
      set = create_permission_set
      resource = create_resource(permission_set: set, read_access: true)
      field = create_resource_field(resource: resource, name: 'billing_email', label: 'Billing', read_access: true)
      change = Admin::ChangeSetParts::FieldEdit.new(field, resource, muting: false).changes('label' => '  ').first

      assert_equal 'billing_email', change.to
    end
  end
end
