require "bundler/setup"

require "active_support/all"

root = File.expand_path("..", __dir__)

Dir.glob("#{root}/framework/**/*.rb").each do |file|
  require file
end

Dir.glob("#{root}/app/**/*.rb").each do |file|
  require file
end

ProjectionRegistry.load!
