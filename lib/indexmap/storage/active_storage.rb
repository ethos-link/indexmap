# frozen_string_literal: true

require "stringio"
require "securerandom"
require "uri"

module Indexmap
  module Storage
    class ActiveStorage
      DEFAULT_CONTENT_TYPE = "application/xml"

      def initialize(model:, public_url:, filename_column: :filename, attachment: :file, content_type: DEFAULT_CONTENT_TYPE)
        @model = model
        @public_url_base = public_url
        @filename_column = filename_column
        @attachment = attachment
        @default_content_type = content_type
      end

      def write(filename, body, content_type: nil)
        if Publication.immutable?(filename) && exist?(filename)
          raise ConfigurationError, "Immutable sitemap already exists: #{filename}"
        end
        attachment_content_type = content_type || default_content_type
        record = find_or_initialize(filename)
        record.save! unless record.persisted?
        record.public_send(attachment).attach(
          io: StringIO.new(body.to_s),
          filename: filename,
          content_type: attachment_content_type
        )

        Artifact.new(filename: filename, body: body.to_s, content_type: attachment_content_type)
      end

      def read(filename)
        record = find_record(filename)
        return unless attached?(record)

        record.public_send(attachment).download
      end

      def exist?(filename)
        attached?(find_record(filename))
      end

      def list(prefix: nil, suffix: nil)
        relation = relation_for(prefix: prefix, suffix: suffix)
        scope = "with_attached_#{attachment}"
        relation = relation.public_send(scope) if relation.respond_to?(scope)

        relation.filter_map do |record|
          filename = record.public_send(filename_column).to_s
          next if prefix && !filename.start_with?(prefix)
          next if suffix && !filename.end_with?(suffix)
          next unless attached?(record)

          filename
        end.sort
      end

      def delete(filename)
        record = find_record(filename)
        record&.public_send(attachment)&.purge
      end

      def public_url(filename)
        URI.join("#{public_url_base}/", filename).to_s
      end

      def write_io(filename, io, content_type: nil)
        if Publication.immutable?(filename) && exist?(filename)
          raise ConfigurationError, "Immutable sitemap already exists: #{filename}"
        end
        record = find_or_initialize(filename)
        record.save! unless record.persisted?
        record.public_send(attachment).attach(io: io, filename: filename,
          content_type: content_type || default_content_type)
      end

      def open(filename, &block)
        blob_for(filename).open(&block)
      end

      def metadata(filename)
        record = find_record(filename)
        raise Errno::ENOENT, filename unless attached?(record)

        blob = record.public_send(attachment).blob
        {etag: blob.checksum, bytes: blob.byte_size, last_modified: record.updated_at,
         generation: blob.metadata["indexmap_generation"]}
      end

      def revision(root)
        exist?(root) ? blob_for(root).id.to_s : nil
      end

      def publish(source, files:, root:, expected:)
        uploads = []
        created_records = []
        root_blob = nil
        build = SecureRandom.hex(16)
        unique = model.connection.indexes(model.table_name).any? do |index|
          index.unique && index.columns == [filename_column.to_s] && index.where.nil?
        end
        raise ConfigurationError, "Atomic Active Storage requires a unique filename index" unless unique

        check_revision!(root, expected)
        publication = Publication.new(root: root)
        publication.validate_files!(files)
        children = files.reject { |filename| filename == root }
        children.each do |filename|
          raise ConfigurationError, "Immutable sitemap already exists: #{filename}" if exist?(filename)
        end
        record = model.create_or_find_by!(filename_column => root)
        [*children, root].each do |filename|
          source.open(filename) do |io|
            check_revision!(root, expected)
            key = SecureRandom.hex(28)
            uploads << key
            metadata = {indexmap_build: build}
            metadata[:indexmap_generation] = children.empty? ? nil : publication.generation(children.first) if filename == root
            blob = ::ActiveStorage::Blob.create_and_upload!(key: key, io: io, filename: ::File.basename(filename),
              content_type: default_content_type, identify: false, metadata: metadata)
            if filename == root
              root_blob = blob
            else
              child = model.create!(filename_column => filename)
              created_records << child.id
              child.public_send(attachment).attach(blob)
            end
          end
        end
        record.with_lock do
          current = record.public_send(attachment)
          actual = current.attached? ? current.blob.id.to_s : nil
          raise SupersededPublication, "Sitemap changed while building: #{root}" unless actual == expected
          present = model.where(filename_column => children).joins(:"#{attachment}_attachment").distinct.count(filename_column)
          unless present == children.size
            raise SupersededPublication, "Sitemap children removed while building: #{root}"
          end

          if current.attached? && (version = publication.current_generation(self))
            archived = model.create_or_find_by!(filename_column => publication.archive(version))
            archived.public_send(attachment).attach(current.blob)
          end
          current.attach(root_blob)
        end
      ensure
        # Also recognize a committed root when a host after_commit callback raises.
        unless root_blob&.attachments&.exists?
          cleanup_uploads(created_records || [], uploads || [], build: build)
        end
      end

      def prune(root:, before:)
        record = find_record(root)
        return [] unless record

        record.with_lock do
          Publication.new(root: root).prune(self, before: before) do |filename|
            find_record(filename).destroy!
          end
        end
      end

      def inspect
        "#<#{self.class.name} model=#{model}>"
      end

      private

      attr_reader :model, :filename_column, :attachment, :default_content_type

      def check_revision!(root, expected)
        raise SupersededPublication, "Sitemap changed while building: #{root}" unless revision(root) == expected
      end

      def cleanup_uploads(records, keys, build:)
        failures = []
        records.each do |id|
          model.find_by(model.primary_key => id)&.destroy!
        rescue => error
          failures << {artifact: "#{model.name}:#{id}", error: error}
        end
        keys.each do |key|
          blob = ::ActiveStorage::Blob.find_by(key: key)
          if blob && blob.metadata["indexmap_build"] == build && !blob.attachments.exists?
            blob.purge
          end
        rescue => error
          failures << {artifact: key, error: error}
        end
        raise PublicationCleanupError.new(failures) unless failures.empty?
      end

      def blob_for(filename)
        record = find_record(filename)
        raise Errno::ENOENT, filename unless attached?(record)

        record.public_send(attachment).blob
      end

      def find_or_initialize(filename)
        model.find_or_initialize_by(filename_column => filename)
      end

      def find_record(filename)
        model.find_by(filename_column => filename)
      end

      def relation_for(prefix:, suffix:)
        if !model.respond_to?(:where) || (!prefix && !suffix)
          return model.all
        end

        column = model.connection.quote_column_name(filename_column)
        if prefix && suffix
          model.where("#{column} LIKE ?", "#{prefix}%#{suffix}")
        elsif prefix
          model.where("#{column} LIKE ?", "#{prefix}%")
        else
          model.where("#{column} LIKE ?", "%#{suffix}")
        end
      end

      def attached?(record)
        record&.public_send(attachment)&.attached?
      end

      def public_url_base
        @public_url_base.to_s.delete_suffix("/")
      end
    end
  end
end
