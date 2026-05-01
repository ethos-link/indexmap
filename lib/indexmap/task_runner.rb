# frozen_string_literal: true

require "nokogiri"

module Indexmap
  class TaskRunner
    def initialize(configuration: Indexmap.configuration)
      @configuration = configuration
    end

    def create
      written_files = Indexmap.create(configuration: configuration)
      index_now_key_path = write_index_now_key if configuration.index_now.write_key_file?
      configuration.run_after_create_callbacks

      {files: written_files.map(&:to_s), written_files: written_files, index_now_key_path: index_now_key_path}
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

    def sitemap_files
      Dir.glob(public_path.join("sitemap*.xml")).sort
    end
  end
end
