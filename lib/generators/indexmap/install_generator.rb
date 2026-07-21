# frozen_string_literal: true

require "rails/generators"

module Indexmap
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Create a lazy-safe Indexmap initializer and task loader"

      def create_initializer
        template "initializer.rb.tt", "config/initializers/indexmap.rb"
      end

      def configure_rakefile
        rakefile = File.join(destination_root, "Rakefile")
        return unless File.exist?(rakefile)
        return if File.read(rakefile).include?('require "indexmap/tasks"')

        inject_into_file "Rakefile", rakefile_setup, before: /^require_relative ["']config\/application["']/
      end

      private

      def rakefile_setup
        <<~RUBY
          indexmap_tasks_requested = Rake.application.options.show_tasks ||
            ARGV.any? { |argument| ["-T", "--tasks"].include?(argument) }
          require "indexmap/tasks" if indexmap_tasks_requested ||
            ARGV.any? { |argument| argument.start_with?("indexmap:") }

        RUBY
      end
    end
  end
end
