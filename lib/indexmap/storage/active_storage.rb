# frozen_string_literal: true

require "stringio"
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

        File.new(filename: filename, body: body.to_s, content_type: attachment_content_type)
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
        unique = model.connection.indexes(model.table_name).any? do |index|
          index.unique && index.columns == [filename_column.to_s] && index.where.nil?
        end
        raise ConfigurationError, "Atomic Active Storage requires a unique filename index" unless unique

        record = model.create_or_find_by!(filename_column => root)
        publication = Publication.new(root: root)
        root_blob = nil
        files.each do |filename|
          valid = filename == root || (publication.child?(filename) && !exist?(filename))
          unless valid
            raise ConfigurationError, "Invalid immutable sitemap filename: #{filename}"
          end
          source.open(filename) do |io|
            blob = ::ActiveStorage::Blob.create_and_upload!(io: io, filename: ::File.basename(filename),
              content_type: default_content_type, identify: false,
              metadata: (filename == root) ? {indexmap_generation: publication.generation(files.first)} : {})
            if filename == root
              root_blob = blob
            else
              child = model.create_or_find_by!(filename_column => filename)
              child.public_send(attachment).attach(blob)
            end
          end
        end
        record.with_lock do
          current = record.public_send(attachment)
          actual = current.attached? ? current.blob.id.to_s : nil
          raise SupersededPublication, "Sitemap changed while building: #{root}" unless actual == expected

          if current.attached? && (version = publication.current_generation(self))
            archived = model.create_or_find_by!(filename_column => publication.archive(version))
            archived.public_send(attachment).attach(current.blob)
          end
          current.attach(root_blob)
        end
      ensure
        root_blob.purge if root_blob && !root_blob.attachments.exists?
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
