# frozen_string_literal: true

require "test_helper"
require "generators/indexmap/install_generator"
require "open3"
require "rbconfig"

class IndexmapInstallGeneratorTest < Minitest::Test
  def test_generated_initializer_defers_origin_and_entries_in_both_load_orders
    Dir.mktmpdir do |destination|
      File.write(File.join(destination, "Rakefile"), <<~RUBY)
        require_relative "config/application"
        Rails.application.load_tasks
      RUBY
      Indexmap::Generators::InstallGenerator.start([], destination_root: destination)
      initializer = File.join(destination, "config/initializers/indexmap.rb")
      source = File.read(initializer).sub('ENV.fetch("BASE_URL", "http://localhost:3000")', "Rails.origin")
      source = source.sub("# config.sections = -> { Sitemap.sections }", <<~RUBY.strip)
        config.format = :single_file
        config.entries = -> { [Indexmap::Entry.new(loc: Rails.origin + "/page")] }
      RUBY
      File.write(initializer, source)

      ["before", "after"].each do |order|
        script = <<~RUBY
          require "pathname"
          require "active_support/lazy_load_hooks"
          module Rails
            def self.public_path = Pathname.new(ENV.fetch("INDEXMAP_TEST_PUBLIC_PATH"))
            def self.origin
              raise "origin resolved before routes" unless @ready
              "https://example.com"
            end
            def self.ready = @ready = true
          end
          require "indexmap" if ARGV.fetch(1) == "before"
          load ARGV.fetch(0)
          abort "Indexmap loaded during boot" if ARGV.fetch(1) == "after" && defined?(Indexmap::Configuration)
          require "indexmap"
          Rails.ready
          result = Indexmap::TaskRunner.new.create
          abort "wrong output" unless result.fetch(:files) == ["sitemap.xml"]
          abort "wrong origin" unless Indexmap.configuration.storage.read("sitemap.xml").include?("https://example.com/page")
          require "indexmap"
          abort "configuration lost" unless Indexmap.configuration.base_url == "https://example.com"
        RUBY
        output, error, status = Open3.capture3(
          {"INDEXMAP_TEST_PUBLIC_PATH" => File.join(destination, order)},
          RbConfig.ruby, "-I#{File.expand_path("../../lib", __dir__)}", "-e", script, initializer, order
        )
        assert status.success?, output + error
      end
    end
  end

  def test_loads_tasks_after_rails_has_removed_the_command_from_argv
    Dir.mktmpdir do |destination|
      File.write(File.join(destination, "Rakefile"), <<~RUBY)
        require_relative "config/application"
        Rails.application.load_tasks
      RUBY
      Indexmap::Generators::InstallGenerator.start([], destination_root: destination)
      FileUtils.mkdir_p(File.join(destination, "config"))
      File.write(File.join(destination, "config/application.rb"), <<~RUBY)
        abort "Indexmap loaded too late" unless defined?(Indexmap::Configuration)
        module Rails
          def self.application = self
          def self.load_tasks = nil
        end
      RUBY
      script = <<~RUBY
        require "rake"
        Rake.application.init("rake", ["indexmap:sitemap:create"])
        ARGV.clear
        load ARGV_FILE
        abort "task missing" unless Rake::Task.task_defined?("indexmap:sitemap:create")
      RUBY
      script = script.sub("ARGV_FILE", File.join(destination, "Rakefile").dump)
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-I#{File.expand_path("../../lib", __dir__)}", "-e", script
      )
      assert status.success?, stderr
    end
  end
end
