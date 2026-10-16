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
    # All of lib/permission_forge (round 7, critique 22): a writer outside the
    # admin (the field generator's RowBuilder) stored `name.humanize` on every
    # generated row, where the narrower globs never looked.
    GLOBS = %w[app/**/*.rb app/**/*.erb lib/permission_forge/**/*.rb].freeze

    INFLECTIONS = /\.(?:humanize|titleize|pluralize|singularize|to_sentence|full_messages?)\b|
                   \b(?:pluralize|time_ago_in_words|distance_of_time_in_words|number_to_human\w*|number_with_delimiter)\(|
                   \bI18n\.l\(|(?<![\w.:])l\(/x
    HOST_TRANSLATIONS = /\.human_attribute_name\(|\.model_name\.human\b/
    # t('errors.…'), I18n.t("support.…"): a Rails-core key family (strings kept for this scan).
    RAILS_KEYS = /\b(?:I18n\.)?t\(\s*:?["']?(?:errors|support|datetime|date|time|number|helpers|activerecord|activemodel)\./

    # [file, line pattern, reason]. No writer stores an inflected name (round
    # 7: the gem stores the name itself; GeneratedText reads what it stored
    # before). The host application's constant name is the same in every
    # language.
    INFLECTION_ALLOWLIST = [
      ['lib/permission_forge/generated_text.rb', /name\.to_s\.humanize/,
       'recognises the label 0.15 and earlier stored (`name.humanize`) as generated; it writes and shows nothing'],
      ['lib/permission_forge/admin/field_label.rb', /ActiveSupport::Inflector\.humanize\(name\)/,
       'Rails\' English for an action key, asked only while I18n.locale is English (FieldLabel.english, round 7 ' \
       'critique 28): what an English host saw before 0.15; any other page shows the key verbatim'],
      ['app/helpers/permission_forge/application_helper.rb', /module_parent_name\.to_s\.titleize/,
       'the host application\'s constant name (admin_app_name overrides it); the same in every locale']
    ].freeze

    # Every label of a stored name goes through Admin::FieldLabel /
    # Admin::ModelLabel (Admin::ModelCatalog's too, since WP-13): no entry.
    HOST_TRANSLATION_ALLOWLIST = [].freeze

    test 'nothing in app/ or lib/permission_forge inflects English' do
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

    test 'nothing in app/ or lib/permission_forge reads a Rails-core translation key' do
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
