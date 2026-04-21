namespace :sitemap do
  desc "Create sitemap files"
  task create: :environment do
    runner = Indexmap::TaskRunner.new
    runner.create
    runner.format
  end

  desc "Format sitemap files for better readability"
  task format: :environment do
    Indexmap::TaskRunner.new.format
  end
end
