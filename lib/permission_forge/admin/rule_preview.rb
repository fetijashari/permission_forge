# frozen_string_literal: true

module PermissionForge
  module Admin
    # What the rule builder's preview shows: the controller's save path run
    # in memory — RuleForm's own checks first, then the model's validations
    # on the attributes the sentence shows (SENTENCE_ATTRIBUTES) — and the
    # first error that save would answer (#refusal, worded by the builder as
    # its form shows it: RuleBuilder.error_text), else the saved rule's
    # sentence and what is said beside it (RuleNotes). Nothing is saved.
    # The preview used to check RuleProblem before the save's own checks,
    # and gave a reason the save would not ("a, is not a value status can
    # hold" for an "is between" with one end typed, where the save says
    # "Enter both ends of the range."; field test round 7, B#87). The rule's
    # name and blocked message are not part of the sentence: their errors
    # are the form's, not the preview's.
    #
    # @example
    #   preview = RulePreview.new(form: form, resource: resource, stored: rule)
    #   preview.refusal&.text     # => "Enter both ends of the range."
    #   preview.rule              # => the PermissionSetRule the save would write (unsaved)
    #
    # @api private
    class RulePreview
      # The attributes of a rule its sentence shows.
      SENTENCE_ATTRIBUTES = %i[field_name operator field_value join_type field_accessor_path].freeze
      # RuleForm's error keys about those (`name` is not one).
      FORM_ERRORS = %i[field operator value].freeze

      # The first error the save would answer: a RuleForm error code, or a
      # model error (ActiveModel::Error); `text` as the builder's form says it.
      Refusal = Data.define(:code, :error) do
        def text = code ? I18n.t("permission_forge.permission_set_rules.builder.errors.#{code}") : RuleBuilder.error_text(error)
      end

      attr_reader :form

      # @param form [RuleForm] the inputs as posted
      # @param resource [Resource]
      # @param stored [PermissionSetRule, nil] the rule being edited (nil for a new one); never changed
      def initialize(form:, resource:, stored: nil)
        @form = form
        @resource = resource
        @stored = stored
      end

      # Nothing to preview yet: no field is chosen (the sentence needs one).
      def empty? = form.column.nil?

      # @return [Refusal, nil]
      def refusal
        return @refusal if defined?(@refusal)

        @refusal = form_refusal || model_refusal
      end

      # The rule the save would write, unsaved: the stored rule (read again,
      # so the caller's copy is never changed) or a new one, with the form's
      # attributes.
      #
      # @return [PermissionSetRule]
      def rule
        @rule ||= base_rule.tap { |rule| rule.assign_attributes(form.attributes) }
      end

      # What is said beside the sentence (RuleNotes) other than why it
      # matches nothing, which the sentence says itself.
      #
      # @return [Array<RuleNotes::Note>]
      def notes
        RuleNotes.for(rule).reject(&:matches_nothing?)
      end

      private

      def form_refusal
        form.valid?
        code = form.errors.slice(*FORM_ERRORS).values.first
        Refusal.new(code: code, error: nil) if code
      end

      def model_refusal
        return if form.errors.except(:name).any?

        rule.valid?
        error = rule.errors.find { |candidate| SENTENCE_ATTRIBUTES.include?(candidate.attribute.to_sym) }
        Refusal.new(code: nil, error: error) if error
      end

      def base_rule
        stored = (@resource.permission_set_rules.find_by(id: @stored.id) if @stored&.persisted?)
        stored || PermissionForge::PermissionSetRule.new(resource: @resource, permission_set: @resource.permission_set)
      end
    end
  end
end
