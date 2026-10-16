require_relative 'gdpr_field_auditor/text_report'

module PermissionForge
  module Services
    # Reports fields that look like personal data and are neither masked nor mapped. It reports and never changes anything.
    #
    # @api public
    class GdprFieldAuditor
      # @param configuration [Configuration]
      # @param sensitive [SensitiveColumns] the matcher (default: one on `configuration`)
      # @return [Array<Hash>] one entry per finding
      def self.call(configuration: PermissionForge.configuration, sensitive: nil)
        new(configuration: configuration, sensitive: sensitive).call
      end

      # What is personal data, and with which mask, is
      # PermissionForge::SensitiveColumns' answer — the same the admin, the
      # field generator and the boot warning get. A column the host's
      # filter_parameters name counts while filter_parameters_integration is on.
      def initialize(configuration: PermissionForge.configuration, sensitive: nil)
        @configuration = configuration
        @sensitive = sensitive || PermissionForge::SensitiveColumns.new(configuration: configuration)
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

      # Rows that show the field in the clear (ResourceField.exposing_in_clear:
      # read on, no mask). A Hidden row is not one: it shows nothing.
      def audit_unmasked_fields(report)
        granting_fields.exposing_in_clear.preload(resource: :permission_set).find_each do |field|
          match = @sensitive.match(field.name)
          report << unmasked_finding(field, match) if match
        end
      end

      def unmasked_finding(field, match)
        resource = field.resource
        { type: :unmasked_field, resource_field_id: field.id, field_name: field.name, resource_name: resource.name,
          suggested_strategy: match.strategy, pattern: match.pattern, permission_set: resource.permission_set.name }
      end

      def audit_unmapped_columns(report)
        PermissionForge::Resource.distinct.pluck(:name).each do |resource_name|
          audit_unmapped_for_resource(report, resource_name)
        end
      rescue ActiveRecord::StatementInvalid
        # Tables don't exist yet (pre-migration)
      end

      # `pattern_matched` is the recommended strategy (the key existing CI
      # scripts read); `pattern` names what matched.
      def audit_unmapped_for_resource(report, resource_name)
        columns = model_columns_for(resource_name)
        return unless columns

        virtual = unmapped_virtual_names_for(resource_name)
        mapped_names = mapped_field_names_for(resource_name)
        (columns + virtual - mapped_names).each do |column_name|
          match = @sensitive.match(column_name)
          next unless match

          finding = { type: :unmapped_column, resource: resource_name, column: column_name,
                      pattern_matched: match.strategy, pattern: match.pattern }
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

      # Resources in effect in a granting Permission Set that grant read
      # (Resource.in_effect: the one definition of "in effect").
      def granting_resources
        PermissionForge::Resource.in_effect.merge(PermissionForge::PermissionSet.granting)
                                 .where(read_access: true).preload(:permission_set, :resource_fields)
      end

      # [[name, suggested strategy]] for the model's implicitly granted names
      # that look like personal data. Names in ignored_fields are left out:
      # the admin does not manage those.
      def implicit_pii_fields(resource_name)
        @implicit_pii_fields ||= {}
        @implicit_pii_fields[resource_name] ||= begin
          names = Array(virtual_fields(resource_name)&.implicit).uniq - Array(@configuration.ignored_fields).map(&:to_s)
          names.filter_map { |name| (match = @sensitive.match(name)) && [name, match.strategy] }
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
        model_class = model_for(resource_name)
        return unless model_class && model_columns_for(resource_name)

        PermissionForge::VirtualFields.new(model_class, @configuration)
      end

      def model_for(resource_name)
        PermissionForge::ModelLookup.model_for(resource_name)
      end

      def model_columns_for(resource_name)
        model_for(resource_name)&.column_names
      rescue ActiveRecord::StatementInvalid
        nil
      end

      # Names with a field row in effect in any granting Permission Set. A row
      # the engine skips counts as no row.
      def mapped_field_names_for(resource_name)
        granting_fields.merge(PermissionForge::Resource.where(name: resource_name)).distinct.pluck(:name)
      end

      # A switched-off row counts as no row.
      def audit_view_all_on_pii_resources(report)
        resources_with_bypass.find_each do |resource|
          pii_fields = resource.resource_fields.select { |field| field.is_active && @sensitive.sensitive?(field.name) }
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

      # Masks combine with AND, so a row in the clear wins over a masked row
      # of the same field of the same resource in another Permission Set.
      # The finding names both: the set that unmasks and the sets that mask.
      def audit_cross_set_unmasking(report)
        masking_sets = sets_masking_pii_fields
        granting_fields.exposing_in_clear.preload(resource: :permission_set).find_each do |field|
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

      # { [resource name, field name] => { id => name } of the granting sets
      # that mask it }. Only a row that grants read votes on the mask
      # (FieldPermissionMerger.merge_row).
      def sets_masking_pii_fields
        masked = granting_fields.where(read_access: true, mask_access: true).preload(resource: :permission_set)
        masked.select { |field| @sensitive.sensitive?(field.name) }.each_with_object({}) do |field, sets|
          resource = field.resource
          (sets[[resource.name, field.name]] ||= {})[resource.permission_set_id] = resource.permission_set.name
        end
      end
    end
  end
end
