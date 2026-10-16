# frozen_string_literal: true

require 'test_helper'
require 'yaml'

module PermissionForge
  class I18nTest < ActiveSupport::TestCase
    SUPPORTED_LOCALES = %i[en sq mk].freeze
    LOCALE_DIR = File.expand_path('../../config/locales', __dir__)

    # ── Helper: flatten YAML keys ──

    def flatten_keys(hash, prefix = '')
      hash.each_with_object([]) do |(key, value), keys|
        full_key = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
        if value.is_a?(Hash)
          keys.concat(flatten_keys(value, full_key))
        else
          keys << full_key
        end
      end
    end

    def load_locale_hash(locale)
      file = File.join(LOCALE_DIR, "permission_forge.#{locale}.yml")
      YAML.load_file(file)
    end

    def en_keys
      @en_keys ||= begin
        data = load_locale_hash(:en)
        flatten_keys(data['en']['permission_forge'], 'permission_forge')
      end
    end

    def locale_keys(locale)
      data = load_locale_hash(locale)
      flatten_keys(data[locale.to_s]['permission_forge'], 'permission_forge')
    end

    def en_values
      @en_values ||= begin
        data = load_locale_hash(:en)
        flat = {}
        collect_values(data['en']['permission_forge'], 'permission_forge', flat)
        flat
      end
    end

    def collect_values(hash, prefix, result)
      hash.each do |key, value|
        full_key = "#{prefix}.#{key}"
        if value.is_a?(Hash)
          collect_values(value, full_key, result)
        else
          result[full_key] = value
        end
      end
    end

    # ── A. All locale files exist ──

    test 'all supported locale files exist' do
      SUPPORTED_LOCALES.each do |locale|
        file = File.join(LOCALE_DIR, "permission_forge.#{locale}.yml")
        assert File.exist?(file), "Missing locale file: permission_forge.#{locale}.yml"
      end
    end

    # ── B. Key completeness — every locale has all keys from en ──

    SUPPORTED_LOCALES.reject { |l| l == :en }.each do |locale|
      test "#{locale} has all keys from en" do
        missing = en_keys - locale_keys(locale)
        assert missing.empty?, "#{locale} missing keys: #{missing.join(', ')}"
      end

      test "#{locale} has no extra keys beyond en" do
        extra = locale_keys(locale) - en_keys
        assert extra.empty?, "#{locale} has extra keys: #{extra.join(', ')}"
      end
    end

    # ── C. No 'translation missing' in any locale ──

    SUPPORTED_LOCALES.each do |locale|
      test "no translation missing errors for #{locale}" do
        en_keys.each do |key|
          result = I18n.t(key, locale: locale, default: nil)
          # For pluralized keys (.one/.other), the parent key returns a hash, which is fine
          next if result.is_a?(Hash)

          assert_not_nil result, "#{locale}: #{key} returned nil"
        end
      end
    end

    # ── D. Interpolation integrity — %{var} placeholders match across locales ──

    SUPPORTED_LOCALES.reject { |l| l == :en }.each do |locale|
      test "#{locale} has matching interpolation variables" do
        mismatches = []

        en_values.each do |key, en_val|
          next unless en_val.is_a?(String)

          en_vars = en_val.scan(/%\{(\w+)\}/).flatten.sort
          next if en_vars.empty?

          locale_val = I18n.t(key, locale: locale, default: nil)
          next unless locale_val.is_a?(String)

          locale_vars = locale_val.scan(/%\{(\w+)\}/).flatten.sort
          mismatches << "#{key}: en has #{en_vars}, #{locale} has #{locale_vars}" if en_vars != locale_vars
        end

        assert mismatches.empty?,
               "#{locale} interpolation mismatches:\n#{mismatches.join("\n")}"
      end
    end

    # ── E. Pluralization completeness ──

    test 'all locales have matching pluralization forms' do
      plural_parents = en_keys.select { |k| k.end_with?('.one') }.map { |k| k.sub(/\.one\z/, '') }

      SUPPORTED_LOCALES.reject { |l| l == :en }.each do |locale|
        keys = locale_keys(locale)
        plural_parents.each do |parent|
          assert keys.include?("#{parent}.one"),
                 "#{locale} missing pluralization key: #{parent}.one"
          assert keys.include?("#{parent}.other"),
                 "#{locale} missing pluralization key: #{parent}.other"
        end
      end
    end

    # ── F. HTML-safe keys exist in all locales ──

    test 'html-safe keys exist in all locales' do
      html_keys = en_keys.select { |k| k.end_with?('_html') }

      SUPPORTED_LOCALES.reject { |l| l == :en }.each do |locale|
        keys = locale_keys(locale)
        html_keys.each do |key|
          assert keys.include?(key),
                 "#{locale} missing HTML-safe key: #{key}"
        end
      end
    end

    # ── G. Top-level locale key matches filename ──

    SUPPORTED_LOCALES.each do |locale|
      test "#{locale} file has correct top-level key" do
        data = load_locale_hash(locale)
        assert data.key?(locale.to_s),
               "permission_forge.#{locale}.yml should have '#{locale}:' as top-level key, got: #{data.keys}"
      end
    end

    # ── H. Code tokens in translations are pure ASCII ──

    test 'code tokens in Cyrillic locales are pure ASCII' do
      ascii_tokens = %w[PermissionForge current_user example.com pf-mono company.organization]
      cyrillic_confusables = [
        0x0410, 0x0412, 0x0421, 0x0415, 0x041D, 0x041A, 0x041C, 0x041E, 0x0420, 0x0422,
        0x0425, 0x0430, 0x0435, 0x043E, 0x0440, 0x0441, 0x0443, 0x0445, 0x0456, 0x0433
      ]

      [:mk].each do |locale|
        file_content = File.read(File.join(LOCALE_DIR, "permission_forge.#{locale}.yml"))

        ascii_tokens.each do |token|
          file_content.scan(/#{Regexp.escape(token)}/i).each do |match|
            match.each_char do |ch|
              assert_not_includes cyrillic_confusables, ch.ord,
                                  "#{locale}: Token '#{token}' contains Cyrillic char U+#{ch.ord.to_s(16).upcase}"
            end
          end
        end
      end
    end

    # ── I. Configuration: available_locales limits loaded files ──

    test 'available_locales config option exists' do
      config = PermissionForge::Configuration.new
      assert_respond_to config, :available_locales
      assert_nil config.available_locales, 'default should be nil'
    end

    test 'available_locales can be set' do
      config = PermissionForge::Configuration.new
      config.available_locales = %i[en sq]
      assert_equal %i[en sq], config.available_locales
    end

    # ── J. A translation is not the English text ──
    #
    # A sq/mk value identical to en, when the en value has three Latin
    # letters or more outside its placeholders and one of them lower-case
    # (a format of placeholders, an acronym or a code such as "API" or
    # "UUID" is no English), is an English string left in the file — unless
    # the allow-list names it with a reason (a word the language shares, the
    # brand, a UI name kept verbatim, a sample value).

    IDENTICAL_ALLOWLIST = File.expand_path('i18n_identical_allowlist.yml', __dir__)
    LATIN_LETTERS = /[A-Za-z]/
    PLACEHOLDER = /%\{\w+\}/

    def english_prose?(value)
      return false unless value.is_a?(String)

      letters = value.gsub(PLACEHOLDER, '').scan(LATIN_LETTERS)
      letters.size >= 3 && letters.any? { |letter| letter.match?(/[a-z]/) }
    end

    def raw_values(locale)
      flat = {}
      collect_values(load_locale_hash(locale)[locale.to_s]['permission_forge'], 'permission_forge', flat)
      flat
    end

    SUPPORTED_LOCALES.reject { |l| l == :en }.each do |locale|
      test "#{locale} values identical to en are allow-listed with a reason" do
        allowed = YAML.load_file(IDENTICAL_ALLOWLIST).fetch(locale.to_s, {}) || {}
        values = raw_values(locale)
        identical = en_values.select { |key, en_value| english_prose?(en_value) && values[key] == en_value }.keys

        assert_empty identical - allowed.keys,
                     "#{locale}: English left in the locale file (translate it, or list it in i18n_identical_allowlist.yml " \
                     "with a reason): #{(identical - allowed.keys).join(', ')}"
        assert_empty allowed.keys - identical, "#{locale}: stale allow-list entries (remove them): #{(allowed.keys - identical).join(', ')}"
        assert_empty allowed.select { |_, reason| reason.to_s.strip.empty? }.keys, "#{locale}: give every allow-list entry a reason"
      end
    end

    test 'the identical-value lint bites' do
      assert english_prose?(en_values.fetch('permission_forge.ui.cancel'))
      assert english_prose?('Fail-open')
      assert_not english_prose?('%{who} · %{when}'), 'a format of placeholders' # rubocop:disable Style/FormatStringToken
      assert_not english_prose?('JSON API'), 'an acronym'
      identical = en_values.select { |key, value| english_prose?(value) && raw_values(:en)[key] == value }
      assert_includes identical.keys, 'permission_forge.ui.cancel'
    end

    # ── K. One pair of quotation marks per locale ──
    #
    # Each locale file quotes with one pair (sq “…”, mk „…“, en “…”); any
    # other typographic quotation mark is a mixed style (R6 #93: sq had
    # both „…“ and “…”). The right single quote is the Albanian apostrophe
    # (t’u) and allowed there; › is the breadcrumb separator, not a quote.

    QUOTATION_MARKS = %w[„ “ ” « » ‚ ‘ ’].freeze
    QUOTES = { en: %w[“ ”], sq: %w[“ ” ’], mk: %w[„ “] }.freeze

    QUOTES.each do |locale, allowed|
      test "#{locale} quotes with one pair of quotation marks" do
        foreign = QUOTATION_MARKS - allowed
        offending = File.readlines(File.join(LOCALE_DIR, "permission_forge.#{locale}.yml")).each_with_index.filter_map do |line, index|
          marks = foreign.select { |mark| line.include?(mark) }
          "#{index + 1}: #{marks.join(' ')} #{line.strip}" if marks.any?
        end

        assert_empty offending, "#{locale}: quotation marks outside #{allowed.join(' ')}:\n#{offending.join("\n")}"
      end
    end

    test 'every bundled locale has a quote style' do
      assert_equal SUPPORTED_LOCALES.sort, QUOTES.keys.sort
    end

    # ── M. One state, one label (the label registry) ──
    #
    # The words of a state the admin shows (a field level, an effective
    # outcome, a lock, an actor kind, a CRUD cell, an action state) live in
    # the label namespaces: Admin::StateLabel's registry (ui.states.<kind>)
    # and the namespaces it replaced. A second key with the same English
    # value there is a second name for one state that can drift (R3 #38:
    # "Unchanged 0 · Not configured 8" for one state). Two namespaces keep
    # their own words until the 0.16 merge; the allow-list says why.

    LABEL_NAMESPACES = %w[ui.states ui.levels ui.badges shared.crud_cell resource_actions.states
                          resources.fields_tab.filters audit_log.actor_types].freeze
    LABEL_ALLOWLIST = {
      'shared.crud_cell' => 'the CRUD toggle cell keeps its words (StateLabel kind :crud reads them) until the ' \
                            '0.16 merge into ui.states.crud; its Allowed / No / Muted / Unchanged repeat other kinds',
      'resource_actions.states' => 'the action states keep their words (StateLabel kind :action reads them) until ' \
                                   'the 0.16 merge into ui.states.action; Blocked / Unchanged repeat other kinds'
    }.freeze

    def in_namespace?(key, namespaces)
      namespaces.any? { |namespace| key.start_with?("permission_forge.#{namespace}.") }
    end

    # { normalised English value => [keys] } for every value that more than
    # one key of the label namespaces (outside the allow-list) holds.
    def label_duplicates(values)
      labels = values.select { |key, _| in_namespace?(key, LABEL_NAMESPACES) && !in_namespace?(key, LABEL_ALLOWLIST.keys) }
      labels.group_by { |_, value| value.to_s.strip.downcase }.select { |_, pairs| pairs.size > 1 }
            .transform_values { |pairs| pairs.map(&:first) }
    end

    test 'one state, one label: no English label repeats within the label namespaces' do
      duplicates = label_duplicates(en_values)

      assert_empty duplicates, 'a state named under two keys (keep one, render it through Admin::StateLabel): ' \
                               "#{duplicates.map { |value, keys| "#{value.inspect} #{keys.join(', ')}" }.join('; ')}"
    end

    test 'the label lint bites: a second key for Not configured fails it' do
      values = en_values.merge('permission_forge.ui.levels.none2' => 'Not configured')

      assert_includes label_duplicates(values).keys, 'not configured'
    end

    test 'every allow-listed label namespace is still in the locale and says why' do
      LABEL_ALLOWLIST.each do |namespace, reason|
        assert reason.to_s.strip.present?, "#{namespace}: give the allow-list entry a reason"
        assert en_values.keys.any? { |key| key.start_with?("permission_forge.#{namespace}.") },
               "stale allow-list entry #{namespace}: the namespace is gone (merged), remove it"
      end
    end

    # ── L. Locale switcher helper ──

    test 'pf_locale_label returns correct labels' do
      helper = Class.new { include PermissionForge::ApplicationHelper }.new
      assert_equal 'English', helper.pf_locale_label(:en)
      assert_equal 'Shqip', helper.pf_locale_label(:sq)
      assert_equal 'Makedonski', helper.pf_locale_label(:mk)
    end
  end
end
