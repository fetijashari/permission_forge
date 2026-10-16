require_relative 'admin_test_case'
require_relative 'admin_page_paths'
require 'support/pseudo_locale'
require 'nokogiri'
require 'json'

module PermissionForge
  module Html
    # Every string the admin, its CSV exports and the JSON API show in a
    # language is the gem's own or host data: rendered under the pseudo-locale
    # xx (test/support/pseudo_locale.rb: en with every value wrapped), every
    # screen of AdminPaths, every error state, every flow's toast, every
    # posted page, every screen a setting draws, every export and every API
    # error class leave no prose once the wrapped words are removed — only
    # host data and digits. A Rails-core key (rails-i18n is absent from the
    # suite), a `humanize`, an English literal in a view or a locale file
    # show up unwrapped, by word.
    #
    # Host data on a screen (review R4 P2-1): the names of records and
    # people (IDENTITY) anywhere; anything else of the host — a label, a
    # description, a rule's message, an event's data, a column name — only
    # where it is marked (SKIPPED: <code>, .pf-mono, [data-pf-host-data]),
    # or as a whole value: an interpolated value, a segment of the <title>,
    # an attribute that is exactly a stored string. So a stored word never
    # hides the same word written in a view.
    class LocaleLeakTest < AdminTestCase
      include AdminPagePaths

      LOCALE = PseudoLocale::LOCALE.to_s
      # Stored names are shown verbatim in these, and a form field holds what
      # was typed: never a translation.
      SKIPPED = 'script, style, code, kbd, pre, textarea, .pf-mono, .pf-mono-key, .pf-audit-code, [data-pf-host-data]'.freeze
      TITLE_SEPARATOR = ' · '.freeze
      TEXT_ATTRIBUTES = %w[aria-label aria-description aria-roledescription placeholder title alt].freeze
      # English the dummy application itself holds: its name (the "Back to"
      # link), the brand, and the time zone's name.
      HOST_WORDS = %w[Dummy PermissionForge UTC].freeze
      # The machine-readable exports (Admin::Exports::Document): a metadata
      # block, a blank line, a header of column identifiers, then stored
      # rows. The metadata and the header are checked; the rows are data.
      EXPORT_HEAD_LINES = 8

      setup do
        PseudoLocale.install!
        PermissionForge.configuration.available_locales = [:en, PseudoLocale::LOCALE]
        store_generated_text
      end

      # Round 7 (S4): text the gem generated, stored the way installs made
      # before 0.15 stored it (past the model, as an API create or a
      # generated row left it), on records every walk shows: the walked set,
      # its group, rule, field and action. None of it is host data
      # (GeneratedText): a screen that prints it as stored leaks it.
      GENERATED = { set: 'Untitled Permission Set', group: 'Untitled Permission Set Group', rule: 'Untitled Rule',
                    message: 'You do not have permission to perform this action.', label: 'Email', action_label: 'Export' }.freeze

      def store_generated_text
        @set.update_columns(name: GENERATED[:set])
        @group.update_columns(name: GENERATED[:group])
        @set.update_columns(permission_set_group_id: @group.id)
        @rule.update_columns(name: GENERATED[:rule], failure_message: GENERATED[:message])
        @email.update_columns(label: GENERATED[:label])
        @action.update_columns(label: GENERATED[:action_label])
      end

      # A generated text is never host data, whichever row holds it.
      def generated?(text)
        PermissionForge::GeneratedText.install_defaults.include?(text.to_s.strip)
      end

      teardown do
        PseudoLocale.remove!
      end

      test 'every screen shows only translated words and host data' do
        failures = paths.flat_map do |path|
          get pf(path), params: { locale: LOCALE }
          assert_response :success, path
          report("GET #{path}", leaks_in(response.body))
        end

        assert_empty failures, failures.join("\n")
      end

      test 'every error state and every flow toast show only translated words and host data' do
        failures = error_states.select(&:renders?).flat_map do |state|
          send(state.verb, pf(state.path), params: state.params.merge(locale: LOCALE))
          report("#{state.verb.upcase} #{state.path}", leaks_in(response.body))
        end
        failures += flows.flat_map do |flow|
          send(flow.verb, pf(flow.path), params: flow.params.merge(locale: LOCALE))
          follow_redirect!
          report("#{flow.verb.upcase} #{flow.path} → toast", leaks_in(response.body))
        end

        assert_empty failures, failures.join("\n")
      end

      test 'every posted page and every screen a setting draws show only translated words and host data' do
        failures = extra_screens(locale: LOCALE).flat_map { |label, body| report(label, leaks_in(body)) }

        assert_empty failures, failures.join("\n")
      end

      test 'the CSV exports show only translated words and host data' do
        failures = []
        { "/people/#{@ana.id}.csv" => :all, "/permission_sets/#{@set.id}.csv?tab=audit" => :all,
          '/audit.csv' => :head, '/audit/holdings.csv' => :head }.each do |path, part|
          get pf(path), params: { locale: LOCALE }
          assert_response :success, path
          assert_equal 'text/csv', response.media_type, path
          text = part == :all ? response.body : response.body.lines.first(EXPORT_HEAD_LINES).join
          failures += report("GET #{path}", PseudoLocale.leaks(text, data_vocabulary))
        end

        assert_empty failures, failures.join("\n")
      end

      test 'every API error class answers in the request language' do
        failures = api_errors.flat_map do |label, request, status|
          request.call
          assert_response status, label
          assert_not_empty response.body, "#{label}: a bodiless answer"
          messages = JSON.parse(response.body).fetch('error').fetch('messages')
          strings(messages).flat_map do |text|
            problems = PseudoLocale.leaks(text, data_vocabulary)
            problems << 'not a translation' unless text.include?(PseudoLocale::OPEN)
            report("#{label} #{text.inspect}", problems)
          end
        end

        assert_empty failures, failures.join("\n")
      end

      # Negative fixtures: a humanized column name and an English literal,
      # rendered through the engine's own controller, are leaks; the gem's
      # own key and a stored name in <code> are not.
      test 'the check bites on a humanized name and an English literal' do
        assert_equal %w[Full address], leaks_in(render_inline("<p><%= 'full_address'.humanize %></p>"))
        assert_equal ['Fail-open'], leaks_in(render_inline('<span class="pf-badge">Fail-open</span>'))
        assert_equal %w[Close], leaks_in(render_inline('<button aria-label="Close">×</button>'))
        assert_equal %w[Full address], leaks_in(render_inline("<p><%= t('permission_forge.ui.audit.who_when', who: 'Full address', when: 1) %></p>"))
        assert_empty leaks_in(render_inline("<p><%= t('permission_forge.ui.cancel') %> <code>full_address</code> 12:30 · 3</p>"))
        assert_empty leaks_in(render_inline("<p><%= t('permission_forge.ui.audit.who_when', who: 'Ana Krasniqi', " \
                                            "when: t('permission_forge.ui.dates.today')) %></p>"))
        # A stored word (the field label "Name", a rule's "Access denied by
        # test rule", the action label "Export") hides no English literal:
        # host data counts where it is marked, or as a whole value.
        assert_equal %w[Name], leaks_in(render_inline("<p><%= 'name'.humanize %></p>"))
        assert_equal %w[Access denied], leaks_in(render_inline('<table><tr><th>Access denied</th></tr></table>'))
        assert_equal %w[Export], leaks_in(render_inline('<button>Export</button>'))
        assert_empty leaks_in(render_inline('<b data-pf-host-data>Export</b> <a aria-label="Export">x</a>'))
        assert_empty leaks_in(render_inline("<p><%= t('permission_forge.ui.audit.who_when', who: 'Access denied by test rule', when: 1) %></p>"))
      end

      # The columns that name a record or a person: what the admin shows as
      # a title, a link, a pill (never free text).
      IDENTITY = {
        'PermissionForge::PermissionSet' => %w[name], 'PermissionForge::PermissionSetGroup' => %w[name],
        'PermissionForge::Resource' => %w[name], 'PermissionForge::ResourceField' => %w[name],
        'PermissionForge::ResourceAction' => %w[name], 'PermissionForge::PermissionSetRule' => %w[name field_name],
        'PermissionForge::AuditEvent' => %w[actor_label record_label], 'User' => %w[name email]
      }.freeze

      API = '/permission_forge/api'.freeze
      HEADERS = { 'Accept-Language' => LOCALE, 'CONTENT_TYPE' => 'application/json' }.freeze

      private

      def report(label, leaks)
        leaks.empty? ? [] : ["#{label}: #{leaks.join(', ')}"]
      end

      # The prose of a screen that no permission_forge.* key produced and
      # that is not host data: its text nodes outside the skipped elements,
      # the attributes assistive technology reads, and the submit buttons.
      def leaks_in(html) # rubocop:disable Metrics/AbcSize -- the three kinds of text, each read once
        doc = Nokogiri::HTML(html)
        doc.css(SKIPPED).each(&:remove)
        title = doc.at_css('title')&.remove&.text.to_s.split(TITLE_SEPARATOR)
        values = title + attribute_texts(doc)
        texts = doc.xpath('//text()').map(&:text) + values.reject { |value| host_values.include?(value.strip) }
        PseudoLocale.leaks(texts.join(' '), vocabulary, host: host_values)
      end

      def attribute_texts(doc)
        doc.css(TEXT_ATTRIBUTES.map { |name| "[#{name}]" }.join(', ')).flat_map { |node| TEXT_ATTRIBUTES.filter_map { |name| node[name] } } +
          doc.css('input[type="submit"][value]').map { |node| node['value'] }
      end

      # Every string the fixtures stored, every column and association name,
      # every action key the host's controllers map, whole: host data as a
      # value.
      def host_values
        @host_values ||= begin
          keys = PermissionForge::Admin::ControllerCatalog.new.entries.map { |entry| entry.key.to_s }
          (stored_strings.reject { |text| generated?(text) || generated_label?(text) } + model_words + keys).to_set(&:strip)
        end
      end

      # A stored field or action label the gem made up (GeneratedText.label?).
      def generated_label?(text)
        labelled = PermissionForge::ResourceField.unscoped.pluck(:name, :label) + PermissionForge::ResourceAction.unscoped.pluck(:name, :label)
        labelled.any? { |name, label| label == text && name != text && PermissionForge::GeneratedText.label?(label, name) }
      end

      def render_inline(template)
        I18n.with_locale(PseudoLocale::LOCALE) { PermissionForge::ApplicationController.render(inline: template, layout: false) }
      end

      # Host data a screen may show bare: the names the fixtures stored (of
      # the records and the people: IDENTITY), the host's model names, what
      # a refused form echoes, the languages' own names. Everything else a
      # screen shows of the host — a description, a label, a rule's message,
      # an event's data, a column name — is marked (<code>, .pf-mono,
      # [data-pf-host-data]: SKIPPED), so a word of it never hides a leak
      # (review R4: the stored strings and column names allowed 81 words).
      def vocabulary
        @vocabulary ||= PseudoLocale.vocabulary(identity_strings + model_names + people_words + request_words + HOST_WORDS)
      end

      # The exports and the API answer with data: their columns, codes and
      # every stored string count too.
      def data_vocabulary
        @data_vocabulary ||= vocabulary | PseudoLocale.vocabulary(stored_strings + model_words + export_words)
      end

      def identity_strings
        IDENTITY.flat_map { |model, columns| model.constantize.unscoped.pluck(*columns).flatten.compact }.reject { |text| generated?(text) }
      end

      def model_names
        Rails.application.eager_load!
        ApplicationRecord.descendants.filter_map(&:name)
      end

      # What the error states and flows post (echoed back by a refused form).
      def request_words
        (error_states + flows + posted_pages).flat_map { |state| json_strings(state.params) }
      end

      # A person's initials (from the stored name), the languages' own names
      # in the switcher (a language is named in itself: "Shqip", never
      # translated) and the locale codes.
      def people_words
        User.all.map { |user| PermissionForge::Admin::PersonLabel.new(user).initials } +
          PermissionForge::ApplicationHelper::LOCALE_LABELS.values + [LOCALE.upcase] + [Time.zone.name]
      end

      def stored_strings
        models = PermissionForge::TestModels.all + [PermissionForge::AuditEvent, User]
        models.flat_map do |klass|
          columns = klass.columns.select { |column| %i[string text json].include?(column.type) }.map(&:name)
          klass.unscoped.pluck(*columns).flatten.flat_map { |value| json_strings(value) }
        end
      end

      def json_strings(value)
        case value
        when Hash then value.flat_map { |key, inner| [key.to_s] + json_strings(inner) }
        when Array then value.flat_map { |inner| json_strings(inner) }
        when String then [value]
        else [value.to_s]
        end
      end

      # The host's model names, column names and association names: stored
      # names the admin shows verbatim.
      def model_words
        Rails.application.eager_load!
        ApplicationRecord.descendants.flat_map do |klass|
          [klass.name] + (klass.table_exists? ? klass.column_names : []) + klass.reflect_on_all_associations.map { |assoc| assoc.name.to_s }
        end
      end

      def export_words
        exports = [PermissionForge::Admin::Exports::Holdings, PermissionForge::Admin::Exports::Events]
        exports.map { |export| export::KIND } + exports.first::COLUMNS + exports.last.columns +
          PermissionForge::Admin::Exports.meta('x', exported_by: PermissionForge::Audit::Actor.current, filters: {}, row_count: 0).keys +
          %w[true false]
      end

      def strings(value)
        case value
        when Hash then value.values.flat_map { |inner| strings(inner) }
        when Array then value.flat_map { |inner| strings(inner) }
        else [value.to_s]
        end
      end

      # One request per error class of the API that answers a body (the 401
      # is bodiless by design), each under Accept-Language: xx: [label,
      # request, status].
      def api_errors # rubocop:disable Metrics/AbcSize -- one entry per error class, nothing to share
        [
          ['404 unknown record', -> { get "#{API}/permission_sets/00000000-0000-0000-0000-000000000000", headers: HEADERS }, :not_found],
          ['404 unknown route', -> { get "#{API}/nothing", headers: HEADERS }, :not_found],
          ['422 missing section', -> { post "#{API}/permission_sets", params: {}.to_json, headers: HEADERS }, :unprocessable_entity],
          ['422 blank name', -> { post "#{API}/permission_sets", params: { permission_set: { name: '' } }.to_json, headers: HEADERS },
           :unprocessable_entity],
          ['422 name taken', -> { post "#{API}/permission_sets", params: { permission_set: { name: @set.name } }.to_json, headers: HEADERS },
           :unprocessable_entity],
          ['422 resource taken', lambda {
            post "#{API}/permission_sets/#{@set.uuid}/resources", params: { resource: { name: 'Customer' } }.to_json, headers: HEADERS
          }, :unprocessable_entity],
          ['422 assignment taken', -> { post "#{API}/permission_sets/#{@set.uuid}/users", params: { user_id: @ana.id }.to_json, headers: HEADERS },
           :unprocessable_entity],
          ['422 bad operator', lambda {
            post "#{API}/permission_sets/#{@set.uuid}/resources/#{@resource.uuid}/rules",
                 params: { rule: { name: 'r', field_name: 'name', operator: 'nope', field_value: 'x' } }.to_json, headers: HEADERS
          }, :unprocessable_entity],
          ['422 bad filter', -> { get "#{API}/audit_events", params: { from: '2026-02-30' }, headers: HEADERS }, :unprocessable_entity],
          ['400 unreadable body', -> { post "#{API}/permission_sets", params: '{not json', headers: HEADERS }, :bad_request],
          ['403 refused', lambda {
            PermissionForge.configuration.api_action_authorization = ->(*) { false }
            PermissionForge.configuration.api_require_authorization = true
            post "#{API}/permission_sets", params: { permission_set: { name: 'New' } }.to_json, headers: HEADERS
          }, :forbidden]
        ]
      end
    end
  end
end
