source 'https://rubygems.org'

gemspec

group :development, :test do
  gem 'acts_as_tenant', '~> 2.0'
  gem 'bcrypt', '~> 3.1' # the docs app (test/support/docs_app.rb): has_secure_password, as `bin/rails generate authentication` needs it
  gem 'brakeman', require: false
  gem 'bundler-audit', require: false
  gem 'i18n-tasks', '~> 1.0', require: false
  gem 'jbuilder', '~> 2.12' # the docs app: the scaffold's jbuilder partial the getting-started guide rewrites
  gem 'oj', '~> 3.16', require: false # Optional: faster JSON for cache backends
  gem 'pg', '~> 1.5' # Postgres RLS enforcement tests (DB=postgres rake test:rls)
  gem 'puma', '>= 8.0.2'
  gem 'redis', '~> 6.0', require: false # the live-Redis cache tests (redis://127.0.0.1:6379/15; they skip without a server)
  gem 'reek', '~> 6.3', require: false
  gem 'rubocop', '~> 1.68', require: false
  gem 'simplecov', '~> 1.2', require: false
  gem 'sqlite3', '~> 2.0'
  gem 'yard', '~> 0.9', require: false
  gem 'yard-activesupport-concern', '~> 0.0.1', require: false # the YARD plugin .yardopts loads
end
