# Copyright (C) 2026 Osvaldo Santana Neto
# SPDX-License-Identifier: AGPL-3.0-only
#
# Emits an Abstract Semantic Graph for AsciiDoc read on stdin, by walking
# Asciidoctor's own parse tree.
#
# Where the AsciiDoc Language specification is silent, Asciidoctor is the de
# facto reference, so comparing against it finds real disagreements far faster
# than writing expectations by hand.
#
# Two things this is NOT:
#
#   * It is not an authority. Asciidoctor does not produce an ASG; its tree is
#     its own. Everything below is *our reading* of how the two correspond, so a
#     disagreement means one of the two is wrong — and sometimes it is this
#     mapping.
#
#   * It does not carry positions. Asciidoctor's sourcemap records the line a
#     block starts on and nothing else: no end line, no columns. Locations are
#     therefore omitted here and compared separately, against the TCK's own
#     cases and against our range invariants.
#
# Usage:
#
#   ruby tools/asciidoctor-oracle.rb < document.adoc

begin
  require 'asciidoctor'
rescue LoadError
  # Homebrew installs the gem into its own GEM_HOME rather than the system one,
  # so find it here rather than making every caller export a variable.
  prefix = `brew --prefix asciidoctor 2>/dev/null`.strip
  lib = prefix.empty? ? nil : Dir.glob(File.join(prefix, 'libexec', 'gems', 'asciidoctor-*', 'lib')).first
  abort 'asciidoctor is not installed (try: brew install asciidoctor)' unless lib

  $LOAD_PATH.unshift lib
  require 'asciidoctor'
end

require 'json'

# Asciidoctor applies substitutions when asked for a title or an item's text.
# The raw source is what a parser should be compared against.
def raw(node, name)
  value = node.instance_variable_get(name)
  value.is_a?(String) ? value : nil
end

def text_node(value)
  return nil if value.nil? || value.empty?

  { 'name' => 'text', 'type' => 'string', 'value' => value }
end

def encode_block(block)
  case block.context
  when :section
    {
      'name' => 'section',
      'type' => 'block',
      'level' => block.level,
      'title' => [text_node(raw(block, :@title))].compact,
      'blocks' => block.blocks.map { |child| encode_block(child) }.compact
    }

  when :paragraph
    {
      'name' => 'paragraph',
      'type' => 'block',
      'inlines' => [text_node(block.lines.join("\n"))].compact
    }

  when :listing, :literal, :pass
    {
      'name' => block.context.to_s,
      'type' => 'block',
      'form' => 'delimited',
      'inlines' => [text_node(block.lines.join("\n"))].compact
    }

  when :quote, :example, :sidebar, :open
    {
      'name' => block.context.to_s,
      'type' => 'block',
      'form' => 'delimited',
      'blocks' => block.blocks.map { |child| encode_block(child) }.compact
    }

  when :ulist, :olist
    {
      'name' => 'list',
      'type' => 'block',
      'variant' => block.context == :olist ? 'ordered' : 'unordered',
      'items' => block.items.map do |item|
        {
          'name' => 'listItem',
          'type' => 'block',
          'principal' => [text_node(raw(item, :@text))].compact
        }
      end
    }

  else
    # Admonitions, tables, description lists and the rest. Named rather than
    # dropped, so a disagreement about *which* construct something is shows up
    # as a difference instead of as silence.
    {
      'name' => block.context.to_s,
      'type' => 'block'
    }
  end
end

source = ARGF.read
document = Asciidoctor.load(source, sourcemap: true, safe: :safe, parse: true)

graph = {
  'name' => 'document',
  'type' => 'block'
}

if document.header?
  graph['header'] = { 'title' => [text_node(document.attributes['doctitle'])].compact }
end

blocks = document.blocks.map { |block| encode_block(block) }.compact
graph['blocks'] = blocks unless blocks.empty?

puts JSON.pretty_generate(graph)
