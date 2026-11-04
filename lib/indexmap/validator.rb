# frozen_string_literal: true

require "nokogiri"
require "date"
require "time"
require "uri"

module Indexmap
  class Validator
    MAX_ENTRIES = 50_000
    MAX_BYTES = 52_428_800

    attr_reader :entries

    def initialize(configuration: Indexmap.configuration, filename: nil)
      @configuration = configuration
      @filename = filename
    end

    def validate!
      sitemap_filename = filename || configuration.index_filename
      raise ValidationError, "Missing sitemap file: #{sitemap_filename}" unless storage.exist?(sitemap_filename)

      @entries = validate_sitemap_files!(sitemap_filename)
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

    attr_reader :configuration, :filename

    def storage
      configuration.storage
    end

    def validate_sitemap_files!(sitemap_filename)
      pending = [[sitemap_filename, false]]
      active = Set.new
      visited = Set.new
      entries = []

      until pending.empty?
        name, leaving = pending.pop
        if leaving
          active.delete(name)
          next
        end
        raise ValidationError, "Sitemap cycle detected: #{name}" if active.include?(name)
        next if visited.include?(name)

        active.add(name)
        visited.add(name)
        pending << [name, true]
        document = read_xml_document(name)
        case document.root&.name
        when "urlset"
          entries.concat(validate_urlset_document!(document, name))
        when "sitemapindex"
          validate_sitemap_index_document!(document, name).reverse_each { |child| pending << [child, false] }
        else
          raise ValidationError, "Invalid sitemap root element in #{name}: #{document.root&.name || "none"}"
        end
      end

      entries
    end

    def read_xml_document(filename)
      body = storage.read(filename)
      raise ValidationError, "Sitemap exceeds 52,428,800 bytes: #{filename}" if body.bytesize > MAX_BYTES

      document = Nokogiri::XML(body) { |config| config.strict.nonet }
      raise ValidationError, "Sitemap DTDs are not allowed: #{filename}" if document.internal_subset
      if document.root && document.root.namespace&.href != "http://www.sitemaps.org/schemas/sitemap/0.9"
        raise ValidationError, "Invalid sitemap namespace: #{filename}"
      end

      document.remove_namespaces!
      document
    rescue Nokogiri::XML::SyntaxError => error
      raise ValidationError, "Invalid sitemap XML in #{filename}: #{error.message.lines.first.strip}"
    end

    def validate_urlset_document!(document, sitemap_filename)
      urls = document.xpath("/urlset/url")
      raise ValidationError, "Sitemap exceeds 50,000 entries: #{sitemap_filename}" if urls.size > MAX_ENTRIES
      raise ValidationError, "Sitemap has no URLs: #{sitemap_filename}" if urls.empty?

      urls.map do |url|
        lastmod = url.at_xpath("lastmod")&.text.to_s.strip
        Parser::Entry.new(loc: location_for(url, filename: sitemap_filename), lastmod: lastmod.empty? ? nil : lastmod, source_sitemap: sitemap_filename)
      end
    end

    def validate_sitemap_index_document!(document, sitemap_filename)
      if document.xpath("/sitemapindex/sitemap").size > MAX_ENTRIES
        raise ValidationError, "Sitemap exceeds 50,000 entries: #{sitemap_filename}"
      end
      child_locations = document.xpath("/sitemapindex/sitemap").map { |node| location_for(node, filename: sitemap_filename) }
      raise ValidationError, "Sitemap index has no child sitemap URLs: #{sitemap_filename}" if child_locations.empty?

      duplicate_children = child_locations.group_by(&:itself).select { |_loc, values| values.size > 1 }.keys
      unless duplicate_children.empty?
        raise ValidationError, "Duplicate child sitemap URLs detected: #{duplicate_children.first(5).join(", ")}"
      end

      child_locations.map do |location|
        child_filename = local_child_filename(location, parent_filename: sitemap_filename)
        raise ValidationError, "Missing child sitemap file: #{child_filename}" unless storage.exist?(child_filename)

        child_filename
      end
    end

    def location_for(node, filename:)
      locations = node.xpath("loc")
      location = locations.first&.text.to_s.strip
      if locations.size != 1 || location.empty?
        raise ValidationError, "Sitemap entry must have one nonempty loc: #{filename}"
      end
      location
    end

    def local_child_filename(location, parent_filename:)
      uri = URI.parse(location)
      base_uri = URI.parse(configuration.base_url)
      if uri.query || uri.fragment || uri.userinfo || (uri.host &&
          [uri.scheme, uri.host, uri.port] != [base_uri.scheme, base_uri.host, base_uri.port]) ||
          (uri.scheme && !%w[http https].include?(uri.scheme))
        raise ValidationError, "Invalid child sitemap URL: #{location}"
      end
      if uri.absolute? || location.start_with?("/")
        normalize_local_filename(uri.path)
      else
        parent_directory = File.dirname(parent_filename)
        normalize_local_filename((parent_directory == ".") ? location : File.join(parent_directory, location))
      end
    rescue URI::InvalidURIError
      raise ValidationError, "Invalid child sitemap URL: #{location}"
    end

    def normalize_local_filename(filename)
      normalized = Pathname(filename.to_s).cleanpath.to_s.sub(%r{\A/+}, "")
      if normalized.empty? || normalized == ".." || normalized.start_with?("../")
        raise ValidationError, "Invalid child sitemap filename: #{filename}"
      end

      normalized
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

        if entry.lastmod.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          Date.iso8601(entry.lastmod)
        else
          Time.iso8601(entry.lastmod)
        end
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
