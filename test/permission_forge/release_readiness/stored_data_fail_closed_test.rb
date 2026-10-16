# frozen_string_literal: true

require 'test_helper'
require_relative '../field_variant_models'

# A host controller the fuzz authorizes against: `export` is the custom
# action of that name, `destroy` is REST (delete_access).
class PfFuzzCustomersController < ApplicationController
  include PermissionForge::Concerns::ControllerActionGuard

  permission_forge_actions resource: 'Customer', actions: { export: :export }

  def export = head(:ok)
  def destroy = head(:ok)
end

module PermissionForge
  module ReleaseReadiness
    # G1 — stored data fails closed at read time (plan-final.md §2 SD).
    #
    # Every interpreted column of every permission model is poisoned past
    # validation (update_columns, as SQL, an older version or another app on
    # the shared tables would write it) with values of its type, and every
    # request path is read again. For every poisoning:
    #
    # 1. nothing raises — the lookups that may deny (find_by!, find_by) may
    #    raise NotAuthorizedError / RecordNotFound, a clone of a row the
    #    validations refuse is refused whole (RecordInvalid), nothing else
    #    may raise anything;
    # 2. when the value is one the validations refuse for a new row
    #    (#refused?), nothing widens against the baseline: the rows a scope
    #    yields are a subset, a `can_*?` that is true was true, an attribute
    #    that was masked or hidden is not raw, the kept params are a subset,
    #    an action the guard allows was allowed, the admin's effective levels
    #    are no higher, and a muting set whose condition was poisoned still
    #    mutes (the per-context reads);
    # 3. when such a refused value changed an answer, the audit names the row
    #    (`rake permission_forge:audit`) and, for a rule's naming columns,
    #    RuleProblem.for names the problem — a broken row is never silent.
    #
    # The enumeration is automatic: every model of PermissionForge::MODEL_NAMES
    # but AuditEvent, every column but the bookkeeping ones and the foreign
    # keys (a pointer is not interpreted). A column added to a model is
    # covered the day it is added; a column to leave out goes in SKIP with a
    # reason, and an entry that matches nothing fails. PENDING_ON_WP1 names
    # the columns whose fixes land with WP-1 (plan-final.md §3): their
    # failures are reported, not counted, and an entry whose column no
    # longer fails must be removed.
    class StoredDataFailClosedTest < ActiveSupport::TestCase
      BOOKKEEPING = %w[id uuid created_at updated_at].freeze
      # 'Model.column' => why it is not poisoned.
      SKIP = {}.freeze
      # 'Model.column' => the WP-1 fix its failures wait for (plan-final.md §3 WP-1).
      # The lead removes each entry once WP-1 is merged; an entry whose column
      # no longer fails fails this test.
      PENDING_ON_WP1 = {}.freeze

      STRINGS = ['', 'zzz', 'a..b', 'nosuch.col', 'Kernel', 'regex', 'inner', 'gone',
                 "10.0.0.0/8\n192.168.0.0/16", 'office', "x\u0000y", 'ü' * 300].freeze
      INTEGERS = [-1, 0, 9, 25, 2**40].freeze
      BOOLEANS = [true, false].freeze
      DATETIMES = -> { [nil, 1.year.ago, 1.year.from_now] }
      TYPED_VALUES = { string: STRINGS, text: STRINGS, integer: INTEGERS, boolean: BOOLEANS, datetime: DATETIMES }.freeze
      # The hour window is two columns: poisoned as pairs too.
      HOUR_PAIRS = {
        'allowed_hours_start' => [{ allowed_hours_start: 9, allowed_hours_end: 9 }, { allowed_hours_start: 9, allowed_hours_end: nil }],
        'allowed_hours_end' => [{ allowed_hours_start: nil, allowed_hours_end: 9 }]
      }.freeze

      # Columns whose refusal is about what they name (not a length or a
      # blank): a refused value that changes an answer must be named by the
      # audit (3.).
      NAMED_BY_AUDIT = {
        'PermissionSet' => %w[allowed_ips allowed_hours_start allowed_hours_end],
        'Resource' => %w[read_access edit_access delete_access view_all modify_all],
        'ResourceField' => %w[read_access edit_access mask_access mask_strategy],
        'PermissionSetRule' => %w[field_name field_accessor_path operator join_type]
      }.freeze
      # The rule columns RuleProblem.for must explain when they are refused and change an answer.
      RULE_NAMING = %w[field_name field_accessor_path operator join_type].freeze

      DENIALS = [PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError, ActiveRecord::RecordNotFound].freeze
      RAW = { 'name' => 'Ada', 'email' => 'ada@example.com', 'domain' => 'example.com' }.freeze
      MATCHED = { ip: '10.1.2.3', session_flags: [] }.freeze
      UNMATCHED = { ip: '203.0.113.9', session_flags: [] }.freeze

      Failure = Struct.new(:model, :column, :value, :path, :message) do
        def key = "#{model}.#{column}"
        def to_s = "#{key} = #{value.inspect}: #{path} — #{message}"
      end

      Outcome = Struct.new(:value, :error)

      setup do
        PermissionForge.configuration.unconfigured_field_strategy = :block
        PermissionForge.configuration.request_context_resolver = -> { @context }
        @context = MATCHED
        build_fixture
        @baseline = read_all
      end

      # --- the fixture --------------------------------------------------------

      # A granting set (Customer read + edit + delete; name editable, email
      # masked, domain readable, supplier_id hidden; export permitted; a
      # filter rule and a join rule through supplier; a PfVariantOrder
      # resource with an owner_id row), a muting set conditional on an office
      # IP that hides domain, and a group holding the granting set.
      def build_fixture
        build_records
        build_granting_set
        build_muting_set
        build_holdings
        Current.user = @user
        @rows = {
          'PermissionSet' => [@granting, @muting], 'Resource' => [@resource, @muting_resource],
          'ResourceField' => [@fields[:email], @fields[:supplier_id], @muting_field], 'ResourceAction' => [@action],
          'PermissionSetRule' => [@filter_rule, @join_rule], 'PermissionSetUser' => [@assignment, @muting_assignment],
          'PermissionSetGroup' => [@group], 'PermissionSetGroupUser' => [@membership]
        }
      end

      # The user, three customers (one the rules allow, one each rule denies)
      # and an order with a secret owner_uuid.
      def build_records
        @user = create_user
        @supplier = create_supplier(owner: @user)
        @customer = create_customer(**RAW, supplier: @supplier)
        @foreign = create_customer(email: 'f@example.com', domain: 'other.com', supplier: @supplier)
        @unowned = create_customer(email: 'u@example.com', domain: 'example.com', supplier: create_supplier)
        @order = PfVariantOrder.create!(title: 't', owner_id: 1, owner_uuid: 'secret-uuid')
      end

      def build_holdings
        @group = create_permission_set_group(name: 'Group')
        @granting.update!(permission_set_group: @group)
        @membership = PermissionForge::PermissionSetGroupUser.create!(uuid: SecureRandom.uuid, user: @user, permission_set_group: @group)
        @assignment = create_permission_set_user(user: @user, permission_set: @granting)
        @muting_assignment = create_permission_set_user(user: @user, permission_set: @muting)
      end

      def build_granting_set
        @granting = create_permission_set(name: 'Granting')
        @resource = create_resource(permission_set: @granting, read_access: true, edit_access: true, delete_access: true)
        @fields = {
          name: create_resource_field(resource: @resource, name: 'name', read_access: true, edit_access: true),
          email: create_resource_field(resource: @resource, name: 'email', read_access: true, mask_access: true, mask_strategy: 'email'),
          domain: create_resource_field(resource: @resource, name: 'domain', read_access: true),
          supplier_id: create_resource_field(resource: @resource, name: 'supplier_id', read_access: false)
        }
        @action = create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        @filter_rule = create_permission_set_rule(permission_set: @granting, resource: @resource, name: 'Domain',
                                                  field_name: 'domain', field_value: 'example.com', include_nulls: false)
        @join_rule = create_permission_set_rule(permission_set: @granting, resource: @resource, name: 'Supplier owner',
                                                field_name: 'owner_id', field_value: 'current_user', include_nulls: false,
                                                join_type: 'joins', field_accessor_path: 'supplier')
        @orders = create_resource(permission_set: @granting, name: 'PfVariantOrder', read_access: true)
        create_resource_field(resource: @orders, name: 'owner_id', read_access: true)
      end

      def build_muting_set
        @muting = create_permission_set(name: 'Lockdown', is_muting: true, allowed_ips: '10.0.0.0/8')
        @muting_resource = create_resource(permission_set: @muting, read_access: false)
        @muting_field = create_resource_field(resource: @muting_resource, name: 'domain', read_access: true, edit_access: true)
      end

      # The rows poisoned per model: the ones in effect for the user, in both
      # directions where the model has one.
      def rows_of(model)
        @rows.fetch(model.name.demodulize) { raise ArgumentError, "no fixture rows for #{model.name}: add them to build_fixture" }
      end

      # --- the read paths -----------------------------------------------------

      def fresh_user
        @fresh_user ||= begin
          user = User.find(@user.id)
          Current.user = user
          user
        end
      end

      def customer = Customer.find(@customer.id)

      def with_context(context)
        previous = @context
        @context = context
        @fresh_user = nil
        yield
      ensure
        @context = previous
        @fresh_user = nil
      end

      def with_scoping(mode)
        previous = PermissionForge.configuration.auto_query_scoping
        PermissionForge.configuration.auto_query_scoping = mode
        yield
      ensure
        PermissionForge.configuration.auto_query_scoping = previous
      end

      def rolled_back
        result = nil
        ActiveRecord::Base.transaction(requires_new: true) do
          result = yield
          raise ActiveRecord::Rollback
        end
        result
      end

      def allowed?(action)
        PermissionForge::ControllerActions::Authorizer.allowed?(controller_path: 'pf_fuzz_customers', action_name: action,
                                                                controller_class: PfFuzzCustomersController, user: fresh_user)
      end

      def fields_in(context)
        with_context(context) { fresh_user.permissions_hash_for(:Customer)&.dig(:fields)&.slice('email', 'domain') }
      end

      def filtered_response
        filtered = PermissionForge::Services::FiltersResponseAttributes.call(attributes: RAW.dup, resource_name: 'Customer', user: fresh_user)
        filtered.transform_keys(&:to_s)
      end

      def permitted_keys
        PermissionForge::Services::PermitsAttributes.call(resource: Customer, permitted_params: RAW.merge('supplier_id' => 1))
                                                    .keys.map(&:to_s).sort
      end

      def effective_levels
        PermissionForge::Admin::EffectiveAccess.call(user: fresh_user).to_h do |outcome|
          [outcome.name, [outcome.fields.to_h { |field| [field.name, field.level] }, outcome.rules.size]]
        end
      end

      # Every path once per poisoning, run on the test instance (instance_exec).
      # The reports (REPORTS) are read when a cheaper path changed or the row
      # was refused; the audit only then (it costs the most and is the third
      # assertion's evidence).
      PERMISSION_PATHS = {
        hash: -> { fresh_user.permissions_hash.dig(:permissions, :resources).keys.map(&:to_s).sort },
        can_read: -> { fresh_user.can_read?(:Customer) },
        can_create: -> { fresh_user.can_create?(:Customer) },
        can_edit: -> { fresh_user.can_edit?(:Customer) },
        can_delete: -> { fresh_user.can_delete?(:Customer) },
        can_view_all: -> { fresh_user.can_view_all?(:Customer) },
        can_modify_all: -> { fresh_user.can_modify_all?(:Customer) },
        can_export: -> { fresh_user.can?(:export, :Customer) },
        authorize_export: -> { allowed?('export') },
        authorize_destroy: -> { allowed?('destroy') },
        fields_matched: -> { fields_in(MATCHED) },
        fields_unmatched: -> { fields_in(UNMATCHED) },
        fields_no_context: -> { fields_in({}) },
        managed: -> { PermissionForge::ControllerActions::ManagedIndex.managed_actions('Customer') }
      }.freeze

      RECORD_PATHS = {
        scoped: -> { Customer.permission_scoped.pluck(:id).sort },
        find_by: -> { Customer.find_by(id: @customer.id)&.id },
        find_by_bang: -> { Customer.find_by!(id: @customer.id).id },
        find_by_unowned: -> { Customer.find_by(id: @unowned.id)&.id },
        filter_all: -> { with_scoping(:filter_only) { Customer.all.map(&:id).sort } },
        filter_count: -> { with_scoping(:filter_only) { Customer.count } },
        filter_exists: -> { with_scoping(:filter_only) { Customer.where(nil).exists? } },
        getters: -> { RAW.keys.to_h { |column| [column, customer.public_send(column)] } },
        bracket: -> { RAW.keys.to_h { |column| [column, customer[column]] } },
        attributes: -> { customer.attributes.slice(*RAW.keys) },
        as_json: -> { customer.as_json.slice(*RAW.keys) },
        variant: -> { PfVariantOrder.find(@order.id).owner_uuid },
        filtered: -> { filtered_response },
        permitted: -> { permitted_keys },
        explain: -> { capture_io { PermissionForge::Concerns::MaskedAttributes.explain_all(customer) }.first.lines.size }
      }.freeze

      REPORT_PATHS = {
        effective: -> { effective_levels },
        rls: -> { PermissionForge::Services::RlsPolicyGenerator.call(model_class: Customer).fetch(:statements).join("\n") },
        generate: -> { rolled_back { PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource.reload).size } },
        clone: lambda {
          rolled_back { PermissionForge::Services::PermissionSetCloner.call(permission_set: @granting.reload, attrs: { name: 'Clone' }).persisted? }
        }
      }.freeze
      PATHS = PERMISSION_PATHS.merge(RECORD_PATHS, REPORT_PATHS).freeze

      REPORTS = %i[effective rls generate clone].freeze
      # A smaller answer than the baseline's: a subset of rows, a false, a
      # masked or hidden value, fewer keys, a lower level.
      SUBSETS = %i[scoped filter_all permitted].freeze
      FLAGS = %i[can_read can_create can_edit can_delete can_view_all can_modify_all can_export filter_exists
                 authorize_export authorize_destroy].freeze
      LOOKUPS = %i[find_by find_by_bang find_by_unowned].freeze
      VALUES = %i[getters bracket attributes as_json filtered].freeze
      CONTEXTS = %i[fields_matched fields_unmatched fields_no_context].freeze
      # Which check tells a wider answer apart, per path (none: the path is
      # read for "nothing raises" only).
      WIDENING_CHECKS = {
        **SUBSETS.index_with(:subset_widened?), **FLAGS.index_with(:flag_widened?), **LOOKUPS.index_with(:lookup_widened?),
        **VALUES.index_with(:value_widened?), **CONTEXTS.index_with(:fields_widened?),
        filter_count: :count_widened?, variant: :variant_widened?, effective: :levels_widened?
      }.freeze

      # A lookup may deny; a clone of a row the validations refuse is
      # refused whole (ActiveRecord::RecordInvalid), never half-made. Any
      # other error from any path is a failure.
      def read(path)
        Outcome.new(instance_exec(&PATHS.fetch(path)), nil)
      rescue *DENIALS => e
        LOOKUPS.include?(path) ? Outcome.new(:denied, nil) : Outcome.new(nil, e)
      rescue ActiveRecord::RecordInvalid => e
        path == :clone ? Outcome.new(:refused, nil) : Outcome.new(nil, e)
      rescue StandardError => e
        Outcome.new(nil, e)
      end

      def read_all(only: PATHS.keys)
        reset_reads
        only.index_with { |path| read(path) }
      end

      # Between two reads of the store: the user's cache entries and the
      # managed-actions index go, and the next read builds from the rows.
      def reset_reads
        PermissionForge.cache.clear
        PermissionForge::ControllerActions::ManagedIndex.invalidate!
        @fresh_user = nil
      end

      def audit_items
        PermissionForge::Services::SecurityAudit.call.findings.flat_map(&:items)
      end

      # --- enumeration ---------------------------------------------------------

      def self.models = PermissionForge::TestModels.all - [PermissionForge::AuditEvent]

      def self.columns_of(model)
        pointers = model.reflect_on_all_associations(:belongs_to).map { |reflection| reflection.foreign_key.to_s }
        model.column_names - BOOKKEEPING - pointers
      end

      # The poisonings of one column: the values of its type (plus nil where
      # nullable), each as an attributes Hash, and the column's pairs.
      def values_for(model, column)
        type = model.columns_hash.fetch(column)
        values = typed_values(type, "#{model.name}.#{column}")
        values += [nil] if type.null && !values.include?(nil)
        values.map { |value| { column => value } } + Array(HOUR_PAIRS[column]).map(&:stringify_keys)
      end

      def typed_values(type, label)
        values = TYPED_VALUES.fetch(type.type) { raise ArgumentError, "#{label}: give #{type.type} columns values" }
        values.respond_to?(:call) ? values.call : values
      end

      # --- refusal and change ---------------------------------------------------

      # Whether the validations refuse the poisoned attributes for a new
      # row like `record`: an error the clean copy does not have (a copy is
      # a new row, so every check-on-change validation runs; its own
      # uniqueness errors are the same on both copies).
      def refused?(record, attrs)
        (errors_of(record, attrs) - errors_of(record, {})).any?
      end

      def errors_of(record, attrs)
        copy = record.class.new(record.attributes.except(*BOOKKEEPING).merge(attrs))
        copy.uuid = SecureRandom.uuid
        copy.valid?
        copy.errors.map { |error| [error.attribute, error.message] }
      end

      def poison(record, attrs)
        original = record.attributes.slice(*attrs.keys)
        record.update_columns(attrs)
        yield
      rescue ActiveRecord::StatementInvalid, ActiveModel::RangeError, RangeError
        # a value the database refuses: nothing to read
        nil
      ensure
        record.update_columns(original)
      end

      def changed?(results)
        results.any? { |path, outcome| outcome != @baseline[path] }
      end

      # --- assertions per poisoning ------------------------------------------------

      def check(record, attrs, failures)
        fail_on = failure_recorder(record, attrs, failures)
        refused = refused?(record, attrs)
        results = results_for(refused)
        results.each { |path, outcome| fail_on.call(path, "raised #{outcome.error.class}: #{outcome.error.message[0, 160]}") if outcome.error }
        return unless refused

        assert_not_widened(results, fail_on)
        assert_named(record, attrs, fail_on) if changed?(results) && named_by_audit?(record, attrs)
      end

      def failure_recorder(record, attrs, failures)
        model = record.class.name.demodulize
        column = attrs.keys.first
        value = attrs.size == 1 ? attrs.values.first : attrs
        ->(path, message) { failures << Failure.new(model, column, value, path, message) }
      end

      # The cheap paths always; the reports when a cheap answer changed or
      # the row was refused.
      def results_for(refused)
        results = read_all(only: PATHS.keys - REPORTS)
        results.merge!(read_all(only: REPORTS)) if refused || changed?(results)
        results
      end

      def named_by_audit?(record, attrs)
        NAMED_BY_AUDIT.fetch(record.class.name.demodulize, []).include?(attrs.keys.first)
      end

      def assert_not_widened(results, fail_on)
        results.each do |path, outcome|
          next if outcome.error

          base = @baseline[path].value
          fail_on.call(path, "widened: #{base.inspect[0, 120]} -> #{outcome.value.inspect[0, 120]}") if widening?(path, outcome.value, base)
        end
      end

      def widening?(path, value, base)
        check = WIDENING_CHECKS[path]
        check ? send(check, value, base) : false
      end

      def subset_widened?(value, base) = !(Array(value) - Array(base)).empty?
      def flag_widened?(value, base) = value == true && base != true
      def count_widened?(value, base) = value.to_i > base.to_i
      def lookup_widened?(value, base) = value != :denied && base == :denied
      def value_widened?(value, base) = RAW.any? { |column, raw| base[column] != raw && value[column] == raw }
      def variant_widened?(value, base) = base != 'secret-uuid' && value == 'secret-uuid'

      def fields_widened?(value, base)
        return false if value.nil?
        return true if base.nil?

        value.any? { |name, entry| entry_widened?(entry, base[name] || {}) }
      end

      def entry_widened?(entry, base)
        %i[read_access edit_access].any? { |flag| entry[flag] == true && base[flag] != true } ||
          (entry[:mask_access] == false && base[:mask_access] == true)
      end

      def levels_widened?(value, base)
        rank = PermissionForge::Admin::FieldLevel.method(:rank)
        value.any? do |name, (fields, _rules)|
          base_fields = base.dig(name, 0) || {}
          fields.any? { |field, level| rank.call(level) > rank.call(base_fields.fetch(field, 'hidden')) }
        end
      end

      # The audit names the poisoned row; a rule's naming columns are explained by RuleProblem.
      def assert_named(record, attrs, fail_on)
        row = record.reload
        label = row_label(row)
        fail_on.call(:audit, "no finding names #{label.inspect}") unless audit_items.any? { |item| names?(item, label) }
        return unless row.is_a?(PermissionForge::PermissionSetRule) && RULE_NAMING.include?(attrs.keys.first)

        fail_on.call(:rule_problem, 'RuleProblem.for is nil') if PermissionForge::Operators::RuleProblem.for(row).nil?
      end

      # [set name, the row's own name] as the findings print them.
      def row_label(row)
        case row
        when PermissionForge::PermissionSet then [row.name]
        when PermissionForge::Resource then [row.permission_set.name, row.name]
        when PermissionForge::ResourceField then [row.resource.permission_set.name, ".#{row.name}"]
        when PermissionForge::PermissionSetRule then [row.resource.permission_set.name, row.name]
        else [row.respond_to?(:name) ? row.name : row.id.to_s]
        end
      end

      def names?(item, label)
        label.all? { |part| item.include?(part) }
      end

      # --- the tests: one per model ------------------------------------------------

      models.each do |model|
        test "#{model.name.demodulize}: every interpreted column, poisoned past validation, never raises or widens" do
          failures = []
          columns = self.class.columns_of(model).reject { |column| SKIP.key?("#{model.name.demodulize}.#{column}") }
          rows_of(model).each do |record|
            columns.each do |column|
              values_for(model, column).each do |attrs|
                poison(record, attrs) { check(record, attrs, failures) }
              end
            end
          end
          report(model.name.demodulize, columns, failures)
        end
      end

      def report(name, columns, failures)
        pending, real = failures.partition { |failure| PENDING_ON_WP1.key?(failure.key) }
        report_pending(pending)
        assert_pending_current(name, columns, pending)
        assert_no_failures(name, real)
      end

      def report_pending(pending)
        pending.group_by(&:key).each do |key, list|
          puts "[G1 pending on WP-1] #{key} (#{PENDING_ON_WP1[key]}): #{list.size} failures, first: #{list.first}"
        end
      end

      # Every pending entry of the model names a column that still fails.
      def assert_pending_current(name, columns, pending)
        PENDING_ON_WP1.keys.select { |key| key.start_with?("#{name}.") }.each do |key|
          assert columns.include?(key.split('.').last), "#{key}: no such column — remove the PENDING_ON_WP1 entry"
          assert pending.any? { |failure| failure.key == key }, "#{key} no longer fails: remove the PENDING_ON_WP1 entry"
        end
      end

      def assert_no_failures(name, real)
        grouped = real.group_by { |failure| [failure.key, failure.path, failure.message[0, 90]] }
        lines = grouped.map { |(key, path, message), list| "#{key} (#{list.size}×, e.g. #{list.first.value.inspect[0, 40]}): #{path} — #{message}" }
        assert_empty lines.first(60), "#{name}: #{real.size} failures in #{grouped.size} groups (first 60 shown)"
      end

      test 'SKIP names columns that exist' do
        all = self.class.models.flat_map { |model| self.class.columns_of(model).map { |column| "#{model.name.demodulize}.#{column}" } }
        assert_predicate all, :any?
        SKIP.each do |key, reason|
          assert_includes all, key, "SKIP entry #{key} matches no column: remove it"
          assert reason.to_s.strip.present?, "#{key}: give the SKIP entry a reason"
        end
      end
    end
  end
end
