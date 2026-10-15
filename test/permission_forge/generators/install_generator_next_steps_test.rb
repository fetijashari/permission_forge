require 'test_helper'
require 'tmpdir'
require 'generators/permission_forge/install/install_generator'

module PermissionForge
  module Generators
    # The generated files alone leave no admin to open: the generator says
    # what to do next (migrate, mount, credentials, the audit task).
    class InstallGeneratorNextStepsTest < ActiveSupport::TestCase
      test 'an install prints the next steps after the files' do
        output = install

        assert_match(%r{create\s+config/initializers/permission_forge\.rb.*Next steps:}m, output)
        assert_includes output, '1. bin/rails db:migrate'
        assert_includes output, 'mount PermissionForge::Engine, at: "/permissions"'
        assert_includes output, 'PF_ADMIN_USER, PF_ADMIN_PASSWORD'
        assert_includes output, 'Option B'
        assert_includes output, 'bin/rails permission_forge:audit'
        assert_includes output, InstallGenerator::QUICK_START_URL
        assert_operator output[/Next steps:.*/m].lines.size, :<=, 10
      end

      test 'the credentials step names what the generated initializer reads' do
        source = render_install_template('initializer.rb.tt')

        assert_match(/^  # config\.http_basic_auth_user\s+= ENV\['PF_ADMIN_USER'\]$/, source)
        assert_match(/^  # config\.http_basic_auth_password = ENV\['PF_ADMIN_PASSWORD'\]$/, source)
        assert_includes source, 'Option A'
        assert_includes source, 'Option B'
      end

      test 'with --skip-migration there is no migrate step' do
        output = install('--skip-migration')

        assert_not_includes output, 'db:migrate'
        assert_includes output, '1. Mount the admin'
      end

      test 'rails destroy prints no next steps' do
        output = install(behavior: :revoke)

        assert_not_includes output, 'Next steps'
      end

      private

      def install(*flags, behavior: :invoke)
        Dir.mktmpdir do |root|
          capture_io { InstallGenerator.start(flags, destination_root: root, behavior: behavior) }.first
        end
      end
    end
  end
end
