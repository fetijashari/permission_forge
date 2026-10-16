# frozen_string_literal: true

require 'yaml'
require 'set'

# The pseudo-locale `xx`: the gem's en file with every string wrapped in
# ⟦ ⟧ and every interpolation marked ⟨%{name}⟩, installed in the I18n
# backend for a test and removed after it. A screen rendered under xx shows
# the words of a permission_forge.* key wrapped; what is left once the
# wrapped words are removed — the interpolated values kept — is either host
# data (the fixtures' names, a stored column name) or a leak: a Rails-core
# key (rails-i18n is absent from the suite), an inflection (`humanize`), an
# English literal in a view, helper, controller or locale file.
#
#   PseudoLocale.install!            # setup
#   PseudoLocale.remainder(text)     # "Full address" for "⟦Resource › ⟨Full address⟩⟧ Fail-open"
#   PseudoLocale.remove!             # teardown
module PseudoLocale
  LOCALE = :xx
  OPEN = '⟦'
  CLOSE = '⟧'
  HOLE_OPEN = '⟨'
  HOLE_CLOSE = '⟩'
  # A wrapped segment with no wrapped segment inside it.
  INNERMOST = /#{OPEN}([^#{OPEN}#{CLOSE}]*)#{CLOSE}/o
  HOLE = /#{HOLE_OPEN}([^#{HOLE_OPEN}#{HOLE_CLOSE}]*)#{HOLE_CLOSE}/o
  INTERPOLATION = /%\{\w+\}/
  EN_PATH = File.expand_path('../../config/locales/permission_forge.en.yml', __dir__)
  # A run of letters is prose when it is two or more Latin letters with a
  # lower-case one among them (an apostrophe or hyphen inside counts:
  # "isn't", "Fail-open"); a token with a digit, an underscore, a dot or a
  # colon is an identifier, a uuid, a time, a constant path, and an
  # all-capitals token an acronym or code (UUID, CSV, EN) — never a
  # translation.
  TOKEN = %r{[[:alnum:]_.:'’\-/@]+}
  PROSE = /\A[A-Za-z][A-Za-z'’-]*[A-Za-z]\z/
  LOWER = /[a-z]/

  module_function

  # The en file wrapped, built once.
  def translations
    @translations ||= wrap(YAML.load_file(EN_PATH).fetch('en'))
  end

  def wrap(value)
    case value
    when Hash then value.transform_values { |inner| wrap(inner) }
    when String then "#{OPEN}#{value.gsub(INTERPOLATION) { |hole| "#{HOLE_OPEN}#{hole}#{HOLE_CLOSE}" }}#{CLOSE}"
    else value
    end
  end

  # Installs xx in the backend and in I18n.available_locales (the dummy app
  # pins en, sq and mk). PermissionForge.configuration.available_locales is
  # the caller's to set (ConfigurationSnapshot restores it).
  def install!
    @available_locales = I18n.available_locales
    # First: the Simple backend drops translations of a locale that is not available.
    I18n.available_locales = @available_locales | [LOCALE]
    I18n.backend.store_translations(LOCALE, translations)
  end

  def remove!
    I18n.available_locales = @available_locales if @available_locales
    I18n.backend.translations.delete(LOCALE) if I18n.backend.respond_to?(:translations)
    @available_locales = nil
  end

  # `text` without the words of any wrapped segment, innermost first: what
  # a translation interpolated (⟨…⟩) is kept, its own words are dropped —
  # and an interpolated value that is, whole, one of `host` (stored host
  # data: a label, a description) is dropped too. A segment is a word
  # boundary: "Bo Berisha⟦ and ⟧Ana" leaves "Bo Berisha Ana".
  def remainder(text, host: Set.new)
    rest = text.to_s.dup
    while rest.match?(INNERMOST)
      rest.gsub!(INNERMOST) do
        " #{Regexp.last_match(1).scan(HOLE).flatten.reject { |value| host.include?(value.strip) }.join(' ')} "
      end
    end
    rest.delete(HOLE_OPEN + HOLE_CLOSE + OPEN + CLOSE)
  end

  # The prose words of `text` (see PROSE) not in `vocabulary` (a Set of
  # tokens, see .tokens): the leaks. `host`: see .remainder.
  def leaks(text, vocabulary, host: Set.new)
    tokens(remainder(text, host: host)).select { |word| word.match?(PROSE) && word.match?(LOWER) && !vocabulary.include?(word) }.uniq
  end

  def tokens(text)
    text.to_s.scan(TOKEN).flat_map { |token| token.split(%r{[@/]}) }.reject(&:empty?)
  end

  # Every token of every string in `strings`, for a vocabulary of host data.
  def vocabulary(strings)
    strings.flatten.compact.flat_map { |string| tokens(string) }.to_set
  end
end
