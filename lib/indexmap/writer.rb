# frozen_string_literal: true

module Indexmap
  class Writer
    attr_reader :counts

    VALID_FORMATS = %i[index single_file].freeze

    def initialize(base_url:, sections: nil, entries: nil, index_filename: "sitemap.xml", format: :index, max_urls: 50_000, max_bytes: 52_428_800, generation: nil)
      @entries = entries || []
      @format = normalize_format(format)
      @sections = normalize_sections(sections)
      @base_url = base_url
      @index_filename = index_filename
      @max_urls = Integer(max_urls.to_s, 10)
      @max_bytes = Integer(max_bytes.to_s, 10)
      @generation = generation
      @counts = {}
      unless (1..Validator::MAX_ENTRIES).cover?(@max_urls) && (1..Validator::MAX_BYTES).cover?(@max_bytes)
        raise ConfigurationError, "Invalid sitemap partition limits"
      end
    end

    def write
      each_file.to_a
    end

    def each_file
      return enum_for(:each_file) unless block_given?

      if single_file?
        body, = urlset_xml(entries)
      else
        index_entries = []
        sections.each_with_index do |section, section_index|
          part = 0
          chunks(section.entries) do |body, lastmod, count|
            part += 1
            filename = if @generation
              Publication.new(root: index_filename).filename(generation: @generation, section: section_index + 1, part: part)
            elsif part == 1
              section.filename
            else
              section.filename.sub(/\.xml\z/, "-#{Kernel.format("%03d", part)}.xml")
            end
            raise ConfigurationError, "Section filenames must end in .xml" if part > 1 && filename == section.filename

            @counts[filename] = count
            index_entries << [filename, lastmod]
            raise ValidationError, "Sitemap exceeds 50,000 entries: #{index_filename}" if index_entries.size > Validator::MAX_ENTRIES

            yield write_file(filename, body)
          end
        end
        body = index_xml(index_entries)
        raise ValidationError, "Sitemap exceeds 52,428,800 bytes: #{index_filename}" if body.bytesize > @max_bytes

        @counts[index_filename] = index_entries.size
      end
      yield write_file(index_filename, body)
    end

    private

    attr_reader :base_url, :entries, :format, :index_filename, :sections

    def normalize_format(value)
      normalized = value.nil? ? :index : value.to_sym
      return normalized if VALID_FORMATS.include?(normalized)

      raise ConfigurationError, "Indexmap format must be one of: #{VALID_FORMATS.join(", ")}"
    end

    def normalize_sections(raw_sections)
      Array(raw_sections).map do |section|
        next section if section.is_a?(Section)

        Section.new(
          filename: section.fetch(:filename),
          entries: section.fetch(:entries)
        )
      end
    end

    def single_file?
      format == :single_file
    end

    def write_file(filename, body)
      Artifact.new(filename: filename, body: body, content_type: "application/xml")
    end

    HEADER = %(<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n)
    FOOTER = "</urlset>\n"

    def chunks(source)
      body = +HEADER
      latest = nil
      count = 0
      source.each do |value|
        entry = normalize_entry(value)
        xml = "  <url>\n    <loc>#{escape(entry.loc)}</loc>\n"
        timestamp = nil
        if entry.lastmod
          date = parsed_lastmod(entry.lastmod)
          xml << "    <lastmod>#{escape(date.iso8601)}</lastmod>\n"
          timestamp = comparable_lastmod(date)
        end
        xml << "  </url>\n"
        if HEADER.bytesize + xml.bytesize + FOOTER.bytesize > @max_bytes
          raise ValidationError, "Sitemap entry exceeds byte limit"
        end
        if count > 0 && (count == @max_urls || body.bytesize + xml.bytesize + FOOTER.bytesize > @max_bytes)
          yield body << FOOTER, latest, count
          body = +HEADER
          latest = nil
          count = 0
        end
        body << xml
        latest = timestamp if timestamp && (latest.nil? || timestamp > latest)
        count += 1
      end
      yield body << FOOTER, latest, count if count > 0
    end

    def urlset_xml(source)
      result = nil
      chunks(source) do |body, lastmod, count|
        raise ValidationError, "Single-file sitemap exceeds partition limits; use index format" if result

        @counts[index_filename] = count
        result = [body, lastmod]
      end
      @counts[index_filename] ||= 0
      result || [HEADER + FOOTER, nil]
    end

    def index_xml(sitemap_sections)
      lines = [
        %(<?xml version="1.0" encoding="UTF-8"?>),
        %(<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">)
      ]

      sitemap_sections.each do |filename, lastmod|
        lines << "  <sitemap>"
        lines << "    <loc>#{escape(index_loc(filename))}</loc>"
        lines << "    <lastmod>#{format_lastmod(lastmod)}</lastmod>" if lastmod
        lines << "  </sitemap>"
      end

      lines << "</sitemapindex>"
      lines.join("\n") + "\n"
    end

    def normalize_entry(entry)
      return entry if entry.is_a?(Entry)

      Entry.new(loc: entry.fetch(:loc), lastmod: entry[:lastmod])
    end

    def index_loc(filename)
      File.join(base_url.sub(%r{/\z}, ""), filename)
    end

    def format_lastmod(value)
      timestamp = parsed_lastmod(value)

      escape(timestamp.iso8601)
    end

    def comparable_lastmod(value)
      parsed = parsed_lastmod(value)
      return parsed.to_time.utc if parsed.is_a?(Date)

      parsed
    end

    def parsed_lastmod(value)
      case value
      when String
        Time.parse(value)
      when Date
        value
      when Time, DateTime
        value
      else
        value.respond_to?(:to_time) ? value.to_time : value
      end
    end

    def escape(value)
      string = value.to_s
      string = string.encode(Encoding::UTF_8) unless string.encoding == Encoding::UTF_8
      raise ValidationError, "Sitemap text must be valid UTF-8" unless string.valid_encoding?

      CGI.escapeHTML(string)
    rescue EncodingError => error
      raise ValidationError, "Sitemap text cannot be encoded as UTF-8: #{error.message}"
    end
  end
end
