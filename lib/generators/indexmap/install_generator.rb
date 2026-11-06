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

        inject_into_file "Rakefile", "require \"indexmap/tasks\"\n\n",
          before: /^require_relative ["']config\/application["']/
      end
    end
  end
end
