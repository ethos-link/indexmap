# frozen_string_literal: true

module Indexmap
  module Storage
    File = Struct.new(:filename, :body, :content_type) do
      def basename
        ::File.basename(filename)
      end
    end
  end
end
