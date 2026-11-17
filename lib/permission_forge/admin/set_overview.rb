# frozen_string_literal: true

module PermissionForge
  module Admin
    # One Permission Set's Resources as the Permission Sets list opens them
    # in place: by model family (`groups`) or one by one (`resources`), all
    # of them or `only` the ones narrowed (a row rule that applies, a masked
    # field), the ones with View All, or one family. The entries and their
    # counts are SetSummaries' (one definition of what a row grants).
    #
    # A family is a model's namespace (`Billing::Invoice` → `Billing`); a
    # model outside any namespace goes with the namespace that is its name
    # plus a plural ending (`Invoice` → `Invoices::`), else with the models
    # of no family. A family is a grouping for reading, never a decision.
    class SetOverview
      VIEWS = %w[groups resources].freeze
      NARROWED = 'narrowed'
      VIEW_ALL = 'view_all'
      # `only` for the models of no family (no namespace is named `-`).
      NO_FAMILY = '-'
      # The entries `only` keeps, by its value; a family's key keeps that family.
      FILTERS = { nil => ->(_entry) { true }, NARROWED => :narrowed?.to_proc, VIEW_ALL => :view_all?.to_proc }.freeze
      # The endings a namespace may add to a model's name to be its family.
      PLURAL_ENDINGS = %w[s es].freeze

      # A family of the set's Resources; `name` nil for the models of no family.
      Family = Data.define(:name, :entries) do
        # The value of `only` that shows this family.
        def key = name || NO_FAMILY
        def sort_key = [name.nil? ? 1 : 0, -entries.size, name.to_s]

        # The family with only the entries `only` keeps, or nil when none is left.
        def kept(only)
          filter = FILTERS.fetch(only) { ->(_entry) { key == only } }
          kept = entries.select(&filter)
          with(entries: kept) if kept.any?
        end

        # { kind => count } of the marks its entries carry, View All first
        # (a muting set's View All is a flag it takes away, not a mark).
        def marks
          totals = SetSummaries::MARKS.index_with { |kind| entries.sum { |entry| entry.marks.fetch(kind) } }
          view_all = entries.any?(&:muting) ? 0 : entries.count(&:view_all?)
          { 'view_all' => view_all }.merge(totals)
        end
      end

      # @param entries [Array<SetSummaries::Entry>]
      # @return [Array<Family>] largest first, the models of no family last
      def self.families(entries)
        namespaces = entries.filter_map { |entry| namespace(entry.name) }.uniq
        grouped = entries.group_by { |entry| family_of(entry.name, namespaces) }
        grouped.map { |name, members| Family.new(name: name, entries: members.sort_by(&:name)) }.sort_by(&:sort_key)
      end

      def self.namespace(name)
        head, rest = name.split('::', 2)
        head if rest
      end

      def self.family_of(name, namespaces)
        namespace(name) || namespaces.find { |candidate| own_namespace?(name, candidate) }
      end

      # `Invoice` and `Invoices`, `Address` and `Addresses`, `Category` and
      # `Categories`, compared without case (`RFQ` and `Rfqs`).
      def self.own_namespace?(name, namespace)
        model = name.downcase
        candidates = PLURAL_ENDINGS.map { |ending| model + ending }
        candidates << "#{model.delete_suffix('y')}ies" if model.end_with?('y')
        candidates.include?(namespace.downcase)
      end
      private_class_method :namespace, :family_of, :own_namespace?

      attr_reader :permission_set, :view, :only

      # @param permission_set [PermissionSet]
      # @param view [String] `groups` or `resources` (anything else: `resources`)
      # @param only [String] `narrowed`, `view_all`, a family's key, or blank
      def initialize(permission_set, view:, only:)
        @permission_set = permission_set
        @view = VIEWS.include?(view) ? view : 'resources'
        @all = self.class.families(SetSummaries.entries([permission_set]))
        @only = only if FILTERS.key?(only) || @all.any? { |family| family.key == only }
      end

      def muting? = permission_set.is_muting == true
      def groups? = view == 'groups'

      # @return [Array<Family>] the families shown (every family in `groups`)
      def families
        groups? ? @all : @all.filter_map { |family| family.kept(only) }
      end

      # @return [Integer] every Resource of the set
      def total = @all.sum { |family| family.entries.size }
      def filtered? = !only.nil? && !groups?
    end
  end
end
