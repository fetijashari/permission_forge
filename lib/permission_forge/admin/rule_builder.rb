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

      attr_reader :form, :resource, :model_errors

      def initialize(form:, resource:, model_errors: [], configuration: PermissionForge.configuration)
        @form = form
        @resource = resource
        @model_errors = Array(model_errors)
        @configuration = configuration
      end

      def errors = form.errors
      def error_codes = errors.values

      def steps = form.path_steps
      def target = form.target_model

      # A Resource that sees everything makes every rule moot.
      def ignored_warning? = resource.view_all ? true : false

      # The "follow a relationship" select: only while the target has any.
      def follow_options = target ? target.associations : []
      def follow? = follow_options.any?

      def model_missing? = target.nil?

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
