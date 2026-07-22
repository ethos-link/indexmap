# frozen_string_literal: true

require "test_helper"
require "generators/indexmap/install_generator"
require "open3"
require "rbconfig"

class IndexmapInstallGeneratorTest < Minitest::Test
  def test_generates_lazy_initializer_and_task_loader
    Dir.mktmpdir do |destination|
      File.write(File.join(destination, "Rakefile"), <<~RUBY)
        require_relative "config/application"
        Rails.application.load_tasks
      RUBY

      Indexmap::Generators::InstallGenerator.start([], destination_root: destination)

      initializer = File.join(destination, "config/initializers/indexmap.rb")
      rakefile = File.read(File.join(destination, "Rakefile"))

      assert File.exist?(initializer)
      assert_includes File.read(initializer), "module IndexmapConfiguration"
      assert_includes File.read(initializer), "IndexmapConfiguration.apply if defined?(Indexmap)"
      assert_includes File.read(initializer), "Search-engine pings start from config.index_filename"
      assert_includes rakefile, 'require "indexmap/tasks"'
      assert_operator rakefile.index('require "indexmap/tasks"'), :<, rakefile.index('require_relative "config/application"')

      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, initializer)
      assert status.success?, stderr

      script = <<~RUBY
        require "pathname"

        module Rails
          def self.public_path
            Pathname.new("public")
          end
        end

        require "indexmap"
        load ARGV.fetch(0)

        configuration = Indexmap.configuration
        IndexmapConfiguration.apply
        abort "configuration replaced" unless Indexmap.configuration.equal?(configuration)
        abort "base URL missing" unless configuration.base_url == "http://localhost:3000"
        abort "index filename missing" unless configuration.index_filename == "sitemap.xml"
      RUBY
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        "-I#{File.expand_path("../../lib", __dir__)}",
        "-e",
        script,
        initializer
      )
      assert status.success?, stderr
    end
  end
end
