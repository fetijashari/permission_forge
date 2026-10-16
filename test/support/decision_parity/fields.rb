# frozen_string_literal: true

# WP-8a — field rows (plan-final.md §2 OD, G5 parts a, b, g). Reopens
# PermissionForge::ReleaseReadiness::DecisionParityTest (which loads this
# file); see it for the convention.
module PermissionForge
  module ReleaseReadiness
    class DecisionParityTest
      PARITY_MODELS = %w[Customer PfVariantOrder].freeze
      # The levels that write no row, by muting: written out here, not read
      # from FieldLevel.row?, so breaking that definition turns (a) red.
      LEVELS_WITHOUT_ROWS = { false => [], true => %w[leave] }.freeze
      # What a generated row is, for comparison: the flags, the strategy, the label.
      ROW = ->(field) { [field.name, field.read_access, field.edit_access, field.mask_access, field.mask_strategy, field.label] }
      # The generator's grant_all for an admin level, where it has one.
      GENERATOR_GRANT_ALL = { 'edit' => true, 'hidden' => false, 'hide' => true, 'leave' => false }.freeze

      # (a) The admin's presets / "Sync fields" (Admin::ColumnFields), the
      # Fields tab's bulk "Add" (Admin::ChangeSet → NewFields) and
      # ResourceFieldGenerator (the API's generate_fields, grant_full_access!,
      # the console) write the same rows for the same level: name, read, edit,
      # mask, strategy, label — timestamps, privacy defaults, virtual fields
      # (PermissionForge::ManagedFields: the same names on every path, under
      # either extra_fields_default_access) and a Resource without Edit
      # (Editable is Read-only there: FieldLevel.capped) included. A level
      # that is no row (Unchanged in a Muting Permission Set) is no row on
      # every path — the generator without grant_all on a muting set writes
      # none either. The first loop runs the library defaults (a Resource
      # with Edit, extra_fields_default_access = :grant), the second the
      # other combinations.
      PARITY_MODELS.each do |model_name|
        [false, true].each do |muting|
          [false, true].each do |gdpr|
            PermissionForge::Admin::FieldLevel.levels_for(muting: muting).each do |level|
              test "(a) #{model_name}, muting=#{muting}, gdpr_defaults=#{gdpr}, #{level}: presets, bulk and the generator write the same rows" do
                assert_paths_agree(model_name, level, muting: muting, gdpr: gdpr, resource_edit: true, extra: :grant)
              end

              [[false, :grant], [true, :unconfigured], [false, :unconfigured]].each do |resource_edit, extra|
                test "(a) #{model_name}, resource edit=#{resource_edit}, extra fields #{extra}, muting=#{muting}, " \
                     "gdpr_defaults=#{gdpr}, #{level}: presets, bulk and the generator write the same rows" do
                  assert_paths_agree(model_name, level, muting: muting, gdpr: gdpr, resource_edit: resource_edit, extra: extra)
                end
              end
            end
          end
        end
      end

      test '(a) Editable on a Resource without Edit is Read-only on every path, and the privacy default does not mask it' do
        PermissionForge.configuration.gdpr_defaults = true
        presets, bulk, generated = rows_by_path('Customer', muting: false, level: 'edit', resource_edit: false)

        assert_equal presets, bulk
        assert_equal presets, generated
        assert_includes presets, ['email', true, false, false, 'email', 'email']
        assert(presets.none? { |row| row[2] }, 'no row is editable on a Resource without Edit')
      end

      test '(a) a declared virtual field gets the level chosen on every path under extra_fields_default_access = :grant' do
        PermissionForge.configuration.extra_fields_default_access = :grant
        presets, bulk, generated = rows_by_path('PfVariantOrder', muting: false, level: 'hidden')

        assert_equal presets, bulk
        assert_equal presets, generated
        assert_includes presets.map(&:first), 'region_uuid'
      end

      test '(a) a column named only by the host filter_parameters starts Masked on every path (Read-only, gdpr_defaults)' do
        PermissionForge.configuration.gdpr_defaults = true
        with_filter_parameters(:domain) do
          presets, bulk, = rows_by_path('Customer', muting: false, level: 'read')
          sets = 2.times.map { parity_set('filter generator') }
          resource = create_resource(permission_set: sets.first, name: 'Customer', read_access: true, edit_access: true)
          Services::ResourceFieldGenerator.call(resource: resource, grant_all: false)
          generated = resource.resource_fields.reload.map(&ROW).sort

          assert_equal presets, bulk
          assert_includes presets, ['domain', true, false, true, 'full', 'domain']
          assert_includes generated, ['domain', false, false, false, 'full', 'domain']
        end
      end

      test '(a) Symbol ignored_fields keep their columns out on every path' do
        PermissionForge.configuration.ignored_fields = PermissionForge.configuration.ignored_fields.map(&:to_sym)
        presets, bulk, generated = rows_by_path('Customer', muting: false, level: 'edit')

        assert_equal presets, bulk
        assert_equal presets, generated
        assert_not_includes presets.map(&:first), 'uuid'
      end

      # (b) One matcher: what SensitiveColumns says is personal data, with its
      # strategy, is what the GDPR audit reports unmasked and what the boot
      # warning names — a column the host's filter_parameters name included.
      test '(b) the GDPR audit and the boot warning name exactly the columns SensitiveColumns matches, with its strategy' do
        with_filter_parameters(:api_token) do
          matcher = PermissionForge::SensitiveColumns.new
          names = %w[email phone_number api_token notes]
          resource = create_resource(permission_set: parity_set('matcher'), name: 'Customer')
          rows = names.index_with { |name| create_resource_field(resource: resource, name: name, read_access: true, mask_access: false) }
          expected = names.filter_map { |name| (match = matcher.match(name)) && [name, match.strategy] }.to_h

          findings = Services::GdprFieldAuditor.call.select { |f| f[:type] == :unmasked_field && rows.values.map(&:id).include?(f[:resource_field_id]) }
          assert_equal(expected, findings.to_h { |f| [f[:field_name], f[:suggested_strategy]] })
          assert_equal({ 'email' => 'email', 'phone_number' => 'last4', 'api_token' => 'full' }, expected)

          names.each do |name|
            rows.except(name).each_value { |row| row.update!(mask_access: true, read_access: true) }
            log = capture_rails_log { PermissionForge::BootChecks.warn_unmasked_gdpr_fields(PermissionForge.configuration) }
            assert_equal matcher.sensitive?(name), log.include?("field '#{name}'"), "boot warning for #{name}"
            rows.except(name).each_value { |row| row.update!(mask_access: false) }
          end
        end
      end

      # (b) "This is intended" (sensitive_acknowledged_at) has one definition,
      # ResourceField#exposes_unacknowledged? / .exposing_unacknowledged: an
      # acknowledged row in the clear is reported by none of the four
      # surfaces — the GDPR audit (rake permission_forge:audit_masks), the
      # security audit's personal_data check, Home's privacy card and the
      # boot warning — and by all four once the acknowledgement is gone.
      test '(b) a row marked "This is intended" is reported by no surface, and by every surface without the mark' do
        resource = create_resource(permission_set: parity_set('acknowledged'), name: 'Customer', read_access: true)
        row = create_resource_field(resource: resource, name: 'email', read_access: true, mask_access: false, mask_strategy: 'email')
        PermissionForge::ResourceField.where.not(id: row.id).exposing_in_clear.find_each { |other| other.update!(mask_access: true) }

        row.update!(sensitive_acknowledged_at: Time.current)
        assert_equal({ audit: false, security: false, home: false, boot: false }, surfaces_reporting(row))

        row.update!(sensitive_acknowledged_at: nil)
        assert_equal({ audit: true, security: true, home: true, boot: true }, surfaces_reporting(row))
      end

      test '(b) the boot warning names what matched: the GDPR pattern, or the host filter_parameters' do
        resource = create_resource(permission_set: parity_set('boot wording'), name: 'Customer', read_access: true)
        row = create_resource_field(resource: resource, name: 'email', read_access: true, mask_access: false, mask_strategy: 'email')
        PermissionForge::ResourceField.where.not(id: row.id).exposing_in_clear.find_each { |other| other.update!(mask_access: true) }

        log = capture_rails_log { PermissionForge::BootChecks.warn_unmasked_gdpr_fields(PermissionForge.configuration) }
        assert_match(/field 'email' on resource 'Customer' matches the GDPR pattern 'email' but is not masked/, log)

        row.update!(name: 'domain')
        with_filter_parameters(:domain) do
          log = capture_rails_log { PermissionForge::BootChecks.warn_unmasked_gdpr_fields(PermissionForge.configuration) }
          assert_match(/field 'domain' on resource 'Customer' is named by the application's filter_parameters but is not masked/, log)
          assert_no_match(/GDPR pattern/, log)
        end
      end

      # (g) "Readable in the clear" has one definition,
      # ResourceField#exposes_in_clear?: the audit's unmasked and cross-set
      # findings name exactly those rows. A Hidden row (read off, mask off)
      # is never one of them, nor is a row written past the validation with
      # mask on and read off.
      test '(g) the GDPR audit names exactly the rows that expose a field in the clear; a Hidden row never' do
        combos = { hidden: [false, false], masked: [true, true], read: [true, false] }
        rows = combos.map do |label, (read, mask)|
          resource = create_resource(permission_set: parity_set("in clear #{label}"), name: 'Customer')
          create_resource_field(resource: resource, name: 'email', read_access: read, mask_access: mask, mask_strategy: 'email')
        end
        legacy = create_resource_field(resource: create_resource(permission_set: parity_set('in clear legacy'), name: 'Customer'),
                                       name: 'email', read_access: true, mask_access: true, mask_strategy: 'email')
        legacy.update_columns(read_access: false)
        rows << legacy.reload
        in_clear = rows.select(&:exposes_in_clear?)
        assert_equal 1, in_clear.size

        report = Services::GdprFieldAuditor.call
        unmasked = report.select { |f| f[:type] == :unmasked_field && rows.map(&:id).include?(f[:resource_field_id]) }
        assert_equal(in_clear.map(&:id), unmasked.map { |f| f[:resource_field_id] })
        set_names = rows.map { |row| row.resource.permission_set.name }
        cross = report.select { |f| f[:type] == :cross_set_unmasking && f[:field_name] == 'email' && set_names.include?(f[:permission_set]) }
        assert_equal(in_clear.map { |row| row.resource.permission_set.name }, cross.map { |f| f[:permission_set] })
      end

      private

      # Which surfaces report `row` as personal data in the clear.
      def surfaces_reporting(row)
        { audit: audit_reports?(row), security: security_reports?(row),
          home: PermissionForge::Admin::AttentionItems.new.privacy_findings.any? { |finding| finding.field&.id == row.id },
          boot: capture_rails_log { PermissionForge::BootChecks.warn_unmasked_gdpr_fields(PermissionForge.configuration) }
                .include?("field '#{row.name}'") }
      end

      def audit_reports?(row)
        Services::GdprFieldAuditor.call.any? { |f| f[:type] == :unmasked_field && f[:resource_field_id] == row.id }
      end

      def security_reports?(row)
        check = Services::SecurityAuditChecks::PersonalDataCheck.new(configuration: PermissionForge.configuration, environment: 'test')
        findings = check.call.select { |finding| finding.code == :unmasked_personal_data }
        findings.flat_map(&:items).any? { |item| item.include?(".#{row.name} ") }
      end

      # The three paths agree, and a level writes rows exactly when it is
      # one (LEVELS_WITHOUT_ROWS).
      def assert_paths_agree(model_name, level, **setting)
        muting, gdpr, resource_edit, extra = setting.values_at(:muting, :gdpr, :resource_edit, :extra)
        PermissionForge.configuration.gdpr_defaults = gdpr
        PermissionForge.configuration.extra_fields_default_access = extra
        presets, bulk, generated = rows_by_path(model_name, muting: muting, level: level, resource_edit: resource_edit)

        assert_equal presets, bulk, 'presets vs bulk'
        if generated.nil?
          assert_not_empty presets
        else
          assert_equal presets, generated, 'presets vs generator'
        end
        assert_equal LEVELS_WITHOUT_ROWS.fetch(muting).exclude?(level), presets.any?, 'a level that is no row writes none'
      end

      # [presets rows, bulk rows, generator rows or nil] for `level` on fresh
      # sets of the same kind; rows as ROW, sorted.
      def rows_by_path(model_name, muting:, level:, resource_edit: true)
        resources = 3.times.map { |i| parity_resource(model_name, "parity #{i}", muting: muting, edit: resource_edit) }
        generated = all_paths_wrote?(resources, level, muting: muting)

        rows = resources.map { |resource| resource.resource_fields.reload.map(&ROW).sort }
        generated ? rows : rows.first(2) << nil
      end

      # Writes the rows on the three paths; false when the generator has no
      # grant_all for `level` (Masked, Read-only, Force mask).
      def all_paths_wrote?(resources, level, muting:)
        names = PermissionForge::Admin::ModelCatalog.new.find(resources.first.name).managed_field_names
        PermissionForge::Admin::ColumnFields.new(resources[0], muting: muting).create(names, level)
        bulk_add(resources[1], names, level)
        grant_all = GENERATOR_GRANT_ALL[level]
        return false if grant_all.nil?

        Services::ResourceFieldGenerator.call(resource: resources[2], grant_all: grant_all)
        true
      end

      def parity_resource(model_name, label, muting:, edit: true)
        create_resource(permission_set: parity_set(label, muting: muting), name: model_name, read_access: true, edit_access: edit)
      end

      # The Fields tab's bulk "Add" of unconfigured columns, as the controller posts it.
      def bulk_add(resource, names, level)
        params = { bulk: { resource_id: resource.id.to_s, keys: names, level: level } }
        PermissionForge::Admin::ChangeSet.new(permission_set: resource.permission_set, params: params).apply!
      end
    end
  end
end
