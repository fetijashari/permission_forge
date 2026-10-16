# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # The one reader of a model's `encrypts` declarations
  # (PermissionForge::EncryptedAttributes): which columns hold ciphertext. A
  # rule cannot compare one (Operators::RuleColumn#encrypted?,
  # ValueTyping), the admin's people search cannot LIKE one, and a person's
  # label is read decrypted.
  class EncryptedAttributesTest < ActiveSupport::TestCase
    test 'a model without encrypts has none, and the answer never raises' do
      assert_not EncryptedAttributes.encrypted?(Customer, 'email')
      assert_not EncryptedAttributes.encrypted?(Object.new, 'email'), 'not a model'
      assert_not EncryptedAttributes.encrypted?(nil, 'email')
      assert_empty EncryptedAttributes.names(Customer)
    end

    test 'an attribute declared with encrypts is, by its name as a String or a Symbol' do
      assert EncryptedAttributes.encrypted?(PfEncryptedNote, 'body')
      assert EncryptedAttributes.encrypted?(PfEncryptedNote, :body)
      assert_not EncryptedAttributes.encrypted?(PfEncryptedNote, 'title')
      assert_not EncryptedAttributes.deterministic?(PfEncryptedNote, 'body'), 'non-deterministic by default'
    end

    test 'RuleColumn asks the model the column was found on: the predicate the rule builder and the applier share' do
      assert Operators::RuleColumn.encrypted?(PfEncryptedNote, 'body')
      assert_not Operators::RuleColumn.encrypted?(PfEncryptedNote, 'title')
      assert Operators::RuleColumn.find('body', [PfEncryptedNote]).encrypted?
      assert_not Operators::RuleColumn.find('title', [PfEncryptedNote]).encrypted?
      assert_not Operators::RuleColumn::UNKNOWN.encrypted?, 'nothing known about the column'
      assert_not Operators::RuleColumn.find('nosuch', [PfEncryptedNote]).encrypted?
    end

    # The applier compares an SQL literal with the column: AR's deterministic
    # query rewriting never runs, so every built-in operator that takes a
    # value is UNUSABLE on ciphertext; the null checks take none.
    test 'ValueTyping: every built-in operator that takes a value is UNUSABLE, the null checks and a custom operator are not' do
      target = Operators::RuleColumn.find('body', [PfEncryptedNote])

      Operators::ValueTyping::SHAPES.each_key do |operator|
        value = operator == 'between' ? 'a,b' : 'mine'

        assert Operators::ValueTyping.call(operator, value, target).equal?(Operators::ValueTyping::UNUSABLE), operator
        assert_equal :encrypted_column, Operators::ValueTyping.problem(operator, value, target), operator
      end
      %w[is_null is_not_null].each do |operator|
        assert_not Operators::ValueTyping.call(operator, '', target).equal?(Operators::ValueTyping::UNUSABLE), operator
        assert_nil Operators::ValueTyping.problem(operator, '', target), operator
      end
      assert_equal 'mine', Operators::ValueTyping.call('my_custom', 'mine', target), 'a custom operator gets the value as written'
    end

    test 'decrypt reads the value the ciphertext holds, and nil for one this app cannot decrypt' do
      note = PfEncryptedNote.create!(body: 'hello')
      raw = note.read_attribute_before_type_cast('body')

      assert_not_equal 'hello', raw, 'the column holds ciphertext'
      assert_equal 'hello', EncryptedAttributes.decrypt(PfEncryptedNote, 'body', raw)
      assert_nil EncryptedAttributes.decrypt(PfEncryptedNote, 'body', '{"p":"garbage","h":{}}')
    end
  end
end
