# frozen_string_literal: true

module PermissionForge
  module Api
    # Template Method concern providing standard CRUD actions for API controllers.
    #
    # Include this concern and override the private template methods to customize
    # behavior per controller. Override any action method for non-standard behavior.
    #
    # @example
    #   class ResourceFieldsController < BaseController
    #     include CrudActions
    #
    #     private
    #
    #     def collection_scope = @resource.resource_fields
    #     def current_record = @field
    #     def serializer_type = :resource_field
    #     def record_params = pf_record_attributes(:resource_field, PermissionForge::ResourceField, :name, :label)
    #   end
    module CrudActions
      extend ActiveSupport::Concern

      def index
        render_collection(collection_scope.order(sort_column), serializer_for(serializer_type))
      end

      def show
        render_record(current_record, serializer_for(serializer_type))
      end

      def create
        record = build_record
        guard_mutation!(:create, record)
        return if performed?

        if record.save
          render_created(record, serializer_for(serializer_type))
        else
          render_validation_errors(record)
        end
      end

      def update
        guard_mutation!(:update, current_record)
        return if performed?

        if current_record.update(record_params)
          render_record(current_record, serializer_for(serializer_type))
        else
          render_validation_errors(current_record)
        end
      end

      def destroy
        guard_mutation!(:destroy, current_record)
        return if performed?

        current_record.destroy!
        head :no_content
      end

      private

      # @return [ActiveRecord::Relation] the parent collection scope
      def collection_scope = raise(NotImplementedError, "#{self.class}#collection_scope")

      # @return [ActiveRecord::Base] the record for show/update/destroy
      def current_record = raise(NotImplementedError, "#{self.class}#current_record")

      # @return [Symbol] key for serializer_for()
      def serializer_type = raise(NotImplementedError, "#{self.class}#serializer_type")

      # @return [ActiveSupport::HashWithIndifferentAccess] the attributes, in
      #   their shapes (BaseController#pf_record_attributes)
      def record_params = raise(NotImplementedError, "#{self.class}#record_params")

      # @return [ActiveRecord::Base] new record built from collection_scope and params
      def build_record = collection_scope.build(record_params)

      # @return [Symbol] default sort column for index
      def sort_column = :name
    end
  end
end
