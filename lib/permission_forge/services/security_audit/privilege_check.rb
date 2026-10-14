# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # Privileged access: View All / Modify All, sets that look temporary,
      # and sets that grant delete almost everywhere.
      class PrivilegeCheck < BaseCheck
        TEMPORARY_NAME = /\b(dev|debug|dbg|test|tmp|temp|sandbox|demo)\b|full access/i
        BROAD_DELETE_MIN = 10
        BROAD_DELETE_SHARE = 0.75

        def call
          [bypass_grants, temporary_sets, broad_delete].compact
        end

        private

        def granting_resources
          @granting_resources ||= PermissionForge::Resource.active.where(permission_set_id: active_granting_sets.select(:id))
                                                           .includes(:permission_set).order(:name).to_a
        end

        def bypass_grants
          bypassing = granting_resources.select(&:rules_bypassed?)
          return if bypassing.empty?

          held = bypassing.any? { |resource| people_counts.fetch(resource.permission_set_id, 0).positive? }
          finding(held ? :medium : :low, :bypass_grants, 'View All / Modify All skip every record rule',
                  'People with these grants see (and with Modify All change) every record of the resource. ' \
                  'Keep them for administrators and give them an end date where possible.',
                  items: bypassing.map { |resource| bypass_item(resource) })
        end

        def bypass_item(resource)
          grant = resource.modify_all ? 'View All + Modify All' : 'View All'
          "#{resource.permission_set.name} › #{resource.name}: #{grant} · #{people(resource.permission_set_id)}"
        end

        def temporary_sets
          sets = PermissionForge::PermissionSet.active.order(:name).select { |set| set.name.match?(TEMPORARY_NAME) }
          return if sets.empty?

          held = sets.map(&:id).any? { |id| people_counts.key?(id) }
          finding(held ? :medium : :low, :temporary_sets, 'Sets that look temporary are still active',
                  'Their names suggest development, debugging or testing. Confirm they belong in this ' \
                  'environment, or delete them.',
                  items: sets.map { |set| "#{set.name} · #{people(set.id)}" })
        end

        def broad_delete
          broad = granting_resources.group_by(&:permission_set).filter_map do |set, resources|
            deletable = resources.count(&:delete_access)
            next if deletable < BROAD_DELETE_MIN || deletable < resources.size * BROAD_DELETE_SHARE

            "#{set.name}: delete on #{deletable} of #{resources.size} resources · #{people(set.id)}"
          end
          return if broad.empty?

          finding(:low, :broad_delete, 'Sets grant delete almost everywhere',
                  'Delete is rarely needed broadly. If people other than administrators hold these sets, ' \
                  'move delete into a separate set.', items: broad)
        end
      end
    end
  end
end
