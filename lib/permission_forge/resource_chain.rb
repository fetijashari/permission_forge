# frozen_string_literal: true

module PermissionForge
  # The Resource names a model class answers to: its own, and those of its
  # single-table-inheritance ancestors up to base_class — nearest first.
  # `VipCustomer < Customer` gives [:VipCustomer, :Customer]; a plain model
  # its own name alone.
  #
  # Every entry the user has along the chain counts, and a subclass can only
  # be narrower than its base: the rules of every entry apply together; a
  # view_all / modify_all bypass skips the rules of the entry that grants it
  # and no other; a field is as closed as the strictest entry that configures
  # it, and an entry that does not grant read hides every field the chain
  # configures. A subclass with no entry of its own is its base. (A class
  # used to answer to its own name only, so a subclass of a protected model
  # had no rules at all and every field of it was unconfigured, before
  # 0.14.) A subclass with a table of its own is not
  # STI and answers to its own name alone.
  #
  # The one resolver for every path: find_by / permission_scoped
  # (PermissionScopedFindable), the auto scope (AutoPermissionScoping), the
  # attribute guard (MaskedAttributes, AttributeAccessGuard), the response
  # filter (FiltersResponseAttributes) and PermitsAttributes.
  #
  # @api private
  module ResourceChain
    # The entry of a field hidden by an unreadable entry along the chain.
    HIDDEN_ENTRY = { read_access: false, edit_access: false, mask_access: false, mask_strategy: 'full' }.freeze

    module_function

    # @param klass [Class] a model class (any class answers to its own name)
    # @return [Array<Symbol>] frozen; worked out once per class
    def names(klass)
      klass.instance_variable_get(:@pf_resource_chain) ||
        klass.instance_variable_set(:@pf_resource_chain, compute_names(klass))
    end

    # The names behind a resource name: the chain of the model it names, or
    # the name alone when it names no model.
    #
    # @param resource_name [String, Symbol]
    # @return [Array<Symbol>]
    def names_for(resource_name)
      klass = resource_name.to_s.safe_constantize
      klass.is_a?(Class) && klass.respond_to?(:base_class) ? names(klass) : [resource_name.to_sym]
    end

    # The user's resource entries along the chain, nearest first.
    #
    # @param user [#permissions_hash]
    # @param names [Array<Symbol>]
    # @return [Array<Hash>]
    def entries(user, names)
      resources = user.permissions_hash.dig(:permissions, :resources)
      return [] unless resources

      names.filter_map do |name|
        entry = resources[name]
        entry if entry.present?
      end
    end

    # The row-level rules that apply to a class, and why none do.
    #
    # @return [Array(Array<Hash>, Symbol)] the rules of every entry without a
    #   bypass, and — when that leaves none — the nearest entry's :view_all /
    #   :modify_all, else :no_rules
    def rules(user, names)
      rules = []
      bypass = nil
      entries(user, names).each do |entry|
        reason = bypass_reason(entry[:permissions])
        if reason
          bypass ||= reason
        else
          rules.concat(entry[:permission_set_rules] || [])
        end
      end
      [rules, (bypass || :no_rules if rules.empty?)]
    end

    # Whether the entry the class answers to grants a resource flag: the
    # nearest entry along the chain — the class's own, or its base's when it
    # has none of its own (the same entry can_*? reads for a class with one;
    # a muted base reaches it, see PermissionHashBuilder's muting phase).
    # False without an entry.
    #
    # @param flag [Symbol] :read_access, :delete_access, …
    # @return [Boolean]
    def grants?(user, names, flag)
      entries(user, names).first&.dig(:permissions, flag) == true
    end

    # @return [Symbol, nil] :view_all or :modify_all when one of them lets
    #   the user past the rules of an entry
    def bypass_reason(permissions)
      return unless permissions

      if permissions[:view_all] then :view_all
      elsif permissions[:modify_all] then :modify_all
      end
    end

    # The field entry a class answers with for one attribute: the one entry
    # along the chain that configures it — one entry is read as a plain
    # model's, its rows decide — or, among several, the strictest; hidden
    # when one of them does not grant read; nil when none configures it (or
    # the user has no field_permissions).
    #
    # @param names [Array<Symbol>, Symbol] the chain, or one name
    # @return [Hash, nil]
    def field_permissions(user, names, attribute)
      return unless user.respond_to?(:field_permissions)
      return user.field_permissions(names, attribute) unless names.is_a?(Array)
      return user.field_permissions(names.first, attribute) if names.size == 1
      return strictest(names.filter_map { |name| user.field_permissions(name, attribute) }) unless user.respond_to?(:permissions_hash)

      compose_field(entries(user, names), attribute.to_sym)
    end

    # One entry: its field entry (its rows decide). Several: hidden when one
    # does not grant read, else the strictest of those that configure the
    # field; nil when none does.
    def compose_field(resource_entries, attribute)
      field_entries = resource_entries.filter_map { |entry| entry.dig(:fields, attribute) }
      return field_entries.first if resource_entries.size <= 1 || field_entries.empty?

      unreadable?(resource_entries) ? HIDDEN_ENTRY.dup : strictest(field_entries)
    end

    # The field entries a class answers with, every configured name composed
    # the same way. The one table itself when one entry has fields: read-only.
    #
    # @return [Hash{Symbol => Hash}]
    def fields(user, names)
      resource_entries = entries(user, names)
      tables = resource_entries.filter_map { |entry| entry[:fields].presence }
      return tables.first || {} if resource_entries.size <= 1

      compose_tables(tables, unreadable?(resource_entries))
    end

    def compose_tables(tables, hidden)
      tables.flat_map(&:keys).uniq.to_h do |name|
        [name, hidden ? HIDDEN_ENTRY.dup : strictest(tables.filter_map { |table| table[name] })]
      end
    end

    # Whether one of several entries does not grant read: a class cannot be
    # more readable than an entry it answers to (a muted base read reaches
    # the fields only the subclass configures).
    def unreadable?(resource_entries)
      resource_entries.any? { |entry| entry.dig(:permissions, :read_access) != true }
    end

    # Of several entries for one field: readable and editable only when every
    # one grants it, masked when any does, with the first masking entry's
    # strategy (in chain order). One entry: itself.
    def strictest(field_entries)
      return field_entries.first if field_entries.size <= 1

      masked = field_entries.find { |entry| entry[:mask_access] }
      { read_access: field_entries.all? { |entry| entry[:read_access] == true },
        edit_access: field_entries.all? { |entry| entry[:edit_access] == true },
        mask_access: !masked.nil?,
        mask_strategy: (masked || field_entries.first)[:mask_strategy] }
    end

    # The class and its superclasses up to base_class that share its table
    # (single-table inheritance: Rails' base_class ignores table_name, and a
    # subclass with a table of its own holds other rows); the names they
    # have. A nameless class (an anonymous subclass) answers as its ancestors
    # do; a subclass renamed after its base answers once.
    def compute_names(klass)
      classes = [klass]
      if klass.respond_to?(:base_class)
        base = klass.base_class
        classes << classes.last.superclass while classes.last != base && same_table?(classes.last.superclass, klass)
      end
      classes.filter_map(&:name).map(&:to_sym).uniq.freeze
    end
    private_class_method :compute_names

    def same_table?(ancestor, klass)
      ancestor.respond_to?(:table_name) && ancestor.table_name == klass.table_name
    end
    private_class_method :same_table?
  end
end
