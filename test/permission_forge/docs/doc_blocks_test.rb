# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/doc_blocks'

module PermissionForge
  module Docs
    # The meta test of the documentation samples: every ruby, erb and bash
    # block in README.md and docs/*.md says what it is (`run`, `fragment` or
    # `file=<path>`), so docs/doc_samples_test.rb can execute the `run` and
    # `file=` blocks in a generated app and nothing is left as prose that only
    # looks executable. The fixtures below prove each rule bites.
    class DocBlocksTest < ActiveSupport::TestCase
      def parse(markdown) = DocBlocks.parse(markdown, file: 'fixture.md')
      def problems(markdown) = DocBlocks.problems(parse(markdown))

      test 'every ruby, erb and bash block in README.md and docs/ carries a marker and follows the rules' do
        blocks = DocBlocks.all
        assert_operator blocks.size, :>, 250, 'the parser found far fewer blocks than the docs hold'
        problems = DocBlocks.problems(blocks)
        assert_empty problems, "#{problems.size} problem(s):\n  #{problems.join("\n  ")}"
      end

      test 'a ruby, erb or bash block with no marker is refused; other languages need none' do
        assert_equal ['fixture.md:1: ```ruby block has no marker: say `run`, `fragment` or `file=<path>`'],
                     problems("```ruby\nx = 1\n```\n")
        assert_equal ['fixture.md:1: ```erb block has no marker: say `run`, `fragment` or `file=<path>`'],
                     problems("```erb\n<%= x %>\n```\n")
        assert_equal ['fixture.md:1: ```bash block has no marker: say `run`, `fragment` or `file=<path>`'],
                     problems("```bash\nls\n```\n")
        assert_empty problems("```json\n{}\n```\n\n```\ntext\n```\n\n```yaml\na: 1\n```\n")
      end

      test 'the marker is one of run, fragment and file=<path>, once' do
        assert_empty problems("```ruby run\nx = 1\n```\n```ruby fragment\n...\n```\n```ruby file=app/x.rb\nx = 1\n```\n")
        assert_equal ['fixture.md:1: `runs` is not a marker (run, fragment, file=<path>)'], problems("```ruby runs\nx = 1\n```\n")
        assert_equal ['fixture.md:1: one marker per block, got `run fragment`'], problems("```ruby run fragment\nx = 1\n```\n")
        assert_equal ['fixture.md:1: file= needs a path'], problems("```ruby file=\nx = 1\n```\n")
      end

      test 'a language alias is refused so a grep for ```ruby finds every block' do
        assert_equal ['fixture.md:1: spell the language `bash`, not `sh`',
                      'fixture.md:1: ```sh block has no marker: say `run`, `fragment` or `file=<path>`'],
                     problems("```sh\nls\n```\n")
      end

      test 'a file= path is inside the app and ends the way its language does' do
        assert_equal ['fixture.md:1: file=/etc/app.rb must be a path inside the app (relative, no ..)'],
                     problems("```ruby file=/etc/app.rb\nx = 1\n```\n")
        assert_equal ['fixture.md:1: file=../app.rb must be a path inside the app (relative, no ..)'],
                     problems("```ruby file=../app.rb\nx = 1\n```\n")
        assert_equal ['fixture.md:1: file=app/views/x.html.erb should end in .rb or .rake or .jbuilder or Gemfile for a ruby block'],
                     problems("```ruby file=app/views/x.html.erb\nx = 1\n```\n")
        assert_empty problems("```erb file=app/views/x.html.erb\n<%= x %>\n```\n```yaml file=config/x.yml\na: 1\n```\n")
      end

      test 'two file= blocks for one path are allowed only when identical' do
        same = "```ruby file=app/x.rb\nx = 1\n```\n\n```ruby file=app/x.rb\nx = 1\n```\n"
        assert_empty problems(same)
        differing = "```ruby file=app/x.rb\nx = 1\n```\n\n```ruby file=app/x.rb\nx = 2\n```\n"
        assert_equal ['file=app/x.rb appears with different content in fixture.md:1, fixture.md:5: keep one copy and point to it'],
                     problems(differing)
      end

      test 'a run or file= ruby block must be valid Ruby; a fragment may elide' do
        assert_empty problems("```ruby fragment\ndef x\n  ...\nend\n```\n")
        assert_equal ["fixture.md:1: a `run` ruby block must be valid Ruby (syntax error, unexpected 'end')"],
                     problems("```ruby run\ndef x\n  ...\nend\n```\n")
        assert_match(/a `file` ruby block must be valid Ruby/, problems("```ruby file=app/x.rb\nfoo(\n```\n").first)
      end

      # The denial handler was rewritten five times (R2 #68, R3 #66, R4 #74,
      # R5 #65, R6 #99); each earlier version fails whatever its marker.
      test 'the five handler versions the rounds went through are refused' do
        redirect_back = handler("redirect_back fallback_location: root_path, alert: 'Not allowed'")
        assert_includes problems(redirect_back), 'fixture.md:1: redirect_back loops when the refused page is the root (R2 #68)'

        head_only = handler('respond_to { |format| format.html { head :forbidden } }')
        assert_includes problems(head_only), 'fixture.md:1: head :forbidden for HTML leaves the sign-in form on screen (R3 #66)'

        static_page = handler("render file: Rails.public_path.join('403.html'), layout: false, status: :forbidden")
        assert_includes problems(static_page), 'fixture.md:1: rendering public/403.html gives a static page Turbo reloads into (R4 #74)'

        unguarded = handler("redirect_to new_session_path if error.reason == :nil_user_denied\n    render 'errors/forbidden', status: :forbidden")
        assert_includes problems(unguarded),
                        'fixture.md:1: a redirect to the sign-in page must skip the sign-in page itself (request.path != new_session_path) (R5 #65)'

        # The round-5 handler: a signed-in visitor on a public action (nothing resumed the session) is
        # redirected to sign in, from where SessionsController#new sends them back — a loop.
        round5 = handler("if error.reason == :nil_user_denied && request.path != new_session_path\n      redirect_to new_session_path\n    " \
                         "else\n      render 'errors/forbidden', status: :forbidden\n    end\n    format.any { head :forbidden }")
        assert_equal ['fixture.md:1: a redirect to the sign-in page must resume the session first (!authenticated?): on an action opened ' \
                      'with allow_unauthenticated_access a signed-in visitor reads as signed out, and SessionsController#new sends them back ' \
                      '(R6 #99)'], problems(round5)

        current = handler("if error.reason == :nil_user_denied && !authenticated? && request.path != new_session_path\n      " \
                          "redirect_to new_session_path\n    else\n      render 'errors/forbidden', status: :forbidden\n    end\n    " \
                          'format.any { head :forbidden }')
        assert_empty problems(current)
        via_generator = handler("if error.reason == :nil_user_denied && !authenticated? && request.path != new_session_path\n      " \
                                "request_authentication\n    else\n      render 'errors/forbidden', status: :forbidden\n    end")
        assert_empty problems(via_generator)
      end

      test 'a # => claim is asserted only when it is a literal' do
        block = parse("```ruby run\nuser.can_read?('Customer') # => true\nuser.permissions_for(:Customer) # => { read_access: true,\n" \
                      "user # => #<User id: 1>\nids # => [1, 2]\nx = 1\n```\n").first
        claims = block.expectations
        assert_equal [2, 3, 4, 5], claims.map(&:line)
        assert_equal [true, false, false, true], claims.map(&:assert?)
        assert_equal "user.can_read?('Customer')", claims.first.source
        assert_equal 'true', claims.first.claim
        ['true', 'false', 'nil', '42', '-1.5', ':sym', '"s"', "'it'"].each { |literal| assert DocBlocks.literal?(literal), literal }
        ['[1, :a, "x"]', '{ read_access: true, edit_access: false }', "{ 'a' => 1 }", '[]', '{}'].each do |literal|
          assert DocBlocks.literal?(literal), literal
        end
        ['#<User id: 1>', '[#<User>]', 'true or false', '{ a: [1] }', 'nil means nothing'].each { |text| assert_not DocBlocks.literal?(text), text }
      end

      test 'a fence of four backticks keeps an inner ```ruby as content' do
        blocks = parse("````markdown\n## Notes\n```ruby\nx = 1\n```\n````\n\n```ruby run\ny = 2\n```\n")
        assert_equal %w[markdown ruby], blocks.map(&:lang)
        assert_includes blocks.first.body, '```ruby'
        assert_equal 8, blocks.last.line
      end

      test 'a document program is its file= and run blocks, in order; headings are kept' do
        markdown = "## Setup\n\n```ruby file=app/x.rb\nX = 1\n```\n\n## Use\n\n```ruby fragment\nnope\n```\n\n```ruby run\nX # => 1\n```\n"
        document = DocBlocks::Document.new(file: 'fixture.md', blocks: parse(markdown))
        assert_equal %w[file run], document.program.map(&:marker)
        assert_equal ['app/x.rb', nil], document.program.map(&:path)
        assert_equal ['## Setup', '## Use', '## Use'], document.blocks.map(&:heading)
      end

      private

      def handler(body)
        "```ruby fragment\nclass ApplicationController < ActionController::Base\n  " \
          "rescue_from PermissionForge::ActionNotAuthorizedError do |error|\n    #{body}\n  end\nend\n```\n"
      end
    end
  end
end
