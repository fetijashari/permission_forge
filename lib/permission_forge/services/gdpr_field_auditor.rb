require_relative 'gdpr_field_auditor/text_report'

module PermissionForge
  module Services
    # Reports fields that look like personal data and are neither masked nor mapped. It reports and never changes anything.
    #
    # @api public
    class GdprFieldAuditor
      # @param configuration [Configuration]
      # @return [Array<Hash>] one entry per finding
      def self.call(configuration: PermissionForge.configuration)
        new(configuration: configuration).call
      end

      def initialize(configuration: PermissionForge.configuration)
        @configuration = configuration
      end

      # @return [Array<Hash>] one entry per finding
      def call
        report = []
        audit_unmasked_fields(report)
        audit_unmapped_columns(report)
        audit_implicit_virtual_grants(report)
        audit_view_all_on_pii_resources(report)
        audit_cross_set_unmasking(report)
        report
      end

      private

      # Field rows that reach someone's permission hash: in effect, in a
      # granting Permission Set. Every check reads rows through here, so a row
      # the engine skips (switched off, or in a switched-off resource or set,
      # or in a muting set) is never reported as both "unmasked" and "unmapped".
      def granting_fields
        PermissionForge::ResourceField.in_effect.merge(PermissionForge::PermissionSet.granting)
      end

      def audit_unmasked_fields(report)
        granting_fields.where(mask_access: false).preload(resource: :permission_set).find_each do |field|
          report << unmasked_finding(field) if gdpr_field?(field.name)
        end
      end

      def unmasked_finding(field)
        resource = field.resource
        { type: :unmasked_field, resource_field_id: field.id, field_name: field.name, resource_name: resource.name,
          suggested_strategy: gdpr_strategy(field.name), permission_set: resource.permission_set.name }
      end

      def audit_unmapped_columns(report)
        PermissionForge::Resource.distinct.pluck(:name).each do |resource_name|
          audit_unmapped_for_resource(report, resource_name)
        end
      rescue ActiveRecord::StatementInvalid
        # Tables don't exist yet (pre-migration)
      end

      def audit_unmapped_for_resource(report, resource_name)
        columns = model_columns_for(resource_name)
        return unless columns

        virtual = unmapped_virtual_names_for(resource_name)
        mapped_names = mapped_field_names_for(resource_name)
        (columns + virtual - mapped_names).each do |column_name|
          match = gdpr_patterns.find { |regex, _| column_name.match?(regex) }
          next unless match

          finding = { type: :unmapped_column, resource: resource_name, column: column_name, pattern_matched: match[1] }
          report << (virtual.include?(column_name) ? finding.merge(virtual: true) : finding)
        end
      end

      # Virtual fields that follow unconfigured_field_strategy when nobody
      # configured them. Implicitly granted ones are reported per Permission
      # Set by audit_implicit_virtual_grants instead.
      def unmapped_virtual_names_for(resource_name)
        fields = virtual_fields(resource_name)
        return [] unless fields

        fields.names.reject { |name| fields.implicit_grant?(name) }
      end

      # Declared virtual fields that look like personal data and have no active
      # field row in a granting resource: under extra_fields_default_access =
      # :grant that set gives its people read and edit on them, unmasked.
      def audit_implicit_virtual_grants(report)
        return unless @configuration.grant_extra_fields_by_default?

        granting_resources.each { |resource| report.concat(implicit_virtual_grants_in(resource)) }
      rescue ActiveRecord::StatementInvalid
        # Tables don't exist yet (pre-migration)
      end

      # A switched-off row counts as no row, because the engine skips it.
      def implicit_virtual_grants_in(resource)
        configured = resource.resource_fields.select(&:is_active).map(&:name)
        implicit_pii_fields(resource.name).filter_map do |name, strategy|
          next if configured.include?(name)

          { type: :implicit_virtual_grant, resource_name: resource.name, field_name: name,
            suggested_strategy: strategy, permission_set: resource.permission_set.name }
        end
      end

      def granting_resources
        granting_sets = PermissionForge::PermissionSet.active.granting.select(:id)
        PermissionForge::Resource.active.where(read_access: true, permission_set_id: granting_sets)
                                 .includes(:permission_set, :resource_fields)
      end

      # [[name, suggested strategy]] for the model's implicitly granted names
      # that match a GDPR pattern. Names in ignored_fields are left out: the
      # admin does not manage those.
      def implicit_pii_fields(resource_name)
        @implicit_pii_fields ||= {}
        @implicit_pii_fields[resource_name] ||= begin
          names = Array(virtual_fields(resource_name)&.implicit).uniq - Array(@configuration.ignored_fields).map(&:to_s)
          names.filter_map { |name| [name, gdpr_strategy(name)] if gdpr_field?(name) }
        end
      end

      # @return [PermissionForge::VirtualFields, nil] nil when the resource
      #   names no model whose columns can be read.
      def virtual_fields(resource_name)
        @virtual_fields ||= {}
        @virtual_fields.fetch(resource_name) do
          @virtual_fields[resource_name] = build_virtual_fields(resource_name)
        end
      end

      def build_virtual_fields(resource_name)
        return unless model_columns_for(resource_name)

        PermissionForge::VirtualFields.new(resource_name.safe_constantize, @configuration)
      end

      def model_columns_for(resource_name)
        model_class = resource_name.safe_constantize
        return unless model_class
        return unless model_class.respond_to?(:column_names)

        model_class.column_names
      rescue ActiveRecord::StatementInvalid
        nil
      end

      # Names with a field row in effect in any granting Permission Set. A row
      # the engine skips counts as no row.
      def mapped_field_names_for(resource_name)
        granting_fields.merge(PermissionForge::Resource.where(name: resource_name)).distinct.pluck(:name)
      end

      def audit_view_all_on_pii_resources(report)
        resources_with_bypass.find_each do |resource|
          pii_fields = resource.resource_fields.select { |field| gdpr_field?(field.name) }
          next if pii_fields.empty?

          report << build_view_all_finding(resource, pii_fields)
        end
      rescue ActiveRecord::StatementInvalid
        # Tables don't exist yet (pre-migration)
      end

      # Resources in effect in a granting Permission Set. In a muting set
      # view_all takes the bypass away, and a switched-off row gives nothing.
      def resources_with_bypass
        resources = PermissionForge::Resource.arel_table
        PermissionForge::Resource.in_effect.merge(PermissionForge::PermissionSet.granting)
                                 .where(resources[:view_all].eq(true).or(resources[:modify_all].eq(true)))
      end

      def build_view_all_finding(resource, pii_fields)
        bypasses = []
        bypasses << 'view_all' if resource.view_all
        bypasses << 'modify_all' if resource.modify_all

        { type: :view_all_on_pii_resource, resource_name: resource.name,
          permission_set: resource.permission_set.name, bypasses: bypasses,
          pii_fields: pii_fields.map(&:name) }
      end

      # Masks combine with AND, so an unmasked row wins over a masked row of
      # the same field of the same resource in another Permission Set. The
      # finding names both: the set that unmasks and the sets that mask.
      def audit_cross_set_unmasking(report)
        masking_sets = sets_masking_pii_fields
        granting_fields.where(mask_access: false).preload(resource: :permission_set).find_each do |field|
          finding = cross_set_finding(field, masking_sets.fetch([field.resource.name, field.name], {}))
          report << finding if finding
        end
      rescue ActiveRecord::StatementInvalid
        # Tables don't exist yet (pre-migration)
      end

      # @param masking [Hash{Integer => String}] the sets that mask the field, by id
      # @return [Hash, nil] nil when no other set masks it
      def cross_set_finding(field, masking)
        resource = field.resource
        masked_in = masking.except(resource.permission_set_id).values.sort
        return if masked_in.empty?

        { type: :cross_set_unmasking, field_name: field.name, resource_name: resource.name,
          permission_set: resource.permission_set.name, masked_in: masked_in }
      end

      # { [resource name, field name] => { id => name } of the granting sets that mask it }
      def sets_masking_pii_fields
        masked = granting_fields.where(mask_access: true).preload(resource: :permission_set)
        masked.select { |field| gdpr_field?(field.name) }.each_with_object({}) do |field, sets|
          resource = field.resource
          (sets[[resource.name, field.name]] ||= {})[resource.permission_set_id] = resource.permission_set.name
        end
      end

      def gdpr_field?(name)
        gdpr_patterns.any? { |regex, _| name.match?(regex) }
      end

      def gdpr_strategy(name)
        gdpr_patterns.find { |regex, _| name.match?(regex) }&.last
      end

      def gdpr_patterns
        @configuration.gdpr_field_patterns
      end
    end
  end
end
