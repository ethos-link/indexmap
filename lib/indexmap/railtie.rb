# frozen_string_literal: true

module Indexmap
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path("../tasks/indexmap_tasks.rake", __dir__)
    end
  end
end
