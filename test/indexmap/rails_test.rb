# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class IndexmapRailsTest < Minitest::Test
  def test_core_stays_independent_and_explicit_rails_integration_loads_after_it
    script = <<~RUBY
      require "indexmap"
      abort "Core loaded Railties" if $LOADED_FEATURES.any? { |file| file.end_with?("/rails/railtie.rb") }
      require "indexmap/rails"
      abort "Railtie missing" unless Indexmap::Railtie < Rails::Railtie
      app = Class.new(Rails::Application)
      app.config.eager_load = false
      app.load_tasks
      abort "Sitemap task missing" unless Rake::Task.task_defined?("indexmap:sitemap:create")
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, "-e", script)
    assert status.success?, output + error
  end
end
