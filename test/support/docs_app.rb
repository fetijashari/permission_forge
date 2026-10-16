# frozen_string_literal: true

# The docs app: a Rails 8.1 application shaped like `rails new` +
# `bin/rails generate authentication` + `bin/rails generate scaffold Customer
# name email phone status notes owner:references`, in a temp directory, with
# PermissionForge installed by the README's own install lines. Every `run`
# and `file=` block of README.md and docs/*.md (test/support/doc_blocks.rb)
# is executed in it, document by document, then the denial flows of the
# documentation are driven as requests (docs_app/scenarios.rb).
#
# Run in a child process by test/permission_forge/docs/doc_samples_test.rb:
#   ruby test/support/docs_app.rb default  <result.json>   the documents + the scenarios
#   ruby test/support/docs_app.rb api_only <result.json>   a `rails new --api` host (docs_app/api_only.rb)
# or served for a browser (the `browser` CI job, test/browser/docs_flows.spec.js):
#   bundle exec ruby test/support/docs_app.rb --serve 4018
#
# The skeleton (docs_app/skeleton) holds the files those generators write,
# unchanged where the docs do not replace them. Nothing from test/dummy or
# test_helper is loaded: the app runs on the shipped defaults, as a reader's.

ENV['RAILS_ENV'] = 'test'
ENV.delete('DATABASE_URL')

require 'json'
require 'tmpdir'
require 'fileutils'
require 'logger'
require 'stringio'
require 'base64'
require 'rack/test'
require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'action_view/railtie'
require 'jbuilder'

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'permission_forge'
require_relative 'doc_blocks'
require_relative 'docs_app/application'

module DocsApp
  SUPPORT = __dir__
  SKELETONS = File.join(SUPPORT, 'docs_app')
  PASSWORD = 'secret123'

  # The documents, in the order a reader meets them; the rest alphabetically.
  FIRST = %w[README.md docs/getting-started.md docs/row-level-rules.md docs/controller-actions.md docs/admin-ui.md
             docs/field-filtering.md docs/masked-attributes.md docs/usage.md docs/tips-and-helpers.md
             docs/activation-conditions.md docs/permission-set-groups.md].freeze

  module_function

  def documents
    all = DocBlocks.documents.index_by(&:file)
    (FIRST + (all.keys - FIRST).sort).filter_map { |file| all[file] }
  end

  def root = Application.root

  # Runs one mode and writes the JSON result (or serves).
  def main(argv)
    mode = argv.fetch(0, 'default')
    return Server.serve(Integer(argv.fetch(1, '4018'))) if mode == '--serve'

    result = mode == 'api_only' ? ApiOnly.run : Default.run
    File.write(argv.fetch(1), JSON.generate(result))
  end

  # The default child: the app from the docs, every program, the scenarios.
  module Default
    module_function

    def run
      Application.boot!(skeleton: 'skeleton')
      Fixtures.host_tables!
      Fixtures.people!
      install = Install.from_readme!
      Fixtures.permissions!
      Database.snapshot!
      documents = Programs.run_all(DocsApp.documents)
      Database.restore!
      { mode: 'default', rails: Rails.version, install: install, documents: documents, scenarios: Scenarios.run }
    end
  end
end

require_relative 'docs_app/database'
require_relative 'docs_app/fixtures'
require_relative 'docs_app/shell'
require_relative 'docs_app/install'
require_relative 'docs_app/programs'
require_relative 'docs_app/scenarios'
require_relative 'docs_app/option_a'
require_relative 'docs_app/api_only'
require_relative 'docs_app/server'

if $PROGRAM_NAME == __FILE__
  begin
    DocsApp.main(ARGV)
  rescue Exception => e # rubocop:disable Lint/RescueException -- the child reports whatever stopped it
    report = { error: "#{e.class}: #{e.message}", backtrace: Array(e.backtrace).first(15) }
    ARGV[1] && ARGV[0] != '--serve' ? File.write(ARGV[1], JSON.generate(report)) : warn(JSON.generate(report))
    exit 1
  end
end
