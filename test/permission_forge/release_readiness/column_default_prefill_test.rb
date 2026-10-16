# frozen_string_literal: true

require_relative '../html/admin_test_case'
require_relative '../html/admin_page_paths'
require 'nokogiri'

module PermissionForge
  # The admin never pre-fills a column default as text. The install
  # migration gives the string columns of the nine tables English defaults
  # ('Untitled Permission Set', 'Untitled Field', the rule's "You do not
  # have permission to perform this action."); a new-record form that shows
  # one in an input or a textarea offers English to a Macedonian admin, who
  # saves it for end users (R6 #91: the rule builder's "Blocked message").
  # Every text default of the nine tables — the live columns and the install
  # template, which must agree — is looked for in every new-record screen
  # and every re-rendered form of AdminPaths; a default of an enumerated
  # column (one with an inclusion validator: mask_strategy, operator) is a
  # choice, not text, and may be selected.
  class ColumnDefaultPrefillTest < Html::AdminTestCase
    include Html::AdminPagePaths

    MIGRATION = File.expand_path('../../../lib/generators/permission_forge/install/templates/migration.rb.tt', __dir__)
    TEMPLATE_DEFAULT = /t\.(?:string|text)\s+:(\w+),.*?default:\s*'([^']*)'/
    NEW_SCREEN = %r{/new\b|[?&]new=1}

    test 'the install migration and the dummy schema give the string columns the same defaults' do
      assert_equal template_defaults.sort, live_defaults.sort
    end

    test 'no new-record screen or re-rendered form pre-fills a text default' do
      defaults = text_defaults
      assert_includes defaults, 'You do not have permission to perform this action.'
      screens = paths.grep(NEW_SCREEN).map { |path| get(pf(path)) && ["GET #{path}", response.body] } + error_screens
      assert_operator screens.size, :>=, 8

      failures = screens.flat_map { |label, html| prefilled(html, defaults).map { |hit| "#{label}: #{hit}" } }
      assert_empty failures, "a column default offered as text:\n#{failures.join("\n")}"
    end

    # Negative fixture: a form that shows the rule's default message, as the
    # rule builder did.
    test 'the check bites' do
      html = '<form><input name="rule[name]" value="Untitled Rule"><textarea name="rule[failure_message]">' \
             'You do not have permission to perform this action.</textarea><select><option selected>full</option></select></form>'
      hits = prefilled(html, text_defaults)
      assert_equal ['input rule[name] = "Untitled Rule"', 'textarea rule[failure_message] = "You do not have permission to perform this action."'],
                   hits
      assert_empty prefilled('<input name="x" value="Sales rep">', text_defaults)
    end

    private

    # [column name, default] of every string/text column of the nine tables
    # with a non-blank default, from the live schema.
    def live_columns
      (PermissionForge::TestModels.all + [PermissionForge::AuditEvent]).flat_map do |klass|
        klass.columns.select { |column| %i[string text].include?(column.type) && column.default.present? }
             .map { |column| [klass, column.name, column.default] }
      end
    end

    def live_defaults = live_columns.map { |_, name, default| [name, default] }

    def template_defaults = File.read(MIGRATION).scan(TEMPLATE_DEFAULT)

    # The defaults that are text: not the value of an enumerated column —
    # and the ones the install migration gave the columns before 0.15
    # (PermissionForge::GeneratedText): an upgraded install still has them.
    def text_defaults
      live = live_columns.reject { |klass, name, _| klass.validators_on(name).any? { |validator| validator.kind == :inclusion } }
      (live.map(&:last) | PermissionForge::GeneratedText.install_defaults).uniq
    end

    # "input rule[name] = "Untitled Rule"" for every text input value,
    # textarea text and selected option of `html` that is a default.
    def prefilled(html, defaults)
      form_values(Nokogiri::HTML(html)).select { |_, _, value| defaults.include?(value) }
                                       .map { |kind, name, value| "#{kind} #{name} = #{value.inspect}" }
    end

    # [kind, input name, value] of every text input, textarea and selected option.
    def form_values(doc)
      input_values(doc) + textarea_values(doc) + option_values(doc)
    end

    def input_values(doc)
      inputs = doc.css('input[value]').reject { |node| %w[hidden radio checkbox submit button].include?(node['type']) }
      inputs.map { |node| ['input', node['name'], node['value']] }
    end

    def textarea_values(doc) = doc.css('textarea').map { |node| ['textarea', node['name'], node.text.strip] }
    def option_values(doc) = doc.css('option[selected]').map { |node| ['option', node.parent['name'], node.text.strip] }
  end
end
