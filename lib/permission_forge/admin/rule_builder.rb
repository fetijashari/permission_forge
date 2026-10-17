# frozen_string_literal: true

module PermissionForge
  module Admin
    # What the rule builder page (permission_set_rules/_builder) decides beyond
    # the RuleForm's own state: which notes show, which option is selected in
    # each select, and how the "how to combine" choices read. The template only
    # draws it.
    #
    # @example
    #   builder = RuleBuilder.new(form: form, resource: resource, model_errors: [])
    #   builder.ignored_warning?       # => false
    #   builder.join_choices.map(&:join) # => ['auto', 'joins', 'left_joins']
    class RuleBuilder
      # join: the value; checked: the stored choice; auto: the one that is
      # automatic (its title is named in the "auto" description).
      JoinChoice = Struct.new(:join, :checked, :auto, keyword_init: true) do
        def auto? = join == 'auto'
      end

      # The builder's own label for an attribute the model refused (Rails'
      # full_messages would say "Field accessor path …", in English). An
      # attribute the builder does not show gets its message alone.
      ERROR_LABELS = {
        name: 'builder.name', field_accessor_path: 'builder.relationship', field_name: 'builder.field',
        operator: 'builder.operator', field_value: 'value_input.value', join_type: 'builder.join',
        failure_message: 'builder.message', is_active: 'builder.active'
      }.freeze

      attr_reader :form, :resource

      # rule: the saved rule being edited (nil for a new one).
      # model_errors: the rule's ActiveModel::Errors after a refused save (or messages).
      def initialize(form:, resource:, model_errors: [], rule: nil, configuration: PermissionForge.configuration)
        @form = form
        @resource = resource
        @model_errors = model_errors.respond_to?(:errors) ? model_errors.errors : Array(model_errors)
        @rule = rule
        @configuration = configuration
      end

      # Why the saved rule matches nothing — a column or relationship that is
      # not there (Operators::RuleProblem) — or nil. Only for the rule as it
      # is stored: a change that did not save shows the model's own errors.
      def problem
        return @problem if defined?(@problem)

        @problem = notes.find(&:matches_nothing?)&.problem
      end

      # What is said beside the saved rule (Admin::RuleNotes: why it matches
      # nothing, then a secret column), for the rule as it is stored; a
      # change that did not save shows the model's own errors.
      #
      # @return [Array<RuleNotes::Note>]
      def notes
        @notes ||= @rule&.persisted? && !@rule.changed? ? RuleNotes.for(@rule) : []
      end

      # The saved rule's path and field name as stored ("ownr.owner_id"),
      # beside the problem's sentence — nil when it is the name the sentence
      # already says (field test round 6, B #63: "stauts is not a column of
      # Customer · stauts").
      def written_field
        written = PermissionForge::Operators::RuleProblem.written_field(@rule)
        written unless problem && written == problem.name
      end

      def errors = form.errors
      def error_codes = errors.values

      # The model's refusals, each named with the builder's label for its field:
      # "Relationship names ownr, which is not an association of Customer".
      def model_errors
        @model_errors.map { |error| RuleBuilder.error_text(error) }
      end

      # A model error as the builder words it: its message, named with the
      # builder's label for its field (ERROR_LABELS) — the footer of a
      # refused save and the preview (RulePreview) say the same.
      #
      # @param error [ActiveModel::Error, #to_s] a message given as text is shown as it is
      # @return [String]
      def self.error_text(error)
        return error.to_s unless error.respond_to?(:attribute)

        key = ERROR_LABELS[error.attribute.to_sym]
        return error.message unless key

        I18n.t('permission_forge.permission_set_rules.builder.model_error',
               field: I18n.t("permission_forge.permission_set_rules.#{key}"), message: error.message)
      end

      def steps = form.path_steps
      def target = form.target_model

      # A Resource that sees everything makes every rule moot.
      def ignored_warning? = resource.view_all ? true : false

      # The "follow a relationship" select: only while the target has any.
      def follow_options = target ? target.associations : []
      def follow? = follow_options.any?

      def model_missing? = target.nil?

      # The stored segment of a path step that names no relationship ("ownr"):
      # its select shows "Pick a relationship…" with this value instead of
      # the first relationship as if it were chosen, and a refresh keeps it.
      def broken_step(index)
        step = steps[index]
        form.path[index] if step && step.last.nil?
      end

      # The stored field while the path leads nowhere: the field select has
      # no columns to offer, so it keeps this one selected; picking the
      # relationship again keeps it when it is a column there.
      def kept_field = (form.field_name.presence if model_missing?)

      # Open the advanced panel when the join is not the automatic one.
      def advanced_open? = form.join != 'auto'

      def join_choices
        RuleForm::JOINS.map { |join| JoinChoice.new(join: join, checked: form.join == join, auto: form.auto_join) }
      end

      def scoping_on? = @configuration.auto_query_scoping.to_s == 'filter_only'

      def field_selected?(column) = column.name == form.field_name
      def operator_selected?(operator) = operator == form.operator
    end
  end
end
