# frozen_string_literal: true

require 'test_helper'
require 'yaml'

module PermissionForge
  # Field test round 7 (C#92): Home counted the same people with two
  # Macedonian nouns side by side — "1 лице го има овој сет" on one card,
  # "1 корисник" on the next. One noun per locale for a person the admin
  # counts: the one the shared count (`ui.people_count`) uses. A synonym in
  # a count phrase under `home.*` fails, by key.
  class LocaleGlossaryTest < ActiveSupport::TestCase
    # locale => [the noun's stem ui.people_count uses, the synonyms a count phrase must not use]
    PERSON = {
      'en' => [/\b(?:person|people)\b/, /\b(?:users?|individuals?)\b/i],
      'sq' => [/(?<!\p{L})person/, /(?<!\p{L})përdorues/i],
      'mk' => [/(?<!\p{L})корисни/, /(?<!\p{L})(?:лице|лица|лицето|луѓе)(?!\p{L})/i]
    }.freeze

    def locale_tree(locale)
      YAML.load_file(File.expand_path("../../config/locales/permission_forge.#{locale}.yml", __dir__)).fetch(locale).fetch('permission_forge')
    end

    # "key.path" => text for every string under `node`.
    def strings(node, path = [])
      return { path.join('.') => node } if node.is_a?(String)
      return {} unless node.is_a?(Hash)

      node.flat_map { |key, inner| strings(inner, path + [key]).to_a }.to_h
    end

    COUNT = '%{count}' # rubocop:disable Style/FormatStringToken -- the placeholder as a locale file writes it

    # The count phrases of Home that count people: a pluralized key whose text names a person.
    def people_counts(locale)
      stem, synonyms = PERSON.fetch(locale)
      strings(locale_tree(locale)['home'], ['home']).select do |key, text|
        key.match?(/\.(?:one|other|few|many)\z/) && text.include?(COUNT) && (text.match?(stem) || text.match?(synonyms))
      end
    end

    PERSON.each do |locale, (stem, synonyms)|
      test "#{locale}: Home counts people with the noun of ui.people_count" do
        shared = strings(locale_tree(locale)['ui']['people_count']).values
        assert shared.all? { |text| text.match?(stem) }, "#{locale}: ui.people_count #{shared.inspect} uses the glossary's noun"

        counts = people_counts(locale)
        assert_operator counts.size, :>=, 6, "#{locale}: the Home cards count people"
        off = counts.select { |_, text| text.match?(synonyms) || !text.match?(stem) }
        assert_empty off, "#{locale}: another noun for a person on Home:\n#{off.map { |key, text| "#{key}: #{text}" }.join("\n")}"
      end
    end

    test 'negative fixture: a synonym is caught' do
      _, synonyms = PERSON.fetch('mk')
      assert_match synonyms, "#{COUNT} лице го има овој сет."
      assert_match synonyms, "#{COUNT} лица го имаат овој сет."
      assert_no_match synonyms, "#{COUNT} корисник го има овој сет."
      assert_no_match synonyms, 'Отвори го лицеви', 'a word that only begins the same'
    end
  end
end
