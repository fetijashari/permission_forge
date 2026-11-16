require_relative 'admin_test_case'

module PermissionForge
  module Html
    # The Permission Sets list summarises each set (#24): how many Resources,
    # what they allow, what narrows them; the Resources themselves open on
    # request, by model family or one by one, on a page of their own that
    # the list loads in place.
    class PermissionSetsIndexSummaryTest < AdminTestCase
      setup do
        @many = create_permission_set(name: 'Warehouse staff')
        @bins = Array.new(12) do |index|
          create_resource(permission_set: @many, name: "Warehouses::Bin#{index}", read_access: true, edit_access: index.even?)
        end
        create_resource(permission_set: @many, name: 'Ledger', read_access: true, view_all: true)
        create_permission_set_rule(permission_set: @many, resource: @bins.first, field_name: 'name', field_value: 'x')
        create_resource_field(resource: @bins.first, name: 'email', read_access: true, mask_access: true)
      end

      def row_for(set)
        get pf('/permission_sets')
        assert_response :success
        Nokogiri::HTML(response.body).at_css("#pf-set-#{set.id}")
      end

      test 'a row summarises the set instead of listing its Resource names' do
        row = row_for(@many)
        text = row.text.squish

        assert_no_match(/Warehouses::Bin\d/, text, 'no Resource name is printed on the list')
        assert_match(/\b13\b/, row.css('.pf-set-count').text)
        assert_match 'Some changes', text
        assert_match 'View All on 1 Resource', text
        assert_match '1 row rule', text
        assert_match '1 masked field', text
        assert_match 'Show 2 model groups', text
        assert_match 'Show 13 Resources', text
        assert_equal ['Read: 13 of 13', 'Create: 0 of 13', 'Edit: 6 of 13', 'Delete: 0 of 13'],
                     row.css('.pf-access-count .pf-sr-only').map(&:text)
      end

      test 'the open links lead to the overview page, marked for the in-place load' do
        links = row_for(@many).css('a[data-pf-expand]')
        groups = links.find { |link| link.text.include?('model groups') }

        assert_equal pf("/permission_sets/#{@many.id}/overview?view=groups"), groups['href']
        assert_equal "pf-set-overview-#{@many.id}", groups['data-pf-expand']
        assert_equal "pf-set-#{@many.id}", groups['data-pf-expand-row']
        assert_equal 'Hide model groups', groups['data-pf-expand-hide']
        assert_equal "pf-set-name-#{@many.id}", groups['aria-describedby'], 'the link names its set for assistive technology'
        assert(links.any? { |link| link['href'].include?('only=narrowed') }, 'the narrowed counts open the narrowed Resources')
        assert(links.any? { |link| link['href'].include?('only=view_all') }, 'the View All count opens those Resources')
      end

      test 'a search finds a set by the name of one of its Resources and says which' do
        get pf('/permission_sets'), params: { q: 'BIN' }
        assert_response :success
        page = Nokogiri::HTML(response.body)

        assert page.at_css("#pf-set-#{@many.id}")
        assert_nil page.at_css("#pf-set-#{@set.id}"), 'a set without a matching Resource is filtered out'
        includes = page.at_css("#pf-set-#{@many.id}").text.squish
        assert_match 'Includes', includes
        assert_match 'Warehouses::Bin0', includes
        assert_match '9 more', includes, 'three names shown, the other nine counted'
      end

      test 'the overview page: groups, then one family, then the narrowed Resources' do
        get pf("/permission_sets/#{@many.id}/overview"), params: { view: 'groups' }
        assert_response :success
        page = Nokogiri::HTML(response.body)
        assert_equal 'Model groups in Warehouse staff', page.at_css('h1').text.squish
        families = page.css('.pf-family').map { |family| family.text.squish }
        assert_equal 2, families.size
        assert_match(/\AWarehouses 12/, families.first)

        get pf("/permission_sets/#{@many.id}/overview"), params: { only: 'Warehouses' }
        page = Nokogiri::HTML(response.body)
        assert_equal 12, page.css('.pf-overview__res').size
        assert_match 'Showing Warehouses only.', page.text.squish

        get pf("/permission_sets/#{@many.id}/overview"), params: { only: 'narrowed' }
        names = Nokogiri::HTML(response.body).css('.pf-overview__res code').map { |code| [code.text, code['title']] }
        assert_equal [['Bin0', 'Warehouses::Bin0']], names, 'shown without its family, named in full in its title'
      end

      test 'a Resource shows its flags in letters and in words, and links to its page' do
        get pf("/permission_sets/#{@many.id}/overview"), params: { only: 'view_all' }
        item = Nokogiri::HTML(response.body).at_css('.pf-overview__res')

        assert_equal 'R · · · V ·', item.css('.pf-flag').map(&:text).join(' ')
        assert_equal 'Read, View All', item.at_css('.pf-sr-only').text
        assert_equal pf("/permission_sets/#{@many.id}/resources/Ledger"), item.at_css('a')['href']
      end

      test 'with X-PF-Fragment the overview is the bare body the list loads in place' do
        get pf("/permission_sets/#{@many.id}/overview"), params: { view: 'groups' }, headers: { 'X-PF-Fragment' => '1' }
        assert_response :success

        assert_no_match(/<html/i, response.body)
        page = Nokogiri::HTML.fragment(response.body)
        assert_nil page.at_css('h1')
        assert page.at_css('.pf-overview .pf-family')
      end

      test 'a muting set: what it takes away, and no rules' do
        muting = create_permission_set(name: 'Contractors', is_muting: true)
        muted = create_resource(permission_set: muting, name: 'Ledger', read_access: false, delete_access: true)
        create_resource_field(resource: muted, name: 'email', read_access: true)

        text = row_for(muting).text.squish
        assert_match 'Takes access away', text
        assert_match '1 hidden field', text

        get pf("/permission_sets/#{muting.id}/overview")
        assert_match 'A lit letter is access this set takes away.', response.body
      end

      test 'a turned-off Resource with View All counts on neither the list nor its overview' do
        create_resource(permission_set: @many, name: 'Archive', read_access: true, view_all: true, is_active: false)

        assert_match 'View All on 1 Resource', row_for(@many).text.squish
        get pf("/permission_sets/#{@many.id}/overview"), params: { only: 'view_all' }
        assert_equal ['Ledger'], Nokogiri::HTML(response.body).css('.pf-overview__res code').map(&:text)
      end

      test 'a view that matches nothing says so and offers every Resource' do
        @bins.first.permission_set_rules.each(&:destroy!)
        @bins.first.resource_fields.each(&:destroy!)

        get pf("/permission_sets/#{@many.id}/overview"), params: { only: 'narrowed' }
        page = Nokogiri::HTML(response.body)
        assert_match 'No Resource of this set matches this view.', page.text
        assert_no_match 'no Resources yet', page.text
        assert(page.css('a').any? { |link| link.text.include?('Show all 13 Resources') })
      end

      test 'a Resource name stored past the validation is shown, not linked, never a 500' do
        @bins.last.update_columns(name: 'Foo/Bar')
        @bins[-2].update_columns(name: '')

        get pf("/permission_sets/#{@many.id}/overview")
        assert_response :success
        codes = Nokogiri::HTML(response.body).css('.pf-overview__res code')
        assert(codes.any? { |code| code.text == 'Foo/Bar' && code.ancestors('a').empty? })
      end

      test 'an unknown set is not found, as on the set page' do
        assert_raises(ActiveRecord::RecordNotFound) { get pf('/permission_sets/0/overview') }
      end

      test 'the list reads a constant number of queries, however many sets and Resources' do
        baseline = list_queries
        3.times do |index|
          set = create_permission_set(name: "Team #{index}")
          4.times { |n| create_resource(permission_set: set, name: "Teams::Desk#{n}", read_access: true) }
        end

        assert_equal baseline, list_queries
      end

      private

      def list_queries
        count = 0
        counter = lambda do |*, payload|
          sql = payload[:sql].to_s
          count += 1 unless payload[:name] == 'SCHEMA' || payload[:cached] || sql.start_with?('PRAGMA')
        end
        ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { get pf('/permission_sets') }
        assert_response :success
        count
      end
    end
  end
end
