# frozen_string_literal: true

module PermissionForge
  module Admin
    # Everything the admin home page asks the owner to look at. Each finder is
    # a read-only query; actions (extend, keep, clean up, acknowledge) live in
    # the controllers.
    class AttentionItems
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

        # Masking, acknowledging or adding the field changes what the locked
        # field, Resource or Permission Set holds: refused (EditableLock), so
        # Home offers neither "Fix" nor "This is intended" for it.
        def locked? = !EditableLock.locked_record(field, resource).nil?

        # Home offers "This is intended" for it: a field that is shown unmasked
        # and can be changed (acknowledging needs the column, see
        # .acknowledgement_supported?).
        def acknowledgeable? = !unconfigured? && !locked?
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

      # An active rule in effect that matches nothing because it names a
      # column or an association that is not there (Operators::RuleProblem):
      # everyone it applies to is denied every record of its resource.
      BrokenRuleFinding = Struct.new(:rule, :problem, :people_count, keyword_init: true) do
        def resource = rule.resource
        def permission_set = rule.resource.permission_set

        # The rule, its Resource or its Permission Set is locked: Home opens
        # the Rules tab instead of the rule's edit page (which refuses it).
        def locked? = !EditableLock.locked_record(rule).nil?
      end

      # A field row in effect masked with a strategy this app does not know.
      MaskStrategyFinding = Struct.new(:field, :people_count, keyword_init: true) do
        def resource = field.resource
        def permission_set = field.resource.permission_set
      end

      # A set whose activation condition nobody can judge: a muting one
      # applies to every request, a granting one never passes.
      ConditionsFinding = Struct.new(:permission_set, :people_count, keyword_init: true)

      # A rule in effect that compares a column holding a secret
      # (PermissionForge::SecretColumns), stored before the model refused one.
      SecretRuleFinding = Struct.new(:rule, :people_count, keyword_init: true) do
        def resource = rule.resource
        def permission_set = rule.resource.permission_set
        def locked? = !EditableLock.locked_record(rule).nil?
      end

      def self.acknowledgement_supported? = PermissionForge::ResourceField.acknowledgement_supported?

      # The threshold of "due for review", in days: config.admin_stale_assignment_days,
      # or the default while it is nil. The one definition — Home's Stale
      # card, the People page (pf_stale?), the audit's stale_assignments and
      # StaleAssignmentAuditor all read it.
      #
      # @param configuration [Configuration]
      # @return [Integer]
      def self.stale_days(configuration = PermissionForge.configuration)
        configuration.try(:admin_stale_assignment_days) || Configuration::AdminUiSettings::DEFAULT_STALE_ASSIGNMENT_DAYS
      end

      # The catalog only counts (`verify: false`): every admin page draws the
      # navigation's count, so it reads the schema cache, never the database.
      def initialize(configuration: PermissionForge.configuration, catalog: ModelCatalog.new(verify: false),
                     sensitive: SensitiveColumns.new(configuration: configuration))
        @configuration = configuration
        @catalog = catalog
        @sensitive = sensitive
      end

      # Every list Home draws a card for (the navigation counts them all).
      CARDS = %i[audit_findings broken_rules secret_rules unknown_mask_strategies broken_conditions privacy_findings
                 unenforced_rules ending_soon expired stale tidy].freeze

      def total
        CARDS.sum { |card| public_send(card).size }
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
          counts = unenforced_rule_counts(enforced.keys)
          findings = counts.map { |id, count| RulesFinding.build(enforced.fetch(id), count, people_counts) }
          findings.sort_by { |finding| [finding.permission_set.name, finding.resource.name] }
        end
      end

      # Rules in effect that name a column or an association that is not
      # there — the audit's missing_rule_columns finding, the same rules.
      def broken_rules
        @broken_rules ||= rules_in_effect.filter_map do |rule|
          problem = PermissionForge::Operators::RuleProblem.for(rule)
          next unless problem

          BrokenRuleFinding.new(rule: rule, problem: problem, people_count: people_counts.fetch(rule.resource.permission_set_id, 0))
        end
      end

      # Rules in effect that compare a column holding a secret — the audit's
      # secret_rule_columns finding, the same rules. They still apply.
      def secret_rules
        @secret_rules ||= begin
          secrets = PermissionForge::SecretColumns.new(configuration: @configuration)
          rules_in_effect.select { |rule| secrets.rule?(rule) }.map do |rule|
            SecretRuleFinding.new(rule: rule, people_count: people_counts.fetch(rule.resource.permission_set_id, 0))
          end
        end
      end

      # --- Field rows and conditions the engine cannot read as written ----------

      # Field rows in effect masked with a strategy this app does not know
      # (ResourceField.with_unknown_mask_strategy, the audit's
      # unknown_mask_strategies): masked fully until fixed.
      def unknown_mask_strategies
        @unknown_mask_strategies ||= PermissionForge::ResourceField.with_unknown_mask_strategy.map do |field|
          MaskStrategyFinding.new(field: field, people_count: people_counts.fetch(field.resource.permission_set_id, 0))
        end
      end

      # Sets whose activation conditions nobody can judge
      # (PermissionSet.with_broken_conditions, the audit's incomplete_conditions).
      def broken_conditions
        @broken_conditions ||= PermissionForge::PermissionSet.with_broken_conditions.map do |set|
          ConditionsFinding.new(permission_set: set, people_count: people_counts.fetch(set.id, 0))
        end
      end

      # Active rules of the granting resources in effect: the rules that are
      # applied right now (a muting set's rules never are). Not the ones View
      # All skips — nobody is denied by those.
      def rules_in_effect
        @rules_in_effect ||= begin
          enforced = granting_resources.reject(&:rules_bypassed?).map(&:id)
          PermissionForge::PermissionSetRule.active.where(resource_id: enforced)
                                            .includes(resource: :permission_set).order(:resource_id, :id).to_a
        end
      end

      def auto_query_scoping?
        @configuration.auto_query_scoping_enabled?
      end

      # --- Assignments --------------------------------------------------------

      def ending_soon
        @ending_soon ||= assignments.ending_within.order(:expires_at).to_a
      end

      def expired
        @expired ||= assignments.expired.order(:expires_at).to_a
      end

      def stale
        @stale ||= assignments.stale_before(stale_days.days.ago)
                              .order(PermissionForge::PermissionSetUser.last_reviewed_column).to_a
      end

      def stale_days
        self.class.stale_days(@configuration)
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

      # Readable Resources whose rules are in force (View All / Modify All
      # skip them), by id. A Resource named after no model this app can load
      # (`Custmer`) has no query to scope: the audit's integrity/unknown_models names it.
      def rule_enforced_resources
        readable_resources.reject { |resource| resource.rules_bypassed? || @catalog.find(resource.name).nil? }
                          .index_by(&:id)
      end

      # Active rules the app's query scoping does not apply, counted per
      # resource: every one while auto_query_scoping is off, the join rules
      # (PermissionSetRule#join_rule?, the one definition) when it is on.
      def unenforced_rule_counts(resource_ids)
        rows = PermissionForge::PermissionSetRule.active.where(resource_id: resource_ids)
        rows = rows.join_type_rules if auto_query_scoping?
        rows.pluck(:resource_id, :join_type)
            .select { |_, join_type| !auto_query_scoping? || !PermissionForge::PermissionSetRule.filter_join_type?(join_type) }
            .group_by(&:first).transform_values(&:size)
      end

      def people_counts
        @people_counts ||= PermissionForge::PermissionSetUser.active_assignments.group(:permission_set_id).count
      end

      # The granting Resource rows that count right now (Resource.in_effect,
      # the one definition), with their sets and fields loaded.
      def granting_resources
        @granting_resources ||= PermissionForge::Resource.in_effect.merge(PermissionForge::PermissionSet.granting)
                                                         .includes(:permission_set, :resource_fields).to_a
      end

      # Those of them people can read: where an unmasked sensitive field shows.
      def readable_resources
        @readable_resources ||= granting_resources.select(&:read_access)
      end

      # Readable and unmasked, and not acknowledged as intentional
      # (ResourceField#exposes_unacknowledged?).
      def unmasked_sensitive_fields
        readable_resources.flat_map do |resource|
          resource.resource_fields.filter_map do |field|
            sensitive_finding(resource, field.name, field: field) if field.exposes_unacknowledged?
          end
        end
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

        readable_resources.flat_map { |resource| unconfigured_findings(resource, passes) }
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
