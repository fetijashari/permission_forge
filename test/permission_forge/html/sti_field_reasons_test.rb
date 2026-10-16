require_relative 'admin_test_case'
require_relative '../sti_models'
require 'nokogiri'

module PermissionForge
  module Html
    # Field test round 8: a person's Effective access row, its Why panel and
    # the field drawer's "Explain for" word one field of a single-table-
    # inheritance subclass from one decision (EffectiveAccess::FieldOutcome
    # and its FieldSources).
    #
    # The field test's setup, on the STI fixtures (Customer = PfStiTicket,
    # VipCustomer = PfStiBugTicket; notes = status, phone = secret): "Sales
    # rep" grants both Resources, hiding status on the base and showing it
    # Read-only on the subclass; "No PII exports" (muting) hides email and
    # status on the base and secret on the subclass.
    class StiFieldReasonsTest < AdminTestCase
      BASE = 'PfStiTicket'.freeze
      SUB = 'PfStiBugTicket'.freeze

      setup do
        @sales = create_permission_set(name: 'Field sales')
        base = create_resource(permission_set: @sales, name: BASE, read_access: true, edit_access: true)
        sub = create_resource(permission_set: @sales, name: SUB, read_access: true, edit_access: true)
        create_resource_field(resource: base, name: 'email', read_access: true)
        create_resource_field(resource: base, name: 'status', read_access: false)
        create_resource_field(resource: sub, name: 'email', read_access: true)
        create_resource_field(resource: sub, name: 'secret', read_access: true, mask_access: true, mask_strategy: 'last4')
        create_resource_field(resource: sub, name: 'status', read_access: true)
        create_resource_field(resource: sub, name: 'title', read_access: true)
        create_resource_field(resource: sub, name: 'owner_id', read_access: true, edit_access: true)
        @pii = create_permission_set(name: 'No PII', is_muting: true)
        muted_base = create_resource(permission_set: @pii, name: BASE, read_access: false)
        muted_sub = create_resource(permission_set: @pii, name: SUB, read_access: false)
        create_resource_field(resource: muted_base, name: 'email', read_access: true)
        create_resource_field(resource: muted_base, name: 'status', read_access: true)
        create_resource_field(resource: muted_base, name: 'owner_id', read_access: false, edit_access: true)
        create_resource_field(resource: muted_sub, name: 'secret', read_access: true)
        [@sales, @pii].each { |set| create_permission_set_user(user: @bo, permission_set: set) }
      end

      def t(key, **)
        I18n.t("permission_forge.#{key}", **)
      end

      def effective_page(locale: 'en')
        get pf("/people/#{@bo.id}"), params: { tab: 'effective', open: [SUB], locale: locale }
        assert_response :success
        Nokogiri::HTML(response.body)
      end

      # The source text of the row of `field` (the badge and the label left out).
      def row_reason(doc, field)
        row = doc.at_css(%([data-pf-why="#{SUB}.field.#{field}"]))
        assert row, "a row for #{field}"
        row.css('> span').last.text.squish
      end

      def why_reasons(doc, field)
        doc.css(%([id="pf-why-#{SUB}.field.#{field}"] li.pf-why__reason)).map do |node|
          [node.at_css('span[aria-hidden]').text, node.at_css('.pf-stack > span').text.squish]
        end
      end

      def explain_text(field = 'status', locale: 'en')
        get pf("/permission_sets/#{@sales.id}/resources/#{SUB}/fields/#{field}"), params: { explain_user_id: @bo.id, locale: locale }
        assert_response :success
        Nokogiri::HTML(response.body).at_css('.pf-panel[aria-live]').text.squish
      end

      def outcome(field)
        PermissionForge::Admin::EffectiveAccess.call(user: @bo).find { |res| res.name == SUB }.fields.find { |f| f.name == field }
      end

      # What the row, the Why panel and Explain for say about `field`, by
      # the one reason they word (FieldOutcome#reason): problems, if any.
      def surface_problems(field, locale)
        doc = effective_page(locale: locale)
        reason = outcome(field).reason
        said = { row: row_reason(doc, field), why: why_reasons(doc, field), explain: explain_text(field, locale: locale),
                 outcome: outcome(field) }
        problems = SURFACE_CHECKS.fetch(reason) { ->(*) { ["unexpected reason #{reason}"] } }.call(self, said, reason, locale)
        problems.map { |problem| "#{locale} #{field} (#{reason}): #{problem}" }
      end

      # A set named on the row is named by the Why panel and Explain for;
      # a mute's level is worded by both the row and Explain for.
      SET_CHECK = lambda do |test, said, reason, locale|
        set = test.send(:row_set, said[:row], said[:outcome], locale)
        glyph = reason == :muted ? '⊘' : '✓'
        expected = test.send(:explain_sentence, said[:outcome], set, locale)
        [("the Why panel does not name #{set}" if said[:why].none? { |g, text| g == glyph && text.include?(set) }),
         ("Explain for #{said[:explain].inspect} does not say #{expected.inspect}" unless said[:explain].include?(expected))].compact
      end
      # The entry that decides is said in the same words on every surface.
      CHAIN_CHECK = lambda do |_test, said, *|
        chain = said[:why].find { |glyph, _| %w[↑ ∅].include?(glyph) }&.last
        [("row #{said[:row].inspect}, Why #{chain.inspect}" unless said[:row] == chain),
         ("Explain for #{said[:explain].inspect} lacks #{chain.inspect}" unless chain && said[:explain].include?(chain))].compact
      end
      SURFACE_CHECKS = { muted: SET_CHECK, granted: SET_CHECK, inherited: CHAIN_CHECK, unreadable: CHAIN_CHECK }.freeze

      ROW_KEYS = { 'hide' => 'muted_by', 'mask' => 'masked_by', 'no_edit' => 'read_only_by' }.freeze
      EXPLAIN_KEYS = { 'hide' => 'hidden_by', 'mask' => 'masked_by', 'no_edit' => 'read_only_by' }.freeze

      # The set name in a row's text ("Hidden by No PII · PfStiTicket" =>
      # "No PII · PfStiTicket"), by the row's key for the outcome.
      def row_set(text, outcome, locale)
        key = outcome.reason == :muted ? ROW_KEYS.fetch(outcome.blocked_level) : 'from'
        prefix, suffix = I18n.with_locale(locale) { t("people.effective_field_source.#{key}", set: "\u0001") }.split("\u0001")
        text.delete_prefix(prefix.to_s).delete_suffix(suffix.to_s)
      end

      # Explain for's sentence for one set (Bo is the person explained).
      def explain_sentence(outcome, set, locale)
        I18n.with_locale(locale) do
          next t('resource_fields.explain.granted', name: 'Bo', sets: set) unless outcome.reason == :muted

          t("resource_fields.explain.#{EXPLAIN_KEYS.fetch(outcome.blocked_level)}", count: 1, name: 'Bo', sets: set)
        end
      end

      # --- B#38: the row's muting reason names the Resource ----------------------------

      test 'the row names the Resource whose row mutes the field, as the Why panel and the grants beside it do' do
        doc = effective_page

        assert_equal t('people.effective_field_source.muted_by', set: "No PII · #{BASE}"), row_reason(doc, 'email'),
                     'muted on the base'
        assert_equal t('people.effective_field_source.muted_by', set: "No PII · #{SUB}"), row_reason(doc, 'secret'),
                     'muted on the subclass'
        assert_includes why_reasons(doc, 'email').map(&:last).join(' '), "No PII · #{BASE}", 'the Why panel says the same'
        assert_includes why_reasons(doc, 'secret').map(&:last).join(' '), "No PII · #{SUB}"
        named = doc.css(%([data-pf-why="#{SUB}.field.email"] [data-pf-host-data])).map(&:text)
        assert_includes named, BASE, 'the model is marked as host data'
      end

      test 'a muting reason words the level the mute decides, not always Hidden' do
        masking = create_permission_set(name: 'Mask emails', is_muting: true)
        create_resource_field(resource: create_resource(permission_set: masking, name: 'Customer', read_access: false),
                              name: 'email', read_access: false, mask_access: true)
        @email.update!(mask_access: false)
        create_permission_set_user(user: @ana, permission_set: masking)

        get pf("/people/#{@ana.id}"), params: { tab: 'effective', open: ['Customer'] }
        assert_response :success
        row = Nokogiri::HTML(response.body).at_css('[data-pf-why="Customer.field.email"]').css('> span').last.text.squish

        assert_equal t('people.effective_field_source.masked_by', set: 'Mask emails'), row
      end

      # --- review of round 8: a mute decides only the level it gives ------------------

      # Ana's Customer › Email: [row text, badge, Why reasons, Explain for panel].
      def customer_row_and_explain
        get pf("/people/#{@ana.id}"), params: { tab: 'effective', open: ['Customer'] }
        assert_response :success
        doc = Nokogiri::HTML(response.body)
        row = doc.at_css('[data-pf-why="Customer.field.email"]')
        [row.css('> span').last.text.squish, row.at_css('.pf-level-badge').text, customer_why(doc), customer_explain]
      end

      def customer_why(doc)
        doc.css('[id="pf-why-Customer.field.email"] li.pf-why__reason').map { |node| node.at_css('.pf-stack > span').text.squish }
      end

      def customer_explain
        get pf("/permission_sets/#{@set.id}/resources/Customer/fields/email"), params: { explain_user_id: @ana.id }
        Nokogiri::HTML(response.body).at_css('.pf-panel[aria-live]')
      end

      def mute_email(name, **flags)
        set = create_permission_set(name: name, is_muting: true)
        create_resource_field(resource: create_resource(permission_set: set, name: 'Customer', read_access: false),
                              name: 'email', read_access: false, **flags)
        create_permission_set_user(user: @ana, permission_set: set)
        set
      end

      test 'a mute that only takes editing away from a masked field does not decide it: the mask does' do
        @email.update!(edit_access: true)
        mute_email('NoEdit', edit_access: true)

        row, badge, why, explain = customer_row_and_explain

        assert_includes badge, t('ui.states.field_level.masked')
        assert_equal t('people.effective_field_source.from', set: 'Sales rep'), row
        assert_includes why, t('ui.level_sentences.no_edit', set: 'NoEdit'), 'the Why panel still says what NoEdit does'
        assert_includes explain.text.squish, t('resource_fields.explain.granted', name: 'Ana', sets: 'Sales rep')
      end

      test 'an edit mute on a resource that gives no Edit changes nothing and is not credited' do
        @resource.update!(edit_access: false)
        @email.update!(edit_access: true, mask_access: false)
        mute_email('NoEdit', edit_access: true)

        row, _badge, why, = customer_row_and_explain

        assert_equal t('people.effective_field_source.from', set: 'Sales rep'), row
        assert_includes why, t('people.effective_why.field_capped')
        assert(why.none? { |text| text.include?('NoEdit') }, why.inspect)
      end

      test 'Explain for words the deciding mute\'s level and names the sets the row names' do
        @email.update!(edit_access: true, mask_access: false)
        mute_email('MaskA', mask_access: true)
        mute_email('NoEditB', edit_access: true)

        row, _badge, _why, explain = customer_row_and_explain

        assert_equal t('people.effective_field_source.masked_by', set: 'MaskA'), row
        assert_includes explain.text.squish, t('resource_fields.explain.masked_by', count: 1, name: 'Ana', sets: 'MaskA')
        assert_not_includes explain.text, 'NoEditB'
      end

      test 'two sets that hide a field are counted in Explain for' do
        mute_email('HideA', read_access: true)
        mute_email('HideB', read_access: true)

        _row, _badge, _why, explain = customer_row_and_explain

        assert_includes explain.text.squish, t('resource_fields.explain.hidden_by', count: 2, name: 'Ana', sets: 'HideA and HideB')
      end

      test 'Explain for draws no empty sentence when the inherited entry decides' do
        get pf("/permission_sets/#{@sales.id}/resources/#{SUB}/fields/status"), params: { explain_user_id: @bo.id }
        panel = Nokogiri::HTML(response.body).at_css('.pf-panel[aria-live]')

        assert(panel.css('> span').none? { |span| span.text.strip.empty? }, panel.to_html)
      end

      # --- B#39: one decision for an inherited hidden field, on every surface -----------

      test 'a field hidden on the base reads the same on the row, the Why panel and Explain for, in every locale' do
        PermissionForge::BUNDLED_LOCALES.each do |locale|
          I18n.with_locale(locale) do
            expected = t('people.effective_why.field_hidden_on', resource: BASE)
            doc = effective_page(locale: locale)

            assert_equal expected, row_reason(doc, 'status'), "#{locale}: the row"
            assert_includes why_reasons(doc, 'status'), ['↑', expected], "#{locale}: the Why panel"
            explained = explain_text(locale: locale)
            assert_includes explained, expected, "#{locale}: Explain for"
            assert_not_includes explained, t('resource_fields.explain.none', name: 'Bo'), "#{locale}: never 'no set shows it'"
            badges = [doc.at_css(%([data-pf-why="#{SUB}.field.status"] .pf-level-badge)).text]
            assert_not_includes badges.join, t('ui.states.effective.hidden_by_muting'), "#{locale}: the mute decides nothing"
          end
        end
      end

      test 'every field of the subclass reads the same reason on the row, the Why panel and Explain for, in every locale' do
        fields = %w[email secret status title owner_id]
        reasons = fields.map { |field| outcome(field).reason }
        assert_equal %i[muted muted inherited granted muted], reasons, 'the setup covers each reason'
        assert_equal 'no_edit', outcome('owner_id').blocked_level
        problems = PermissionForge::BUNDLED_LOCALES.flat_map do |locale|
          fields.flat_map { |field| surface_problems(field, locale.to_s) }
        end
        create_resource_field(resource: @pii.resources.find_by!(name: SUB), name: 'title', read_access: false, mask_access: true)
        assert_equal 'mask', outcome('title').blocked_level
        problems += PermissionForge::BUNDLED_LOCALES.flat_map { |locale| surface_problems('title', locale.to_s) }

        assert_empty problems, problems.join("\n")
      end

      test 'the hidden-on reason follows the decision: muting the subclass row too still leaves the base deciding' do
        create_resource_field(resource: @pii.resources.find_by!(name: SUB), name: 'status', read_access: true)

        doc = effective_page

        assert_equal t('people.effective_why.field_hidden_on', resource: BASE), row_reason(doc, 'status')
      end

      test 'once the base shows the field, the subclass\'s own row and the mute on the base decide' do
        @sales.resources.find_by!(name: BASE).resource_fields.find_by!(name: 'status').update!(read_access: true)

        doc = effective_page

        assert_equal t('people.effective_field_source.muted_by', set: "No PII · #{BASE}"), row_reason(doc, 'status')
        assert_includes why_reasons(doc, 'status').map(&:last).join(' '), "No PII · #{BASE}"
      end

      test 'a subclass entry without Read says so on the row, as the Why panel does' do
        @sales.resources.find_by!(name: SUB).update!(read_access: false, edit_access: false)

        doc = effective_page
        expected = t('people.effective_why.field_own_unreadable')

        assert_equal expected, row_reason(doc, 'email')
        assert_includes why_reasons(doc, 'email'), ['∅', expected]
      end
    end
  end
end
