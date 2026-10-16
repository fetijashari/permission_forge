# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # Field test round 7 (E#73): a rule on an attribute declared with
  # `encrypts` (Active Record encryption) compared the rule's plaintext with
  # the ciphertext the column holds, in raw SQL — it matched nothing and
  # nothing said why. The column cannot be compared as written, so
  # (Operators::RuleProblem :encrypted_column, the one definition
  # PermissionForge::EncryptedAttributes):
  #
  # - a new rule that compares a value with it is refused on `field_name`;
  # - is_null / is_not_null keep working: ciphertext is NULL exactly when the
  #   value is;
  # - a rule stored before (or written past the model) matches nothing, is
  #   named and stays editable in its other attributes; checked again when
  #   its column, path, join type or model changes, or its operator moves off
  #   the null checks; a copy keeps it as it is.
  class PermissionSetRuleEncryptedColumnTest < ActiveSupport::TestCase
    NotAuthorizedError = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError

    setup do
      @user = create_user
      @set = create_permission_set(name: 'Notes')
      create_permission_set_user(user: @user, permission_set: @set)
      @resource = create_resource(permission_set: @set, name: 'PfEncryptedNote', read_access: true)
      @secret = PfEncryptedNote.create!(title: 'secret', body: 'mine')
      @empty = PfEncryptedNote.create!(title: 'empty')
      Current.user = @user
    end

    teardown do
      Current.user = nil
    end

    def new_rule(**attrs)
      PermissionSetRule.new({ uuid: SecureRandom.uuid, name: 'Encrypted', failure_message: 'No', field_name: 'body',
                              field_value: 'mine', operator: 'equal', include_nulls: false, permission_set: @set,
                              resource: @resource }.merge(attrs))
    end

    # A rule saved before the check (or by another application on the shared tables).
    def stored_rule(**attrs)
      rule = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Stored', field_name: 'title',
                                        field_value: 'secret', include_nulls: false)
      rule.update_columns({ field_name: 'body', field_value: 'mine' }.merge(attrs))
      @user.invalidate_permissions
      rule.reload
    end

    def encrypted_message
      I18n.t('permission_forge.validations.permission_set_rule.encrypted_column', name: 'body', model: 'PfEncryptedNote')
    end

    test 'a new rule comparing a value with an encrypted attribute is refused on field_name, with a message in every locale' do
      %w[equal not_equal contains starts_with in between greater_than].each do |operator|
        value = operator == 'between' ? 'a,b' : 'mine'
        rule = new_rule(operator: operator, field_value: value)

        assert_not rule.valid?, operator
        assert_includes rule.errors[:field_name], encrypted_message, operator
      end
      %w[en sq mk].each do |locale|
        text = I18n.t('permission_forge.validations.permission_set_rule.encrypted_column', locale: locale, name: 'body',
                                                                                           model: 'PfEncryptedNote', default: nil)

        assert text.present?, locale
        assert_includes text, 'body', locale
      end
    end

    test 'is_null and is_not_null on an encrypted attribute are accepted and select what they say' do
      assert new_rule(operator: 'is_null', field_value: '').valid?
      assert new_rule(operator: 'is_not_null', field_value: '').valid?

      scope = ->(operator) { Services::PermissionRuleApplier.scope(model_class: PfEncryptedNote, rules: [rule_hash(operator)], current_user: @user) }

      assert_equal [@empty.id], scope.call('is_null').pluck(:id)
      assert_equal [@secret.id], scope.call('is_not_null').pluck(:id)
    end

    test 'the column is found in any case where the database ignores it' do
      skip 'PostgreSQL compares a quoted name as written' if ActiveRecord::Base.connection.adapter_name.match?(/postgres/i)

      rule = new_rule(field_name: 'Body')

      assert_not rule.valid?
      assert_includes rule.errors[:field_name], I18n.t('permission_forge.validations.permission_set_rule.encrypted_column',
                                                       name: 'Body', model: 'PfEncryptedNote')
    end

    test 'a stored one matches nothing, is named, and stays editable in its other attributes' do
      rule = stored_rule

      assert_equal :encrypted_column, Operators::RuleProblem.for(rule)&.kind
      assert_empty PfEncryptedNote.permission_scoped.to_a
      assert_raises(NotAuthorizedError) { PfEncryptedNote.find_by(id: @secret.id) }

      assert rule.update(name: 'Renamed'), rule.errors.full_messages.inspect
      assert rule.update(is_active: false), rule.errors.full_messages.inspect
      assert rule.update(field_value: 'yours'), 'its value: the column was not checked again'
      assert rule.update(operator: 'contains'), 'another operator that compares a value'
    end

    test 'it is checked again when its column changes or its operator moves off the null checks' do
      rule = stored_rule(operator: 'is_null', field_value: '')

      assert_nil Operators::RuleProblem.for(rule), 'a null check is not a problem'
      assert_not rule.update(operator: 'equal', field_value: 'mine'), 'off the null checks'
      assert_includes rule.errors[:field_name], encrypted_message

      rule = create_permission_set_rule(permission_set: @set, resource: @resource, field_name: 'title', field_value: 'x')

      assert_not rule.update(field_name: 'body'), 'onto the encrypted column'
      assert_includes rule.errors[:field_name], encrypted_message
    end

    test 'a copy of a Permission Set keeps a stored one as it is' do
      stored_rule

      copy = Services::PermissionSetCloner.call(permission_set: @set, attrs: { name: 'Notes (copy)' })

      copied = PermissionSetRule.where(permission_set_id: copy.id).sole
      assert_equal %w[body equal], [copied.field_name, copied.operator]
    end

    private

    def rule_hash(operator)
      { name: 'Null check', failure_message: 'No', include_nulls: false, join_type: nil, field_name: 'body',
        operator: operator, field_value: '' }
    end
  end
end
