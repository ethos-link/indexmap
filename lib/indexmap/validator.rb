# frozen_string_literal: true

require "nokogiri"
require "date"
require "time"
require "uri"

module Indexmap
  class Validator
    def initialize(configuration: Indexmap.configuration, path: nil)
      @configuration = configuration
      @path = path
    end

    def validate!
      sitemap_path = path || Indexmap::Path.existing_public_path(
        public_path: configuration.public_path,
        index_filename: configuration.index_filename
      )
      raise ValidationError, "Missing sitemap file: #{sitemap_path}" unless File.exist?(sitemap_path)

      validate_sitemap_file!(sitemap_path)
      entries = Parser.new(path: sitemap_path).entries
      validate_presence!(entries)
      validate_duplicates!(entries)
      validate_parameterized_urls!(entries)
      validate_fragment_urls!(entries)
      validate_absolute_http_urls!(entries)
      validate_same_host_urls!(entries)
      validate_lastmods!(entries)
      true
    end

    private

    attr_reader :configuration, :path

    def validate_sitemap_file!(sitemap_path)
      document = read_xml_document(sitemap_path)
      root_name = document.root&.name

      case root_name
      when "urlset"
        validate_urlset_document!(document, sitemap_path)
      when "sitemapindex"
        validate_sitemap_index_document!(document, sitemap_path)
      else
        raise ValidationError, "Invalid sitemap root element in #{sitemap_path}: #{root_name || "none"}"
      end
    end

    def read_xml_document(file_path)
      document = Nokogiri::XML(File.read(file_path, encoding: "UTF-8")) { |config| config.strict }
      document.remove_namespaces!
      document
    rescue Nokogiri::XML::SyntaxError => error
      raise ValidationError, "Invalid sitemap XML in #{file_path}: #{error.message.lines.first.strip}"
    end

    def validate_urlset_document!(document, sitemap_path)
      return if document.xpath("/urlset/url/loc").any?

      raise ValidationError, "Sitemap has no URLs: #{sitemap_path}"
    end

    def validate_sitemap_index_document!(document, sitemap_path)
      child_locations = document.xpath("/sitemapindex/sitemap/loc").map { |node| node.text.to_s.strip }.reject(&:empty?)
      raise ValidationError, "Sitemap index has no child sitemap URLs: #{sitemap_path}" if child_locations.empty?

      duplicate_children = child_locations.group_by(&:itself).select { |_loc, values| values.size > 1 }.keys
      unless duplicate_children.empty?
        raise ValidationError, "Duplicate child sitemap URLs detected: #{duplicate_children.first(5).join(", ")}"
      end

      child_locations.each do |location|
        child_path = local_child_path(sitemap_path, location)
        raise ValidationError, "Missing child sitemap file: #{child_path}" unless File.exist?(child_path)

        validate_sitemap_file!(child_path)
      end
    end

    def local_child_path(sitemap_path, location)
      uri = URI.parse(location)
      filename = (uri.absolute? || location.start_with?("/")) ? File.basename(uri.path) : location
      File.expand_path(filename, File.dirname(sitemap_path))
    rescue URI::InvalidURIError
      File.expand_path(location, File.dirname(sitemap_path))
    end

    def validate_presence!(entries)
      return unless entries.empty?

      raise ValidationError, "Sitemap has no URLs"
    end

    def validate_duplicates!(entries)
      duplicates = entries.map(&:loc).group_by(&:itself).select { |_url, values| values.size > 1 }.keys
      return if duplicates.empty?

      raise ValidationError, "Duplicate sitemap URLs detected: #{duplicates.first(5).join(", ")}"
    end

    def validate_parameterized_urls!(entries)
      param_urls = entries.map(&:loc).select { |url| url&.include?("?") }
      return if param_urls.empty?

      raise ValidationError, "Parameterized sitemap URLs detected: #{param_urls.first(5).join(", ")}"
    end

    def validate_fragment_urls!(entries)
      fragment_urls = entries.map(&:loc).select { |url| parse_uri(url)&.fragment }
      return if fragment_urls.empty?

      raise ValidationError, "Fragment sitemap URLs detected: #{fragment_urls.first(5).join(", ")}"
    end

    def validate_absolute_http_urls!(entries)
      invalid_urls = entries.map(&:loc).reject do |url|
        uri = parse_uri(url)
        uri&.absolute? && %w[http https].include?(uri.scheme)
      end
      return if invalid_urls.empty?

      raise ValidationError, "Invalid sitemap URLs detected: #{invalid_urls.first(5).join(", ")}"
    end

    def validate_same_host_urls!(entries)
      base_uri = parse_uri(configuration.base_url)
      return unless base_uri&.host

      invalid_urls = entries.map(&:loc).reject do |url|
        uri = parse_uri(url)
        uri&.host == base_uri.host && uri&.scheme == base_uri.scheme && uri&.port == base_uri.port
      end
      return if invalid_urls.empty?

      raise ValidationError, "Sitemap URLs outside configured base URL detected: #{invalid_urls.first(5).join(", ")}"
    end

    def validate_lastmods!(entries)
      invalid_entries = entries.select do |entry|
        next false if entry.lastmod.nil?

        Date.iso8601(entry.lastmod)
        false
      rescue ArgumentError
        true
      end
      return if invalid_entries.empty?

      raise ValidationError, "Invalid sitemap lastmod values detected: #{invalid_entries.first(5).map(&:loc).join(", ")}"
    end

    def parse_uri(url)
      URI.parse(url.to_s)
    rescue URI::InvalidURIError
      nil
    end
  end
end
