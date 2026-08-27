# frozen_string_literal: true

source "https://rubygems.org"
gemspec
gem "activerecord", ">= 7.1"
gem "rspec"
gem "pg"
# The specs boot a Rails application and load Solid Queue's own schema into an
# in-memory database — see spec/support/solid_queue.rb for why doubles were not
# enough. None of this is a runtime dependency: an app mounting the engine
# already has Rails, and brings whatever Solid Queue it runs.
gem "rails", ">= 7.1"
gem "solid_queue", ">= 1.0"
gem "sqlite3"
