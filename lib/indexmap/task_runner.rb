# frozen_string_literal: true

require "nokogiri"

module Indexmap
  class TaskRunner
    def initialize(configuration: Indexmap.configuration)
      @configuration = configuration
    end

    def create
      remove_existing_sitemap_files
      artifacts = Indexmap.create(configuration: configuration, run_after_create: true)
      {files: sitemap_files, artifacts: artifacts, index_now_key_path: write_index_now_key}
    end

    def format
      sitemap_files.each do |file_path|
        content = File.read(file_path)
        document = Nokogiri::XML(
          content,
          nil,
          nil,
          Nokogiri::XML::ParseOptions::DEFAULT_XML | Nokogiri::XML::ParseOptions::NOBLANKS
        )
        save_options = Nokogiri::XML::Node::SaveOptions::FORMAT | Nokogiri::XML::Node::SaveOptions::AS_XML

        File.write(file_path, document.to_xml(indent: 2, save_with: save_options))
      end

      sitemap_files
    end

    def validate
      Validator.new(configuration: configuration).validate!
      sitemap_files
    end

    def write_index_now_key(generate_if_missing: false)
      pinger = Pinger::IndexNow.new(configuration: configuration)
      return pinger.ensure_key_file if generate_if_missing

      pinger.write_key_file
    end

    def public_path
      default_output.public_path
    end

    private

    attr_reader :configuration

    def default_output
      configuration.output_for(:default)
    end

    def remove_existing_sitemap_files
      Dir.glob(public_path.join("sitemap*.xml*")).each do |file_path|
        File.delete(file_path)
      end
    end

    def sitemap_files
      Dir.glob(public_path.join("sitemap*.xml")).sort
    end
  end
end
