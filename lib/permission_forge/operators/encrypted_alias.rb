# frozen_string_literal: true

module PermissionForge
  module Operators
    # The model whose encrypted column a rule names through a name its
    # query gives a table that is on no model along the rule's path: an
    # alias (`twins_notes.body` on a self-join), a `has_many :through`'s
    # join table, a table a default scope or a host's join brings in
    # (RuleSources). RuleColumn leaves such a name to the database
    # (UNKNOWN) — except a column that holds ciphertext, which no built-in
    # operator can compare (RuleColumn#encrypted?): failing to see one would
    # compare the ciphertext, and `not_equal` would show the rows it should
    # hide.
    #
    # - The name is resolved to the table it stands for, and every loaded
    #   model on that table (PermissionForge::EncryptedAttributes.models_on,
    #   single-table inheritance included) says whether it encrypts the
    #   column: one that does makes it encrypted.
    # - A name whose table cannot be told, or that no loaded model is on (a
    #   subquery, a table without a model), is judged by every model along
    #   the path, the rule's own included: a column of that name that any of
    #   them encrypts counts as encrypted (fail closed).
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

      # The model whose encrypted column `name` is, when `table` is a name
      # the query gives a table: one on that table, or one along the path;
      # nil otherwise.
      #
      # @param table [String] the field name's qualifier
      # @param name [String] the column as written
      # @return [Class, nil]
      def model(table, name)
        source = @joined.find { |alias_name, _table| RuleColumn.same_name?(alias_name, table, @exact) } or return

        (on_table(source).presence || @models).find { |model| encrypts?(model, name) }
      end

      private

      # The loaded models on the table the name stands for.
      def on_table(source)
        _alias_name, table = source
        return [] unless table

        PermissionForge::EncryptedAttributes.models_on(table, exact: @exact)
      end

      def encrypts?(model, name)
        PermissionForge::EncryptedAttributes.names(model).any? { |attribute| RuleColumn.same_name?(attribute.to_s, name, @exact) }
      end
    end
  end
end
