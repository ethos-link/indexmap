# frozen_string_literal: true

module Indexmap
  class Railtie < Rails::Railtie
    rake_tasks do
      require "indexmap/tasks"
    end
  end
end
