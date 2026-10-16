# frozen_string_literal: true

require 'prism'
require_relative 'static_guard'

# Every PermissionForge::Warnings.emit call of the gem (BootWarningsChannelTest's
# severity and audience guards): [key, severity as written, file:line,
# audience as written]. The key of an interpolated one is its static part
# ("masked_models.unmaskable."); a site that passes no severity is 'config'
# (the default), no audience 'all' (the default); a computed one is its
# expression ("SEVERITY.fetch(setting, :config)").
module EmitSites
  module_function

  def all(paths)
    paths.flat_map do |path|
      found = []
      walk(Prism.parse_file(path).value) { |node| found << site(node, path) }
      found
    end
  end

  def walk(node, &block)
    yield node if emit?(node)
    node.compact_child_nodes.each { |child| walk(child, &block) }
  end

  def emit?(node)
    node.is_a?(Prism::CallNode) && node.name == :emit && node.receiver&.slice.to_s.end_with?('Warnings')
  end

  def site(node, path)
    arguments = node.arguments&.arguments || []
    [key(arguments.first), severity(arguments), "#{Pathname(path).relative_path_from(StaticGuard::ROOT)}:#{node.location.start_line}",
     option(arguments, 'audience:', 'all')]
  end

  def key(argument)
    argument.slice.delete_prefix(':').delete('"').sub(/\#\{.*\z/, '')
  end

  def severity(arguments) = option(arguments, 'severity:', 'config')

  # The keyword `name` as written (a Symbol without its colon), else `default`.
  def option(arguments, name, default)
    options = arguments.find { |argument| argument.is_a?(Prism::KeywordHashNode) }
    option = options&.elements&.find { |element| element.key.slice == name }
    option ? option.value.slice.delete_prefix(':') : default
  end
end
