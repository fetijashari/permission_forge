require 'test_helper'
require 'ripper'
require 'action_view'

module PermissionForge
  module Html
    # Markup is built with `tag`, `content_tag`, `safe_join` and `tag.attributes`,
    # never by marking a string safe by hand: a hand-marked string is the one
    # place a value can reach the page unescaped.
    #
    # Ruby is tokenized (Ripper), so comments, strings and interpolation cannot
    # hide or fake a call; templates are compiled by Erubi first and the Ruby
    # they produce is tokenized the same way.
    class NoHandMarkedSafeTest < ActiveSupport::TestCase
      ROOT = File.expand_path('../../..', __dir__)

      # path => why that file may mark a string safe. Empty on purpose; an
      # entry needs a reason a reviewer can check.
      ALLOW_LIST = {}.freeze

      # Method names that mark a string safe (or skip escaping) wherever they
      # appear: a call, `send(:html_safe)`, `helpers.raw(x)`.
      SINKS = %w[html_safe safe_concat safe_expr_append].freeze
      # `raw` is also a common local variable, so it counts only as a call:
      # with a receiver, with parentheses, or with an argument after it.
      RAW_ARGUMENT = %i[on_tstring_beg on_ident on_const on_ivar on_symbeg on_int on_lparen].freeze
      SKIPPED = %i[on_sp on_ignored_nl on_nl].freeze

      # The sinks found in Ruby source: [line, text].
      def self.offences(source)
        tokens = Ripper.lex(source)
        tokens.each_index.filter_map do |index|
          (line,), type, text = tokens[index]
          previous = tokens[0...index].reverse.find { |(_, kind, _)| !SKIPPED.include?(kind) }
          [line, text] if previous&.at(2) != 'def' && sink?(type, text, previous, next_token(tokens, index))
        end
      end

      def self.next_token(tokens, index)
        tokens[(index + 1)..].find { |(_, kind, _)| kind != :on_sp }
      end

      def self.sink?(type, text, previous, following)
        return SINKS.include?(text) if type == :on_ident && text != 'raw'
        return %w[inline: SafeBuffer].include?(text) if %i[on_label on_const].include?(type)

        type == :on_ident && raw_call?(previous, following)
      end

      def self.raw_call?(previous, following)
        %w[. &.].include?(previous&.at(2)) || RAW_ARGUMENT.include?(following&.at(1))
      end

      def self.erb_offences(source)
        offences(ActionView::Template::Handlers::ERB::Erubi.new(source).src)
      end

      test 'nothing in app/ or lib/ marks a string safe by hand' do
        offenders = []
        Dir[File.join(ROOT, '{app,lib}/**/*.{rb,erb}')].each do |path|
          relative = path.delete_prefix("#{ROOT}/")
          next if ALLOW_LIST.key?(relative)

          source = File.read(path)
          found = relative.end_with?('.erb') ? self.class.erb_offences(source) : self.class.offences(source)
          found.each { |line, text| offenders << "#{relative}:#{line}: #{text}" }
        end
        assert_empty offenders, "hand-marked safe strings (use tag/content_tag/safe_join/tag.attributes):\n#{offenders.join("\n")}"
      end

      # The planted lines are single-quoted on purpose: they are source text, not strings to interpolate.
      # rubocop:disable Lint/InterpolationCheck
      test 'the scan catches every way of marking a string safe' do
        [
          'x.to_s.html_safe',
          '"<b>#{name}</b>".html_safe', # an interpolated string: a `#` comment strip would cut it
          'def evil_badge(name) = "<b>#{name}</b>".html_safe',
          'def evil_raw(name) = raw("<i>#{name}</i>")',
          'helpers.raw(x)',
          'x.send(:html_safe)',
          'x.public_send("html_safe")'.sub('"html_safe"', ':html_safe'),
          'buffer.safe_concat(x)',
          'render inline: "<%= x %>"',
          'ActiveSupport::SafeBuffer.new(x)'
        ].each do |source|
          assert_not_empty self.class.offences(source), "missed: #{source}"
        end
        assert_not_empty self.class.erb_offences('<%== x %>')
        assert_not_empty self.class.erb_offences('<%= "<b>#{x}</b>".html_safe %>')
        assert_not_empty self.class.erb_offences('<%= raw(x) %>')
      end

      # rubocop:enable Lint/InterpolationCheck

      test 'the scan does not flag talk about the methods, or defining one' do
        assert_empty self.class.offences("# never call html_safe or raw(x)\nputs 'html_safe'\n")
        assert_empty self.class.offences("def raw(attr) = attr\n")
        assert_empty self.class.erb_offences('<%# html_safe %><p>raw html_safe</p>')
      end

      test 'every allow-list entry names a file that still exists and gives a reason' do
        assert_predicate ALLOW_LIST, :frozen?
        ALLOW_LIST.each do |path, reason|
          assert File.exist?(File.join(ROOT, path)), "#{path} is on the allow-list but gone"
          assert reason.to_s.length > 10, "#{path} needs a reason"
        end
      end

      class HelperTest < ActionView::TestCase
        include PermissionForge::UiHelper

        test 'pf_attrs_when emits escaped attributes only when the condition holds' do
          assert_equal 'aria-invalid="true"', pf_attrs_when(true, aria: { invalid: true })
          assert_equal '', pf_attrs_when(nil, aria: { invalid: true })
          assert_equal 'data-pf-show-when="rule[x]=&quot;&gt;"', pf_attrs_when(true, data: { pf_show_when: 'rule[x]=">' })
          assert pf_attrs_when(true, list: 'a').html_safe?
        end

        test 'the lock icon is a decorative svg' do
          svg = Nokogiri::HTML5.fragment(pf_lock_icon).at_css('svg.pf-lock')
          assert_equal 'true', svg['aria-hidden']
          assert_equal '0 0 16 16', svg['viewBox']
          assert_equal 2, svg.element_children.size
        end
      end
    end
  end
end
