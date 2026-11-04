# frozen_string_literal: true

module Indexmap
  class Output
    VALID_FORMATS = %i[index single_file].freeze

    attr_writer :atomic, :max_urls, :max_bytes

    attr_writer :base_url, :entries, :format, :index_filename, :sections

    def initialize(configuration:)
      @configuration = configuration
    end

    def base_url
      resolve(@base_url) || configuration.base_url
    end

    def entries
      resolved_entries = resolve(@entries)

      value = resolved_entries.nil? ? configuration.entries : resolved_entries
      value.is_a?(Enumerable) ? value : Array(value)
    end

    def format
      value = resolve(@format) || configuration.format
      value.nil? ? :index : value.to_sym
    end

    def index_filename
      resolve(@index_filename) || configuration.index_filename
    end

    def storage
      configuration.storage
    end

    def sections
      resolved_sections = resolve(@sections)

      Array(resolved_sections.nil? ? configuration.sections : resolved_sections)
    end

    def atomic
      @atomic.nil? ? configuration.atomic == true : @atomic == true
    end

    def writer(generation: nil)
      base_url = self.base_url
      format = self.format
      raise ConfigurationError, "Indexmap base_url is not configured" if base_url.to_s.strip.empty?

      unless VALID_FORMATS.include?(format)
        raise ConfigurationError, "Indexmap format must be one of: #{VALID_FORMATS.join(", ")}"
      end

      if format == :single_file
        entries = self.entries
        raise ConfigurationError, "Indexmap entries are not configured" if entries.is_a?(Array) && entries.empty?
      else
        sections = self.sections
        raise ConfigurationError, "Indexmap sections are not configured" if sections.empty?
      end

      Writer.new(
        entries: entries,
        format: format,
        sections: sections,
        base_url: base_url,
        index_filename: index_filename,
        max_urls: @max_urls || configuration.max_urls || Validator::MAX_ENTRIES,
        max_bytes: @max_bytes || configuration.max_bytes || Validator::MAX_BYTES,
        generation: generation
      )
    end

    private

    attr_reader :configuration

    def resolve(value)
      value.respond_to?(:call) ? value.call : value
    end
  end
end
