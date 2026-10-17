module PermissionForge
  # "Who can see iban?" — pick a resource and a field, see its level in every
  # Permission Set that includes the resource.
  #
  # @api private
  class FieldLookupsController < ApplicationController
    # Labels are computed here from the allow-listed resource name (via
    # ModelCatalog, which only resolves real models) so the view never
    # constantizes request input.
    def show
      @resource_names = PermissionForge::Resource.distinct.order(:name).pluck(:name)
      @resource_name = @resource_names.include?(params[:resource]) ? params[:resource] : nil
      model = @resource_name && PermissionForge::Admin::ModelCatalog.new.find(@resource_name)
      @fields = @resource_name ? field_names(@resource_name, model) : []
      @field_options = @fields.map { |name| [name, field_label(model, name)] }
      load_field(model)
    end

    private

    def load_field(model)
      @field = @fields.include?(params[:field]) ? params[:field] : nil
      @field_label = field_label(model, @field) if @field
      @rows = @field ? PermissionForge::Admin::FieldAcrossSets.call(@resource_name, @field) : []
    end

    def field_names(resource_name, model)
      configured = PermissionForge::ResourceField.joins(:resource)
                                                 .where(PermissionForge::Resource.table_name => { name: resource_name })
                                                 .distinct.pluck(:name)
      (configured + (model ? model.managed_column_names + model.virtual_field_names : [])).uniq.sort
    end

    def field_label(model, name)
      PermissionForge::Admin::FieldLabel.for(model, name).text
    end
  end
end
