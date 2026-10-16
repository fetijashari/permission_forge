# frozen_string_literal: true

require 'test_helper'
require_relative '../encrypted_rule_models'

module PermissionForge
  # Review of round 7: an encrypted column the rule reaches other than by
  # its own model's name was not seen as encrypted (fail-open):
  #
  # - P1-1: through a join's alias (`twins_pf_encrypted_twins.body` on a
  #   self-join) the column resolved to RuleColumn::UNKNOWN, the rule saved,
  #   nothing reported it, and `not_equal 'mine'` compared the ciphertext —
  #   it SHOWED the row it should hide. An alias is resolved to the model it
  #   joins (Operators::RuleSources: alias → table → model along the path);
  #   when it cannot be, a column of that name that any model along the path
  #   encrypts counts as encrypted.
  # - P2-2: a subclass that `encrypts` a column its parent does not was
  #   invisible to a rule resolved on the parent. A column is encrypted when
  #   the class, its base class or any loaded class of the hierarchy on the
  #   same table encrypts it (PermissionForge::EncryptedAttributes).
  class PermissionSetRuleEncryptedReachTest < ActiveSupport::TestCase
    NotAuthorizedError = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError
    ALIAS = 'twins_pf_encrypted_twins'

    setup do
      @user = create_user
      @set = create_permission_set(name: 'Notes')
      create_permission_set_user(user: @user, permission_set: @set)
      Current.user = @user
    end

    teardown do
      Current.user = nil
    end

    def encrypted_message(model)
      I18n.t('permission_forge.validations.permission_set_rule.encrypted_column', name: 'body', model: model)
    end

    def new_rule(resource, **attrs)
      PermissionSetRule.new({ uuid: SecureRandom.uuid, name: 'Encrypted', failure_message: 'No', field_name: 'body',
                              field_value: 'mine', operator: 'equal', include_nulls: false, permission_set: @set,
                              resource: resource }.merge(attrs))
    end

    # A rule saved before the check (or by another application on the shared tables).
    def stored_rule(resource, **attrs)
      rule = create_permission_set_rule(permission_set: @set, resource: resource, name: 'Stored', field_name: 'title',
                                        field_value: 'x', include_nulls: false)
      rule.update_columns(attrs)
      @user.invalidate_permissions
      rule.reload
    end

    def alias_attrs
      { join_type: Operators::Constants::JOINS, field_accessor_path: 'twin', field_name: "#{ALIAS}.body",
        operator: 'not_equal', field_value: 'mine' }
    end

    def assert_reported(rule)
      assert_equal :encrypted_column, Operators::RuleProblem.for(rule)&.kind
      assert_includes Admin::AttentionItems.new.broken_rules.map { |item| item.rule.id }, rule.id, 'Home lists it'
      findings = Services::SecurityAudit.call.findings.select { |finding| finding.items.any? { |item| item.include?(rule.name) } }

      assert_equal [:encrypted_rule_columns], findings.map(&:code).uniq, 'rake permission_forge:audit names it'
    end

    # ---- P1-1: an alias ---------------------------------------------------------

    test 'a rule on an encrypted column reached through a self-join alias is refused on field_name' do
      resource = create_resource(permission_set: @set, name: 'PfEncryptedTwin', read_access: true)
      rule = new_rule(resource, **alias_attrs)

      assert_not rule.valid?
      assert_includes rule.errors[:field_name], encrypted_message('PfEncryptedTwin')
      assert new_rule(resource, **alias_attrs, operator: 'is_null', field_value: '').valid?, 'a null check is no comparison'
      assert new_rule(resource, **alias_attrs, field_name: "#{ALIAS}.title").valid?, 'a plain column of the alias'
    end

    test 'a stored one through the alias matches nothing, never the row it should hide, and is reported' do
      resource = create_resource(permission_set: @set, name: 'PfEncryptedTwin', read_access: true)
      mine = PfEncryptedTwin.create!(title: 'mine', body: 'mine')
      hidden = PfEncryptedTwin.create!(title: 'hidden', body: 'x', twin: mine)
      rule = stored_rule(resource, **alias_attrs)

      assert_reported(rule)
      assert_empty PfEncryptedTwin.permission_scoped.to_a, 'the twin of `hidden` holds mine: not_equal must not show it'
      assert_raises(NotAuthorizedError) { PfEncryptedTwin.find_by(id: hidden.id) }
    end

    test 'RuleColumn resolves an alias the join gives to the model it joins' do
      joined = Operators::RuleSources.tables(PfEncryptedTwin.joins(:twin))
      models = [PfEncryptedTwin, PfEncryptedTwin]

      assert_equal 'pf_encrypted_twins', joined.fetch(ALIAS)
      column = Operators::RuleColumn.find("#{ALIAS}.body", models, joined: joined)

      assert_predicate column, :encrypted?
      assert_equal PfEncryptedTwin, column.model
      assert_same Operators::RuleColumn::UNKNOWN, Operators::RuleColumn.find("#{ALIAS}.title", models, joined: joined),
                  'a column the alias does not encrypt stays with the database'
    end

    # The fallback: a name the query gives a table that is no model along
    # the path (a host's own SQL join, an alias of an unknown table). Any
    # model along the path, the rule's own included, that encrypts a column
    # of that name makes the column count as encrypted.
    test 'an alias that cannot be resolved counts as encrypted when a model along the path encrypts the column' do
      along = Operators::RuleColumn.find('partners.body', [Customer, PfEncryptedTwin], joined: { 'partners' => 'no_such_table' })

      assert_predicate along, :encrypted?
      assert_equal PfEncryptedTwin, along.model
      root = Operators::RuleColumn.find('partners.body', [PfEncryptedTwin, Customer], joined: %w[partners])

      assert_predicate root, :encrypted?, 'the root counts, and a name without its table too'
      assert_same Operators::RuleColumn::UNKNOWN, Operators::RuleColumn.find('partners.title', [PfEncryptedTwin], joined: %w[partners])
      assert_same Operators::RuleColumn::UNKNOWN, Operators::RuleColumn.find('partners.body', [Customer], joined: %w[partners])
      target = Operators::RuleColumn.find('partners.body', [PfEncryptedTwin], joined: %w[partners])

      assert Operators::ValueTyping.call('not_equal', 'mine', target).equal?(Operators::ValueTyping::UNUSABLE)
    end

    # ---- P2-2: single-table inheritance --------------------------------------------

    test 'a column a loaded subclass encrypts is encrypted for the whole hierarchy on its table' do
      [PfEncryptedStiNote, PfEncryptedStiSecret, PfEncryptedStiMemo].each do |model|
        assert EncryptedAttributes.encrypted?(model, 'body'), model.name
        assert_not EncryptedAttributes.encrypted?(model, 'title'), model.name
      end
      assert_nil PfEncryptedStiNote.encrypted_attributes, 'Rails answers nil for the base class'
      assert Operators::RuleColumn.find('body', [PfEncryptedStiNote]).encrypted?
    end

    test 'a rule on the base class is refused, and a stored one matches nothing for the base and the subclass' do
      resource = create_resource(permission_set: @set, name: 'PfEncryptedStiNote', read_access: true)
      rule = new_rule(resource)

      assert_not rule.valid?
      assert_includes rule.errors[:field_name], encrypted_message('PfEncryptedStiNote')

      secret = PfEncryptedStiSecret.create!(title: 'secret', body: 'mine')
      PfEncryptedStiNote.create!(title: 'plain', body: 'mine')
      stored = stored_rule(resource, field_name: 'body', operator: 'equal', field_value: 'mine')

      assert_reported(stored)
      assert_empty PfEncryptedStiNote.permission_scoped.to_a
      assert_empty PfEncryptedStiSecret.permission_scoped.to_a
      assert_raises(NotAuthorizedError) { PfEncryptedStiSecret.find_by(id: secret.id) }
    end

    test 'the RLS policy of the base class compiles a stored one to FALSE' do
      resource = create_resource(permission_set: @set, name: 'PfEncryptedStiNote', read_access: true)
      stored_rule(resource, field_name: 'body', operator: 'equal', field_value: 'mine')

      result = Services::RlsPolicyGenerator.call(model_class: PfEncryptedStiNote)
      select_policy = result[:statements].find { |statement| statement.match?(/\ACREATE POLICY permission_forge_select\b/) }

      assert_match(/OR \(FALSE\)\)/, select_policy)
    end
  end
end
