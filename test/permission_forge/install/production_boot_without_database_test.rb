# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'tmpdir'
require 'fileutils'

module PermissionForge
  module Install
    # A fresh `rails new --skip-kamal` app comments its production database
    # paths out (config/database.yml: the deploy supplies DATABASE_URL at
    # runtime). The Dockerfile's build step, `RAILS_ENV=production
    # SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile`, boots the app in
    # production with that configuration; so does any production runner
    # before the deploy sets the URL. The same app without the gem boots.
    #
    # Through 0.15.0-rc the engine's after_initialize pinged the database and
    # rescued only ActiveRecord::ActiveRecordError, and the sqlite3 adapter
    # refuses a configuration without a file with an ArgumentError ("No
    # database file specified"): the boot aborted (field test round 8, E#7).
    #
    # A generated app on disk (the real install generator, run in
    # development), booted in production with Rails 8.1's database.yml as
    # `rails new --skip-kamal` writes it, and a cache store that raises as
    # Solid Cache does without its database. `assets:precompile` is a stand-in
    # task here (the test bundle has no asset pipeline), with the same
    # prerequisite as Propshaft's and Sprockets': :environment.
    class ProductionBootWithoutDatabaseTest < ActiveSupport::TestCase
      GEM_ROOT = File.expand_path('../../..', __dir__)
      UNREACHABLE_WARNING = Regexp.new(Regexp.escape('[PermissionForge] The database could not be reached at boot, ' \
                                                     "or the gem's models could not be loaded " \
                                                     '(ArgumentError: No database file specified'))

      FILES = {
        'config/boot.rb' => <<~RUBY,
          ENV['BUNDLE_GEMFILE'] = __GEMFILE__
          require 'bundler/setup'
        RUBY
        'config/application.rb' => <<~RUBY,
          require_relative 'boot'
          require 'rails'
          require 'active_record/railtie'
          require 'action_controller/railtie'
          require 'action_view/railtie'
          require 'permission_forge'

          module ProductionBootApp
            class Application < Rails::Application
              config.load_defaults Rails::VERSION::STRING.to_f
              config.eager_load = Rails.env.production?
              config.active_support.deprecation = :silence
              # Rails 8.1's production cache_store is :solid_cache_store, whose
              # database is not configured either: every read and write raises
              # the adapter's ArgumentError (UnconfiguredStore stands in for it).
              if Rails.env.production?
                require_relative '../lib/unconfigured_store'
                config.cache_store = UnconfiguredStore.new
              end
            end
          end
        RUBY
        'lib/unconfigured_store.rb' => <<~RUBY,
          require 'active_support/cache'

          class UnconfiguredStore < ActiveSupport::Cache::Store
            def self.supports_cache_versioning? = true

            private

            def unconfigured = raise(ArgumentError, 'No database file specified. Missing argument: database')
            def read_entry(*) = unconfigured
            def write_entry(*) = unconfigured
            def delete_entry(*) = unconfigured
          end
        RUBY
        'config/environment.rb' => <<~RUBY,
          require_relative 'application'
          Rails.application.initialize!
        RUBY
        # What `rails new --skip-kamal` writes on Rails 8.1 (the comments
        # trimmed): no production database file until the deploy says where.
        'config/database.yml' => <<~YAML,
          default: &default
            adapter: sqlite3
            max_connections: 5
            timeout: 5000

          development:
            <<: *default
            database: storage/development.sqlite3

          production:
            primary:
              <<: *default
              # database: path/to/persistent/storage/production.sqlite3
            cache:
              <<: *default
              # database: path/to/persistent/storage/production_cache.sqlite3
              migrations_paths: db/cache_migrate
        YAML
        'config/routes.rb' => <<~RUBY,
          Rails.application.routes.draw do
            mount PermissionForge::Engine, at: '/permissions'
          end
        RUBY
        'Rakefile' => <<~RUBY,
          require_relative 'config/application'
          Rails.application.load_tasks
          namespace :assets do
            task precompile: :environment do
              puts 'PRECOMPILED'
            end
          end
        RUBY
        'bin/rails' => <<~RUBY,
          #!/usr/bin/env ruby
          APP_PATH = File.expand_path('../config/application', __dir__)
          require_relative '../config/boot'
          require 'rails/commands'
        RUBY
        'app/models/application_record.rb' => <<~RUBY,
          class ApplicationRecord < ActiveRecord::Base
            primary_abstract_class
          end
        RUBY
        'app/models/user.rb' => <<~RUBY
          class User < ApplicationRecord
            include PermissionForge::Concerns::PermissionedUser
          end
        RUBY
      }.freeze

      class << self
        # The app with the generated initializer, once per process.
        def app
          @app ||= build
        end

        def environment(rails_env)
          { 'RAILS_ENV' => rails_env, 'DATABASE_URL' => nil, 'DB' => nil, 'RUBYOPT' => nil,
            'SECRET_KEY_BASE_DUMMY' => '1', 'PF_ADMIN_USER' => nil, 'PF_ADMIN_PASSWORD' => nil }
        end

        private

        def build
          root = Dir.mktmpdir('pf_production_boot')
          at_exit { FileUtils.remove_entry(root) if File.directory?(root) }
          write_files(root)
          out, status = Open3.capture2e(environment('development'), RbConfig.ruby, 'bin/rails', 'generate',
                                        'permission_forge:install', chdir: root)
          raise "bin/rails generate permission_forge:install failed:\n#{out}" unless status.success?

          root
        end

        # FILES, booting on this run's Gemfile (rails_7.1.gemfile too).
        def write_files(root)
          gemfile = File.expand_path(ENV.fetch('BUNDLE_GEMFILE', File.join(GEM_ROOT, 'Gemfile')), GEM_ROOT)
          FILES.each do |path, body|
            FileUtils.mkdir_p(File.join(root, File.dirname(path)))
            File.write(File.join(root, path), body.sub('__GEMFILE__', gemfile.dump))
          end
          %w[log tmp storage].each { |dir| FileUtils.mkdir_p(File.join(root, dir)) }
        end
      end

      test 'assets:precompile boots in production with no database file configured, and never connects' do
        out, err, status = rails('assets:precompile')

        assert status.success?, "assets:precompile aborted (exit #{status.exitstatus}):\n#{out}\n#{err}"
        assert_includes out, 'PRECOMPILED'
        assert_no_match(/ArgumentError|could not be reached|SECURITY warning/, err, 'an asset build does not run the database boot checks')
      end

      test 'a production runner with no database file configured boots, says the checks were skipped, and runs' do
        out, err, status = rails('runner', 'Rails.application.executor.wrap { puts :ran }')

        assert status.success?, "the runner aborted (exit #{status.exitstatus}):\n#{out}\n#{err}"
        assert_includes out, 'ran'
        assert_equal 1, err.scan(UNREACHABLE_WARNING).size, err
        assert_no_match(/SECURITY warning/, err, 'no SECURITY warning for a database (or a cache store) that is not configured')
      end

      private

      def rails(*command)
        Open3.capture3(self.class.environment('production'), RbConfig.ruby, 'bin/rails', *command, chdir: self.class.app)
      end
    end
  end
end
