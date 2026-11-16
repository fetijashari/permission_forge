# frozen_string_literal: true

require 'active_support/core_ext/enumerable'

module PermissionForge
  module Admin
    # What the Permission Sets list says about each set without building its
    # Resource records: how many Resources it has, what they allow (each flag
    # counted) and what narrows them (row rules, masked fields). Read from
    # tuples in three queries, whatever the number of sets or rows. Every count
    # asks the one definition of what it counts, on a tuple shaped like the
    # row: PermissionHashBuilder.granted_flags for what a granting Resource
    # row grants (edit and delete only with read, Modify All only with View
    # All), FieldLevel.level_of for a field's level. Rules on a Resource that
    # View All bypasses are counted apart, as the Resources tab does
    # ("rules ignored"). A Muting Permission Set adds no rules
    # (PermissionHashBuilder): its counts are what it takes away.
    # SetOverview reads the same entries for one set.
    class SetSummaries
      FLAGS = %i[read_access create_access edit_access delete_access view_all modify_all].freeze
      CRUD = FLAGS.first(4).freeze
      COLUMNS = (%i[id permission_set_id name is_active] + FLAGS).freeze
      # The kinds of mark a Resource carries, in the order they are shown.
      MARKS = %w[rules ignored masked hidden].freeze

      # The flags of a Resource row, for PermissionHashBuilder.granted_flags.
      FlagRow = Struct.new(*FLAGS, keyword_init: true)
      # The flags of a field row, for FieldLevel.level_of.
      FieldRow = Struct.new(:read_access, :edit_access, :mask_access, keyword_init: true)

      # One Resource row of a set. `flags`: what a granting row grants
      # (granted_flags) or what a muting row takes away (as stored); `rules`:
      # its active row rules (none on a muting set); `masked`: its active
      # fields shown masked (granting) or force-masked (muting); `hidden`: the
      # fields a muting row hides.
      Entry = Data.define(:id, :set_id, :name, :active, :muting, :flags, :rules, :masked, :hidden) do
        # Rules View All bypasses (the Resources tab: "rules ignored").
        def ignored_rules = view_all? ? rules : 0
        def applied_rules = rules - ignored_rules
        # A turned-off Resource grants nothing (PermissionHashBuilder skips it).
        def view_all? = active && flags[:view_all] == true

        # It narrows what the set grants on this Resource (a rule that applies,
        # a masked field) or, on a muting set, takes fields away.
        def narrowed? = (applied_rules + masked + hidden).positive?

        # An active Resource whose stored name contains `needle` (downcased).
        def matches?(needle) = active && name.downcase.include?(needle)

        # { kind => count } of the marks it carries (MARKS).
        def marks = MARKS.zip([applied_rules, ignored_rules, masked, hidden]).to_h
      end

      # A set's counts over its active Resources (`inactive` counts the others).
      Summary = Data.define(:muting, :entries) do
        def active = entries.select(&:active)
        def resources = active.size
        def inactive = entries.size - resources
        def flags = FLAGS.index_with { |flag| active.count { |entry| entry.flags[flag] } }
        def rules = total(:applied_rules)
        def rule_resources = on(:applied_rules)
        def ignored_rules = total(:ignored_rules)
        def masked = total(:masked)
        def masked_resources = on(:masked)
        def hidden = total(:hidden)
        def hidden_resources = on(:hidden)

        # How much the set allows, in one state (Admin::StateLabel kind
        # :access_profile): `takes_away` for a muting set with Resources,
        # `none` when nothing is granted, `full` when every Resource allows
        # Read, Create, Edit and Delete, `read_only` when none allows more
        # than Read, else `mixed`.
        def profile
          return 'none' if resources.zero?
          return 'takes_away' if muting

          counts = flags.values_at(*CRUD)
          return 'full' if counts.all?(resources)

          changes = counts.drop(1).sum
          return 'mixed' if changes.positive?

          counts.first.positive? ? 'read_only' : 'none'
        end

        # Every active Resource bypasses its rules: the set sees every row.
        def every_row? = !muting && resources.positive? && flags[:view_all] == resources

        def groups = SetOverview.families(entries).size

        # The active Resources whose stored name contains `needle` (downcased).
        def matching(needle) = entries.select { |entry| entry.matches?(needle) }

        private

        def total(count) = active.sum(&count)
        def on(count) = active.count { |entry| entry.public_send(count).positive? }
      end

      # Builds the entries of one read: the rules and field levels of the
      # active Resources, and which sets are muting.
      Reader = Struct.new(:muting, :rules, :levels) do
        def entry(row)
          id, set_id, name, active, *values = row
          muting_set = muting.fetch(set_id, false)
          levels_of = levels.fetch(id, {})
          Entry.new(id: id, set_id: set_id, name: name, active: active == true, muting: muting_set,
                    flags: flags(values, muting_set), rules: muting_set ? 0 : rules.fetch(id, 0),
                    masked: levels_of.fetch(muting_set ? 'mask' : 'masked', 0),
                    hidden: muting_set ? levels_of.fetch('hide', 0) : 0)
        end

        private

        def flags(values, muting_set)
          stored = FLAGS.zip(values).to_h { |flag, value| [flag, value == true] }
          muting_set ? stored : PermissionForge::Services::PermissionHashBuilder.granted_flags(FlagRow.new(**stored))
        end
      end

      # @param sets [Enumerable<PermissionSet>]
      # @return [Hash{Integer => Summary}] by set id, one for every set given
      def self.call(sets)
        sets = sets.to_a
        by_set = entries(sets).group_by(&:set_id)
        sets.to_h { |set| [set.id, Summary.new(muting: set.is_muting == true, entries: by_set.fetch(set.id, []))] }
      end

      # @param sets [Enumerable<PermissionSet>]
      # @return [Array<Entry>] every Resource row of the sets, in name order
      def self.entries(sets)
        muting = sets.to_h { |set| [set.id, set.is_muting == true] }
        rows = resource_rows(muting.keys)
        active_ids = rows.filter_map { |row| row.first if row[3] == true }
        reader = Reader.new(muting, rule_counts(active_ids), field_levels(active_ids))
        rows.map { |row| reader.entry(row) }
      end

      def self.resource_rows(set_ids)
        PermissionForge::Resource.where(permission_set_id: set_ids).order(:name).pluck(*COLUMNS)
      end
      private_class_method :resource_rows

      # Active rules per Resource id.
      def self.rule_counts(resource_ids)
        return {} if resource_ids.empty?

        PermissionForge::PermissionSetRule.where(resource_id: resource_ids, is_active: true).group(:resource_id).count
      end
      private_class_method :rule_counts

      # Active fields per Resource id and level ({ id => { level => count } }),
      # each flag combination's level read by FieldLevel.level_of.
      def self.field_levels(resource_ids)
        return {} if resource_ids.empty?

        counts = PermissionForge::ResourceField.where(resource_id: resource_ids, is_active: true)
                                               .group(:resource_id, :read_access, :edit_access, :mask_access).count
        counts.each_with_object(Hash.new { |hash, key| hash[key] = Hash.new(0) }) do |((id, *values), count), levels|
          levels_for(values).each { |level| levels[id][level] += count }
        end
      end
      private_class_method :field_levels

      # The levels a field with these flags has: on a granting set, and on a muting one.
      def self.levels_for(values)
        read, edit, mask = values.map { |value| value == true }
        row = FieldRow.new(read_access: read, edit_access: edit, mask_access: mask)
        [PermissionForge::FieldLevel.level_of(row, muting: false), PermissionForge::FieldLevel.level_of(row, muting: true)]
      end
      private_class_method :levels_for
    end
  end
end
