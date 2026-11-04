# frozen_string_literal: true

module Indexmap
  Artifact = Struct.new(:filename, :body, :content_type) do
    def basename
      File.basename(filename)
    end
  end
end
