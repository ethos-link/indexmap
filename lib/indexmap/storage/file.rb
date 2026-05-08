# frozen_string_literal: true

module Indexmap
  module Storage
    File = Struct.new(:filename, :body, :content_type, keyword_init: true) do
      def basename
        ::File.basename(filename)
      end
    end
  end
end
