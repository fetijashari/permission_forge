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
  #   exactly when the value is; RuleProblem :encrypted_column), whichever
  #   table of the rule's query it is in ({.models_on}: a table the query
  #   joins that is on no model along the rule's path);
  # - the admin's people search leaves one out of its LIKE, and bulk matching
  #   of its lower-cased equality; a deterministically encrypted one matches
  #   a whole value exactly (`where(email: value)` encrypts the value);
  # - a person's label reads one decrypted (Admin::PersonLabel).
  #
  # Rails' `encrypted_attributes` (no rdoc; a canary watches it) is nil on a
  # model that encrypts nothing and holds Symbols — an `ignore_case`
  # attribute's `original_<name>` column among them. Under single-table
  # inheritance it is per class, and a subclass's `encrypts` adds to its
  # parent's Set when the parent has one (`||= Set.new`): the parent's
  # answer depends on what encrypts what, and in which order. A column holds
  # ciphertext when any class that stores rows in it says so, so the answer
  # is the hierarchy's on the model's table ({.family}): the class, its base
  # class and every loaded class of the hierarchy on that table. A subclass
  # Rails has not loaded yet (lazy loading in development) is not seen.
  #
  # The value Rails reads from a column it cannot decrypt is no value
  # ({.decrypt}): under `support_unencrypted_data` Rails answers with the
  # stored ciphertext instead of raising.
  #
  # @api private
  module EncryptedAttributes
    module_function

    # Whether the column holds ciphertext: an attribute of that name is
    # declared with `encrypts` by the model or a class of its hierarchy on
    # its table ({.family}).
    #
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
    # @return [Array<Symbol>] the encrypted attributes of the model's
    #   hierarchy on its table ({.family}; none for a non-model)
    def names(model)
      return [] unless model.respond_to?(:encrypted_attributes)

      family(model).flat_map { |klass| Array(klass.encrypted_attributes) }.uniq
    end

    # The classes that store rows in the model's table: the model, its base
    # class and every loaded descendant of the base class on the same table
    # (single-table inheritance). Just the model for an abstract class or a
    # class without a base class.
    #
    # @param model [Class]
    # @return [Array<Class>]
    def family(model)
      return [model] unless model.respond_to?(:base_class) && !model.abstract_class?

      base = model.base_class
      table = model.table_name
      [model, base, *base.descendants.select { |klass| !klass.abstract_class? && klass.table_name == table }].uniq
    end

    # Every loaded model class that stores rows in a table of that name:
    # what a table a query joins stands for when it is on no model the
    # caller knows (a `has_many :through`'s join table, a table a default
    # scope or a host's join brings in: Operators::EncryptedAlias). Any
    # loaded, non-abstract Active Record class whose table (its last
    # segment, without a schema) is the name — the classes of a
    # single-table hierarchy among them, so {.names} of any one of them
    # covers the hierarchy. A class the application has not loaded yet
    # (lazy loading in development) is not seen; nor is the database a
    # class is on told apart (a table of that name in another database
    # counts too: fail closed).
    #
    # @param table [String] the table's name, as the query gives it
    # @param exact [Boolean] compare names as written (PostgreSQL), else
    #   without regard to case (Operators::RuleColumn.same_name?)
    # @return [Array<Class>]
    def models_on(table, exact: false)
      ActiveRecord::Base.descendants.select do |klass|
        next false if klass.abstract_class?

        own = klass.table_name.to_s.split('.').last
        own.present? && Operators::RuleColumn.same_name?(own, table.to_s, exact)
      rescue StandardError
        false # a class that cannot name its table (an anonymous one without `table_name`) stores rows in none
      end
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
    # Under `support_unencrypted_data` Rails answers a value it cannot
    # decrypt with the stored value itself: a result that is still
    # ciphertext is nil too. A value stored in plaintext reads as written
    # there (Rails' own reading).
    #
    # @param model [Class]
    # @param name [String, Symbol]
    # @param raw [Object] the value as stored (read_attribute_before_type_cast)
    # @return [Object, nil]
    def decrypt(model, name, raw)
      value = model.type_for_attribute(name.to_s).deserialize(raw)
      value unless value.is_a?(String) && ActiveRecord::Encryption.encryptor.encrypted?(value)
    rescue ActiveRecord::Encryption::Errors::Base
      nil
    end
  end
end
