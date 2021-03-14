#!/usr/bin/env ruby
require 'logger'

$LOAD_PATH.unshift ::File.expand_path("#{::File.dirname(__FILE__)}/lib")
require 'resque/server'

# Set the RESQUECONFIG env variable if you've a `resque.rb` or similar
# config file you want loaded on boot.
load ::File.expand_path(ENV['RESQUECONFIG']) if ENV['RESQUECONFIG'] && ::File.exist?(::File.expand_path(ENV['RESQUECONFIG']))

use Rack::ShowExceptions
run Resque::Server.new
