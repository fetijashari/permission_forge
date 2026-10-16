require 'nokogiri'

module PermissionForge
  module Html
    # The layout proxies that need no browser: what generated the phone-width
    # defects of rounds 1-5 (a sentence in a single-line placeholder, a wide
    # grid outside a scroll frame, a scroll frame that is not the containing
    # block of what it clips). The browser probe (test/browser/layout_probe.js)
    # measures the real thing in the `browser` CI job; this lint runs in every
    # suite run.
    #
    #   lint = LayoutLint.new(css: File.read('app/frontend/permission_forge/pf_admin.css'))
    #   lint.page_problems(response.body)  # wide grids outside a frame, frames without the cue
    #   lint.css_problems                  # scroll containers that are no containing block, no cue
    #   LayoutLint.placeholder_problem(:input, text, locale: 'mk')
    class LayoutLint
      WIDE = 480 # px: a grid at least this wide scrolls sideways on a phone
      # Characters a single-line input shows on a phone (Cyrillic glyphs are
      # wider), and per line of a textarea.
      PLACEHOLDER_LIMITS = { input: { latin: 40, cyrillic: 34 }, textarea: { latin: 60, cyrillic: 60 } }.freeze
      FRAME = '.pf-scroll-x'.freeze
      SCROLLING = /\boverflow(?:-x|-y)?\s*:\s*(?:auto|scroll)\b/
      POSITIONED = /\bposition\s*:\s*(?:relative|sticky|absolute|fixed)\b/
      RULE = /([^{}]+)\{([^{}]*)\}/m

      # Why a placeholder does not fit, or nil. A textarea is judged per line.
      def self.placeholder_problem(kind, text, locale:)
        script = text.match?(/\p{Cyrillic}/) ? :cyrillic : :latin
        limit = PLACEHOLDER_LIMITS.fetch(kind).fetch(script)
        longest = text.lines.map { |line| line.chomp.length }.max.to_i
        return if longest <= limit

        "#{locale} #{kind} placeholder is #{longest} characters (#{script} limit #{limit}): #{text.inspect}; " \
          'shorten it and move the sentence to a pf-hint under the control'
      end

      def initialize(css:)
        @css = css.gsub(%r{/\*.*?\*/}m, '')
      end

      # [selectors, declarations] of every rule, at-rule blocks unwrapped.
      def rules
        @rules ||= @css.scan(RULE).map { |selectors, body| [selectors.strip, body.strip] }
      end

      # The classes whose rule declares min-width >= WIDE px: a grid that
      # scrolls sideways on a phone, so it must be rendered inside a frame.
      def wide_classes
        @wide_classes ||= rules.flat_map do |selectors, body|
          next [] if body[/\bmin-width\s*:\s*(\d+)px/, 1].to_i < WIDE

          selectors.split(',').flat_map { |selector| selector.strip.split(/[\s>+~]+/).last.scan(/\.(pf-[\w-]+)/).flatten }
        end.uniq
      end

      def page_problems(html)
        doc = Nokogiri::HTML5(html)
        unframed(doc) + uncued(doc)
      end

      def css_problems
        unpositioned_scroll_containers + missing_cue
      end

      private

      def unframed(doc)
        wide_classes.flat_map do |name|
          doc.css(".#{name}").reject { |node| node.ancestors(FRAME).any? }
             .map { |node| "#{describe(node)} is #{WIDE}px or wider with no #{FRAME} ancestor (pf_scroll_frame)" }
        end
      end

      # A scrollable region is a tab stop with a name (pf_scroll_frame): the
      # keyboard and screen-reader cue; the stylesheet paints the visual one.
      def uncued(doc)
        doc.css(FRAME).flat_map do |frame|
          [("#{describe(frame)} has no tabindex=0" unless frame['tabindex'] == '0'),
           ("#{describe(frame)} has no aria-label or aria-labelledby" if frame['aria-label'].to_s.strip.empty? && frame['aria-labelledby'].to_s.strip.empty?),
           ("#{describe(frame)} is no region" unless frame.name == 'section' || frame['role'] == 'region')].compact
        end
      end

      # A scroll container that is not positioned is no containing block for
      # an absolutely positioned descendant (a .pf-sr-only header cell): the
      # descendant sits at its static position in the page, outside the
      # container's clipping, and widens the document instead of scrolling.
      def unpositioned_scroll_containers
        rules.filter_map do |selectors, body|
          "#{selectors} scrolls but is no containing block: add position: relative" if body.match?(SCROLLING) && !body.match?(POSITIONED)
        end
      end

      def missing_cue
        frame = rules.find { |selectors, _| selectors == FRAME }
        return ["no #{FRAME} rule"] unless frame
        return [] if frame.last.include?('linear-gradient')

        ["#{FRAME} paints no scroll cue (the edge gradients)"]
      end

      def describe(node)
        "<#{node.name}#{" id=#{node['id']}" if node['id']}#{" class=#{node['class']}" if node['class']}>"
      end
    end
  end
end
