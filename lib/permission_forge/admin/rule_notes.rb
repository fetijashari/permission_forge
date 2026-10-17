# frozen_string_literal: true

module PermissionForge
  module Admin
    # The one list of what the admin says about a stored rule beside its
    # sentence, most severe first: why it matches nothing
    # (Operators::RuleProblem — the taxonomy the audit and Home share), then
    # that it compares a column holding a secret (PermissionForge::SecretColumns:
    # refused for a new rule; this one still evaluates, and who may read
    # which record tells the secret apart). The rule builder's banner, its
    # preview and the Rules tab's row badge all draw this list: Home's "Fix
    # rule" for a secret rule used to open a builder with no banner and a
    # preview that read as fine (field test round 7, B#48b).
    #
    # @example
    #   RuleNotes.for(rule).map(&:kind)   # => [:matches_nothing, :secret_column], [:secret_column] or []
    #
    # @api private
    module RuleNotes
      # `kind`: :matches_nothing (`problem` is the Operators::RuleProblem) or
      # :secret_column (`problem` nil; `column` is the field name as stored).
      Note = Data.define(:kind, :problem, :column) do
        def matches_nothing? = kind == :matches_nothing
      end

      # The kinds, most severe first (the order of the list).
      KINDS = %i[matches_nothing secret_column].freeze

      # @param rule [PermissionSetRule] stored or in memory
      # @param secrets [SecretColumns]
      # @return [Array<Note>]
      def self.for(rule, secrets: PermissionForge::SecretColumns.new)
        return [] if rule.nil?

        problem = PermissionForge::Operators::RuleProblem.for(rule)
        notes = []
        notes << Note.new(kind: :matches_nothing, problem: problem, column: rule.field_name.to_s) if problem
        notes << Note.new(kind: :secret_column, problem: nil, column: rule.field_name.to_s) if secrets.rule?(rule)
        notes
      end
    end
  end
end
