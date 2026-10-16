# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'socket'
require 'tmpdir'
require 'fileutils'

module PermissionForge
  module Install
    # A warning about the admin or the API is printed by the process that
    # serves them, not by every runner (round 7: a-onboarding #23,
    # c-enforcement #73). Through 0.15.0-rc each `bin/rails runner`, rake task
    # and `db:seed` of a fresh install printed "HTTP Basic Auth is enabled but
    # credentials are not configured. The admin UI will return 401" and the
    # shared-login line, although a runner serves no admin and the README's
    # credentials are set for the server only.
    #
    # A generated app on disk (bin/rails, config/, the real install
    # generator and its migration), in development, as a reader runs it:
    # `bin/rails runner` keeps the admin warnings off standard error (the log
    # has them) and still prints the others; `bin/rails server` prints them.
    class RunnerWarningsTest < ActiveSupport::TestCase
      GEM_ROOT = File.expand_path('../../..', __dir__)
      ADMIN_ONLY = {
        basic_auth_without_credentials: /HTTP Basic Auth is enabled but credentials are not configured/,
        audit_actor_shared_login: /audit_actor_resolver is not set/
      }.freeze
      # A warning every process gets: Rails' development :memory_store is a
      # cache per process (cache_stale_permissions).
      EVERY_PROCESS = /Development: the permission cache is an in-memory store/
      BOOT_TIMEOUT = 90

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

          module RunnerApp
            class Application < Rails::Application
              config.load_defaults Rails::VERSION::STRING.to_f
              config.eager_load = false
              config.secret_key_base = 'runner-warnings-' * 4
              # What config/environments/development.rb of `rails new` sets on Rails 8.
              config.cache_store = :memory_store
              config.active_support.deprecation = :silence
            end
          end
        RUBY
        'config/environment.rb' => <<~RUBY,
          require_relative 'application'
          Rails.application.initialize!
        RUBY
        'config/database.yml' => <<~YAML,
          development:
            adapter: sqlite3
            database: db/development.sqlite3
        YAML
        'config/routes.rb' => <<~RUBY,
          Rails.application.routes.draw do
            mount PermissionForge::Engine, at: '/permissions'
          end
        RUBY
        'config.ru' => <<~RUBY,
          require_relative 'config/environment'
          run Rails.application
        RUBY
        'Rakefile' => <<~RUBY,
          require_relative 'config/application'
          Rails.application.load_tasks
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
        'app/models/user.rb' => <<~RUBY,
          class User < ApplicationRecord
            include PermissionForge::Concerns::PermissionedUser
          end
        RUBY
        'db/migrate/20200101000000_create_users.rb' => <<~RUBY
          class CreateUsers < ActiveRecord::Migration[7.1]
            def change
              create_table(:users) { |t| t.string :name; t.string :email }
            end
          end
        RUBY
      }.freeze

      class << self
        # The app, generated and migrated once per process.
        def app
          @app ||= build
        end

        private

        def build
          root = Dir.mktmpdir('pf_runner_warnings')
          at_exit { FileUtils.remove_entry(root) if File.directory?(root) }
          gemfile = File.expand_path(ENV.fetch('BUNDLE_GEMFILE', File.join(GEM_ROOT, 'Gemfile')), GEM_ROOT)
          FILES.each do |path, body|
            FileUtils.mkdir_p(File.join(root, File.dirname(path)))
            File.write(File.join(root, path), body.sub('__GEMFILE__', gemfile.dump))
          end
          %w[log tmp].each { |dir| FileUtils.mkdir_p(File.join(root, dir)) }
          [%w[generate permission_forge:install], %w[db:migrate]].each { |command| run!(root, *command) }
          root
        end

        def run!(root, *command)
          out, status = Open3.capture2e(environment, RbConfig.ruby, 'bin/rails', *command, chdir: root)
          raise "bin/rails #{command.join(' ')} failed:\n#{out}" unless status.success?

          out
        end
      end

      # The development environment of the reader's shell: no test database,
      # no PF_ADMIN_* credentials (README Option A sets them for the server).
      def self.environment
        { 'RAILS_ENV' => 'development', 'DATABASE_URL' => nil, 'DB' => nil, 'PF_ADMIN_USER' => nil,
          'PF_ADMIN_PASSWORD' => nil, 'RUBYOPT' => nil }
      end

      test 'bin/rails runner keeps the admin warnings off standard error; the log has them, the other warnings print' do
        root = self.class.app
        log = File.join(root, 'log/development.log')
        File.write(log, '')
        out, err, status = Open3.capture3(self.class.environment, RbConfig.ruby, 'bin/rails', 'runner', 'puts :ran', chdir: root)

        assert status.success?, "#{out}\n#{err}"
        assert_includes out, 'ran'
        ADMIN_ONLY.each do |key, line|
          assert_no_match line, err, "#{key} on a runner's standard error"
          assert_match line, File.read(log), "#{key} in the log"
        end
        assert_match EVERY_PROCESS, err, 'a warning about the cache still reaches the runner'
      end

      test 'bin/rails server prints the admin warnings' do
        output = server_boot_output(self.class.app)

        ADMIN_ONLY.each { |key, line| assert_match line, output, "#{key} on the server's terminal" }
      end

      private

      # What `bin/rails server` writes until it listens (then it is stopped).
      def server_boot_output(root)
        port = TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] }
        output = +''
        Open3.popen2e(self.class.environment, RbConfig.ruby, 'bin/rails', 'server', '-b', '127.0.0.1', '-p', port.to_s,
                      '-P', "tmp/pids/server_#{port}.pid", chdir: root) do |stdin, merged, thread|
          stdin.close
          read_until_listening(merged, output)
          Process.kill('TERM', thread.pid)
          thread.join(30) || Process.kill('KILL', thread.pid)
        end
        output
      end

      def read_until_listening(stream, output)
        deadline = Time.now + BOOT_TIMEOUT
        until output.match?(/Listening on|Use Ctrl-C to stop/) || Time.now > deadline
          ready = stream.wait_readable(1)
          next unless ready

          chunk = stream.read_nonblock(4096, exception: false)
          break if chunk.nil?

          output << chunk if chunk.is_a?(String)
        end
        assert_match(/Listening on|Use Ctrl-C to stop/, output, "the server did not boot:\n#{output}")
      end
    end
  end
end
