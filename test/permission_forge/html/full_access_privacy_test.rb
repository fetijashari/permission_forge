require_relative 'admin_test_case'

module PermissionForge
  module Html
    # "Full access" asks for full access: privacy defaults mask nothing, and
    # the columns that look personal stay flagged (the Sensitive badge on the
    # Fields tab, the Home privacy audit) so the admin decides. The other
    # granting levels keep the privacy defaults.
    class FullAccessPrivacyTest < AdminTestCase
      setup do
        @config = PermissionForge.configuration
        @config.gdpr_defaults = true
        @admin = create_permission_set(name: 'Admin')
        create_permission_set_user(user: @bo, permission_set: @admin)
      end

      def t(key, **)
        I18n.t("permission_forge.#{key}", **)
      end

      def level_of(resource, name)
        PermissionForge::Admin::FieldLevel.level_of(resource.resource_fields.find_by!(name: name), muting: false)
      end

      def add_customer(preset)
        post pf("/permission_sets/#{@admin.id}/resources"), params: { model_name: 'Customer', preset: preset }
        @admin.resources.find_by!(name: 'Customer')
      end

      def fields_row(name)
        css_select('.pf-fields__row').find { |row| row.at_css('code.pf-mono-key')&.text == name }
      end

      test 'the Full access preset masks nothing and keeps the recommended strategy' do
        customer = add_customer('full')

        assert_equal(%w[edit edit edit], %w[name email domain].map { |name| level_of(customer, name) })
        assert_equal [], customer.resource_fields.select(&:mask_access).map(&:name)
        assert_equal(%w[first1_last4 email], %w[name email].map { |name| customer.resource_fields.find_by!(name: name).mask_strategy })
        @bo.regenerate_permissions
        assert_not @bo.masked_field?(:Customer, :name)
      end

      test 'the Full access preset gives Rails timestamps Read-only, as the generator does' do
        customer = add_customer('full')

        assert_equal(%w[read read], %w[created_at updated_at].map { |name| level_of(customer, name) })
      end

      test 'after Full access the personal-data columns stay flagged on the Fields tab and on Home' do
        add_customer('full')
        follow_redirect!

        assert_response :success
        row = fields_row('name')
        assert row, 'the name row is listed'
        assert_includes row.css('.pf-badge').map { |badge| badge.text.strip }, t('ui.badges.sensitive')

        get pf('/'), params: { privacy: 'all' }
        body = CGI.unescapeHTML(response.body)
        where = t('home.privacy_card.where', resource: 'Customer', set: 'Admin', people: '1 person')
        assert_includes body, where
        findings = PermissionForge::Admin::AttentionItems.new.privacy_findings.select { |f| f.permission_set == @admin }
        assert_equal %w[email full_address name], findings.reject(&:unconfigured?).map(&:name).sort
      end

      # Detection reads column names only: a company's name is flagged like a
      # person's. The admin is told a flag may be wrong and confirms the field.
      test 'a flag may not be personal data: the card says so, and This is intended clears it' do
        add_customer('full')
        get pf('/'), params: { privacy: 'all' }
        assert_includes CGI.unescapeHTML(response.body), t('home.privacy_card.by_name_note')

        get pf("/permission_sets/#{@admin.id}/resources/Customer/fields/name")
        match = PermissionForge::SensitiveColumns.new.match('name')
        sensitive = t('resource_fields.show.sensitive', pattern: match.pattern, strategy: t('ui.mask_strategies.first1_last4'))
        assert_includes CGI.unescapeHTML(response.body), sensitive

        post pf("/permission_sets/#{@admin.id}/resources/Customer/fields/name/acknowledge")
        findings = PermissionForge::Admin::AttentionItems.new.privacy_findings.select { |f| f.permission_set == @admin }
        assert_equal %w[email full_address], findings.map(&:name).sort
        assert PermissionForge::SensitiveColumns.new.sensitive?('name'), 'still flagged Sensitive'
      end

      test 'no note about name-based flags while nothing sensitive is shown unmasked' do
        add_customer('read')
        get pf('/'), params: { privacy: 'all' }

        assert_not_includes CGI.unescapeHTML(response.body), t('home.privacy_card.by_name_note')
      end

      test 'the Read-only preset still starts sensitive columns Masked' do
        customer = add_customer('read')

        assert_equal(%w[masked masked read], %w[name email domain].map { |name| level_of(customer, name) })
      end

      test 'the Add resource form says Full access is the exception to the privacy defaults' do
        get pf("/permission_sets/#{@admin.id}/resources/new")

        body = CGI.unescapeHTML(response.body)
        assert_includes body, t('resources.new.note_gdpr')
        assert_includes body, t('resources.new.presets.full.desc')
      end

      test 'sync: "with full access" masks nothing, "Read-only" masks the sensitive columns' do
        customer = add_customer('nothing')
        customer.resource_fields.where(name: %w[name email domain]).destroy_all
        customer.update!(read_access: true, edit_access: true) # Editable needs the Resource's Edit (FieldLevel.capped)
        base = "/permission_sets/#{@admin.id}/resources/Customer"

        post pf("#{base}/sync"), params: { op: 'add_new', level: 'edit' }
        assert_equal(%w[edit edit edit], %w[name email domain].map { |name| level_of(customer, name) })

        customer.resource_fields.where(name: %w[name email domain]).destroy_all
        post pf("#{base}/sync"), params: { op: 'add_new', level: 'read' }
        assert_equal(%w[masked masked read], %w[name email domain].map { |name| level_of(customer, name) })
      end
    end
  end
end
