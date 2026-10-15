# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # Who holds access: stale, orphaned and leftover assignments, inactive
      # users, people stacking many sets.
      class AssignmentCheck < BaseCheck
        MANY_SETS = 3

        def call
          [stale, missing_users, inactive_users, expired_uncleaned, many_sets, inactive_sets_assigned,
           all_permanent].compact
        end

        private

        def active
          PermissionForge::PermissionSetUser.active_assignments
        end

        def stale_days
          configuration.try(:admin_stale_assignment_days) || Configuration::AdminUiSettings::DEFAULT_STALE_ASSIGNMENT_DAYS
        end

        def stale
          result = StaleAssignmentAuditor.call(threshold_days: stale_days)
          return if result[:stale_count].zero?

          labels = labels_for(result[:assignments].pluck(:user_id))
          finding(:medium, :stale_assignments, "Permanent access not reviewed in #{stale_days} days",
                  'Confirm these people still need it (Keep on the admin Home), or give it an end date.',
                  items: result[:assignments].map do |row|
                    "#{labels[row[:user_id]]} — #{row[:permission_set]} (#{row[:days_stale]} days)"
                  end)
        end

        def missing_users
          ids = active.distinct.pluck(:user_id) - user_ids
          return if ids.empty?

          finding(:medium, :missing_users, 'Assignments for users that no longer exist',
                  'These rows grant access to ids the user table no longer has; a new user reusing an id ' \
                  'would inherit it. Remove them.', items: ids.sort.map { |id| "User ##{id}" })
        end

        def inactive_users
          check = configuration.user_active_check
          return unless check

          inactive = assigned_users.reject { |user| check.call(user) }
          return if inactive.empty?

          finding(:medium, :inactive_users, 'Deactivated users still hold access',
                  'user_active_check says these users are inactive, but their assignments remain and apply if ' \
                  'they are reactivated or use another way in. Remove the access.',
                  items: inactive.map { |user| label(user) })
        end

        def expired_uncleaned
          count = PermissionForge::PermissionSetUser.expired.count
          return if count.zero?

          finding(:low, :expired_uncleaned, "#{count} expired assignment(s) not cleaned up",
                  'Expired assignments no longer grant access but clutter reviews. Run ' \
                  '`rake permission_forge:cleanup_expired_assignments` or use Clean up on the admin Home.')
        end

        def many_sets
          heavy = active.group(:user_id).count.select { |_, count| count >= MANY_SETS }
          return if heavy.empty?

          labels = labels_for(heavy.keys)
          finding(:low, :many_sets, "People holding #{MANY_SETS} or more sets",
                  'Granting sets add up (most permissive wins). Check their effective access on the admin Person page.',
                  items: heavy.sort_by { |_, count| -count }.map { |id, count| "#{labels[id]}: #{count} sets" })
        end

        def inactive_sets_assigned
          sets = PermissionForge::PermissionSet.where(is_active: false).order(:name)
                                               .select { |set| people_counts.fetch(set.id, 0).positive? }
          return if sets.empty?

          finding(:low, :inactive_sets_assigned, 'Turned-off sets still have people',
                  'They grant nothing while off, but turning one on restores access silently.',
                  items: sets.map { |set| "#{set.name} · #{people(set.id)}" })
        end

        def all_permanent
          total = active.count
          return if total.zero? || active.where.not(expires_at: nil).exists?

          finding(:info, :all_permanent, "All #{total} assignment(s) are permanent",
                  'Consider end dates for temporary needs (contractors, projects, cover).')
        end

        def assigned_users
          @assigned_users ||= user_model.where(id: active.distinct.select(:user_id)).to_a
        end

        def user_ids
          @user_ids ||= user_model.where(id: active.distinct.select(:user_id)).pluck(:id)
        end

        def labels_for(ids)
          users = user_model.where(id: ids).index_by(&:id)
          ids.index_with { |id| users[id] ? label(users[id]) : "User ##{id}" }
        end

        def label(user)
          PermissionForge::Admin::PersonLabel.new(user, configuration: configuration).name
        end

        def user_model
          configuration.user_model
        end
      end
    end
  end
end
