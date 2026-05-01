# frozen_string_literal: true

require "digest"

module Indexmap
  Artifact = Struct.new(:filename, :body, :content_type, :updated_at, keyword_init: true) do
    def checksum
      Digest::SHA256.hexdigest(body.to_s)
    end
  end
end
