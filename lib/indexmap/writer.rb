# frozen_string_literal: true

module Indexmap
  class Writer
    VALID_FORMATS = %i[index single_file].freeze

    def initialize(public_path:, base_url:, sections: nil, entries: nil, index_filename: "sitemap.xml", format: :index)
      @entries = normalize_entries(entries)
      @format = normalize_format(format)
      @sections = normalize_sections(sections)
      @public_path = Pathname(public_path)
      @base_url = base_url
      @index_filename = index_filename
    end

    def write
      FileUtils.mkdir_p(public_path)

      return public_path.join(index_filename).write(urlset_xml(entries)) if single_file?

      sections.each do |section|
        public_path.join(section.filename).write(urlset_xml(section.entries))
      end

      public_path.join(index_filename).write(index_xml(sections))
    end

    private

    attr_reader :base_url, :entries, :format, :index_filename, :public_path, :sections

    def normalize_entries(raw_entries)
      Array(raw_entries).map { |entry| normalize_entry(entry) }
    end

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

    def urlset_xml(entries)
      lines = [
        %(<?xml version="1.0" encoding="UTF-8"?>),
        %(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">)
      ]

      entries.each do |entry|
        sitemap_entry = normalize_entry(entry)
        lines << "  <url>"
        lines << "    <loc>#{escape(sitemap_entry.loc)}</loc>"
        lines << "    <lastmod>#{format_lastmod(sitemap_entry.lastmod)}</lastmod>" if sitemap_entry.lastmod
        lines << "  </url>"
      end

      lines << "</urlset>"
      lines.join("\n") + "\n"
    end

    def index_xml(sitemap_sections)
      lines = [
        %(<?xml version="1.0" encoding="UTF-8"?>),
        %(<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">)
      ]

      sitemap_sections.each do |section|
        lines << "  <sitemap>"
        lines << "    <loc>#{escape(index_loc(section.filename))}</loc>"
        lines << "    <lastmod>#{format_lastmod(section_lastmod(section))}</lastmod>"
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

    def section_lastmod(section)
      timestamps = Array(section.entries).map { |entry| comparable_lastmod(normalize_entry(entry).lastmod) }.compact
      timestamps.max || Time.now.utc
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
      CGI.escapeHTML(value.to_s)
    end
  end
end
