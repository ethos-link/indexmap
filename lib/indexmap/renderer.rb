# frozen_string_literal: true

module Indexmap
  class Renderer
    def initialize(output:)
      @output = output
    end

    def render
      Dir.mktmpdir("indexmap-render") do |dir|
        public_path = Pathname(dir)
        output.writer.tap do |writer|
          writer.public_path = public_path
          writer.write
        end

        public_path.glob("sitemap*.xml").sort.map do |path|
          Artifact.new(
            filename: path.basename.to_s,
            body: path.read,
            content_type: "application/xml; charset=utf-8",
            updated_at: path.mtime
          )
        end
      end
    end

    private

    attr_reader :output
  end
end
