# frozen_string_literal: true

require "net/http"
require "nokogiri"
require "uri"

module Indexmap
  class Parser
    Entry = Struct.new(:loc, :lastmod, :source_sitemap, keyword_init: true)

    def initialize(source: nil, rebase_remote_children: false, index_filename: Indexmap.configuration.index_filename, storage: Indexmap.configuration.storage)
      @source = (source || index_filename).to_s
      @rebase_remote_children = rebase_remote_children
      @index_filename = index_filename
      @storage = storage
    end

    def entries(reset: false)
      return reset! && entries if reset
      return @entries if defined?(@entries)

      visited = Set.new
      @entries = parse_source(@source, visited: visited)
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

    def parse_source(source, visited:)
      normalized_source = normalize_source(source)
      return [] if normalized_source.nil? || visited.include?(normalized_source)

      visited.add(normalized_source)
      xml = read_source(normalized_source)
      return [] if xml.to_s.strip.empty?

      document = Nokogiri::XML(xml)
      document.remove_namespaces!

      if document.at_xpath("/sitemapindex")
        document.xpath("//sitemap/loc").flat_map do |node|
          child_source = resolve_child_sitemap(normalized_source, node.text.to_s.strip)
          next [] if child_source.nil?

          parse_source(child_source, visited: visited)
        end
      else
        document.xpath("//url").map do |url_node|
          loc = url_node.at_xpath("loc")&.text.to_s.strip
          next if loc.empty?

          lastmod = url_node.at_xpath("lastmod")&.text.to_s.strip
          Entry.new(loc: loc, lastmod: lastmod.empty? ? nil : lastmod, source_sitemap: normalized_source)
        end.compact
      end
    end

    def resolve_child_sitemap(parent_source, loc)
      return if loc.empty?

      if remote_source?(parent_source)
        parent_uri = URI.parse(parent_source)
        if remote_source?(loc)
          remote_child_source(parent_uri, loc)
        else
          URI.join(parent_uri.to_s, loc).to_s
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
      return child_uri.to_s unless @rebase_remote_children
      return child_uri.to_s if child_uri.host == parent_uri.host && child_uri.port == parent_uri.port && child_uri.scheme == parent_uri.scheme

      child_uri.scheme = parent_uri.scheme
      child_uri.host = parent_uri.host
      child_uri.port = parent_uri.port
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

    def read_source(source)
      if remote_source?(source)
        fetch_remote_source(source)
      elsif storage.exist?(source)
        storage.read(source)
      end
    end

    def fetch_remote_source(source, redirects_remaining: 3)
      uri = URI.parse(source)
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "Indexmap::Parser/1.0"

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 20) do |http|
        http.request(request)
      end

      case response
      when Net::HTTPSuccess
        response.body
      when Net::HTTPRedirection
        return if redirects_remaining <= 0

        location = response["location"].to_s
        return if location.empty?

        redirected = URI.join(source, location).to_s
        fetch_remote_source(redirected, redirects_remaining: redirects_remaining - 1)
      end
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
