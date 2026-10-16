require_relative 'admin_test_case'

module PermissionForge
  module Html
    # One state, one rendering (plan-ux E): every state the admin shows is
    # worded by Admin::StateLabel — glyph and word together — and every
    # page that shows the same fact shows the same string. One loop over
    # the registry's states, not one test per finding:
    #
    # - a configured field level: the Fields tab's control, the field
    #   drawer's control and the set's row under "Across all Permission Sets";
    # - an effective field outcome: the person's Effective access row, its
    #   Why panel and the field drawer's "Explain for";
    # - an effective CRUD state: the grid's cells and its legend;
    # - an action state: the action page's "Right now" badge and its row
    #   under "Across all Permission Sets".
    class StateRenderingTest < AdminTestCase
      StateLabel = PermissionForge::Admin::StateLabel
      FieldLevel = PermissionForge::FieldLevel

      def label(kind, state) = StateLabel.for(kind, state).to_s
      def word(kind, state) = StateLabel.word(kind, state)

      def text_of(node) = node&.text.to_s.squish

      # The label of the checked radio of a level control named `name`.
      def checked_level_word(name)
        radio = css_select('input[type=radio]').find { |input| input['name'] == name && input.key?('checked') }
        assert radio, "a level is checked in #{name}"
        text_of(css_select("label[for='#{radio['id']}']").first)
      end

      # The badge of `set`'s row under "Across all Permission Sets".
      def across_badge(set)
        row = css_select('.pf-listbox .pf-option').find { |option| option.text.include?(set.name) }
        assert row, "#{set.name} has a row under Across all Permission Sets"
        text_of(row.at_css('.pf-level-badge'))
      end

      def configure(set, level, muting:)
        resource = set == @set ? @resource : create_resource(permission_set: set, name: 'Customer', read_access: !muting)
        create_resource_field(resource: resource, name: 'phone', mask_strategy: 'last4', **FieldLevel.flags_for(level, muting: muting))
      end

      def set_of_kind(muting)
        muting ? create_permission_set(name: 'No phone numbers', is_muting: true) : @set
      end

      # --- a configured field level ---------------------------------------------------

      [false, true].each do |muting|
        FieldLevel.levels_for(muting: muting).each do |level|
          test "field level #{level}#{' (muting)' if muting}: the Fields tab, the drawer and Across all sets word it alike" do
            set = set_of_kind(muting)
            field = configure(set, level, muting: muting)

            get pf("/permission_sets/#{set.id}/resources/Customer")
            assert_response :success
            assert_equal word(:field_level, level), checked_level_word("pf[fields][#{field.id}][level]"), 'Fields tab'

            get pf("/permission_sets/#{set.id}/resources/Customer/fields/phone")
            assert_response :success
            assert_equal word(:field_level, level), checked_level_word('field[level]'), 'field drawer'
            assert_equal label(:field_level, level), across_badge(set).split(' (').first, 'Across all Permission Sets'
          end
        end
      end

      test 'a column with no setting: Not configured on a granting set, Unchanged on a muting one, alike everywhere' do
        muting = set_of_kind(true)
        create_resource(permission_set: muting, name: 'Customer')

        get pf("/permission_sets/#{@set.id}/resources/Customer/fields/phone")
        assert_equal label(:field_level, :none), across_badge(@set)
        assert_equal label(:field_level, :leave), across_badge(muting)

        get pf("/permission_sets/#{@set.id}/resources/Customer")
        row = css_select('.pf-fields__row').find { |node| node.at_css('code.pf-mono-key')&.text == 'phone' }
        assert text_of(row.at_css('.pf-badge')).start_with?(word(:field_level, :none)), 'the Fields tab names it Not configured'

        get pf("/permission_sets/#{muting.id}/resources/Customer")
        name = "pf[new_fields][#{muting.resources.first.id}][phone][level]"
        assert_equal word(:field_level, :leave), checked_level_word(name), 'a muting set starts it on Unchanged'
      end

      # --- an effective field outcome ------------------------------------------------

      EFFECTIVE = %w[hidden masked read edit hidden_by_muting].freeze

      # Ana holds @set; `state` is the outcome her phone field gets.
      def arrange_effective(state)
        return configure(@set, state, muting: false) unless state == 'hidden_by_muting'

        configure(@set, 'read', muting: false)
        muting = set_of_kind(true)
        configure(muting, 'hide', muting: true)
        create_permission_set_user(user: @ana, permission_set: muting)
      end

      def effective_row_badge(name)
        link = css_select('.pf-effective__field').find { |row| row.at_css('code.pf-mono-key')&.text == name }
        text_of(link&.at_css('.pf-level-badge'))
      end

      def expected_effective(state)
        state == 'hidden_by_muting' ? label(:effective, :hidden_by_muting) : label(:field_level, state)
      end

      EFFECTIVE.each do |state|
        test "effective #{state}: the Effective access row, the Why panel and Explain for word it alike" do
          arrange_effective(state)
          expected = expected_effective(state)

          get pf("/people/#{@ana.id}"), params: { tab: 'effective', open: ['Customer'], why: 'Customer.field.phone' }
          assert_response :success
          assert_equal expected, effective_row_badge('phone').split(' (').first, 'Effective access row'
          why = text_of(css_select("[id='pf-why-Customer.field.phone'] .pf-level-badge").first)
          assert_equal expected, why.split(' (').first, 'Why panel'

          get pf("/permission_sets/#{@set.id}/resources/Customer/fields/phone"), params: { explain_user_id: @ana.id }
          assert_response :success
          explain = text_of(css_select('.pf-panel .pf-level-badge').first)
          assert_equal expected, explain.split(' (').first, 'Explain for'
        end
      end

      # --- an effective CRUD state -----------------------------------------------------

      test 'the Effective access legend words the states as its cells do' do
        muting = set_of_kind(true)
        create_resource(permission_set: muting, name: 'Customer', edit_access: true)
        create_permission_set_user(user: @ana, permission_set: muting)

        get pf("/people/#{@ana.id}"), params: { tab: 'effective', open: ['Customer'] }
        assert_response :success
        legend = text_of(css_select('.pf-legend').first)
        %i[granted blocked none].each do |state|
          assert_includes legend, label(:effective, state), "the legend names #{state}"
          cell = css_select(".pf-effective .pf-state--#{state}").first
          assert cell, "a #{state} cell"
          assert_equal label(:effective, state), text_of(cell)
        end
        assert_includes legend, label(:field_level, :masked)
      end

      # --- an action state -------------------------------------------------------------

      ACTIONS = { permitted: [false, true], not_permitted: [false, false], blocked: [true, true], unchanged: [true, false] }.freeze

      ACTIONS.each do |state, (muting, permitted)|
        test "action #{state}: Right now and Across all sets word it alike" do
          set = set_of_kind(muting)
          resource = set == @set ? @resource : create_resource(permission_set: set, name: 'Customer')
          action = create_resource_action(resource: resource, name: 'export', is_permitted: permitted)

          get pf("/permission_sets/#{set.id}/resources/Customer/actions/#{action.id}")
          assert_response :success
          right_now = css_select('.pf-badge').map { |node| text_of(node) }
          assert_includes right_now, label(:action, state), 'Right now'
          assert_equal label(:action, state), across_badge(set), 'Across all Permission Sets'
        end
      end
    end
  end
end
