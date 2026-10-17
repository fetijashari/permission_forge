# frozen_string_literal: true

module DocsApp
  # Serves the docs app for a browser (test/browser/docs_flows.spec.js, the
  # `browser` CI job): installed from the README, seeded, every document's
  # `file=` blocks applied (the handler, the template, the SessionsController
  # line, the wired scaffold, Admin::BaseController), Option B on, Turbo
  # loaded, forgery protection on. Prints one DOCS: line, then serves with
  # Puma until stopped.
  module Server
    TURBO = File.expand_path('../../browser/node_modules/@hotwired/turbo/dist/turbo.es2017-esm.js', __dir__)
    TURBO_CDN = 'https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.23/dist/turbo.es2017-esm.js'

    module_function

    def serve(port)
      Application.boot!(skeleton: 'skeleton', serve: true)
      Fixtures.host_tables!
      Fixtures.people!
      Install.from_readme!
      apply_files!
      Fixtures.permissions!
      turbo!
      Scenarios.option_b!
      announce(port)
      require 'rackup'
      Rackup::Handler.get('puma').run(Rails.application, Port: port, Host: '127.0.0.1', Silent: true)
    end

    # The files of every document, as the test applies them.
    def apply_files!
      console = Programs::Console.new
      DocsApp.documents.each { |document| document.program.select(&:file?).each { |block| console.run(block) } }
      console.settle!
    end

    # Turbo from the browser job's npm install, else from a CDN.
    def turbo!
      path = File.join(Application.root, 'public/turbo.js')
      File.exist?(TURBO) ? FileUtils.cp(TURBO, path) : File.write(path, "import #{TURBO_CDN.inspect};\n")
    end

    def announce(port)
      people = Fixtures::PEOPLE.keys.to_h { |name| [name, Fixtures.email(name)] }
      puts "DOCS:#{JSON.generate(base: "http://127.0.0.1:#{port}", password: PASSWORD, people: people,
                                 customers: Fixtures::CUSTOMERS.to_h { |name, owner| [name, { owner: owner, id: Fixtures.customer(name).id }] })}"
      $stdout.flush
    end
  end
end
