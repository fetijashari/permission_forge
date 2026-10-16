# frozen_string_literal: true

module DocsApp
  # PermissionForge installed the way the README says: its install block
  # (`bin/rails generate permission_forge:install`, `bin/rails db:migrate`)
  # is run through Shell before anything else needs the tables. When the
  # documents run later, the same lines find the app installed and skip.
  module Install
    module_function

    def initializer = File.join(Application.root, 'config/initializers/permission_forge.rb')

    def installed? = File.exist?(initializer)

    # @return [Hash] what the README's block did
    def from_readme!
      block = readme_install_block
      lines = Shell.run(block.body)
      failed = lines.select { |line| line[:error] }
      raise "the README's install lines failed: #{failed.inspect}" if failed.any?

      { from: block.location, lines: lines, table_prefix: PermissionForge.table_name_prefix,
        preset: PermissionForge.configuration.preset.to_s }
    end

    def readme_install_block
      readme = DocBlocks.documents.find { |document| document.file == 'README.md' }
      block = readme&.program&.find { |candidate| candidate.lang == 'bash' && candidate.body.include?('permission_forge:install') }
      block || raise('README.md has no runnable install block (```bash run with permission_forge:install)')
    end

    # `rails generate permission_forge:install`: the real generator, once.
    def generate(flags)
      return { skipped: 'already installed (the README installed the app)' } if installed?
      raise ArgumentError, "generator flags are not run here: #{flags.join(' ')}" unless flags.empty?

      require 'rails/generators'
      require 'generators/permission_forge/install/install_generator'
      output = Shell.capture { PermissionForge::Generators::InstallGenerator.start([], destination_root: Application.root) }
      load initializer
      output.merge(generated: true)
    end

    # `rails db:migrate`: the pending migrations of the app.
    def migrate
      paths = Rails.application.paths['db/migrate'].to_a
      ran = ActiveRecord::Migration.suppress_messages { ActiveRecord::MigrationContext.new(paths).migrate }
      PermissionForge::Audit.reset! # the table check ran at boot, before the audit table existed
      { migrated: Array(ran).map { |migration| migration.respond_to?(:name) ? migration.name : migration.to_s } }
    end
  end
end
