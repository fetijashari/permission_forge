# frozen_string_literal: true

module PermissionForge
  module Operators
    # The names a rule's query gives its tables, as a field_name can be
    # qualified with: the FROM table and each JOIN's table — its alias where
    # ActiveRecord assigned one (a table joined twice), as the database then
    # knows it by the alias alone. Read from the relation's Arel join
    # sources, the aliases ActiveRecord actually assigns — never from the SQL
    # text, in which a column of an ON clause (`"customers"."supplier_id"`)
    # reads like a table. A join written as SQL (a host's `joins('INNER JOIN
    # ...')`) gives the table or alias each of its JOINs names.
    #
    # RuleColumn.find compares a qualifier with them: the applier with its
    # real query (the default scope's and the host's joins included), the
    # model's validation and the audit with the rule's own join ({.of_join}).
    #
    # @example
    #   RuleSources.of(Customer.joins(:supplier)) # => ["customers", "suppliers"]
    #
    # @api private
    module RuleSources
      # A word that ends a JOIN's table where an alias would stand.
      JOIN_KEYWORDS = %w[ON USING INNER LEFT RIGHT FULL CROSS NATURAL JOIN OUTER WHERE LATERAL].freeze
      # One identifier, bare or quoted the way any adapter quotes one.
      IDENTIFIER = /"[^"]+"|`[^`]+`|\[[^\]]+\]|[A-Za-z_][\w$]*/
      # A JOIN of SQL text: its table (possibly qualified) and its alias.
      STRING_JOIN = /\bJOIN\s+(?<table>(?:#{IDENTIFIER})(?:\s*\.\s*(?:#{IDENTIFIER}))*)(?:\s+(?:AS\s+)?(?<alias>#{IDENTIFIER}))?/i

      class << self
        # @param relation [ActiveRecord::Relation]
        # @return [Array<String>]
        def of(relation)
          arel = relation.arel
          [arel.source.left, *arel.join_sources].flat_map { |node| names_of(node) }.uniq
        end

        # The names a rule's own join gives (its model's query, the rule's
        # path joined as the applier joins it).
        #
        # @param model [Class] the rule's model
        # @param join_type [String] the rule's join type (an unknown one reads as `joins`)
        # @param association_chain [Array<String>] the rule's path, split
        # @return [Array<String>]
        def of_join(model, join_type, association_chain)
          join_method = Services::PermissionRuleApplier::JOIN_METHODS.fetch(join_type.to_s, :joins)
          of(RulePath.join(model.unscoped, join_method, association_chain))
        end

        private

        def names_of(node)
          case node
          when Arel::Nodes::StringJoin then string_join_names(node.left.to_s)
          when Arel::Nodes::Join then names_of(node.left)
          when Arel::Table then [(node.table_alias || node.name).to_s]
          when Arel::Nodes::TableAlias then [node.name.to_s]
          else []
          end
        end

        def string_join_names(sql)
          sql.scan(STRING_JOIN).map do |table, alias_name|
            named = alias_name && !JOIN_KEYWORDS.include?(alias_name.upcase) ? alias_name : table.split('.').last
            unquote(named.strip)
          end
        end

        def unquote(identifier)
          identifier.match?(/\A(["`\[]).*["`\]]\z/) ? identifier[1..-2] : identifier
        end
      end
    end
  end
end
