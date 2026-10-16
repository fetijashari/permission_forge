# frozen_string_literal: true

module PermissionForge
  module Operators
    # The model whose encrypted column a rule names through an alias its
    # query gives a table (`twins_notes.body` on a self-join: RuleSources).
    # RuleColumn leaves an alias to the database (UNKNOWN) — except a column
    # that holds ciphertext, which no built-in operator can compare
    # (RuleColumn#encrypted?): failing to see one would compare the
    # ciphertext, and `not_equal` would show the rows it should hide.
    #
    # - The alias is resolved to the table it stands for, and the models
    #   along the rule's path on that table say whether they encrypt the
    #   column (PermissionForge::EncryptedAttributes: their hierarchies on
    #   the table, single-table inheritance included).
    # - An alias whose table cannot be told, or is none of theirs (a host's
    #   SQL join, a subquery), is judged by every model along the path, the
    #   rule's own included: a column of that name that any of them encrypts
    #   counts as encrypted (fail closed).
    #
    # Names are compared as the database compares them (RuleColumn.same_name?).
    #
    # @api private
    class EncryptedAlias
      # @param models [Array<Class>] the rule's model, then the model of each
      #   association on its path
      # @param joined [Hash{String => String, nil}, Array<String>, nil] the
      #   names the rule's query gives its tables (RuleSources.tables; a list
      #   of names: their tables not known)
      def initialize(models, joined)
        @models = models
        @joined = joined || {}
        @exact = RuleColumn.exact_names?(models.last)
      end

      # The model along the path whose encrypted column `name` is, when
      # `table` is a name the query gives a table; nil otherwise.
      #
      # @param table [String] the field name's qualifier
      # @param name [String] the column as written
      # @return [Class, nil]
      def model(table, name)
        source = @joined.find { |alias_name, _table| RuleColumn.same_name?(alias_name, table, @exact) } or return
        on_table = on_table(source)

        (on_table.presence || @models).find { |model| encrypts?(model, name) }
      end

      private

      # The models along the path on the table the alias stands for.
      def on_table(source)
        _alias_name, table = source
        return [] unless table

        @models.select { |model| RuleColumn.same_name?(model.table_name.to_s.split('.').last, table, @exact) }
      end

      def encrypts?(model, name)
        PermissionForge::EncryptedAttributes.names(model).any? { |attribute| RuleColumn.same_name?(attribute.to_s, name, @exact) }
      end
    end
  end
end
