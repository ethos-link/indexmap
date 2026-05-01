# frozen_string_literal: true

require "nokogiri"
require "tmpdir"

module Indexmap
  class Creator
    ValidationConfiguration = Struct.new(:base_url, keyword_init: true)

    def initialize(output:)
      @output = output
    end

    def create
      FileUtils.mkdir_p(output.public_path.dirname)

      Dir.mktmpdir("indexmap", output.public_path.dirname) do |dir|
        staging_path = Pathname(dir)
        written_files = write_to(staging_path)
        sitemap_files = sitemap_files_in(staging_path)

        format(sitemap_files)
        validate(staging_path.join(output.index_filename))

        publish(sitemap_files)
        written_files.map { |path| output.public_path.join(path.basename) }
      end
    end

    private

    attr_reader :output

    def write_to(staging_path)
      output.writer.tap do |writer|
        writer.public_path = staging_path
      end.write
    end

    def sitemap_files_in(path)
      path.glob("sitemap*.xml").sort
    end

    def format(files)
      files.each do |file_path|
        document = Nokogiri::XML(
          file_path.read,
          nil,
          nil,
          Nokogiri::XML::ParseOptions::DEFAULT_XML | Nokogiri::XML::ParseOptions::NOBLANKS
        )
        save_options = Nokogiri::XML::Node::SaveOptions::FORMAT | Nokogiri::XML::Node::SaveOptions::AS_XML

        file_path.write(document.to_xml(indent: 2, save_with: save_options))
      end
    end

    def validate(index_path)
      Validator.new(
        configuration: ValidationConfiguration.new(base_url: output.base_url),
        path: index_path
      ).validate!
    end

    def publish(files)
      FileUtils.mkdir_p(output.public_path)

      files.map do |file_path|
        final_path = output.public_path.join(file_path.basename)
        File.rename(file_path, final_path)
        final_path
      end
    end
  end
end
