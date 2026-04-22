# frozen_string_literal: true

module Indexmap
  class GoogleConfiguration
    attr_writer :credentials, :property

    def credentials
      resolve(@credentials)
    end

    def property
      resolve(@property)
    end

    private

    def resolve(value)
      value.respond_to?(:call) ? value.call : value
    end
  end
end
