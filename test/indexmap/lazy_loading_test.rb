# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class IndexmapLazyLoadingTest < Minitest::Test
  def test_entrypoint_does_not_load_search_console_dependencies
    script = <<~RUBY
      require "indexmap"

      loaded = $LOADED_FEATURES.grep(%r{/(?:google/apis|googleauth)(?:/|\\.rb)})
      abort loaded.join("\\n") unless loaded.empty?
    RUBY

    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-I#{File.expand_path("../../lib", __dir__)}",
      "-e",
      script
    )

    assert status.success?, stderr
  end

  def test_task_entrypoint_registers_tasks
    script = <<~RUBY
      require "indexmap/tasks"

      abort "task missing" unless Rake::Task.task_defined?("indexmap:sitemap:create")
    RUBY

    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-I#{File.expand_path("../../lib", __dir__)}",
      "-e",
      script
    )

    assert status.success?, stderr
  end
end
