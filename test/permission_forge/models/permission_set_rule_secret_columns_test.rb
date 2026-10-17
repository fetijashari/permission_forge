# frozen_string_literal: true

require 'test_helper'
require_relative '../secret_column_models'

module PermissionForge
  # A record rule never compares a column that holds a secret (a password
  # digest, a token, an `encrypted_*` column): PermissionForge::SecretColumns,
  # config.rule_secret_column_patterns (`[]` opts out). The model refuses
  # one on a new rule and when the column or the path changes; the rule
  # builder does not offer them; a rule stored before keeps evaluating as it
  # did (the audit and Home list it).
  class PermissionSetRuleSecretColumnsTest < ActiveSupport::TestCase
    setup do
      @set = create_permission_set(name: 'Support')
      @records = create_resource(permission_set: @set, name: 'PfSecretRecord', read_access: true)
      @notes = create_resource(permission_set: @set, name: 'PfSecretNote', read_access: true)
    end

    def new_rule(resource: @records, **attrs)
      PermissionSetRule.new({ uuid: SecureRandom.uuid, name: 'Secret', failure_message: 'No', field_name: 'label',
                              field_value: 'x', operator: 'equal', include_nulls: false, permission_set: @set,
                              resource: resource }.merge(attrs))
    end

    def secret_message = I18n.t('permission_forge.validations.permission_set_rule.secret_column')

    test 'the default patterns name digests, tokens, encrypted columns and secrets — and nothing else here' do
      columns = SecretColumns.new

      %w[password_digest reset_digest api_token token remember_token_hash encrypted_note client_secret_hash
         PASSWORD_DIGEST pf_secret_records.api_token].each { |name| assert columns.secret?(name), name }
      %w[label owner_id email name digest_count secretary].each { |name| assert_not columns.secret?(name), name }
    end

    # The credentials a host's user table commonly has (Devise, Authlogic,
    # has_secure_password, OTP gems, API keys), anchored to name segments
    # so an ordinary column is never caught.
    {
      'password' => true, 'password_hash' => true, 'crypted_password' => true, 'encrypted_password' => true,
      'password_salt' => true, 'salt' => true, 'secret' => true, 'secret_key' => true, 'api_key' => true,
      'private_key' => true, 'access_key' => true, 'otp_secret' => true, 'otp_backup_codes' => true, 'passwd' => true,
      'owner_id' => false, 'foreign_key' => false, 'sort_key' => false, 'keyword' => false, 'secretary' => false,
      'salty_snack' => false, 'footprint' => false, 'hotpot' => false, 'crypto_wallet' => false, 'compass_bearing' => false,
      'otter_count' => false, 'basalt' => false
    }.each do |column, secret|
      test "the default patterns #{secret ? 'name' : 'leave'} #{column}" do
        assert_equal secret, SecretColumns.new(configuration: PermissionForge::Configuration.new).secret?(column)
      end
    end

    test 'a stored rule on a secret column cannot change its value or operator (no guessing at the secret)' do
      rule = create_permission_set_rule(permission_set: @set, resource: @records, field_name: 'label', field_value: 'x')
      rule.update_columns(field_name: 'api_token', field_value: 'abc')
      rule.reload

      assert_not rule.update(field_value: 'abd'), 'a new guess at the value'
      assert_includes rule.errors[:field_name], secret_message
      assert_not rule.reload.update(operator: 'starts_with'), 'a new operator'
      assert_includes rule.errors[:field_name], secret_message
      assert rule.reload.update(name: 'Renamed'), 'the other attributes stay editable'
    end

    test 'a new rule on a secret column is refused, with a message in every locale' do
      %w[password_digest api_token encrypted_note client_secret_hash pf_secret_records.api_token].each do |name|
        rule = new_rule(field_name: name)

        assert_not rule.valid?, name
        assert_includes rule.errors[:field_name], secret_message, name
      end
      assert_predicate new_rule(field_name: 'label'), :valid?
      %w[en sq mk].each do |locale|
        assert I18n.exists?('permission_forge.validations.permission_set_rule.secret_column', locale.to_sym), locale
      end
    end

    test 'a join rule whose column at the end of its path is a secret is refused' do
      rule = new_rule(resource: @notes, join_type: 'joins', field_accessor_path: 'pf_secret_record', field_name: 'api_token')

      assert_not rule.valid?
      assert_includes rule.errors[:field_name], secret_message
      assert_predicate new_rule(resource: @notes, join_type: 'joins', field_accessor_path: 'pf_secret_record',
                                field_name: 'label'), :valid?
    end

    test 'changing the column of a rule to a secret is refused' do
      rule = create_permission_set_rule(permission_set: @set, resource: @records, field_name: 'label', field_value: 'x')

      assert_not rule.update(field_name: 'password_digest')
      assert_includes rule.errors[:field_name], secret_message
    end

    test 'a rule stored before keeps evaluating and stays editable in its other attributes' do
      rule = create_permission_set_rule(permission_set: @set, resource: @records, field_name: 'label', field_value: 'x')
      rule.update_columns(field_name: 'api_token', field_value: 'abc')
      user = create_user
      create_permission_set_user(user: user, permission_set: @set)
      PfSecretRecord.create!(label: 'match', api_token: 'abc')
      PfSecretRecord.create!(label: 'other', api_token: 'zzz')
      Current.user = user

      assert_equal %w[match], PfSecretRecord.permission_scoped.pluck(:label), 'it evaluates as before'
      rule.reload.name = 'Renamed'
      assert rule.save, rule.errors.full_messages.inspect
    ensure
      Current.user = nil
    end

    test 'rule_secret_column_patterns = [] opts out' do
      PermissionForge.configuration.rule_secret_column_patterns = []

      assert_predicate new_rule(field_name: 'password_digest'), :valid?
    end

    test 'rule_secret_column_patterns takes a list of regular expressions' do
      PermissionForge.configuration.rule_secret_column_patterns = [/\Apin\z/]

      assert_not new_rule(field_name: 'pin').valid?
      assert_predicate new_rule(field_name: 'password_digest'), :valid?
      assert_raises(ConfigurationError) { PermissionForge.configuration.rule_secret_column_patterns = 'token' }
      assert_raises(ConfigurationError) { PermissionForge.configuration.rule_secret_column_patterns = ['token'] }
    end

    test 'the rule builder does not offer a secret column, except the one a stored rule already names' do
      offered = Admin::RuleForm.new(resource: @records).field_options.map(&:name)

      assert_includes offered, 'label'
      %w[password_digest api_token encrypted_note client_secret_hash].each { |name| assert_not_includes offered, name }

      stored = create_permission_set_rule(permission_set: @set, resource: @records, field_name: 'label', field_value: 'x')
      stored.update_columns(field_name: 'api_token')
      editing = Admin::RuleForm.new(resource: @records, rule: stored.reload).field_options.map(&:name)
      assert_includes editing, 'api_token', 'the stored rule still shows what it names'
      assert_not_includes editing, 'password_digest'
    end
  end
end
