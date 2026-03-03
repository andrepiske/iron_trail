# frozen_string_literal: true
ENV['DB'] ||= 'mysql'
require 'fileutils'
require 'bundler'

Bundler::GemHelper.install_tasks

desc 'Copy the database.DB.yml per ENV[\'DB\']'
task :install_database_yml do
  puts "installing database.yml for #{ENV['DB']}"

  FileUtils.rm('spec/dummy_app/db/database.yml', force: true)

  FileUtils.cp(
    "spec/dummy_app/config/database-template.#{ENV['DB']}.yml",
    'spec/dummy_app/config/database.yml'
  )
end

desc 'Delete generated files and databases'
task :clean do
  db = ENV.fetch('DB', 'mysql')
  db_name = ENV.fetch('IRONTRAIL_CI_DATABASE', 'iron_trail_test')
  puts "Will drop #{db} database '#{db_name}'"

  case db
  when 'mysql'
    host = ENV.fetch('IRONTRAIL_CI_DB_HOST', '127.0.0.1')
    port = ENV.fetch('IRONTRAIL_CI_DB_PORT', '3306')
    user = ENV.fetch('IRONTRAIL_CI_DB_USER', 'root')
    password = ENV.fetch('IRONTRAIL_CI_DB_PASSWORD', '')

    pwd_arg = password.empty? ? '' : "-p#{password}"
    system("mysql -h #{host} -P #{port} -u #{user} #{pwd_arg} -e 'DROP DATABASE IF EXISTS `#{db_name}`' > /dev/null 2>&1")
  else
    raise "Don't know DB '#{db}'"
  end

  # Delete generated IronTrail migrations
  migrate_path = File.expand_path('spec/dummy_app/db/migrate', __dir__)
  Dir.glob("#{migrate_path}/*.rb").each do |full_path|
    base_name = File.basename(full_path)
    next unless base_name =~ /^\d{14}_create_irontrail_.+\.rb$/

    FileUtils.rm full_path
  end
end

desc 'Create the database.'
task :create_db do
  db = ENV.fetch('DB', 'mysql')
  db_name = ENV.fetch('IRONTRAIL_CI_DATABASE', 'iron_trail_test')
  puts "Will create #{db} database '#{db_name}'"

  case db
  when 'mysql'
    host = ENV.fetch('IRONTRAIL_CI_DB_HOST', '127.0.0.1')
    port = ENV.fetch('IRONTRAIL_CI_DB_PORT', '3306')
    user = ENV.fetch('IRONTRAIL_CI_DB_USER', 'root')
    password = ENV.fetch('IRONTRAIL_CI_DB_PASSWORD', '')

    pwd_arg = password.empty? ? '' : "-p#{password}"
    system("mysql -h #{host} -P #{port} -u #{user} #{pwd_arg} -e 'CREATE DATABASE IF NOT EXISTS `#{db_name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci'")
  else
    raise "Don't know DB '#{db}'"
  end
end

task prepare: %i[clean install_database_yml create_db]

require 'rspec/core/rake_task'

task(:spec).clear
RSpec::Core::RakeTask.new(:spec)

# Loading the testing/rspec file will affect RSpec globally. Because of that,
# we want to test it in a separate scope. We could also always require it,
# but that wouldn't be true in a real rails app and could make all tests
# farther apart from reality, thus less reliable.
RSpec::Core::RakeTask.new(:testing_spec).tap do |task|
  task.pattern = 'spec/testing_itself.rb'
end

task default: %i[prepare spec testing_spec]
