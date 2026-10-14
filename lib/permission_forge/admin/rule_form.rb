# frozen_string_literal: true

module PermissionForge
  module Admin
    # Form object behind the rule builder: turns the sentence-style inputs
    # (relationship path, field, operator, adaptive value, "the current user",
    # include empty, join choice) into PermissionSetRule attributes, and lists
    # the choices offered at each step from model reflection.
    class RuleForm
      ARITY = {
        'equal' => :one, 'not_equal' => :one, 'less_than' => :one, 'greater_than' => :one,
        'less_than_or_equal' => :one, 'greater_than_or_equal' => :one, 'in' => :list, 'not_in' => :list,
        'contains' => :one, 'not_contains' => :one, 'starts_with' => :one, 'ends_with' => :one,
        'between' => :range, 'is_null' => :none, 'is_not_null' => :none
      }.freeze
      USER_OPERATORS = %w[equal not_equal in not_in is_null is_not_null].freeze
      NULLABLE = %w[equal not_equal in not_in].freeze
      JOINS = %w[auto joins left_joins].freeze
      CURRENT_USER = 'current_user'
      VALUE_ERRORS = { one: :value, list: :list, range: :range }.freeze

      attr_reader :name, :path, :field_name, :operator, :value, :values, :value_from, :value_to,
                  :current_user, :include_nulls, :failure_message, :join, :is_active, :errors

      def initialize(resource:, params: nil, rule: nil, catalog: ModelCatalog.new)
        @resource = resource
        @catalog = catalog
        @errors = {}
        if params
          assign_inputs(RuleFormInput.from_params(normalize(params)))
          @operator = 'equal' unless operators.include?(@operator)
        else
          assign_inputs(RuleFormInput.from_rule(rule))
        end
      end

      # --- choices ----------------------------------------------------------------

      def root_model
        @root_model ||= @catalog.find(@resource.name)
      end

      # [[ModelInfo, Association selected or nil], ...] for each path step, plus
      # the model the field is read from.
      def path_steps
        model = root_model
        steps = []
        @path.each do |assoc_name|
          break unless model

          assoc = model.association(assoc_name)
          steps << [model, assoc]
          model = assoc && @catalog.find(assoc.class_name)
        end
        @target_model = model
        steps
      end

      def target_model
        path_steps unless defined?(@target_model)
        @target_model
      end

      def field_options
        target_model ? target_model.columns.reject(&:virtual?) : []
      end

      def column
        field_options.find { |option| option.name == @field_name }
      end

      def operators
        column&.user_reference? ? USER_OPERATORS : ARITY.keys
      end

      def arity
        ARITY.fetch(@operator, :one)
      end

      def nullable?
        NULLABLE.include?(@operator)
      end

      def user_field?
        column&.user_reference? || false
      end

      def enum_values
        column&.enum_values
      end

      def input_type
        case column&.type
        when :integer, :decimal, :float, :bigint then 'number'
        when :date then 'date'
        when :datetime, :timestamp then 'datetime-local'
        else 'text'
        end
      end

      def follows_relationship?
        @path.any?
      end

      # --- persistence --------------------------------------------------------------

      def valid?
        @errors = {}
        @errors[:name] = :name_blank if @name.blank?
        @errors[:field] = :field if column.nil?
        validate_value
        @errors.empty?
      end

      def attributes
        {
          name: @name, field_name: @field_name, operator: @operator, field_value: field_value,
          field_accessor_path: @path.any? ? @path.join('.') : nil, join_type: join_type,
          include_nulls: nullable? && @include_nulls, failure_message: @failure_message.presence,
          is_active: @is_active
        }
      end

      def field_value
        case arity
        when :none then nil
        when :list then @values.join(',')
        when :range then [@value_from, @value_to].join(',')
        else @current_user ? CURRENT_USER : @value
        end
      end

      # Rules without a relationship are filter rules (join_type nil).
      def join_type
        return nil if @path.empty?
        return @join if %w[joins left_joins].include?(@join)

        @include_nulls ? 'left_joins' : 'joins'
      end

      def auto_join
        @include_nulls ? 'left_joins' : 'joins'
      end

      # Unsaved rule for previews.
      def preview_rule
        PermissionForge::PermissionSetRule.new(attributes.merge(resource: @resource))
      end

      private

      def normalize(params)
        (params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h).deep_stringify_keys
      end

      # Sets the reader ivars (@name, @path, ...) from RuleFormInput.
      def assign_inputs(inputs)
        inputs.each { |key, value| instance_variable_set(:"@#{key}", value) }
      end

      def validate_value
        @errors[:value] = VALUE_ERRORS[arity] if value_missing?
      end

      def value_missing?
        case arity
        when :one then !@current_user && @value.blank?
        when :list then @values.empty?
        when :range then @value_from.blank? || @value_to.blank?
        else false
        end
      end
    end
  end
end
