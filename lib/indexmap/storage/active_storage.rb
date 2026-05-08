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

      def inspect
        "#<#{self.class.name} model=#{model}>"
      end

      private

      attr_reader :model, :filename_column, :attachment, :default_content_type

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
