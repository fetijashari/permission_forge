require 'nokogiri'

module PermissionForge
  module Html
    # A small accessibility lint for rendered admin pages: the structural
    # checks axe-core would make that need no browser, so they run in every
    # suite run. It is no substitute for an axe-core pass in a real browser
    # (colour contrast, computed roles): run axe over the same pages by hand
    # when the markup or the stylesheet changes a lot. Returns a list of
    # problem strings; empty is clean.
    #
    #   A11yLint.new(response.body).problems
    class A11yLint
      UNNAMED_INPUT_TYPES = %w[hidden submit button reset image].freeze
      FOCUSABLE = 'a[href], button, input:not([type=hidden]), select, textarea, [tabindex]'.freeze
      LINK_ROLES = %w[link button menuitem tab].freeze
      CHECKS = %i[document headings landmarks controls buttons links link_roles images tables ids references live_regions pressed hidden_focus].freeze

      def initialize(html, fragment: false)
        @doc = Nokogiri::HTML5(html)
        @fragment = fragment
        @ids = @doc.css('[id]').map { |node| node['id'] }
      end

      def problems
        CHECKS.flat_map { |check| send(:"check_#{check}") }
      end

      private

      def check_document
        [('<html> has no lang' if @doc.at_css('html')['lang'].to_s.empty?),
         ('<title> is empty' if @doc.at_css('title')&.text.to_s.strip.empty?)].compact
      end

      def check_headings
        headings = @doc.css('h1, h2, h3, h4, h5, h6')
        levels = headings.map { |heading| heading.name[1].to_i }
        empty = headings.select { |heading| heading.text.strip.empty? }.map { |heading| "empty <#{heading.name}>" }
        empty + h1_problems(levels) + level_jumps(headings, levels)
      end

      def h1_problems(levels)
        return [] if @fragment || levels.one?(1)

        ["#{levels.count(1)} <h1> elements (want exactly 1)"]
      end

      def level_jumps(headings, levels)
        levels.each_cons(2).with_index.filter_map do |(from, to), index|
          "heading level jumps from h#{from} to h#{to} (#{headings[index + 1].text.strip[0, 30].inspect})" if to > from + 1
        end
      end

      def check_landmarks
        return [] if @fragment

        navs = @doc.css('nav')
        found = []
        found << "#{@doc.css('main').size} <main> landmarks (want 1)" unless @doc.css('main').one?
        found << 'several <nav> landmarks and one has no label' if navs.size > 1 && navs.any? { |nav| !named?(nav) }
        found
      end

      def check_controls
        controls = @doc.css('input, select, textarea').reject { |control| UNNAMED_INPUT_TYPES.include?(control['type'].to_s.downcase) }
        controls.reject { |control| control.ancestors('label').any? || labelled?(control) }.map { |control| "#{describe(control)} has no label" }
      end

      def check_buttons
        buttons = @doc.css('button, input[type=submit], input[type=button]')
        buttons.reject { |button| named?(button) || button['value'].to_s.strip != '' }.map { |button| "#{describe(button)} has no text" }
      end

      def check_links
        @doc.css('a[href]').reject { |link| named?(link) }.map { |link| "#{describe(link)} has no text" }
      end

      def check_link_roles
        odd = @doc.css('a[role]').reject { |link| LINK_ROLES.include?(link['role']) }
        odd.map { |link| "#{describe(link)} has role=#{link['role']} (not a link role)" }
      end

      def check_images
        @doc.css('img').reject { |image| image.key?('alt') }.map { |image| "#{describe(image)} has no alt" }
      end

      def check_tables
        native = @doc.css('table').flat_map do |table|
          [("#{describe(table)} has no header cells" unless table.at_css('th')),
           ("#{describe(table)} has no caption or label" unless table.at_css('caption') || named?(table))].compact
        end
        native + @doc.css('[role=table]').reject { |table| named?(table) }.map { |table| "#{describe(table)} has no label" }
      end

      def check_ids
        @ids.tally.select { |_, count| count > 1 }.keys.map { |id| "duplicate id #{id.inspect}" }
      end

      def check_references
        orphans = @doc.css('label[for]').reject { |label| @ids.include?(label['for']) }
        orphans.map { |label| "label for=#{label['for'].inspect} has no control" } + dangling_aria
      end

      def dangling_aria
        %w[aria-labelledby aria-describedby aria-controls].flat_map do |attribute|
          @doc.css("[#{attribute}]").flat_map do |node|
            (node[attribute].split - @ids).map { |id| "#{describe(node)} #{attribute} points at missing ##{id}" }
          end
        end
      end

      def check_live_regions
        toasts = @doc.css('.pf-toast').reject { |toast| %w[alert status].include?(toast['role']) || toast['aria-live'] }
        toasts.map { 'a toast is not a live region' }
      end

      def check_pressed
        @doc.css('[aria-pressed]').reject { |node| node.name == 'button' }.map { |node| "#{describe(node)} has aria-pressed (buttons only)" }
      end

      def check_hidden_focus
        @doc.css('[aria-hidden=true]').flat_map do |hidden|
          reachable = (hidden.matches?(FOCUSABLE) ? [hidden] : []) + hidden.css(FOCUSABLE).to_a
          reachable = reachable.reject { |node| node['tabindex'] == '-1' || node.key?('disabled') }
          reachable.map { |node| "#{describe(node)} is focusable inside aria-hidden" }
        end
      end

      def labelled?(control)
        named?(control) || @doc.css("label[for='#{control['id']}']").any? { |label| label.text.strip != '' }
      end

      def named?(node)
        node['aria-label'].to_s.strip != '' || node['title'].to_s.strip != '' || referenced_name?(node) || content_name?(node)
      end

      def referenced_name?(node)
        node['aria-labelledby'].to_s.split.any? { |id| @doc.at_css("[id='#{id}']")&.text.to_s.strip != '' }
      end

      def content_name?(node)
        node.text.strip != '' || node.css('img[alt]').any? { |image| image['alt'].strip != '' } || node.css('svg title').any?
      end

      def describe(node)
        "<#{node.name}#{" id=#{node['id']}" if node['id']}#{" name=#{node['name']}" if node['name']}#{" class=#{node['class']}" if node['class']}>"
      end
    end
  end
end
