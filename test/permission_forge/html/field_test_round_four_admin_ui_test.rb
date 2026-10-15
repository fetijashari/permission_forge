require_relative 'admin_test_case'

module PermissionForge
  module Html
    # Admin findings of the fourth recorded field test (pf-showcase-4,
    # b-admin-ui): the Assignments grid at phone width, the privacy audit's
    # "This is intended" sentence on a locked set, the Why badge of a field
    # hidden by muting and the event page of a change with no actor.
    class FieldTestRoundFourAdminUiTest < AdminTestCase
      LOCALES = %w[en sq mk].freeze
      CSS = File.read(File.expand_path('../../../app/frontend/permission_forge/pf_admin.css', __dir__))

      def t(key, **)
        I18n.t("permission_forge.#{key}", **)
      end

      def body
        CGI.unescapeHTML(response.body)
      end

      # --- 1. Assignments grid at phone width (b #72) -------------------------------

      def narrow_block
        CSS[/@container \(max-width: 639px\) \{(.*?)\n\}/m, 1]
      end

      # The card scrolled sideways (a 640px table in a 356px card) and clipped "Reason".
      test 'a narrow card stacks each Assignments row instead of scrolling it' do
        block = narrow_block
        assert block, 'pf_admin.css has a container query for a narrow table card'
        assert_match(/\.pf-table-frame \{ container-type: inline-size; \}/, CSS)
        assert_match(/\.pf-table-frame \.pf-table--assignments \{ display: block; min-width: 0; \}/, block)
        assert_match(/\.pf-table-frame \.pf-table--assignments > \.pf-table__row \{ grid-template-columns: auto minmax\(0, 1fr\);/,
                     block)
        assert_match(/> :not\(:first-child\) \{ grid-column: 2; \}/, block)
      end

      test 'the Assignments card is the container the narrow layout measures' do
        create_permission_set_user(user: @bo, permission_set: @set, expires_at: 30.days.from_now)
        get pf("/permission_sets/#{@set.id}"), params: { tab: 'assignments' }

        assert_response :success
        assert_select '.pf-card.pf-table-frame > .pf-table--assignments', 1
        # Every row still has a cell per column (the desktop subgrid).
        css_select('.pf-table--assignments > .pf-table__row').each { |row| assert_equal 5, row.css('> [role=cell]').size }
      end

      # --- 2. Privacy audit: "This is intended" only where a row offers it (b #93) --

      def unmasked_name
        create_resource_field(resource: @resource, name: 'name', read_access: true, mask_access: false)
      end

      def privacy_card
        css_select('section[aria-labelledby=pf-card-privacy]').first
      end

      test 'the privacy audit names This is intended when a row offers it' do
        unmasked_name
        get pf('/'), params: { privacy: 'all' }

        assert_includes privacy_card.text.squish, t('home.privacy_card.by_name_note').squish
        assert_includes privacy_card.text.squish, t('home.privacy_card.intended_note')
        assert(privacy_card.css('button').any? { |button| button.text.strip == t('home.privacy_card.intended') })
      end

      test 'a privacy audit whose rows are all locked does not tell the admin to choose This is intended' do
        unmasked_name
        @set.update_columns(is_editable: false)
        LOCALES.each do |locale|
          get pf('/'), params: { privacy: 'all', locale: locale }

          assert_no_missing_translations
          I18n.with_locale(locale) do
            assert_includes privacy_card.text.squish, t('home.privacy_card.by_name_note').squish
            assert_not_includes privacy_card.text.squish, t('home.privacy_card.intended_note')
            assert_empty(privacy_card.css('button').select { |button| button.text.strip == t('home.privacy_card.intended') })
          end
        end
      end

      test 'a finding offers This is intended when it is shown unmasked and not locked' do
        name = unmasked_name
        finding = -> { Admin::AttentionItems.new.privacy_findings.find { |f| f.name == 'name' } }
        assert_predicate finding.call, :acknowledgeable?

        name.update_columns(is_editable: false)
        assert_not finding.call.acknowledgeable?
        unconfigured = Admin::AttentionItems.new.privacy_findings.find(&:unconfigured?)
        assert_not unconfigured.acknowledgeable?
      end

      # --- 3. Why badge of a field hidden by muting (b #52) --------------------------

      def mute_email_for(user)
        muting = create_permission_set(name: 'No PII exports', is_muting: true)
        resource = create_resource(permission_set: muting, read_access: false)
        create_resource_field(resource: resource, name: 'email', read_access: true)
        create_permission_set_user(user: user, permission_set: muting)
      end

      def why_badge(key)
        css_select("[id='pf-why-#{key}'] .pf-level-badge").first
      end

      def row_badge(name)
        link = css_select('.pf-effective__field').find { |row| row.at_css('code.pf-mono-key')&.text == name }
        link&.at_css('.pf-level-badge')
      end

      test 'the Why panel of a field hidden by muting reads as its row does' do
        mute_email_for(@ana)
        create_resource_field(resource: @resource, name: 'phone', read_access: false)
        get pf("/people/#{@ana.id}"), params: { tab: 'effective', open: ['Customer'], why: 'Customer.field.email' }

        assert_response :success
        muted = "⊘ #{t('people.effective_tab.hidden_by_muting')}"
        assert_equal muted, row_badge('email').text.strip
        assert_equal muted, why_badge('Customer.field.email').text.strip
        assert_includes why_badge('Customer.field.email')['class'], 'pf-level-badge--muted'
        # A field no set grants keeps the neutral badge, in its row and its panel.
        assert_equal "∅ #{t('ui.levels.hidden')}", row_badge('phone').text.strip
        assert_equal "∅ #{t('ui.levels.hidden')}", why_badge('Customer.field.phone').text.strip
      end

      test 'a masked field keeps its strategy in the row and its sample in the Why panel' do
        get pf("/people/#{@ana.id}"), params: { tab: 'effective', open: ['Customer'] }

        assert_match(/\A•• #{t('ui.levels.masked')} \(#{t('ui.mask_strategies.email')}\)\z/, row_badge('email').text.strip)
        assert_match(/\A•• #{t('ui.levels.masked')} \(#{t('ui.mask_strategies.email')}\) · \S+@\S+\z/,
                     why_badge('Customer.field.email').text.strip)
      end

      # --- 4. Event page of a change with no actor (b #94) ---------------------------

      def with_unattributed_change
        config = PermissionForge.configuration
        old_resolver = config.current_user_resolver
        config.audit_trail_enabled = true
        config.current_user_resolver = -> {}
        @set.update!(description: 'Changed from a runner')
        yield assert_audit_event('permission_set.updated', record_id: @set.id.to_s, actor_type: 'unknown')
      ensure
        config.current_user_resolver = old_resolver
      end

      test 'the event page names Unknown once: the explanation does not start with it again' do
        with_unattributed_change do |event|
          LOCALES.each do |locale|
            get pf("/audit/#{event.uuid}"), params: { locale: locale }

            assert_response :success
            assert_no_missing_translations
            I18n.with_locale(locale) do
              unknown = t('audit_log.actor_types.unknown')
              who = css_select('section[aria-labelledby=pf-event-who]').first
              hint = who.css('p').find { |p| p.at_css('code') }
              assert hint, 'the explanation is shown'
              assert_equal 'PermissionForge.with_audit_actor', hint.at_css('code').text
              assert_not hint.text.strip.start_with?(unknown), "#{locale}: the explanation repeats #{unknown}"
            end
          end
        end
      end

      test 'the record footer keeps naming Unknown before its explanation' do
        with_unattributed_change do
          get pf("/permission_sets/#{@set.id}"), params: { locale: 'en' }

          hint = css_select('.pf-audit-footer__hint').first
          assert hint
          assert hint.text.strip.start_with?("#{t('audit_log.actor_types.unknown')}:")
        end
      end
    end
  end
end
