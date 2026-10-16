# frozen_string_literal: true

require 'prism'
require_relative 'static_guard'

# Per-method placement of the lines StaticGuard finds (R2 review, P1-5): a
# hit is measured when it sits inside the block of a measuring call
# (`Cache::Report.of { }`, `Cache::Report.measure { }`, `report.measure { }`,
# `cache_outcome { }`), or inside a method every caller of which, in the
# same file, is measured itself (a private helper of a measured block). A
# method nobody in its file calls is not measured: a hit there is reported.
#
#   MeasuredCalls.unmeasured(globs: %w[lib/**/*.rb], needle: /invalidate_permissions/)
module MeasuredCalls
  # The calls whose block is measured, by name; `of` and `measure` only on a
  # receiver that names a report. `settle_cache` (Services::Concerns::
  # SettlesCache) runs its block only inside Cache::Report.of.
  MEASURING = { of: /Report\z/, measure: /report\z/i, cache_outcome: nil, settle_cache: nil }.freeze

  # One parsed file: the line ranges of the measuring blocks, its methods
  # (`defs`: name and lines) and where each method name is called.
  Parsed = Struct.new(:measured, :defs, :calls) do
    def measured_line?(line) = measured.any? { |range| range.cover?(line) }

    # The innermost method around `line`, or nil at the file's top level.
    def method_at(line)
      defs.select { |_, range| range.cover?(line) }.min_by { |_, range| range.size }
    end

    # Whether `line` is measured: in a measuring block, or in a method all
    # of whose callers are (and that has at least one).
    def reached_measured?(line, seen = [])
      return true if measured_line?(line)

      name, range = method_at(line)
      return false unless name && seen.exclude?(name)

      sites = calls.fetch(name, []).reject { |site| range.cover?(site) }
      sites.any? && sites.all? { |site| reached_measured?(site, seen + [name]) }
    end
  end

  module_function

  # @return [Array<StaticGuard::Hit>] the hits of `needle` in `globs` that are
  #   not measured, minus `allowlist` entries (StaticGuard's format)
  def unmeasured(globs:, needle:, allowlist: [])
    StaticGuard.all_hits(globs: globs, needle: needle).reject do |hit|
      StaticGuard.allowed?(hit, allowlist) || parse(hit.file).reached_measured?(hit.line_number)
    end
  end

  def parse(file)
    @parsed ||= {}
    @parsed[file] ||= begin
      parsed = Parsed.new([], [], Hash.new { |hash, key| hash[key] = [] })
      walk(Prism.parse_file(StaticGuard::ROOT.join(file).to_s).value, parsed)
      parsed
    end
  end

  def walk(node, parsed)
    return unless node

    case node
    when Prism::DefNode then parsed.defs << [node.name, lines(node)]
    when Prism::CallNode then note_call(node, parsed)
    end
    node.compact_child_nodes.each { |child| walk(child, parsed) }
  end

  def note_call(node, parsed)
    receiver = node.receiver
    parsed.calls[node.name] << node.location.start_line if receiver.nil? || receiver.is_a?(Prism::SelfNode)
    block = node.block
    parsed.measured << lines(block) if block.is_a?(Prism::BlockNode) && measuring?(node)
  end

  def measuring?(node)
    return false unless MEASURING.key?(node.name)

    receiver = MEASURING[node.name]
    receiver.nil? ? node.receiver.nil? : node.receiver&.slice.to_s.match?(receiver)
  end

  def lines(node)
    location = node.location
    location.start_line..location.end_line
  end
end
