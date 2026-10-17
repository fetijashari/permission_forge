require_relative 'admin_test_case'
require_relative '../virtual_field_models'

module PermissionForge
  module Html
    # Virtual fields on the admin's Fields tab, field drawer, sync panel, set
    # page and home page: listed, configurable, and described truthfully.
    class VirtualFieldsTest < AdminTestCase
      setup do
        @config = PermissionForge.configuration
        @config.admin_model_resolver = -> { [::Customer, ::Supplier, ::PfVirtualAccount] }
        @base = "/permission_sets/#{@set.id}/resources/Customer"
      end

      def t(key, **)
        I18n.t("permission_forge.#{key}", **)
      end

      def level_of(resource, name)
        field = resource.resource_fields.find_by(name: name)
        field && PermissionForge::Admin::FieldLevel.level_of(field, muting: resource.permission_set.is_muting)
      end

      def setting_href(key)
        "#{ROOT}/settings?focus=#{key}#set-#{key}"
      end

      def add_account(preset, set: @set)
        post pf("/permission_sets/#{set.id}/resources"), params: { model_name: 'PfVirtualAccount', preset: preset }
        set.resources.find_by!(name: 'PfVirtualAccount')
      end

      # --- Fields tab ---------------------------------------------------------

      test 'an unconfigured declared virtual field says it is editable by default' do
        get pf(@base)

        assert_response :success
        badge = t('resources.fields_tab.not_configured', state: t('ui.states.field_level.none'), behaviour: t('resources.fields_tab.implicit_grant'))
        assert_select "a.pf-badge--unconfigured[href='#{setting_href('extra_fields_default_access')}']", text: badge, count: 2
        assert_select '.pf-fields__row', text: /full_address/ do
          assert_select '.pf-badge', text: t('ui.badges.virtual')
          assert_select '.pf-badge', text: t('ui.badges.sensitive')
        end
        assert_select "a.pf-badge--unconfigured[href='#{setting_href('unconfigured_field_strategy')}']", minimum: 1
      end

      test 'under :unconfigured the same field follows the unconfigured-field setting' do
        @config.extra_fields_default_access = :unconfigured
        @config.unconfigured_field_strategy = :block
        get pf(@base)

        assert_no_match t('resources.fields_tab.implicit_grant'), response.body
        assert_select '.pf-fields__row', text: /full_address/ do
          assert_select "a.pf-badge--unconfigured[href='#{setting_href('unconfigured_field_strategy')}']",
                        text: t('resources.fields_tab.not_configured', state: t('ui.states.field_level.none'), behaviour: t('ui.unconfigured.block'))
        end
      end

      test 'a configured virtual field shows its level and no default note' do
        create_resource_field(resource: @resource, name: 'full_address', read_access: true, mask_access: true)
        create_resource_field(resource: @resource, name: 'contact_count', read_access: true)
        get pf(@base)

        assert_no_match t('resources.fields_tab.implicit_grant'), response.body
        assert_select '.pf-fields__row', text: /full_address/ do
          assert_select '.pf-badge', text: t('ui.badges.virtual')
          assert_select '.pf-badge--column_missing', count: 0
        end
      end

      test 'the unconfigured filter and the sync panel include virtual fields' do
        get pf(@base), params: { filter: 'unconfigured', sync: 1 }

        assert_select '.pf-fields__row code', text: 'full_address'
        assert_select '.pf-sync li', text: /contact_count/ do
          assert_select '.pf-badge', text: t('ui.badges.virtual')
        end
        new_count = PermissionForge::Admin::FieldRows.new(@resource).new_columns.size
        assert_match t('resources.sync.new_count', count: new_count), response.body
      end

      test 'discovered virtual fields are listed only while discovery is on, and never as editable by default' do
        account = add_account('nothing')
        account.resource_fields.destroy_all
        path = "/permission_sets/#{@set.id}/resources/PfVirtualAccount"

        get pf(path)
        assert_select '.pf-fields__row code', text: 'theme', count: 0

        @config.virtual_field_discovery = true
        get pf(path)
        assert_select '.pf-fields__row', text: /theme/ do
          assert_select '.pf-badge', text: t('ui.badges.virtual')
          assert_select "a.pf-badge--unconfigured[href='#{setting_href('unconfigured_field_strategy')}']"
        end
        assert_select "a.pf-badge--unconfigured[href='#{setting_href('extra_fields_default_access')}']", count: 1
      end

      # --- Adding and syncing ---------------------------------------------------

      test 'the Read-only preset makes virtual fields read-only instead of leaving them editable' do
        @config.virtual_field_discovery = true
        account = add_account('read')

        assert_equal(%w[read read read], %w[full_address nickname theme].map { |name| level_of(account, name) })
        @ana.regenerate_permissions
        entry = @ana.field_permissions(:PfVirtualAccount, :full_address)
        assert_equal [true, false], entry.values_at(:read_access, :edit_access)
      end

      test 'the Full access preset makes virtual fields editable, sensitive ones too (no privacy-default mask)' do
        @config.gdpr_defaults = true
        account = add_account('full')

        assert_equal 'edit', level_of(account, 'full_address')
        assert_equal 'edit', level_of(account, 'supplier_id')
        assert_nil level_of(account, 'theme'), 'discovery is off'
      end

      test 'the muting Hide sensitive preset hides a sensitive virtual field' do
        muting = create_permission_set(name: 'Contractors', is_muting: true)
        account = add_account('hide_sensitive', set: muting)

        assert_equal 'hide', level_of(account, 'full_address')
      end

      test 'sync adds unconfigured virtual fields at the chosen level' do
        post pf("#{@base}/sync"), params: { op: 'add_new', level: 'read' }

        assert_equal(%w[read read], %w[full_address contact_count].map { |name| level_of(@resource, name) })
        assert_empty PermissionForge::Admin::FieldRows.new(@resource.reload).new_columns
        get pf(@base)
        assert_no_match t('resources.fields_tab.implicit_grant'), response.body
      end

      test 'a virtual field is configured from the Fields tab like a column' do
        params = { pf: { new_fields: { @resource.id => { 'full_address' => { level: 'hidden' } } },
                         bulk: { resource_id: @resource.id, keys: ['contact_count'], level: 'read' } } }
        post pf("#{@base}/review"), params: params
        assert_response :success
        patch pf("#{@base}/apply"), params: params

        assert_equal(%w[hidden read], %w[full_address contact_count].map { |name| level_of(@resource, name) })
      end

      # --- Field drawer -----------------------------------------------------------

      test 'the drawer of an unconfigured declared virtual field says what applies now' do
        get pf("#{@base}/fields/full_address")

        assert_response :success
        assert_match t('resource_fields.show.not_configured_implicit', set: @set.name), CGI.unescapeHTML(response.body)
        assert_select "a[href='#{setting_href('extra_fields_default_access')}']"
        assert_select "a[href='#{setting_href('extra_fields_method')}']"
        assert_match t('resource_fields.show.virtual_model_masking_off'), response.body
        assert_select "a[href='#{setting_href('mask_virtual_attributes')}']"
      end

      test 'the drawer follows extra_fields_default_access' do
        @config.extra_fields_default_access = :unconfigured
        get pf("#{@base}/fields/full_address")
        body = CGI.unescapeHTML(response.body)

        assert_no_match t('resource_fields.show.not_configured_implicit', set: @set.name), body
        assert_match t('resource_fields.show.not_configured', set: @set.name, behaviour: t('ui.unconfigured.warn')), body
      end

      # PfVirtualProfile declares `display_name` (wrapped here) and
      # `missing_reader`, which has no method and so can never be wrapped.
      test 'the drawer says the level applies on the model only where the reader is really wrapped' do
        create_resource(permission_set: @set, name: 'PfVirtualProfile', read_access: true)
        ::PfVirtualProfile.pf_mask_virtual_readers(%w[display_name])
        fields = "/permission_sets/#{@set.id}/resources/PfVirtualProfile/fields"
        on = t('resource_fields.show.virtual_model_masking_on')
        off = t('resource_fields.show.virtual_model_masking_off')

        @config.mask_virtual_attributes = %w[PfVirtualProfile]
        get pf("#{fields}/display_name")
        assert_match on, response.body
        assert_no_match off, response.body

        get pf("#{fields}/missing_reader")
        assert_match off, response.body, 'the config selects the model, but nothing masks this field on it'
        assert_no_match on, response.body

        @config.mask_virtual_attributes = %w[Customer]
        get pf("#{fields}/display_name")
        assert_match off, response.body, 'a wrapped reader is inert while the config does not select the model'
        assert_no_match on, response.body
      end

      # --- A switched-off row -------------------------------------------------------

      # The engine skips a switched-off row, so the row's level is not what applies.
      test 'a switched-off row of a declared virtual field says it is editable by default' do
        create_resource_field(resource: @resource, name: 'full_address', read_access: false, is_active: false)
        get pf(@base)

        assert_select '.pf-fields__row', text: /full_address/ do
          assert_select '.pf-badge--off'
          assert_select "a.pf-badge--unconfigured[href='#{setting_href('extra_fields_default_access')}']",
                        text: t('resources.fields_tab.turned_off', behaviour: t('resources.fields_tab.implicit_grant'))
        end

        get pf("#{@base}/fields/full_address")
        body = CGI.unescapeHTML(response.body)
        assert_match t('resource_fields.show.turned_off_implicit', set: @set.name), body
        assert_no_match t('resource_fields.show.not_configured_implicit', set: @set.name), body
        assert_select "a[href='#{setting_href('extra_fields_default_access')}']"
      end

      test 'a switched-off row that is not granted by default follows the unconfigured-field setting' do
        @config.extra_fields_default_access = :unconfigured
        @config.unconfigured_field_strategy = :block
        create_resource_field(resource: @resource, name: 'full_address', read_access: true, is_active: false)
        @email.update!(is_active: false)
        get pf(@base)

        badge = t('resources.fields_tab.turned_off', behaviour: t('ui.unconfigured.block'))
        %w[full_address email].each do |name|
          assert_select '.pf-fields__row', text: /#{name}/ do
            assert_select "a.pf-badge--unconfigured[href='#{setting_href('unconfigured_field_strategy')}']", text: badge
          end
        end
        assert_no_match t('resources.fields_tab.implicit_grant'), response.body

        get pf("#{@base}/fields/email")
        assert_match t('resource_fields.show.turned_off', set: @set.name, behaviour: t('ui.unconfigured.block')),
                     CGI.unescapeHTML(response.body)
        assert_select "a[href='#{setting_href('unconfigured_field_strategy')}']"
      end

      test 'an active row has no such note, on the tab or in the drawer' do
        create_resource_field(resource: @resource, name: 'full_address', read_access: false)
        get pf(@base)

        assert_select '.pf-fields__row', text: /full_address/ do
          assert_select '.pf-badge--unconfigured', count: 0
        end
        get pf("#{@base}/fields/full_address")
        body = CGI.unescapeHTML(response.body)
        %w[turned_off_implicit not_configured_implicit].each do |key|
          assert_no_match t("resource_fields.show.#{key}", set: @set.name), body
        end
        assert_select "a[href='#{setting_href('extra_fields_default_access')}']", count: 0
      end

      # Listed as turned off, not as "not configured" (see SwitchedOffRowsTest);
      # Fix opens the drawer, which links to the setting that decides.
      test 'the home page lists a sensitive virtual field whose only row is switched off' do
        create_resource_field(resource: @resource, name: 'full_address', read_access: false, is_active: false)
        get pf('/')

        assert_select '.pf-card__row', text: /full_address/ do
          assert_select '.pf-badge--off'
          assert_select '.pf-badge--unconfigured', count: 0
          assert_select "a[href='#{pf("#{@base}/fields/full_address")}']", text: t('home.privacy_card.fix')
        end
      end

      test 'switched-off rows render cleanly in every locale and mode' do
        create_resource_field(resource: @resource, name: 'full_address', read_access: false, is_active: false)
        @email.update!(is_active: false)

        %i[grant unconfigured].each do |mode|
          @config.extra_fields_default_access = mode
          PermissionForge::BUNDLED_LOCALES.each do |locale|
            [@base, "#{@base}/fields/full_address", "#{@base}/fields/email"].each do |path|
              get pf(path), params: { locale: locale }
              assert_response :success, "#{mode} #{locale} #{path}"
              assert_no_missing_translations
              assert_csp_safe(path)
            end
          end
        end
      end

      test 'the drawer of a discovered virtual field says it is never granted by default' do
        @config.virtual_field_discovery = true
        add_account('nothing').resource_fields.destroy_all
        get pf("/permission_sets/#{@set.id}/resources/PfVirtualAccount/fields/theme")

        assert_response :success
        assert_select "a[href='#{setting_href('virtual_field_discovery')}']"
        assert_select "a[href='#{setting_href('extra_fields_method')}']", count: 0
        assert_no_match t('resource_fields.show.not_configured_implicit', set: @set.name), CGI.unescapeHTML(response.body)
      end

      test 'a column has no virtual notes in its drawer' do
        get pf("#{@base}/fields/domain")

        assert_select "a[href='#{setting_href('mask_virtual_attributes')}']", count: 0
        assert_select "a[href='#{setting_href('extra_fields_default_access')}']", count: 0
      end

      test 'saving a level in the drawer creates the row for a virtual field' do
        patch pf("#{@base}/fields/full_address"), params: { field: { level: 'masked', mask_strategy: 'last4' } }

        field = @resource.resource_fields.find_by(name: 'full_address')
        assert_equal %w[masked last4], [level_of(@resource, 'full_address'), field.mask_strategy]
        get pf("#{@base}/fields/full_address")
        assert_no_match t('resource_fields.show.not_configured_implicit', set: @set.name), CGI.unescapeHTML(response.body)
      end

      test 'explain says a person gets an unconfigured virtual field by default' do
        get pf("#{@base}/fields/full_address"), params: { explain_user_id: @ana.id }

        assert_match t('resource_fields.explain.virtual_default', name: 'Ana'), CGI.unescapeHTML(response.body)
        assert_no_match t('resource_fields.explain.none', name: 'Ana'), CGI.unescapeHTML(response.body)

        @config.extra_fields_default_access = :unconfigured
        get pf("#{@base}/fields/full_address"), params: { explain_user_id: @ana.id }
        assert_match t('resource_fields.explain.unconfigured', name: 'Ana'), CGI.unescapeHTML(response.body)
      end

      # --- Person page ------------------------------------------------------------

      test 'the person page explains a virtual field by what really applies' do
        path = "/people/#{@ana.id}"
        params = { tab: 'effective', why: 'Customer.field.full_address', open: ['Customer'] }
        by_default = t('people.effective_field_source.virtual')
        reason = t('people.effective_why.field_virtual')

        get pf(path), params: params
        assert_match by_default, response.body
        assert_match reason, response.body

        @config.extra_fields_default_access = :unconfigured
        get pf(path), params: params
        assert_no_match by_default, response.body
        assert_no_match reason, response.body

        @config.extra_fields_default_access = :grant
        %w[full_address contact_count].each { |name| create_resource_field(resource: @resource, name: name, read_access: false) }
        get pf(path), params: params
        assert_no_match by_default, response.body
        assert_no_match reason, response.body
      end

      # --- Set page and home ------------------------------------------------------

      test 'the set page counts unconfigured virtual fields as new' do
        get pf("/permission_sets/#{@set.id}")
        new_count = PermissionForge::Admin::ModelCatalog.new.find('Customer').managed_field_names.size - 1

        assert_match t('permission_sets.resource_summary.new', count: new_count), response.body
        assert_includes PermissionForge::Admin::ModelCatalog.new.find('Customer').managed_field_names, 'full_address'
      end

      test 'the privacy audit lists a sensitive virtual field left on the implicit grant' do
        get pf('/')

        assert_select '.pf-card__row', text: /full_address/ do
          assert_select "a.pf-badge--unconfigured[href='#{setting_href('extra_fields_default_access')}']"
        end
        where = t('home.privacy_card.where_virtual', resource: 'Customer', set: @set.name, people: '1 person')
        assert_match where, CGI.unescapeHTML(response.body)

        @config.extra_fields_default_access = :unconfigured
        @config.unconfigured_field_strategy = :block
        get pf('/')
        assert_select '.pf-card__row code', text: 'full_address', count: 0
      end

      # --- Every locale, strict CSP ------------------------------------------------

      test 'virtual field screens render cleanly in every locale and mode' do
        @config.virtual_field_discovery = true
        add_account('nothing').resource_fields.where(name: %w[theme full_address]).destroy_all
        account = "/permission_sets/#{@set.id}/resources/PfVirtualAccount"
        paths = [@base, "#{@base}?sync=1", "#{@base}/fields/full_address?explain_user_id=#{@ana.id}",
                 account, "#{account}/fields/theme", "#{account}/fields/full_address", '/', "/permission_sets/#{@set.id}",
                 "/people/#{@ana.id}?tab=effective&why=Customer.field.full_address&open[]=Customer&open[]=PfVirtualAccount"]

        %i[grant unconfigured].each do |mode|
          @config.extra_fields_default_access = mode
          PermissionForge::BUNDLED_LOCALES.each do |locale|
            paths.each do |path|
              get pf(path), params: { locale: locale }
              assert_response :success, "#{mode} #{locale} #{path}"
              assert_no_missing_translations
              assert_csp_safe(path)
            end
          end
        end
      end

      private

      def assert_csp_safe(path)
        body = response.body
        assert_no_match(/\sstyle="/, body, "inline style on #{path}")
        assert_no_match(/<script(?![^>]*\ssrc=)/, body, "inline script on #{path}")
        assert_no_match(/\son[a-z]+="/, body, "inline handler on #{path}")
        classes = body.scan(/class="([^"]*)"/).flatten.flat_map(&:split).uniq
        assert_empty classes.reject { |c| c.start_with?('pf-') }, "unprefixed classes on #{path}"
      end
    end
  end
end
