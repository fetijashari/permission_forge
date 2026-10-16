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
        sub = create_resource(permission_set: @sales, name: SUB, read_access: true)
        create_resource_field(resource: base, name: 'email', read_access: true)
        create_resource_field(resource: base, name: 'status', read_access: false)
        create_resource_field(resource: sub, name: 'email', read_access: true)
        create_resource_field(resource: sub, name: 'secret', read_access: true, mask_access: true, mask_strategy: 'last4')
        create_resource_field(resource: sub, name: 'status', read_access: true)
        create_resource_field(resource: sub, name: 'title', read_access: true)
        @pii = create_permission_set(name: 'No PII', is_muting: true)
        muted_base = create_resource(permission_set: @pii, name: BASE, read_access: false)
        muted_sub = create_resource(permission_set: @pii, name: SUB, read_access: false)
        create_resource_field(resource: muted_base, name: 'email', read_access: true)
        create_resource_field(resource: muted_base, name: 'status', read_access: true)
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
        said = { row: row_reason(doc, field), why: why_reasons(doc, field), explain: explain_text(field, locale: locale) }
        problems = SURFACE_CHECKS.fetch(reason) { ->(*) { ["unexpected reason #{reason}"] } }.call(self, said, reason, locale)
        problems.map { |problem| "#{locale} #{field} (#{reason}): #{problem}" }
      end

      # A set named on the row is named by the Why panel and Explain for.
      SET_CHECK = lambda do |test, said, reason, locale|
        set = test.send(:row_set, said[:row], reason, locale)
        glyph = reason == :muted ? '⊘' : '✓'
        [("the Why panel does not name #{set}" if said[:why].none? { |g, text| g == glyph && text.include?(set) }),
         ("Explain for #{said[:explain].inspect} does not name #{set}" unless said[:explain].include?(set))].compact
      end
      # The entry that decides is said in the same words on every surface.
      CHAIN_CHECK = lambda do |_test, said, *|
        chain = said[:why].find { |glyph, _| %w[↑ ∅].include?(glyph) }&.last
        [("row #{said[:row].inspect}, Why #{chain.inspect}" unless said[:row] == chain),
         ("Explain for #{said[:explain].inspect} lacks #{chain.inspect}" unless chain && said[:explain].include?(chain))].compact
      end
      SURFACE_CHECKS = { muted: SET_CHECK, granted: SET_CHECK, inherited: CHAIN_CHECK, unreadable: CHAIN_CHECK }.freeze

      # The set name in a row's text ("Hidden by No PII · PfStiTicket" => "No PII · PfStiTicket").
      def row_set(text, reason, locale)
        I18n.with_locale(locale) do
          key = reason == :muted ? 'people.effective_field_source.muted_by' : 'people.effective_field_source.from'
          prefix, suffix = t(key, set: "\u0001").split("\u0001")
          text.delete_prefix(prefix.to_s).delete_suffix(suffix.to_s)
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
        reasons = %w[email secret status title].map { |field| outcome(field).reason }
        assert_equal %i[muted muted inherited granted], reasons, 'the setup covers each reason'

        problems = PermissionForge::BUNDLED_LOCALES.flat_map do |locale|
          %w[email secret status title].flat_map { |field| surface_problems(field, locale.to_s) }
        end

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
        @sales.resources.find_by!(name: SUB).update!(read_access: false)

        doc = effective_page
        expected = t('people.effective_why.field_own_unreadable')

        assert_equal expected, row_reason(doc, 'email')
        assert_includes why_reasons(doc, 'email'), ['∅', expected]
      end
    end
  end
end
