# frozen_string_literal: true

require "nokogiri"
require "date"
require "time"
require "uri"
require "tmpdir"
require "stringio"
require "json"

module Indexmap
  class Validator
    MAX_ENTRIES = 50_000
    MAX_BYTES = 52_428_800

    attr_reader :entries

    def initialize(configuration: Indexmap.configuration, filename: nil, storage: nil)
      @configuration = configuration
      @storage = storage
      @filename = filename
    end

    def validate!(collect: true)
      sitemap_filename = filename || configuration.index_filename
      raise ValidationError, "Missing sitemap file: #{sitemap_filename}" unless storage.exist?(sitemap_filename)

      @entries = []
      count = 0
      Dir.mktmpdir("indexmap-validation") do |directory|
        duplicates = Duplicates.new(directory: directory)
        validate_sitemap_files!(sitemap_filename) do |entry|
          validate_parameterized_urls!([entry])
          validate_fragment_urls!([entry])
          validate_absolute_http_urls!([entry])
          validate_same_host_urls!([entry])
          validate_lastmods!([entry])
          yield entry if block_given?
          duplicates.add(entry.loc)
          @entries << entry if collect
          count += 1
        end
        duplicates.validate!
      end
      raise ValidationError, "Sitemap has no URLs" if count == 0

      true
    end

    def each_entry
      return enum_for(:each_entry) unless block_given?

      Dir.mktmpdir("indexmap-entries") do |directory|
        path = File.join(directory, "entries.jsonl")
        File.open(path, "wb") do |file|
          validate!(collect: false) { |entry| file.puts(JSON.generate(entry.to_h)) }
        end
        File.foreach(path) do |line|
          yield Parser::Entry.new(**JSON.parse(line, symbolize_names: true))
        end
      end
    end

    private

    attr_reader :configuration, :filename

    def storage
      @storage ||= configuration.storage
    end

    def validate_sitemap_files!(sitemap_filename)
      pending = [[sitemap_filename, false]]
      active = Set.new
      visited = Set.new
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
        children = read_sitemap(name) { |entry| yield entry }
        children.reverse_each { |child| pending << [child, false] }
      end
    end

    def read_sitemap(filename)
      children = []
      root = nil
      count = 0
      open_sitemap(filename) do |io|
        reader = Nokogiri::XML::Reader.from_io(io, nil, nil, Nokogiri::XML::ParseOptions::NONET)
        reader.each do |node|
          if node.node_type == Nokogiri::XML::Reader::TYPE_DOCUMENT_TYPE
            raise ValidationError, "Sitemap DTDs are not allowed: #{filename}"
          end
          next unless node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT

          if node.depth == 0
            unless Encoding.find(reader.encoding || "UTF-8") == Encoding::UTF_8
              raise ValidationError, "Sitemap must use UTF-8 encoding: #{filename}"
            end
            root = node.local_name
            unless %w[urlset sitemapindex].include?(root)
              raise ValidationError, "Invalid sitemap root element in #{filename}: #{root}"
            end
            unless node.namespace_uri == "http://www.sitemaps.org/schemas/sitemap/0.9"
              raise ValidationError, "Invalid sitemap namespace: #{filename}"
            end
          elsif node.depth == 1 && node.local_name == ((root == "urlset") ? "url" : "sitemap")
            count += 1
            raise ValidationError, "Sitemap exceeds 50,000 entries: #{filename}" if count > MAX_ENTRIES

            fields = read_fields(reader)
            location = location_for(fields, filename: filename)
            if root == "urlset"
              lastmod = fields.fetch("lastmod").to_s.strip
              yield Parser::Entry.new(loc: location, lastmod: lastmod.empty? ? nil : lastmod, source_sitemap: filename)
            else
              child = local_child_filename(location, parent_filename: filename)
              children << child
            end
          end
        end
      end
      if count == 0
        message = (root == "sitemapindex") ? "Sitemap index has no child sitemap URLs" : "Sitemap has no URLs"
        raise ValidationError, "#{message}: #{filename}"
      end
      children.each { |child| raise ValidationError, "Missing child sitemap file: #{child}" unless storage.exist?(child) }
      if children.uniq.size != children.size
        raise ValidationError, "Duplicate child sitemap URLs detected: #{filename}"
      end
      children
    rescue Nokogiri::XML::SyntaxError => error
      raise ValidationError, "Invalid sitemap XML in #{filename}: #{error.message.lines.first.strip}"
    end

    def open_sitemap(filename, &block)
      if storage.respond_to?(:open) && storage.respond_to?(:metadata)
        if storage.metadata(filename).fetch(:bytes) > MAX_BYTES
          raise ValidationError, "Sitemap exceeds 52,428,800 bytes: #{filename}"
        end
        storage.open(filename, &block)
      else
        body = storage.read(filename)
        raise ValidationError, "Sitemap exceeds 52,428,800 bytes: #{filename}" if body.bytesize > MAX_BYTES

        yield StringIO.new(body)
      end
    end

    def read_fields(reader)
      fields = {"loc" => nil, "lastmod" => nil}
      return fields if reader.self_closing?

      text = nil
      while reader.read
        type = reader.node_type
        if type == Nokogiri::XML::Reader::TYPE_END_ELEMENT
          break if reader.depth == 1

          text = nil if reader.depth == 2
        elsif type == Nokogiri::XML::Reader::TYPE_ELEMENT && reader.depth == 2
          name = reader.local_name
          if fields.key?(name)
            raise ValidationError, "Repeated sitemap field: #{name}" if fields[name]

            fields[name] = +""
            text = reader.self_closing? ? nil : fields[name]
          else
            text = nil
          end
        elsif text && [Nokogiri::XML::Reader::TYPE_TEXT, Nokogiri::XML::Reader::TYPE_CDATA,
          Nokogiri::XML::Reader::TYPE_WHITESPACE, Nokogiri::XML::Reader::TYPE_SIGNIFICANT_WHITESPACE].include?(type)
          text << reader.value
        end
      end
      fields
    end

    def location_for(fields, filename:)
      location = fields.fetch("loc").to_s.strip
      if location.empty?
        raise ValidationError, "Sitemap entry must have one nonempty loc: #{filename}"
      end
      raise ValidationError, "Sitemap loc must be shorter than 2,048 characters: #{filename}" if location.length >= 2048

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
        uri&.absolute? && %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo
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

require_relative "validator/duplicates"
