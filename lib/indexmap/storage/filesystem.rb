# frozen_string_literal: true

require "uri"
require "active_support/core_ext/file/atomic"

module Indexmap
  module Storage
    class Filesystem
      DEFAULT_CONTENT_TYPE = "application/xml"

      def initialize(path:, public_url: nil)
        @path = Pathname(path).expand_path
        @path.mkpath
        @path = @path.realpath
        @public_url_base = public_url
      end

      def write(filename, body, content_type: DEFAULT_CONTENT_TYPE)
        if Publication.immutable?(filename) && exist?(filename)
          raise ConfigurationError, "Immutable sitemap already exists: #{filename}"
        end
        target = path_for(filename)
        target.dirname.mkpath
        ::File.atomic_write(target) { |file| file.write(body.to_s) }

        File.new(
          filename: normalize_filename(filename),
          body: body.to_s,
          content_type: content_type || DEFAULT_CONTENT_TYPE
        )
      end

      def read(filename)
        path_for(filename).read(encoding: "UTF-8")
      end

      def exist?(filename)
        path_for(filename).file?
      end

      def list(prefix: nil, suffix: nil)
        path.glob("**/*").select(&:file?).filter_map do |file|
          filename = file.relative_path_from(path).to_s
          next if prefix && !filename.start_with?(prefix)
          next if suffix && !filename.end_with?(suffix)

          filename
        end.sort
      end

      def delete(filename)
        path_for(filename).delete if exist?(filename)
      end

      def public_url(filename)
        return normalize_filename(filename) if public_url_base.to_s.strip.empty?

        URI.join("#{public_url_base.to_s.delete_suffix("/")}/", normalize_filename(filename)).to_s
      end

      def open(filename, &block)
        path_for(filename).open("rb", &block)
      end

      def write_io(filename, io, content_type: DEFAULT_CONTENT_TYPE)
        if Publication.immutable?(filename) && exist?(filename)
          raise ConfigurationError, "Immutable sitemap already exists: #{filename}"
        end
        target = path_for(filename)
        target.dirname.mkpath
        ::File.atomic_write(target) { |file| IO.copy_stream(io, file) }
      end

      def metadata(filename)
        stat = path_for(filename).stat
        {etag: "#{stat.ino}-#{stat.size}-#{stat.mtime.to_r}", bytes: stat.size, last_modified: stat.mtime.utc}
      end

      def revision(root)
        exist?(root) ? metadata(root).fetch(:etag) : nil
      end

      def publish(source, files:, root:, expected:)
        with_lock(root) do
          raise SupersededPublication, "Sitemap changed while building: #{root}" unless revision(root) == expected

          files.each do |filename|
            next if filename == root
            unless Publication.new(root: root).child?(filename) && !exist?(filename)
              raise ConfigurationError, "Invalid immutable sitemap filename: #{filename}"
            end
            source.open(filename) { |io| write_io(filename, io) }
          end
          publication = Publication.new(root: root)
          if (version = publication.current_generation(self))
            self.open(root) { |io| write_io(publication.archive(version), io) }
          end
          source.open(root) { |io| write_io(root, io) }
        end
      end

      def prune(root:, before:)
        with_lock(root) { Publication.new(root: root).prune(self, before: before) }
      end

      def inspect
        "#<#{self.class.name} path=#{path}>"
      end

      private

      attr_reader :path, :public_url_base

      def with_lock(root)
        lock = path_for(".indexmap-#{Digest::SHA256.hexdigest(root)}.lock")
        lock.open("a") do |file|
          file.flock(::File::LOCK_EX)
          yield
        ensure
          file.flock(::File::LOCK_UN)
        end
      end

      def path_for(filename)
        target = path.join(normalize_filename(filename))
        ancestor = target
        ancestor = ancestor.parent until ancestor.exist? || ancestor.symlink?
        resolved = ancestor.realpath
        unless resolved == path || resolved.to_s.start_with?("#{path}/")
          raise ArgumentError, "Storage filename escapes its root: #{filename.inspect}"
        end
        target
      end

      def normalize_filename(filename)
        normalized = Pathname(filename.to_s).cleanpath
        if normalized.absolute? || normalized.to_s.start_with?("../") || normalized.to_s == ".."
          raise ArgumentError, "Storage filename must be relative: #{filename.inspect}"
        end

        normalized.to_s
      end
    end
  end
end
