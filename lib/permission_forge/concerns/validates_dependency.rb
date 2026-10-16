# frozen_string_literal: true

module PermissionForge
  module Concerns
    # Declarative validation for boolean permission field dependencies.
    #
    # @example
    #   class Resource < ActiveRecord::Base
    #     include PermissionForge::Concerns::ValidatesDependency
    #
    #     validates_dependency :edit_access, requires: :read_access
    #     validates_dependency :delete_access, requires: :read_access
    #   end
    #
    #   resource = Resource.new(edit_access: true, read_access: false)
    #   resource.valid? # => false
    #   resource.errors[:edit_access] # => ["requires read_access to be enabled"]
    #
    # @api private
    module ValidatesDependency
      extend ActiveSupport::Concern

      private

      # Checks if this record belongs to a muting permission set.
      # Works for both Resource (direct) and ResourceField (via resource).
      def belongs_to_muting_permission_set?
        ps = if respond_to?(:permission_set)
               permission_set
             elsif respond_to?(:resource) && resource.respond_to?(:permission_set)
               resource.permission_set
             end
        ps&.is_muting == true
      end

      class_methods do
        # @param field [Symbol] the dependent boolean field
        # @param requires [Symbol] the prerequisite boolean field
        def validates_dependency(field, requires:)
          method_name = :"validate_#{field}_requires_#{requires}"

          validate method_name

          define_method(method_name) do
            return if belongs_to_muting_permission_set?

            return unless send(field) && !send(requires)

            errors.add(field, :requires,
                       message: I18n.t('permission_forge.validations.requires', requires: requires))
          end
          private method_name
        end
      end
    end
  end
end
