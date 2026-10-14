require 'erb'

# Renders the install generator's ERB templates the way the generator does,
# with the generator's defaults for anything a test does not set.
module InstallTemplates
  DIRECTORY = File.expand_path('../../lib/generators/permission_forge/install/templates', __dir__)

  DEFAULTS = {
    migration_version: '[7.1]',
    table_prefix: 'permission_forge_',
    tenant_column: nil,
    tenant_model: nil,
    user_id_type: 'bigint',
    tenant_id_type: 'bigint'
  }.freeze

  CONFIGURE_CALL = 'PermissionForge.configure do |config|'.freeze

  private

  def render_install_template(name, **locals)
    locals = DEFAULTS.merge(locals)
    context = Struct.new(*locals.keys).new(*locals.values)
    ERB.new(File.read(File.join(DIRECTORY, name))).result(context.instance_eval { binding })
  end

  # What the generated initializer configures, on a fresh Configuration (the
  # suite's own configuration is left alone).
  #
  # @return [PermissionForge::Configuration]
  def install_template_configuration(**locals)
    source = render_install_template('initializer.rb.tt', **locals)
    raise "the initializer no longer calls #{CONFIGURE_CALL}" unless source.include?(CONFIGURE_CALL)

    config = PermissionForge::Configuration.new
    configurer = Object.new
    configurer.define_singleton_method(:configure) { |&block| block.call(config) }
    configurer.instance_eval(source.sub(CONFIGURE_CALL, 'configure do |config|'), 'initializer.rb.tt')
    config
  end
end
