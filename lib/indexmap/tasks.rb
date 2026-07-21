# frozen_string_literal: true

require "indexmap"
require "rake"

unless Rake::Task.task_defined?("indexmap:sitemap:create")
  load File.expand_path("../tasks/indexmap_tasks.rake", __dir__)
end
