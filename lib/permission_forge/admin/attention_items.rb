# frozen_string_literal: true

module PermissionForge
  module Admin
    # Everything the admin home page asks the owner to look at. Each finder is
    # a read-only query; actions (extend, keep, clean up, acknowledge) live in
    # the controllers.
    class AttentionItems
      ENDING_DAYS = 7

      # `field` — the field row, when there is one, switched on or off.
      # `implicit_grant` — no active field row, and the field is readable and
      # editable anyway because the model declares it as an extra (virtual) field.
      SensitiveFinding = Struct.new(:permission_set, :resource, :field, :column, :match, :people_count, :implicit_grant,
                                    keyword_init: true) do
        # No setting in force: no row, or one that is turned off (the engine skips it).
        def unconfigured? = field.nil? || turned_off?
        def turned_off? = !field.nil? && !field.is_active
        def implicit_grant? = implicit_grant == true
        def name = field&.name || column
      end

      TidyFinding = Struct.new(:permission_set, :kind, :people_count, keyword_init: true) do
        # A finding for an active set nobody uses, or an inactive set people
        # are still assigned to; nil otherwise.
        def self.for(permission_set, people)
          active = permission_set.is_active
          if people.zero? && active
            new(permission_set: permission_set, kind: :no_people, people_count: 0)
          elsif people.positive? && !active
            new(permission_set: permission_set, kind: :inactive_with_people, people_count: people)
          end
        end
      end

      # Active record rules the app's query scoping won't apply to every query:
      # all of them while auto_query_scoping is off, join rules when it's on.
      RulesFinding = Struct.new(:permission_set, :resource, :rule_count, :people_count, keyword_init: true) do
        def self.build(resource, rule_count, people_counts)
          new(permission_set: resource.permission_set, resource: resource, rule_count: rule_count,
              people_count: people_counts.fetch(resource.permission_set_id, 0))
        end
      end

      def self.acknowledgement_supported?
        PermissionForge::ResourceField.column_names.include?('sensitive_acknowledged_at')
      rescue StandardError
        false
      end

      def initialize(configuration: PermissionForge.configuration, catalog: ModelCatalog.new,
                     sensitive: SensitiveColumns.new(configuration: configuration))
        @configuration = configuration
        @catalog = catalog
        @sensitive = sensitive
      end

      def total
        [audit_findings.size, privacy_findings.size, unenforced_rules.size, ending_soon.size, expired.size, stale.size,
         tidy.size].sum
      end

      def all_good?
        total.zero?
      end

      # --- Audit log -----------------------------------------------------------

      # [AuditLog.recording_problem] — :off, :failing or :missing_table —
      # while the log does not record. Empty when it records.
      def audit_findings
        @audit_findings ||= [audit_problem].compact
      end

      # --- Privacy audit ------------------------------------------------------

      def privacy_findings
        @privacy_findings ||= unmasked_sensitive_fields + unconfigured_sensitive_fields
      end

      # --- Record rules --------------------------------------------------------

      def unenforced_rules
        @unenforced_rules ||= begin
          enforced = rule_enforced_resources
          counts = unenforced_rule_scope.where(resource_id: enforced.keys).group(:resource_id).count
          findings = counts.map { |id, count| RulesFinding.build(enforced.fetch(id), count, people_counts) }
          findings.sort_by { |finding| [finding.permission_set.name, finding.resource.name] }
        end
      end

      def auto_query_scoping?
        @configuration.auto_query_scoping_enabled?
      end

      # --- Assignments --------------------------------------------------------

      def ending_soon
        @ending_soon ||= assignments.where(expires_at: Time.current..ENDING_DAYS.days.from_now.end_of_day)
                                    .order(:expires_at).to_a
      end

      def expired
        @expired ||= assignments.expired.order(:expires_at).to_a
      end

      def stale
        @stale ||= assignments.stale_before(stale_days.days.ago)
                              .order(PermissionForge::PermissionSetUser.last_reviewed_column).to_a
      end

      def stale_days
        @configuration.admin_stale_assignment_days || 90
      end

      # --- Permission Sets to tidy up -----------------------------------------

      def tidy
        @tidy ||= PermissionForge::PermissionSet.order(:name).filter_map do |ps|
          TidyFinding.for(ps, people_counts.fetch(ps.id, 0))
        end
      end

      private

      def audit_problem = AuditLog.recording_problem(@configuration)

      def assignments
        PermissionForge::PermissionSetUser.includes(:permission_set, :user)
      end

      # Resources whose rules are in force (View All / Modify All skip them), by id.
      def rule_enforced_resources
        granting_resources.reject(&:rules_bypassed?).index_by(&:id)
      end

      def unenforced_rule_scope
        rules = PermissionForge::PermissionSetRule.active
        auto_query_scoping? ? rules.join_type_rules : rules
      end

      def people_counts
        @people_counts ||= PermissionForge::PermissionSetUser.active_assignments.group(:permission_set_id).count
      end

      def granting_resources
        @granting_resources ||= PermissionForge::Resource.active.where(read_access: true)
                                                         .where(permission_set_id: PermissionForge::PermissionSet.active.granting.select(:id))
                                                         .includes(:permission_set, :resource_fields).to_a
      end

      def unmasked_sensitive_fields
        acknowledged = self.class.acknowledgement_supported?
        granting_resources.flat_map do |resource|
          resource.resource_fields.filter_map do |field|
            sensitive_finding(resource, field.name, field: field) if exposed?(field, acknowledged)
          end
        end
      end

      # Readable and unmasked, and not acknowledged as intentional.
      def exposed?(field, acknowledged)
        return false unless field.is_active && field.read_access && !field.mask_access

        !(acknowledged && field.sensitive_acknowledged_at.present?)
      end

      # Sensitive columns and virtual fields with no active field row are a
      # leak when they are readable unmasked anyway: the unconfigured-field
      # strategy lets them through, or the model declares them as extra fields
      # and extra_fields_default_access grants those. A switched-off row
      # counts as no row, because the engine skips it; its finding keeps the
      # row, so the card can say "turned off" instead of "not configured".
      def unconfigured_sensitive_fields
        passes = %w[pass_through warn].include?(@configuration.unconfigured_field_strategy.to_s)
        return [] unless passes || @configuration.grant_extra_fields_by_default?

        granting_resources.flat_map { |resource| unconfigured_findings(resource, passes) }
      end

      # `passes` — whether unconfigured_field_strategy lets a field with no row through.
      def unconfigured_findings(resource, passes)
        model = @catalog.find(resource.name)
        return [] unless model

        rows = resource.resource_fields.index_by(&:name)
        model.managed_field_names.filter_map do |name|
          row = rows[name]
          next if row&.is_active

          implicit = model.implicit_grant?(name)
          sensitive_finding(resource, name, field: row, implicit_grant: implicit) if implicit || passes
        end
      end

      # A finding when `column` looks sensitive, else nil. `details` are the
      # finding's own attributes (field:, implicit_grant:).
      def sensitive_finding(resource, column, **details)
        match = @sensitive.match(column)
        return unless match

        SensitiveFinding.new(permission_set: resource.permission_set, resource: resource, column: column, match: match,
                             people_count: people_counts.fetch(resource.permission_set_id, 0), **details)
      end
    end
  end
end
