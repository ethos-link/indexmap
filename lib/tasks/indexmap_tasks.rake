namespace :sitemap do
  desc "Create sitemap files"
  task create: :environment do
    runner = Indexmap::TaskRunner.new
    runner.create
    runner.format
    runner.validate
  end

  desc "Format sitemap files for better readability"
  task format: :environment do
    Indexmap::TaskRunner.new.format
  end

  desc "Validate sitemap shape and URL hygiene"
  task validate: :environment do
    Indexmap::TaskRunner.new.validate
  end

  desc "Ping all configured search engines"
  task ping: :environment do
    Rake::Task["sitemap:index_now:ping"].invoke
    Rake::Task["sitemap:google:ping"].invoke
  end

  namespace :google do
    desc "Ping Google Search Console"
    task ping: :environment do
      Indexmap::Pinger::Google.new.ping
    end
  end

  namespace :index_now do
    desc "Ping IndexNow. ENV: SINCE=2026-04-18T10:30:00Z or INDEXNOW_RECENT_HOURS=24"
    task ping: :environment do
      Indexmap::Pinger::IndexNow.new.ping
    end

    desc "Write the IndexNow key file into public/"
    task write_key: :environment do
      path = Indexmap::TaskRunner.new.write_index_now_key
      puts "Wrote #{path}" if path
    end
  end
end
