$LOAD_PATH.unshift 'lib'
require 'resque/version'

Gem::Specification.new do |s|
  s.name              = 'resque'
  s.version           = Resque::Version
  s.summary           = "Action Verb's Resque fork"
  s.homepage          = 'https://www.actionverb.com/open-source/resque'
  s.email             = 'kevin@actionverb.com'
  s.authors           = ['Chris Wanstrath', 'Steve Klabnik', 'Terence Lee', 'Kevin Bombino']

  s.files             = %w[README.md Rakefile LICENSE]
  s.files            += Dir.glob('lib/**/*')
  s.files            += Dir.glob('bin/**/*')
  s.files            += Dir.glob('man/**/*')
  s.files            += Dir.glob('tasks/**/*')
  s.executables       = []
  s.license           = 'MIT'

  s.extra_rdoc_files  = ['LICENSE', 'README.md']
  s.rdoc_options      = ['--charset=UTF-8']

  s.add_dependency 'connection_pool', '~> 2.2.2'
  s.add_dependency 'mono_logger', '~> 1.0'
  s.add_dependency 'multi_json', '~> 1.0'
  s.add_dependency 'redis-namespace', '~> 1.6'
  s.add_dependency 'sinatra', '>= 0.9.2'
  s.add_dependency 'statsd-ruby', '~> 1'
  s.add_dependency 'vegas', '~> 0.1.2'

  s.description = <<description
    Resque is a Redis-backed Ruby library for creating background jobs,
    placing those jobs on multiple queues, and processing them later.

    Background jobs can be any Ruby class or module that responds to
    perform. Your existing classes can easily be converted to background
    jobs or you can create new classes specifically to do work. Or, you
    can do both.

    Resque is heavily inspired by DelayedJob (which rocks) and is
    comprised of three parts:

    * A Ruby library for creating, querying, and processing jobs
    * A Rake task for starting a worker which processes jobs
    * A Sinatra app for monitoring queues, jobs, and workers.
description
end
