require_relative 'admin_test_case'

module PermissionForge
  module Html
    # The Fields tab's bulk "Set to <level>" buttons are named submit buttons of
    # the batched-edit form: the chosen level travels only as the pressed
    # button's own name/value. Whatever submits that form (the browser, or
    # pf_admin.js on its behalf) has to send the button along with it.
    class BulkFieldLevelsTest < AdminTestCase
      FORM = 'pf-res-form'.freeze

      setup do
        @base = "/permission_sets/#{@set.id}/resources/Customer"
      end

      # The name/value pairs a browser submits when the bulk button for +level+
      # is pressed with the rows +keys+ ticked, read from the rendered page. That
      # includes every row's own checked level radio, which the bulk level has
      # to override for the ticked rows.
      def bulk_click(level:, keys:)
        selectors = ["form##{FORM} input[type=hidden]",
                     "button[type=submit][form=#{FORM}][value='#{level}']",
                     *keys.map { |key| "input[type=checkbox][form=#{FORM}][data-pf-select][value='#{key}']" },
                     "input[type=hidden][form=#{FORM}][name^='pf[bulk]']",
                     "input[type=radio][form=#{FORM}][checked]"]
        pairs(selectors.flat_map { |selector| css_select(selector).to_a })
      end

      def pairs(elements)
        elements.map { |element| [element['name'], element['value']] }
      end

      def level_of(name)
        field = @resource.resource_fields.find_by(name: name)
        field && PermissionForge::Admin::FieldLevel.level_of(field, muting: false)
      end

      test 'the bulk controls all belong to the batched-edit form' do
        get pf(@base)

        assert_select "form##{FORM}[data-pf-review][method=post][action='#{pf("#{@base}/review")}']"
        assert_select "input[type=hidden][form=#{FORM}][name='pf[bulk][resource_id]'][value='#{@resource.id}']"
        PermissionForge::Admin::FieldLevel.levels_for(muting: false).each do |level|
          assert_select "button[type=submit][form=#{FORM}][name='pf[bulk][level]'][value='#{level}']", count: 1
        end
        %w[email domain].each do |key|
          assert_select "input[type=checkbox][form=#{FORM}][name='pf[bulk][keys][]'][value='#{key}']", count: 1
        end
      end

      # pf_admin.js keeps the selection to the rows that are shown: the search
      # box hides a row by its [data-pf-row-text] element, and a checkbox is
      # out of reach of "select all" and the bulk bar once that row is hidden.
      test 'each bulk checkbox sits inside the row the search box filters' do
        get pf(@base)

        rows = css_select('[data-pf-bulk] #pf-field-rows [data-pf-row-text]')

        assert_select 'input[data-pf-row-filter=pf-field-rows]', count: 1
        assert_equal css_select("input[form=#{FORM}][data-pf-select]").size, rows.size
        rows.each { |row| assert_equal 1, row.css('input[data-pf-select]').size, row['data-pf-row-text'] }
        assert_select '[data-pf-bulk] #pf-field-rows input[data-pf-select-all]', count: 1
      end

      # Enter in a text input submits through the form's first submit button in
      # document order. That has to be the plain one: with a bulk "Set to"
      # button first, Enter would propose its level for every ticked row.
      test "the form's default button carries no bulk level" do
        get pf(@base)

        submits = css_select("form##{FORM} button[type=submit], button[type=submit][form=#{FORM}]")

        assert_operator submits.size, :>, 1
        assert_nil submits.first['name']
        assert_out_of_sight_but_rendered submits.first
        assert_equal 'pf[bulk][level]', submits[1]['name'], 'the bulk buttons come right after it'
      end

      test 'pressing a bulk button reviews and applies its level for the ticked rows' do
        get pf(@base)
        post pf("#{@base}/review"), params: URI.encode_www_form(bulk_click(level: 'hidden', keys: %w[email domain]))

        assert_response :success
        assert_select '.pf-change-list li', count: 2
        apply = css_select('form').find { |form| form.css("input[name='pf[bulk][level]'][value=hidden]").any? }
        assert apply, 'the review page carries the bulk level on to apply'
        post apply['action'], params: URI.encode_www_form(pairs(apply.css('input[type=hidden]')))

        assert_redirected_to pf(@base)
        assert_equal(%w[hidden hidden], %w[email domain].map { |name| level_of(name) })
      end

      test 'the same ticked rows without the pressed button change nothing' do
        get pf(@base)
        ticked = bulk_click(level: 'hidden', keys: %w[email domain]).reject { |pair| pair.first == 'pf[bulk][level]' }
        post pf("#{@base}/review"), params: URI.encode_www_form(ticked)

        assert_redirected_to pf(@base)
        assert_equal I18n.t('permission_forge.flash.no_changes'), flash[:notice]
        assert_equal 'masked', level_of('email')
      end
    end
  end
end
