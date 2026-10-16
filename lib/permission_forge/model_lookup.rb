# frozen_string_literal: true

module PermissionForge
  # "This name is a model with a table" has one definition: the class a
  # Resource name or a rule's Resource stands for, when it is an ActiveRecord
  # model that is not abstract and whose table exists. Anything else — a
  # module (`Kernel`), a class that is no model (`String`), an abstract
  # model, a model whose table is not there yet, a name that is no constant,
  # a constant whose file raises while it loads — is no model: the callers
  # describe or skip, they never fail on it (a Resource named `Kernel` made
  # the field generator raise NoMethodError and the API answer 500).
  #
  # @example
  #   ModelLookup.model_for('Customer')  # => Customer
  #   ModelLookup.model_for('Kernel')    # => nil
  #
  # @api private
  module ModelLookup
    # What is rescued while a name is resolved: anything raised as the
    # constant loads, a model file's SyntaxError or LoadError included.
    UNTELLABLE = [StandardError, ScriptError].freeze

    module_function

    # @param name [String, Symbol, nil] a constant path
    # @return [Class, nil] the model, or nil when the name is no model with a table
    def model_for(name)
      klass = name.to_s.safe_constantize
      klass if klass.is_a?(Class) && klass < ActiveRecord::Base && !klass.abstract_class? && klass.table_exists?
    rescue *UNTELLABLE
      nil
    end

    # @param name [String, Symbol, nil]
    # @return [Boolean] whether the name is a model with a table
    def model?(name)
      !model_for(name).nil?
    end
  end
end
