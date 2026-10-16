require_relative 'admin_test_case'
require_relative '../sti_models'
require 'nokogiri'

module PermissionForge
  module Html
    # Field test round 7 (B#35): a Permission Set that holds two Resources of
    # one single-table-inheritance chain (a base and its subclass) showed two
    # rows with the same name in the field drawer's "Across all Permission
    # Sets" — "Sales rep ∅ Hidden" and "Sales rep ◉ Read-only" — and a
    # person's effective access said "from Sales rep" without saying which.
    # Such a row now reads "<set> · <Model>", the model marked as host data;
    # a set holding one Resource of the chain is named alone.
    class StiSetEntriesTest < AdminTestCase
      setup do
        @both = create_permission_set(name: 'Ticket desk')
        base = create_resource(permission_set: @both, name: 'PfStiTicket', read_access: true)
        @sub = create_resource(permission_set: @both, name: 'PfStiBugTicket', read_access: true)
        create_resource_field(resource: base, name: 'title', read_access: false)
        create_resource_field(resource: @sub, name: 'title', read_access: true)
        @one = create_permission_set(name: 'Bug triage')
        create_resource_field(resource: create_resource(permission_set: @one, name: 'PfStiBugTicket', read_access: true),
                              name: 'title', read_access: true)
        create_permission_set_user(user: @bo, permission_set: @both)
      end

      def options_text(doc)
        doc.css('.pf-listbox .pf-option__main').map { |node| node.text.squish }
      end

      test 'the drawer\'s rows name the Resource when the set holds more than one of the chain' do
        get pf("/permission_sets/#{@both.id}/resources/PfStiBugTicket/fields/title")
        assert_response :success
        doc = Nokogiri::HTML(response.body)

        assert_equal ['Bug triage', 'Ticket desk · PfStiBugTicket', 'Ticket desk · PfStiTicket'], options_text(doc).sort
        marked = doc.css('.pf-listbox [data-pf-host-data]').map(&:text)
        assert_equal %w[PfStiBugTicket PfStiTicket], marked.sort, 'the model name is host data'
      end

      test 'a person\'s effective access names the Resource the same way' do
        get pf("/people/#{@bo.id}"), params: { tab: 'effective', open: ['PfStiBugTicket'] }
        assert_response :success
        doc = Nokogiri::HTML(response.body)

        assert_includes doc.text.squish, 'Ticket desk · PfStiBugTicket', 'the field source names the Resource whose entry decides'
        assert doc.css('[data-pf-host-data]').any? { |node| node.text == 'PfStiBugTicket' }, 'marked as host data'
      end

      # Review of the round-7 fixes (P2-6): the reasons a Muting Permission
      # Set gives (a flag, a field, an action it takes away) named the set
      # alone. They name the Resource whose row does the muting.
      test 'a person\'s effective access names the muting Resource the same way' do
        hold = create_permission_set(name: 'Contractor hold', is_muting: true)
        create_resource(permission_set: hold, name: 'PfStiTicket', read_access: true)
        held_sub = create_resource(permission_set: hold, name: 'PfStiBugTicket', read_access: false)
        create_resource_action(resource: held_sub, name: 'export', is_permitted: true)
        create_resource_field(resource: held_sub, name: 'title', read_access: true)
        create_resource_action(resource: @sub, name: 'export', is_permitted: true)
        create_permission_set_user(user: @bo, permission_set: hold)

        get pf("/people/#{@bo.id}"), params: { tab: 'effective', open: ['PfStiBugTicket'] }
        assert_response :success
        doc = Nokogiri::HTML(response.body)
        muted = doc.css('[id^="pf-why-PfStiBugTicket."] li.pf-why__reason').select { |node| node.at_css('span').text == '⊘' }
                   .map { |node| node.at_css('.pf-stack > span').text.squish }
        flag = I18n.t('permission_forge.ui.flags_short.read_access')

        assert(muted.any? { |text| text.include?('Contractor hold · PfStiTicket') && text.include?(flag) }, "the read flag: #{muted}")
        assert(muted.any? { |text| text.include?('Contractor hold · PfStiBugTicket') && !text.include?(flag) }, "the action: #{muted}")
        assert_not(muted.any? { |text| text.match?(/Contractor hold(?! ·)/) }, 'never the set alone')
      end

      test 'a set with one Resource of the chain is named alone' do
        get pf("/permission_sets/#{@one.id}/resources/PfStiBugTicket/fields/title")
        doc = Nokogiri::HTML(response.body)
        assert_includes options_text(doc), 'Bug triage'
        assert_not(options_text(doc).any? { |text| text.start_with?('Bug triage ·') })
      end
    end
  end
end
