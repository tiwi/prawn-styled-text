require 'oga'
require_relative 'callbacks'
require_relative 'prawn-document'

module PrawnStyledText
  class AdjustFontSizeError < StandardError
    def message
      "Adjust font size method has to respond to calls method"
    end
  end

  BLOCK_TAGS = [ :br, :div, :h1, :h2, :h3, :h4, :h5, :h6, :hr, :li, :p, :ul, :ol ]
  DEF_BG_MARK = 'ffffff'
  DEF_HEADING_T = 16
  DEF_HEADING_H = 8
  DEF_MARGIN_UL = 15
  DEF_SYMBOL_UL = "\x95 "
  HEADINGS = { h1: 32, h2: 24, h3: 20, h4: 16, h5: 14, h6: 13 }
  RENAME = { 'font-family': :font, 'font-size': :size, 'font-style': :styles, 'letter-spacing': :character_spacing, 'background-color': :background }

  @@margin_ul = 0
  @@symbol_ul = ''
  @@last_el = nil

  def self.adjust_values(pdf, values, adjust_font_size)
    ret = {}
    values.each do |k, v|
      key = k.to_sym
      key = RENAME[key] if RENAME.include?( key )
      ret[key] = case key
        when :character_spacing
          v.to_f
        when :color, :background
          parse_color( v )
        when :font
          matches = v.match /'([^']*)'|"([^"]*)"|(.*)/
          matches[3] || matches[2] || matches[1] || ''
        when :height
          i = v.to_i
          v.include?( '%' ) ? ( i * pdf.bounds.height * 0.01 ) : i
        when :size
          parse_size(pdf, v, adjust_font_size)
        when :styles
          v.split( ',' ).map { |s| s.strip.to_sym }
        when :width
          i = v.to_i
          v.include?( '%' ) ? ( i * pdf.bounds.width * 0.01 ) : i
        else
          v
        end
    end
    ret
  end

  def self.closing_tag(pdf, data, adjust_font_size)
    context = { tag: data[:name], options: {} }
    context[:flush] ||= true if BLOCK_TAGS.include? data[:name]
    # Evalutate tag
    case data[:name]
    when :br # new line
      context[:text] ||= [ { text: "\n" } ] if @@last_el == :br
    when :img # image
      context[:flush] ||= true
      context[:src] = data[:node].get 'src'
    when :ul
      @@margin_ul = 0
    when :ol
      @@margin_ul = 0
      @@current_index = nil
    end
    # Evalutate attributes
    attributes = data[:node].get 'style'
    context[:options] = adjust_values( pdf, attributes.scan( /\s*([^:]+):\s*([^;]+)[;]*/ ), adjust_font_size ) if attributes
    context
  end

  def self.opening_tag(pdf, data, adjust_font_size)
    context = { tag: data[:name], options: {} }
    context[:flush] ||= true if BLOCK_TAGS.include? data[:name]
    # Evalutate attributes
    attributes = data[:node].get 'style'

    if attributes
      context[:options].merge!(
        adjust_values(pdf, attributes.scan( /\s*([^:]+):\s*([^;]+)[;]*/ ), adjust_font_size)
      )
    end

    tag_name = data[:name]
    if [:ul, :ol].include?(tag_name)
      @@margin_ul += ( context[:options][:'margin-left'] ? context[:options][:'margin-left'].to_i : DEF_MARGIN_UL )

      if tag_name == :ul
        @@symbol_ul = if context[:options][:'list-symbol']
            matches = context[:options][:'list-symbol'].match /'([^']*)'|"([^"]*)"|(.*)/
            matches[3] || matches[2] || matches[1] || ''
          else
            DEF_SYMBOL_UL
          end
      else
        @@current_index = 1
      end
    end
    context
  end

  def self.text_node(pdf, data, adjust_font_size)
    context = { pre: '', options: {} }
    styles = []
    font_size = pdf.font_size
    data.each do |part|
      # Evalutate tag
      tag = part[:name]
      case tag
      when :a # link
        link = part[:node].get 'href'
        context[:options][:link] = link if link
      when :b, :strong # bold
        styles.push :bold
      when :del, :s
        @@strike_through ||= StrikeThroughCallback.new( pdf )
        context[:options][:callback] = @@strike_through
      when :h1, :h2, :h3, :h4, :h5, :h6
        context[:options][:size] = HEADINGS[tag]
        context[:options][:'margin-top'] = DEF_HEADING_T
        context[:options][:'line-height'] = DEF_HEADING_H
      when :i, :em # italic
        styles.push :italic
      when :li # list item
        context[:options][:'margin-left'] = @@margin_ul
        if defined?(@@current_index) && @@current_index
          context[:pre] = "#{@@current_index}. "
          @@current_index += 1
        else
          context[:pre] = @@symbol_ul.force_encoding( 'windows-1252' ).encode( 'UTF-8' )
        end
      when :mark, :span
        @@highlight = HighlightCallback.new( pdf )
        @@highlight.set_color nil
        context[:options][:callback] = @@highlight
      when :small
        context[:options][:size] = font_size * 0.66
      when :u, :ins # underline
        styles.push :underline
      when :font
        attributes = {
          font: part[:node]['face'],
          color: part[:node]['color'],
          size: part[:node]['size']
        }.delete_if { |k, v| v.nil? }
        values = adjust_values(pdf, attributes, adjust_font_size)
        context[:options].merge! values
      end
      context[:options][:styles] = styles if styles.any?
      # Evalutate attributes
      attributes = part[:node].get 'style'
      if attributes
        values = adjust_values(pdf, attributes.scan( /\s*([^:]+):\s*([^;]+)[;]*/ ), adjust_font_size)
        @@highlight.set_color( values[:background] ) if values[:background]
        context[:options].merge! values
      end
      font_size = context[:options][:size] if font_size
    end
    context
  end

  def self.traverse( nodes, context = [], &block )
    nodes.each do |node|
      if node.is_a? Oga::XML::Text
        text = node.text.delete( "\n\r" )
        yield :text_node, text, context
        @@last_el = nil unless text.empty?
      elsif node.is_a? Oga::XML::Element
        element = { name: node.name.to_sym, node: node }
        yield :opening_tag, element[:name], element
        context.push( element )
        traverse( node.children, context, &block ) if node.children.count > 0
        yield :closing_tag, element[:name], context.pop
        @@last_el = element[:name]
      end
    end
  end

  private

  def self.parse_color( value )
    if value.start_with?( 'rgb' )
      matches = /rgb\((?<numbers>.*)\)/.match( value )
      numbers = matches[:numbers].split(',').map(&:strip)
      numbers.map { |n| n.to_i.to_s(16).rjust(2, '0') }.join
    else
      value.delete( '#' )
    end
  end

  def self.parse_size(pdf, value, adjust_font_size = nil)
    size =
      if value.include? 'em'
        (pdf.font_size * value.to_f).to_i
      else
        value.to_i
      end

    return size unless adjust_font_size

    adjust_font_size.call(size)
  end
end
