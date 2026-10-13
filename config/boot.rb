ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.

# Load .env BEFORE app_config evaluates. dotenv-rails only loads during
# `before_configuration`, which is too late here — app_config reads ENV at
# require time. `Dotenv.load` never overwrites variables already set (so
# container/Coolify envs keep priority) and silently skips a missing file.
begin
  require "dotenv"
  Dotenv.load(File.expand_path("../.env", __dir__))
rescue LoadError
  # dotenv not installed — assume the environment is provided externally.
end

require_relative "app_config"
