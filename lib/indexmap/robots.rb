# frozen_string_literal: true

require "uri"

module Indexmap
  class Robots
    attr_writer :indexable, :groups, :sitemaps

    def initialize(configuration:)
      @configuration = configuration
      @indexable = false
      @groups = [{user_agent: "*", allow: ["/"]}]
    end

    def body
      return "User-agent: *\nDisallow: /\n" unless resolve(@indexable) == true

      groups = Array(resolve(@groups))
      raise ConfigurationError, "Robots groups must not be empty" if groups.empty?

      lines = groups.flat_map do |group|
        unknown = group.keys - %i[user_agent allow disallow]
        raise ConfigurationError, "Unknown robots group keys: #{unknown.join(", ")}" unless unknown.empty?

        agents = Array(group.fetch(:user_agent))
        raise ConfigurationError, "Robots user agents must not be empty" if agents.empty?

        agents.map { |agent| "User-agent: #{value(agent)}" } +
          Array(group[:allow]).map { |path| "Allow: #{path_value(path)}" } +
          Array(group[:disallow]).map { |path| "Disallow: #{path_value(path)}" } + [""]
      end
      sitemaps = resolve(@sitemaps) || [File.join(@configuration.base_url.to_s, @configuration.index_filename.to_s)]
      Array(sitemaps).each do |location|
        location = value(location)
        uri = URI.parse(location)
        unless uri.is_a?(URI::HTTP) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
          raise ConfigurationError, "Robots sitemap must be an absolute HTTP(S) URL"
        end
        lines << "Sitemap: #{location}"
      end
      lines.join("\n") + "\n"
    rescue URI::InvalidURIError
      raise ConfigurationError, "Robots sitemap must be an absolute HTTP(S) URL"
    end

    private

    def resolve(value)
      value.respond_to?(:call) ? value.call : value
    end

    def value(input)
      text = input.to_s
      if text.empty? || text.match?(/[\x00-\x1f\x7f#]/)
        raise ConfigurationError, "Robots values must be nonempty and contain no controls or comments"
      end
      text
    end

    def path_value(input)
      path = value(input)
      raise ConfigurationError, "Robots paths must start with /" unless path.start_with?("/")

      path
    end
  end
end
