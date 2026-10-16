# frozen_string_literal: true

module PermissionForge
  # The one reader of a model's Active Record encryption declarations
  # (`encrypts :email`): which columns hold ciphertext. Rails keeps the
  # column's name, so nothing in the schema says so — the column of an
  # encrypted attribute stores `{"p":"…","h":{…}}`, and SQL that compares it
  # with a value compares the ciphertext:
  #
  # - a record rule cannot compare one (Operators::RuleColumn#encrypted?,
  #   Operators::ValueTyping: every built-in operator that takes a value
  #   matches nothing; is_null / is_not_null work, as the ciphertext is NULL
  #   exactly when the value is; RuleProblem :encrypted_column);
  # - the admin's people search leaves one out of its LIKE, and bulk matching
  #   of its lower-cased equality; a deterministically encrypted one matches
  #   a whole value exactly (`where(email: value)` encrypts the value);
  # - a person's label reads one decrypted (Admin::PersonLabel).
  #
  # Rails' `encrypted_attributes` (no rdoc; a canary watches it) is nil on a
  # model that encrypts nothing and holds Symbols — an `ignore_case`
  # attribute's `original_<name>` column among them. A subclass's `encrypts`
  # can add to its parent's set (load order), so callers ask the class they
  # query.
  #
  # @api private
  module EncryptedAttributes
    module_function

    # @param model [Class, nil] a model class (anything else has none)
    # @param name [String, Symbol] a column or attribute name, as the model has it
    # @return [Boolean]
    def encrypted?(model, name)
      names(model).include?(name.to_s.to_sym)
    end

    # Whether the attribute is encrypted deterministically: the same value
    # always gives the same ciphertext, so `where(name => value)` finds it.
    #
    # @param model [Class, nil]
    # @param name [String, Symbol]
    # @return [Boolean]
    def deterministic?(model, name)
      encrypted?(model, name) && Array(model.deterministic_encrypted_attributes).include?(name.to_s.to_sym)
    end

    # @param model [Class, nil]
    # @return [Array<Symbol>] the encrypted attributes of the model (none for a non-model)
    def names(model)
      return [] unless model.respond_to?(:encrypted_attributes)

      Array(model.encrypted_attributes)
    end

    # Of `names` (column names), those that do not hold ciphertext: what SQL
    # can compare as written.
    #
    # @param model [Class]
    # @param names [Array<String>]
    # @return [Array<String>]
    def plain(model, names)
      names.reject { |name| encrypted?(model, name) }
    end

    # Of `names`, the deterministically encrypted ones.
    #
    # @param model [Class]
    # @param names [Array<String>]
    # @return [Array<String>]
    def deterministic(model, names)
      names.select { |name| deterministic?(model, name) }
    end

    # The value a stored ciphertext holds, read through the attribute's type
    # (past any reader the model overrides, as MaskedAttributes does); nil
    # when this application cannot decrypt it (another key, not ciphertext).
    #
    # @param model [Class]
    # @param name [String, Symbol]
    # @param raw [Object] the value as stored (read_attribute_before_type_cast)
    # @return [Object, nil]
    def decrypt(model, name, raw)
      model.type_for_attribute(name.to_s).deserialize(raw)
    rescue ActiveRecord::Encryption::Errors::Base
      nil
    end
  end
end
