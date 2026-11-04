# frozen_string_literal: true

require "net/http"
require "nokogiri"
require "uri"
require "pathname"
require "stringio"

module Indexmap
  class Parser
    Entry = Struct.new(:loc, :lastmod, :source_sitemap)

    def initialize(source: nil, rebase_remote_children: false, index_filename: Indexmap.configuration.index_filename, storage: Indexmap.configuration.storage)
      @source = (source || index_filename).to_s
      @rebase_remote_children = rebase_remote_children
      @index_filename = index_filename
      @storage = storage
    end

    def entries(reset: false)
      return reset! && entries if reset
      return @entries if defined?(@entries)

      @entries = each_entry.to_a
    end

    # Unlike entries, this does not cache or retain the URL inventory.
    def each_entry
      return enum_for(:each_entry) unless block_given?

      visited = Set.new
      pending = [@source]
      until pending.empty?
        source = normalize_source(pending.pop)
        next if source.nil? || visited.include?(source)

        visited.add(source)
        children = []
        open_source(source) do |io|
          reader = Nokogiri::XML::Reader.from_io(io, nil, nil, Nokogiri::XML::ParseOptions::NONET)
          root = nil
          reader.each do |node|
            if node.node_type == Nokogiri::XML::Reader::TYPE_DOCUMENT_TYPE
              raise ValidationError, "Sitemap DTDs are not allowed: #{source}"
            end
            next unless node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT

            root = node.local_name if node.depth == 0
            next unless node.depth == 1

            if root == "sitemapindex" && node.local_name == "sitemap"
              fields = read_fields(reader)
              child = resolve_child_sitemap(source, fields.fetch("loc").to_s.strip)
              children << child if child
            elsif root == "urlset" && node.local_name == "url"
              fields = read_fields(reader)
              loc = fields.fetch("loc").to_s.strip
              next if loc.empty?

              lastmod = fields.fetch("lastmod").to_s.strip
              yield Entry.new(loc: loc, lastmod: lastmod.empty? ? nil : lastmod, source_sitemap: source)
            end
          end
        end
        pending.concat(children.reverse)
      end
    end

    def paths(reset: false)
      return reset! && paths if reset
      return @paths if defined?(@paths)

      seen = Set.new
      @paths = entries.map do |entry|
        path = extract_path(entry.loc)
        next if path.nil?

        normalized = normalize_path(path)
        next if seen.include?(normalized)

        seen.add(normalized)
        normalized
      end.compact
    end

    def urls(base_url:, reset: false)
      return reset! && urls(base_url: base_url) if reset

      target = URI.parse(base_url)
      port_suffix = (target.port && ![80, 443].include?(target.port)) ? ":#{target.port}" : ""

      paths.map do |path|
        "#{target.scheme}://#{target.host}#{port_suffix}#{path}"
      end
    end

    def reset!
      remove_instance_variable(:@entries) if defined?(@entries)
      remove_instance_variable(:@paths) if defined?(@paths)
    end

    private

    attr_reader :index_filename, :storage

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
          text = fields.key?(name) ? (fields[name] = +"") : nil
        elsif text && [Nokogiri::XML::Reader::TYPE_TEXT, Nokogiri::XML::Reader::TYPE_CDATA,
          Nokogiri::XML::Reader::TYPE_WHITESPACE, Nokogiri::XML::Reader::TYPE_SIGNIFICANT_WHITESPACE].include?(type)
          text << reader.value
        end
      end
      fields
    end

    def resolve_child_sitemap(parent_source, loc)
      return if loc.empty?

      if remote_source?(parent_source)
        parent_uri = URI.parse(parent_source)
        if remote_source?(loc)
          remote_child_source(parent_uri, loc)
        else
          remote_child_source(parent_uri, URI.join(parent_uri.to_s, loc).to_s)
        end
      elsif remote_source?(loc)
        uri = URI.parse(loc)
        normalize_local_source(uri.path)
      else
        resolve_local_child_sitemap(parent_source, loc)
      end
    rescue URI::InvalidURIError
      resolve_local_child_sitemap(parent_source, loc)
    end

    def resolve_local_child_sitemap(parent_source, loc)
      if loc.start_with?("/")
        normalize_local_source(loc)
      else
        parent_directory = File.dirname(parent_source)
        normalize_local_source((parent_directory == ".") ? loc : File.join(parent_directory, loc))
      end
    end

    def remote_child_source(parent_uri, loc)
      child_uri = URI.parse(loc)
      if @rebase_remote_children
        child_uri.scheme = parent_uri.scheme
        child_uri.host = parent_uri.host
        child_uri.port = parent_uri.port
      end
      check_remote_origin!(child_uri)
      child_uri.to_s
    end

    def normalize_source(source)
      return if source.to_s.strip.empty?

      if remote_source?(source)
        URI.parse(source).to_s
      else
        normalize_local_source(source)
      end
    rescue URI::InvalidURIError
      nil
    end

    def normalize_local_source(source)
      normalized = Pathname(source.to_s).cleanpath.to_s.sub(%r{\A/+}, "")
      return if normalized.empty? || normalized == ".." || normalized.start_with?("../")

      normalized
    end

    def remote_source?(value)
      uri = URI.parse(value.to_s)
      uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
    rescue URI::InvalidURIError
      false
    end

    def open_source(source)
      if remote_source?(source)
        body = fetch_remote_source(source)
        yield StringIO.new(body) if body && !body.strip.empty?
      elsif storage.exist?(source)
        if storage.respond_to?(:open) && storage.respond_to?(:metadata)
          check_size!(storage.metadata(source).fetch(:bytes))
          storage.open(source) { |io| yield io }
        else
          body = storage.read(source)
          check_size!(body.bytesize)
          yield StringIO.new(body) unless body.strip.empty?
        end
      end
    end

    def check_size!(bytes)
      raise ValidationError, "Sitemap exceeds #{Validator::MAX_BYTES} bytes" if bytes > Validator::MAX_BYTES
    end

    def check_remote_origin!(uri)
      origin = URI.parse(@source)
      unless uri.is_a?(URI::HTTP) && !uri.userinfo &&
          [uri.scheme, uri.host, uri.port] == [origin.scheme, origin.host, origin.port]
        raise ValidationError, "Remote sitemap must use the source origin: #{uri}"
      end
    end

    def fetch_remote_source(source, redirects_remaining: 3)
      uri = URI.parse(source)
      check_remote_origin!(uri)
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "Indexmap::Parser/1.0"
      redirected = nil
      body = nil

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 20) do |http|
        http.request(request) do |response|
          check_size!(response.content_length) if response.content_length
          body = +"" if response.is_a?(Net::HTTPSuccess)
          if response.is_a?(Net::HTTPRedirection)
            location = response["location"].to_s
            redirected = URI.join(source, location).to_s unless location.empty? || redirects_remaining <= 0
          end
          bytes = 0
          response.read_body do |chunk|
            bytes += chunk.bytesize
            check_size!(bytes)
            body << chunk if body
          end
        end
      end
      redirected ? fetch_remote_source(redirected, redirects_remaining: redirects_remaining - 1) : body
    rescue URI::InvalidURIError
      nil
    end

    def extract_path(loc)
      return if loc.to_s.strip.empty?

      if loc.start_with?("http://", "https://")
        path = URI.parse(loc).path
        (path.nil? || path.empty?) ? "/" : path
      elsif loc.start_with?("/")
        loc
      else
        "/#{loc}"
      end
    rescue URI::InvalidURIError
      nil
    end

    def normalize_path(path)
      return "/" if path == "/"

      normalized = path.start_with?("/") ? path : "/#{path}"
      normalized.delete_suffix("/")
    end
  end
end
