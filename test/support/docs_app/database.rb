# frozen_string_literal: true

module DocsApp
  # The SQLite file of the docs app, snapshotted once the app is installed
  # and seeded, and put back before each document: every document then runs
  # on the app as installed (README's "Sales Team" and getting-started's
  # "Sales Team" each find the name free), and the scenarios on it again.
  module Database
    module_function

    def file = File.join(Application.root, 'db/test.sqlite3')
    def copy(name) = "#{file}.#{name}"

    # @param name [Symbol] :golden is the app as installed
    def snapshot!(name = :golden)
      disconnect
      FileUtils.cp(file, copy(name))
    end

    def restore!(name = :golden)
      disconnect
      FileUtils.cp(copy(name), file)
      Dir["#{file}-*"].each { |journal| FileUtils.rm_f(journal) }
    end

    # Every connection closed (SQLite checkpoints and drops its WAL when the
    # last one closes), so the file can be copied whole.
    def disconnect
      handler = ActiveRecord::Base.connection_handler
      handler.respond_to?(:clear_all_connections!) ? handler.clear_all_connections!(:all) : handler.clear_all_connections!
    end
  end
end
