# frozen_string_literal: true

require "nokogiri"

module Indexmap
  class TaskRunner
    def initialize(configuration: Indexmap.configuration, storage: nil)
      @configuration = configuration
      @storage = storage
    end

    def create
      creator = Creator.new(output: default_output, storage: storage)
      written_files = creator.create
      index_now_key_filename = write_index_now_key if configuration.index_now.write_key_file?
      configuration.run_after_create_callbacks

      {
        files: written_files.map(&:to_s),
        written_files: written_files,
        sitemaps: creator.sitemaps,
        index_now_key_filename: index_now_key_filename
      }
    end

    def format
      if configuration.output_names.any? { |name| configuration.output_for(name).atomic }
        raise ConfigurationError, "Format immutable sitemaps by regenerating them"
      end
      sitemap_files.each do |filename|
        content = storage.read(filename)
        document = Nokogiri::XML(
          content,
          nil,
          nil,
          Nokogiri::XML::ParseOptions::DEFAULT_XML | Nokogiri::XML::ParseOptions::NOBLANKS
        )
        save_options = Nokogiri::XML::Node::SaveOptions::FORMAT | Nokogiri::XML::Node::SaveOptions::AS_XML

        storage.write(filename, document.to_xml(indent: 2, save_with: save_options), content_type: "application/xml")
      end

      sitemap_files
    end

    def validate
      Validator.new(configuration: configuration, storage: storage).validate!(collect: false)
      sitemap_files
    end

    def prune(retention: 48 * 3600)
      raise ConfigurationError, "Retention must be at least one hour" unless retention.is_a?(Numeric) && retention >= 3600
      raise ConfigurationError, "Storage does not support pruning" unless storage.respond_to?(:prune)

      configuration.output_names.flat_map do |name|
        output = configuration.output_for(name)
        output.atomic ? storage.prune(root: output.index_filename, before: Time.now.utc - retention) : []
      end
    end

    def write_index_now_key(generate_if_missing: false)
      pinger = Pinger::IndexNow.new(configuration: configuration, storage: storage)
      return pinger.ensure_key_file if generate_if_missing

      pinger.write_key_file
    end

    def storage
      @storage ||= configuration.storage
    end

    private

    attr_reader :configuration

    def default_output
      configuration.output_for(:default)
    end

    def sitemap_files
      storage.list(prefix: "sitemap", suffix: ".xml")
    end
  end
end
