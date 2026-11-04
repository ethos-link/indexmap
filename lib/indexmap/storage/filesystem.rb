# frozen_string_literal: true

require "uri"
require "tmpdir"
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

        Artifact.new(
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
        prefix = prefix.to_s
        unless prefix.empty? || normalize_filename(prefix) == prefix.delete_suffix("/")
          raise ArgumentError, "Storage prefix must be a normalized relative path: #{prefix.inspect}"
        end
        directory, _, fragment = prefix.rpartition("/")
        ancestor = path
        directory.split("/").each do |segment|
          ancestor = ancestor.join(segment)
          return [] if segment.start_with?(".") || ancestor.symlink?
        end
        base = directory.empty? ? path : path_for(directory)
        return [] unless base.directory?

        pending = base.children.select { |entry| entry.basename.to_s.start_with?(fragment) }
        filenames = []
        until pending.empty?
          entry = pending.pop
          next if entry.symlink? || entry.basename.to_s.start_with?(".")

          if entry.directory?
            pending.concat(entry.children)
          elsif (!suffix || entry.to_s.end_with?(suffix)) && entry.file?
            filenames << entry.relative_path_from(path).to_s
          end
        end
        filenames.sort
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
        check_revision!(root, expected)
        publication = Publication.new(root: root)
        publication.validate_files!(files)
        with_staging(root, expected: expected) do |staged|
          files.each do |filename|
            source.open(filename) { |io| staged.write_io(filename, io) }
          end
          archive = if expected && (version = publication.current_generation(self))
            publication.archive(version).tap do |filename|
              self.open(root) { |io| staged.write_io(filename, io) }
            end
          end
          with_lock(root) do
            check_revision!(root, expected)
            children = files.reject { |filename| filename == root }
            children.each do |filename|
              raise ConfigurationError, "Immutable sitemap already exists: #{filename}" if exist?(filename)
            end
            moved = []
            root_revision = staged.revision(root)
            begin
              children.each do |filename|
                move_staged(staged, filename)
                moved << filename
              end
              move_staged(staged, archive, retired_at: Time.now.utc) if archive
              move_staged(staged, root)
            ensure
              # A root rename can succeed immediately before an interrupt.
              moved.each { |filename| delete(filename) } unless revision(root) == root_revision
            end
          end
        end
      rescue Errno::ENOENT
        check_revision!(root, expected)
        raise
      end

      def prune(root:, before:)
        with_lock(root) do
          Publication.new(root: root).prune(self, before: before) + prune_staging(root, before: before)
        end
      end

      def inspect
        "#<#{self.class.name} path=#{path}>"
      end

      private

      attr_reader :path, :public_url_base

      def check_revision!(root, expected)
        raise SupersededPublication, "Sitemap changed while building: #{root}" unless revision(root) == expected
      end

      def staging_path(root)
        path_for(".indexmap-builds/#{Digest::SHA256.hexdigest(root)}")
      end

      def with_staging(root, expected:)
        directory = nil
        lock = nil
        with_lock(root) do
          check_revision!(root, expected)
          base = staging_path(root)
          base.mkpath
          directory = Dir.mktmpdir("build-", base)
          lock = ::File.open(::File.join(directory, ".lock"), "w")
          lock.flock(::File::LOCK_EX)
        end
        yield Filesystem.new(path: directory)
      ensure
        begin
          FileUtils.remove_entry(directory) if directory
        ensure
          lock&.close
        end
      end

      def move_staged(staged, filename, retired_at: nil)
        target = path_for(filename)
        target.dirname.mkpath
        staged.open(filename) do |io|
          ::File.utime(retired_at, retired_at, io.path) if retired_at
          ::File.atomic_write(target) do |temporary|
            temporary.close
            ::File.rename(io.path, temporary.path)
          end
        end
      end

      def prune_staging(root, before:)
        base = staging_path(root)
        return [] unless base.directory?

        base.children.filter_map do |directory|
          next if directory.symlink? || !directory.directory? || directory.mtime >= before

          begin
            directory.join(".lock").open("a") do |lock|
              next unless lock.flock(::File::LOCK_EX | ::File::LOCK_NB)

              FileUtils.remove_entry_secure(directory.to_s)
              directory.relative_path_from(path).to_s
            end
          rescue Errno::ENOENT
            # A completed build can remove its staging directory during pruning.
            nil
          end
        end
      end

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
