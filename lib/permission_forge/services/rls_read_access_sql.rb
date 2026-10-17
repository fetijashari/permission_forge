# frozen_string_literal: true

module PermissionForge
  module Services
    # The read-access gate of an RLS policy under
    # `config.no_read_access_strategy = :deny`: the session user sees a row
    # only when RecordReadAccess would let them read the model's records at
    # all (ResourceChain.readable?) — an entry along the model's Resource
    # chain, and every entry there grants read_access. Nothing under
    # :rules_only (the policy applies the rules alone, as the app layer
    # does). Extracted from {RlsPolicyGenerator} for SRP; it calls back into
    # the generator's quoting, session-user and table helpers.
    #
    # Read per statement, as the app layer's hash is built from the rows:
    #   - an entry for a name: an active, unexpired assignment to an active
    #     granting set with an active Resource row of that name (with tenancy
    #     on, of the protected row's tenant, as the view_all bypass);
    #   - it grants read: such a row with read_access, in a set without an
    #     activation condition (PermissionSet.unconditional: a condition
    #     cannot be judged in a policy, so a conditional set never grants
    #     read there — its row counts as an entry without read);
    #   - read taken: an active Resource row with read_access in an active
    #     muting set the user holds (conditional or not) naming the entry's
    #     name or an ancestor's — a muting row reaches every entry whose
    #     chain names it (PermissionHashBuilder's muting phase).
    # Each difference is narrower than the app layer, never wider.
    #
    # Single-table inheritance: the policy is per table and compiled for the
    # class that includes the concern, so every row needs that class's chain
    # readable; a row of a loaded STI subclass (its inheritance column holds
    # the subclass's sti_name) also needs each entry of the subclass's own
    # names to grant read when the user has one. That is the subclass's
    # chain rule, never wider than a read through the base class or through
    # the subclass (narrower than the subclass's when only its own Resource
    # grants read: the base class's reads see nothing then).
    #
    # @api private
    module RlsReadAccessSql
      private

      # The gate, or nil under :rules_only. Part of the digest: switching the
      # strategy makes the policy stale.
      def read_access_sql
        return unless @configuration.deny_record_reads_without_read_access?

        own = ResourceChain.names(@model_class)
        gates = [chain_readable_sql(own), *sti_subclasses.map { |klass| subclass_readable_sql(klass, own) }]
        "(#{gates.join(' AND ')})"
      end

      # ResourceChain.readable?: an entry along the chain, none without read.
      # One name: its entry grants read (an entry that grants read exists).
      def chain_readable_sql(names)
        return readable_entry_sql(names.first, names) if names.one?

        any_entry = names.map { |name| entry_exists_sql(name) }.join(' OR ')
        "((#{any_entry}) AND #{entries_readable_sql(names, names)})"
      end

      # A row of the subclass: each of its own names (those the compiled
      # class does not answer to) grants read when the user has an entry.
      def subclass_readable_sql(klass, own)
        chain = ResourceChain.names(klass)
        "(#{inheritance_column_sql} IS DISTINCT FROM #{connection.quote(klass.sti_name)} " \
          "OR #{entries_readable_sql(chain - own, chain)})"
      end

      # For each name: no entry, or an entry that grants read.
      def entries_readable_sql(names, chain)
        checks = names.map do |name|
          "(NOT #{entry_exists_sql(name)} OR #{readable_entry_sql(name, chain)})"
        end
        "(#{checks.join(' AND ')})"
      end

      # The entry of the name grants read and no muting row takes it: one
      # naming it or a name after it along the chain (an ancestor's).
      def readable_entry_sql(name, chain)
        "(#{entry_exists_sql(name, read: true)} AND NOT #{read_muted_sql(chain.drop(chain.index(name)))})"
      end

      def entry_exists_sql(name, read: false)
        resource_row_exists_sql(
          muting: false, names: [name],
          extra: read ? [unconditional_set_sql, 'r.read_access = TRUE'] : []
        )
      end

      def read_muted_sql(names)
        resource_row_exists_sql(muting: true, names: names, extra: ['r.read_access = TRUE'])
      end

      # The loaded STI subclasses on the table (a subclass with a table of
      # its own is another policy's business), each with a name the compiled
      # class does not answer to, in name order (the digest is stable).
      # None without an inheritance column.
      def sti_subclasses
        return [] unless SchemaRead.column?(@model_class, @model_class.inheritance_column, ignored: false)

        own = ResourceChain.names(@model_class).map(&:to_s)
        @model_class.descendants.select { |klass| klass.table_name == table_name && klass.name && own.exclude?(klass.name) }
                    .sort_by(&:name)
      end

      # Whether the session user holds, through an active, unexpired
      # assignment, an active granting (or muting) set with an active
      # Resource row of one of the names — of the protected row's tenant
      # when tenancy is on — meeting the extra conditions. The read-access
      # gate reads it, and so does the generator's view_all bypass.
      def resource_row_exists_sql(muting:, names:, extra: [])
        conditions = [
          "psu.user_id = (#{uid_sql})", assignment_active_sql,
          "ps.is_active = TRUE AND ps.is_muting = #{muting ? 'TRUE' : 'FALSE'}",
          resource_names_sql(names), 'r.is_active = TRUE',
          tenant_predicate_sql.delete_prefix('AND ').presence,
          *extra
        ]
        "EXISTS ( SELECT 1 FROM #{psu_table} psu JOIN #{ps_table} ps ON ps.id = psu.permission_set_id " \
          "JOIN #{resources_table} r ON r.permission_set_id = ps.id WHERE #{conditions.compact.join(' AND ')} )"
      end

      def resource_names_sql(names)
        "r.name IN (#{names.map { |name| connection.quote(name.to_s) }.join(', ')})"
      end

      def inheritance_column_sql
        "#{quoted_table}.#{connection.quote_column_name(@model_class.inheritance_column)}"
      end
    end
  end
end
