# frozen_string_literal: true

module Indexmap
  module Stores
    class File
      attr_reader :root

      def initialize(root)
        @root = Pathname(root)
      end

      def upload(filename:, body:, content_type: "application/xml; charset=utf-8")
        path = path_for(filename)
        FileUtils.mkdir_p(path.dirname)

        temp_path = path.sub_ext("#{path.extname}.tmp")
        ::File.write(temp_path, body)
        ::File.rename(temp_path, path)

        Artifact.new(
          filename: filename,
          body: body,
          content_type: content_type,
          updated_at: path.mtime
        )
      end

      def fetch(filename)
        path = path_for(filename)
        return unless path.file?

        Artifact.new(
          filename: filename,
          body: path.read,
          content_type: "application/xml; charset=utf-8",
          updated_at: path.mtime
        )
      end

      def fetch!(filename)
        fetch(filename) || raise(Indexmap::Error, "Missing sitemap artifact: #{filename}")
      end

      def path_for(filename)
        root.join(filename)
      end
    end
  end
end
