require_relative 'admin_test_case'
require_relative 'admin_page_paths'
require 'nokogiri'

module PermissionForge
  module Html
    # Field test round 8 (B#95): the edit page of a rule whose relationship
    # no longer exists printed "field_accessor_path: ownr" under the picker
    # in every language, while the banner, the picker's label and Home named
    # it in the page's language. The locale-leak walk took it for host data:
    # it was inside <code>.
    #
    # The class: a stored column name of the gem's own tables, followed by a
    # colon, is the raw attribute label of a form or a debug dump — never
    # what an admin page says. Every screen, error state and posted page is
    # walked (in sq: the column names are the same in every language) with
    # a rule that follows a relationship, a valid one and a misspelled one;
    # the Technical details panels (.pf-tech, shared/_tech_details: raw
    # attributes for developers, by design) are left out.
    class RawAttributeNamesTest < AdminTestCase
      include AdminPagePaths

      LOCALE = 'sq'.freeze
      # "<column>: <value>" written on purpose, each with its reason.
      ALLOWED = {
        'is_editable: false' => 'the lock flag as the code or API that locked the row sets it, inside a translated ' \
                                'sentence (shared/_mode_banners, home/_broken_rules_card): what a developer searches for'
      }.freeze

      setup do
        @broken.update_columns(field_accessor_path: 'ownr', join_type: 'joins', field_name: 'name')
        @path_rule = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Supplier name',
                                                field_name: 'name', field_value: 'Acme', field_accessor_path: 'supplier',
                                                join_type: 'joins')
      end

      # Every column name of the nine tables with an underscore (a bare
      # "name:" or "label:" is also a word).
      def column_names
        PermissionForge::TestModels.all.flat_map(&:column_names).uniq.select { |name| name.include?('_') }
      end

      def raw_label_pattern
        /(?<![\w.])(?:#{column_names.map { |name| Regexp.escape(name) }.join('|')}):\s*[\w.]*/
      end

      def raw_labels(body)
        doc = Nokogiri::HTML(body)
        doc.css('script, style, pre, .pf-tech').each(&:remove)
        text = doc.text.gsub(/\s+/, ' ')
        text.scan(raw_label_pattern).reject { |found| ALLOWED.key?(found) }.uniq
      end

      def report(label, found)
        found.empty? ? [] : ["#{label}: #{found.join(', ')}"]
      end

      def rule_edit(rule) = "/permission_sets/#{@set.id}/resources/Customer/rules/#{rule.id}/edit"

      test 'no screen prints a column name of the gem as a label' do
        failures = (paths + [rule_edit(@path_rule)]).flat_map do |path|
          get pf(path), params: { locale: LOCALE }
          assert_response :success, path
          report("GET #{path}", raw_labels(response.body))
        end
        failures += error_states.select(&:renders?).flat_map do |state|
          send(state.verb, pf(state.path), params: state.params.merge(locale: LOCALE))
          report("#{state.verb.upcase} #{state.path}", raw_labels(response.body))
        end
        failures += extra_screens(locale: LOCALE).flat_map { |label, body| report(label, raw_labels(body)) }

        assert_empty failures, failures.join("\n")
      end

      test 'the rule builder names the stored relationship path in the page language' do
        %w[en sq mk].each do |locale|
          get pf(rule_edit(@broken)), params: { locale: locale }
          hint = Nokogiri::HTML(response.body).css('p.pf-hint').find { |node| node.at_css('code')&.text == 'ownr' }

          assert hint, "#{locale}: the stored path is shown"
          expected = I18n.t('permission_forge.permission_set_rules.builder.path_html', path: '', locale: locale).strip
          assert_equal expected, hint.text.sub('ownr', '').strip, locale
          assert_not_includes response.body, 'field_accessor_path', locale
        end
      end
    end
  end
end
