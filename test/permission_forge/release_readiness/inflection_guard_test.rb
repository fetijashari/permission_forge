# frozen_string_literal: true

require 'test_helper'
require 'support/static_guard'

module PermissionForge
  # Nothing the admin renders goes through Rails' English inflections or
  # Rails-core translation keys. `humanize` / `titleize` / `pluralize` turn a
  # stored name into English whatever the page's language ("Full address"
  # on a Macedonian page); `to_sentence`, `time_ago_in_words`,
  # `full_messages`, `number_to_human` and the `errors.*` / `support.*` /
  # `datetime.*` keys read Rails' locale files, which a host without
  # rails-i18n has in English only. A label of a stored name has one
  # definition (Admin::FieldLabel / Admin::ModelLabel: the host's
  # translation when there is one, else the row's label, else the name
  # verbatim), lists go through Admin::ListSentence, validation sentences
  # through Admin::ErrorSentence. Comments and string literals do not count
  # (StaticGuard); an allow-listed line needs a reason and must still match.
  class InflectionGuardTest < ActiveSupport::TestCase
    GLOBS = %w[app/**/*.rb app/**/*.erb lib/permission_forge/admin/**/*.rb
               lib/permission_forge/unique_conflict.rb lib/permission_forge/audit/event_query.rb].freeze

    INFLECTIONS = /\.(?:humanize|titleize|pluralize|singularize|to_sentence|full_messages?)\b|
                   \b(?:pluralize|time_ago_in_words|distance_of_time_in_words|number_to_human\w*|number_with_delimiter)\(|
                   \bI18n\.l\(|(?<![\w.:])l\(/x
    HOST_TRANSLATIONS = /\.human_attribute_name\(|\.model_name\.human\b/
    # t('errors.…'), I18n.t("support.…"): a Rails-core key family (strings kept for this scan).
    RAILS_KEYS = /\b(?:I18n\.)?t\(\s*:?["']?(?:errors|support|datetime|date|time|number|helpers|activerecord|activemodel)\./

    # [file, line pattern, reason]: a stored default is written once when a
    # row is created (the host's column name made readable; an admin edits
    # the label afterwards), the host application's constant name is the
    # same in every language.
    INFLECTION_ALLOWLIST = [
      ['app/models/permission_forge/resource_field.rb', /self\.label = name\.to_s\.humanize/,
       'the label stored for a new row without one (default_label), as generated rows are labelled'],
      ['lib/permission_forge/admin/column_fields.rb', /label: column\.humanize/, 'the label stored when a field row is generated from a column'],
      ['lib/permission_forge/admin/change_set_parts/new_fields.rb', /label: column\.humanize/,
       'the label stored when a field row is generated from a column'],
      ['lib/permission_forge/admin/change_set_parts/new_actions.rb', /label: key\.humanize/,
       'the label stored when an action row is created from a controller action key'],
      ['lib/permission_forge/admin/change_set_parts/field_edit.rb', /field\.name\.humanize/,
       'a label an admin blanked is stored as the generated default again'],
      ['app/helpers/permission_forge/application_helper.rb', /module_parent_name\.to_s\.titleize/,
       'the host application\'s constant name (admin_app_name overrides it); the same in every locale']
    ].freeze

    # Admin::ModelCatalog builds its Column / Association / ModelInfo labels
    # itself; the admin renders them through Admin::FieldLabel and
    # Admin::ModelLabel instead. WP-13 (schema freshness) owns the file this
    # wave: make the catalog call the two and remove this entry.
    HOST_TRANSLATION_ALLOWLIST = [
      ['lib/permission_forge/admin/model_catalog.rb', /human_attribute_name\(name\)/,
       'the catalog labels are not rendered: FieldLabel decides the label of a column or association (wp-9 → wp-13 handoff)'],
      ['lib/permission_forge/admin/model_catalog.rb', /model_name\.human/,
       'the catalog labels are not rendered: ModelLabel decides the label of a model (wp-9 → wp-13 handoff)']
    ].freeze

    test 'nothing in app/ or lib/permission_forge/admin inflects English' do
      hits = StaticGuard.scan(globs: GLOBS, needle: INFLECTIONS, allowlist: INFLECTION_ALLOWLIST,
                              canonical: %w[lib/permission_forge/admin/list_sentence.rb])

      assert_empty hits.map(&:to_s), "Rails' English inflection in the admin (use Admin::FieldLabel / ModelLabel, ListSentence, " \
                                     "ErrorSentence, pf_relative, or add a reasoned allow-list entry):\n#{hits.join("\n")}"
      StaticGuard.assert_allowlist_current(self, globs: GLOBS, needle: INFLECTIONS, allowlist: INFLECTION_ALLOWLIST,
                                                 canonical: %w[lib/permission_forge/admin/list_sentence.rb])
    end

    test 'the label of a stored name is decided in one place' do
      canonical = %w[lib/permission_forge/admin/field_label.rb lib/permission_forge/admin/model_label.rb]
      hits = StaticGuard.scan(globs: GLOBS, needle: HOST_TRANSLATIONS, canonical: canonical, allowlist: HOST_TRANSLATION_ALLOWLIST)

      assert_empty hits.map(&:to_s), "human_attribute_name / model_name.human outside Admin::FieldLabel / ModelLabel:\n#{hits.join("\n")}"
      StaticGuard.assert_allowlist_current(self, globs: GLOBS, needle: HOST_TRANSLATIONS, canonical: canonical,
                                                 allowlist: HOST_TRANSLATION_ALLOWLIST)
    end

    test 'nothing in app/ or lib/permission_forge/admin reads a Rails-core translation key' do
      hits = StaticGuard.scan(globs: GLOBS, needle: RAILS_KEYS, strings: :keep)

      assert_empty hits.map(&:to_s),
                   "a Rails-core key the gem does not own (English without rails-i18n); use a permission_forge.* key:\n#{hits.join("\n")}"
    end

    # Negative fixtures: each needle finds what it is for.
    test 'the needles bite' do
      {
        INFLECTIONS => ['x = name.humanize', "t('.a', count: pluralize(2, 'x'))", 'time_ago_in_words(t)', 'record.errors.full_messages',
                        'Model.name.demodulize.pluralize', 'I18n.l(date)', '<%= l(date) %>'],
        HOST_TRANSLATIONS => ['klass.human_attribute_name(name)', 'klass.model_name.human(count: 2)'],
        RAILS_KEYS => ["I18n.t('errors.messages.blank')", 't("support.array.words_connector")', "t(:'datetime.distance_in_words')"]
      }.each do |needle, lines|
        lines.each { |line| assert_match needle, StaticGuard.code_of(line, strings: :keep), line }
      end
      ['# name.humanize in a comment', "t('permission_forge.errors.admin.ip')", 'AuditLogDays.localize(filters)',
       'label.humanized_name', 'pf_to_sentence(list)'].each do |line|
        assert_no_match INFLECTIONS, StaticGuard.code_of(line), line
        assert_no_match RAILS_KEYS, StaticGuard.code_of(line, strings: :keep), line
      end
    end
  end
end
