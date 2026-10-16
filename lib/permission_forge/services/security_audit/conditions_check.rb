# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # Activation conditions and field rows whose read-time meaning is not
      # what the row looks like: conditions the validation would refuse
      # today (ActivationConditions: nobody can judge them, so a muting set
      # applies to every request and a granting set never passes) and
      # resources holding both a row and an explicit row for one of its
      # variants (the explicit row decides since 0.15).
      class ConditionsCheck < BaseCheck
        LEVEL_LABELS = { 'hidden' => 'Hidden', 'masked' => 'Masked', 'read' => 'Read-only', 'edit' => 'Editable' }.freeze

        def call
          [incomplete_conditions, variant_rows_conflict].compact
        end

        private

        def incomplete_conditions
          sets = PermissionForge::PermissionSet.with_broken_conditions # Home's card reads the same
          return if sets.empty?

          finding(:medium, :incomplete_conditions, 'Activation conditions nobody can judge',
                  'These rows hold a condition the validation refuses today: an IP entry that is not an IP address or ' \
                  'CIDR range, a list with no entry, the same start and end hour, one hour of the two, or an hour outside ' \
                  '0–23. Such a condition cannot be judged, so a muting set applies to every request and a granting set ' \
                  'never passes. Fix the condition on the set\'s Conditions tab (the admin and the API normalise the list; ' \
                  'newline or comma lists and arrays are accepted).',
                  items: sets.map { |set| condition_item(set) })
        end

        def condition_item(set)
          what = set.condition_problems.map { |kind, value| describe_problem(kind, value, set) }.join('; ')
          effect = set.is_muting ? 'applies to every request' : 'never passes'
          "#{set.name}#{' (muting)' if set.is_muting}: #{what} — #{effect} · #{people(set.id)}"
        end

        def describe_problem(kind, value, set)
          case kind
          when :ip_entry then "IP entry “#{value}” is not an IP address or CIDR range"
          when :ip_empty then 'IP list has no entry'
          when :hours_equal then "start hour #{set.allowed_hours_start} equals end hour #{set.allowed_hours_end}"
          when :hours_incomplete then set.allowed_hours_start.nil? ? 'start hour missing' : 'end hour missing'
          when :hours_range then 'hour outside 0–23'
          end
        end

        # Granting resources in effect: a muting resource's rows and variants
        # all mute (deny direction), so two rows there never disagree.
        def variant_rows_conflict
          resources = PermissionForge::Resource.in_effect.merge(PermissionForge::PermissionSet.granting)
                                               .includes(:permission_set, :resource_fields).order(:id)
          items = resources.flat_map { |resource| conflicts_of(resource) }
          return if items.empty?

          finding(:info, :variant_rows_conflict, 'Field rows next to an explicit row for their variant',
                  'Since 0.15 an explicit row for a name decides that name: the variant derived from the other row ' \
                  '(owner_id → owner_uuid) no longer widens it. Check that each explicit row says what you mean.',
                  items: items)
        end

        def conflicts_of(resource)
          rows = resource.resource_fields.select(&:is_active)
          by_name = rows.index_by(&:name)
          variants = PermissionForge::FieldVariants.new(resource.name, configuration)
          rows.flat_map do |row|
            variants.call(row.name).filter_map do |variant|
              explicit = by_name[variant]
              conflict_item(resource, row, explicit) if explicit
            end
          end
        end

        def conflict_item(resource, row, explicit)
          "#{resource.permission_set.name} › #{resource.name}: #{row.name} (#{level(row)}) → " \
            "#{explicit.name} (#{level(explicit)}): the #{explicit.name} row decides"
        end

        def level(row)
          LEVEL_LABELS.fetch(PermissionForge::Admin::FieldLevel.level_of(row, muting: false))
        end
      end
    end
  end
end
