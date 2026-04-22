# frozen_string_literal: true

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

      entries = Parser.new(path: sitemap_path).entries
      validate_duplicates!(entries)
      validate_parameterized_urls!(entries)
      true
    end

    private

    attr_reader :configuration, :path

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
  end
end
