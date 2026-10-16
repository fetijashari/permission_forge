require_relative 'admin_test_case'

module PermissionForge
  module Html
    # Admin findings of the second recorded field test (pf-showcase-2,
    # b-admin-ui): a Muting Permission Set's new resource, the savebar on tabs
    # that apply at once, the WHY panel's per-set field level and the footer
    # of a record changed by code with no audit actor.
    class FieldTestRoundTwoCopyTest < AdminTestCase
      LOCALES = %w[en sq mk].freeze

      def t(key, **)
        I18n.t("permission_forge.#{key}", **)
      end

      def body
        CGI.unescapeHTML(response.body)
      end

      def muting_set
        @muting_set ||= create_permission_set(name: 'No PII exports', is_muting: true)
      end

      def add_customer(set, preset)
        post pf("/permission_sets/#{set.id}/resources"), params: { model_name: 'Customer', preset: preset, locale: 'en' }
        assert_response :redirect
        flash[:notice].tap { follow_redirect! }
      end

      # --- 1. Muting Permission Set: Add resource ---------------------------------

      # b-admin-ui #47: "Added Customer with 0 fields" and an amber "⚠ Sync fields with model ·
      # 8 new columns not configured" right after "Leave everything unchanged".
      test 'a muting resource added with nothing changed says it mutes nothing yet, and the sync panel is no warning' do
        notice = add_customer(muting_set, 'leave')

        assert_equal t('flash.resources.added_muting_nothing', resource: 'Customer'), notice
        assert_select 'details.pf-sync.pf-sync--info', count: 1
        summary = css_select('details.pf-sync > summary').first.text.squish
        assert_no_match(/⚠/, summary)
        assert_match(/columns with no setting, so they mute nothing/, summary)
        assert_no_match(/not configured/, summary)
      end

      test 'a muting resource added with a preset that takes something away says what it takes away' do
        notice = add_customer(muting_set, 'block_changes')

        assert_equal "Added Customer. It takes away #{%w[Create Edit Delete].to_sentence}.", notice
      end

      test 'a muting resource whose preset hides sensitive columns counts them' do
        notice = add_customer(muting_set, 'hide_sensitive')
        hidden = PermissionForge::Resource.find_by!(permission_set: muting_set, name: 'Customer').resource_fields.size

        assert_predicate hidden, :positive?
        assert_equal "Added Customer. It takes away #{t('flash.resources.muted_fields', count: hidden)}.", notice
      end

      test 'a granting resource keeps its field count, and its unconfigured columns still warn' do
        granting = create_permission_set(name: 'Support')
        notice = add_customer(granting, 'nothing')
        created = PermissionForge::Resource.find_by!(permission_set: granting, name: 'Customer').resource_fields.size

        assert_equal t('flash.resources.added', resource: 'Customer', count: created), notice
        PermissionForge::Resource.find_by!(permission_set: granting).resource_fields.first.destroy!
        get pf("/permission_sets/#{granting.id}/resources/Customer"), params: { locale: 'en' }
        assert_select 'details.pf-sync:not(.pf-sync--info)', count: 1
        assert_match(/⚠/, css_select('details.pf-sync > summary').first.text)
      end

      test 'a muting resource still warns about a configured field whose column is gone' do
        resource = create_resource(permission_set: muting_set, read_access: false, edit_access: false)
        create_resource_field(resource: resource, name: 'legacy_fax', read_access: true, edit_access: true)

        get pf("/permission_sets/#{muting_set.id}/resources/Customer"), params: { locale: 'en' }

        assert_select 'details.pf-sync:not(.pf-sync--info)', count: 1
        assert_match(/⚠/, css_select('details.pf-sync > summary').first.text)
      end

      test 'the muting sync summary reads in every locale' do
        create_resource(permission_set: muting_set, read_access: false, edit_access: false)
        LOCALES.each do |locale|
          get pf("/permission_sets/#{muting_set.id}/resources/Customer"), params: { locale: locale }

          assert_response :success
          assert_no_missing_translations
        end
      end

      # --- 2. Savebar on tabs that apply at once ----------------------------------

      # b-admin-ui #49: "Assigning or revoking applies immediately" above a savebar offering
      # "No unsaved changes · Review and save".
      test 'the set savebar is quiet on the tabs that apply at once, and stays rendered for the header' do
        %w[assignments conditions audit].each do |tab|
          get pf("/permission_sets/#{@set.id}"), params: { tab: tab }

          assert_select '#pf-set-savebar.pf-savebar--quiet', 1, "#{tab}: the savebar hides until the header changes"
          assert_select "#pf-set-name[form='pf-set-form']", 1, "#{tab}: the header still saves through the bar (no JS)"
          assert_select "#pf-set-savebar button[type='submit'][form='pf-set-form']", 1
        end

        get pf("/permission_sets/#{@set.id}")
        assert_select '#pf-set-savebar', 1
        assert_select '#pf-set-savebar.pf-savebar--quiet', 0
      end

      test 'only a page running the script hides a quiet savebar, and only while nothing changed' do
        css = File.read(PermissionForge::Engine.root.join('app/frontend/permission_forge/pf_admin.css'))

        assert_includes css, '.pf-js .pf-savebar--quiet[data-pf-dirty="false"] { display: none; }'
      end

      # --- 3. Effective access WHY: each set's level -------------------------------

      # b-admin-ui #62: "✓ Sales rep shows this field." while Sales rep shows it Masked (Email).
      test 'the WHY panel says how each set shows the field' do
        muting = create_resource(permission_set: muting_set, read_access: false, edit_access: false)
        create_resource_field(resource: muting, name: 'email', read_access: true, edit_access: true)
        create_resource_field(resource: @resource, name: 'name', read_access: true, edit_access: true)
        create_resource_field(resource: @resource, name: 'phone', read_access: true)
        create_permission_set_user(user: @ana, permission_set: muting_set)

        get pf("/people/#{@ana.id}"), params: { tab: 'effective', why: 'Customer.field.email', locale: 'en' }

        assert_response :success
        assert_equal ['Sales rep shows this field masked (Email).', 'No PII exports hides this field.'],
                     why_reasons('Customer.field.email')
        assert_equal ['Sales rep shows this field and lets people edit it.'], why_reasons('Customer.field.name')
        assert_equal ['Sales rep shows this field read-only.'], why_reasons('Customer.field.phone')
        assert_not_includes body, 'Sales rep shows this field.'
      end

      # On a field the granting sets show unmasked (phone, read-only): a mask
      # on a field they already mask changes nothing and is not credited
      # (review R4 P2-4, admin_view_models_test.rb WHY_STATES).
      test 'a muting set that forces a mask says so, in every locale' do
        muting = create_resource(permission_set: muting_set, read_access: false, edit_access: false)
        create_resource_field(resource: muting, name: 'phone', read_access: false, edit_access: false, mask_access: true)
        create_resource_field(resource: @resource, name: 'phone', read_access: true)
        create_permission_set_user(user: @ana, permission_set: muting_set)

        LOCALES.each do |locale|
          get pf("/people/#{@ana.id}"), params: { tab: 'effective', why: 'Customer.field.phone', locale: locale }

          assert_response :success
          assert_no_missing_translations
          I18n.with_locale(locale) do
            assert_includes why_reasons('Customer.field.phone'), t('ui.level_sentences.mask', set: 'No PII exports')
          end
        end
      end

      # --- 4. Footer of a change with no audit actor --------------------------------

      # b-admin-ui (lock from a runner): "Last edited by Unknown" with nothing saying why.
      test 'a change made by code with no audit actor names it as the audit log does, with a hint' do
        enable_audit_trail_without_resolver do
          @set.update!(description: 'Changed from a runner')
          assert_audit_event('permission_set.updated', record_id: @set.id.to_s, actor_type: 'unknown')

          get pf("/permission_sets/#{@set.id}"), params: { locale: 'en' }

          footer = css_select('.pf-audit-footer').first
          # Created and last edited by nobody known: "Unknown" is said once (the creation).
          assert_equal 1, footer.text.squish.scan(t('ui.states.actor.unknown')).size, footer.text.squish
          assert_match t('shared.audit_footer.edited_at', updated_at: t('ui.dates.today')), footer.text.squish
          hint = footer.css('.pf-audit-footer__hint').first
          assert hint, 'the footer explains the unknown actor'
          assert_equal 'PermissionForge.with_audit_actor', hint.css('code').text
          assert_match(/no actor was named for this change/i, hint.text)
        end
      end

      test 'a record created and changed by named actors has no hint' do
        enable_audit_trail_without_resolver do
          PermissionForge.with_audit_actor(user: @bo) do
            @named = create_permission_set(name: 'Made by Bo')
            @named.update!(description: 'Changed by Bo')
          end

          get pf("/permission_sets/#{@named.id}"), params: { locale: 'en' }

          assert_select '.pf-audit-footer__hint', 0
        end
      end

      test 'the unknown-actor hint reads in every locale' do
        enable_audit_trail_without_resolver do
          @set.update!(description: 'Changed from a runner')
          LOCALES.each do |locale|
            get pf("/permission_sets/#{@set.id}"), params: { locale: locale }

            assert_no_missing_translations
            assert_select '.pf-audit-footer__hint code', text: 'PermissionForge.with_audit_actor'
          end
        end
      end

      private

      def why_reasons(key)
        css_select("#pf-why-#{key.gsub('.', '\\.')} .pf-why__reason > span:nth-child(2) > span:first-child")
          .map { |node| node.text.squish }
      end

      def enable_audit_trail_without_resolver
        config = PermissionForge.configuration
        old_resolver = config.current_user_resolver
        config.audit_trail_enabled = true
        config.current_user_resolver = -> {}
        yield
      ensure
        config.current_user_resolver = old_resolver
      end
    end
  end
end
