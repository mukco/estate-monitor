# frozen_string_literal: true

# A real Solid Queue, on a real schema, in memory.
#
# The alternative was doubles, and doubles are what let four bugs ship: a
# constant that no released Solid Queue defines, a column that has never
# existed, a `respond_to?` guard that swallowed the second, and a hand-rolled
# split of a field the model already parses for you. Every one of them is
# invisible to a test that stubs the model and obvious to a test that boots it.
#
# So the specs boot a Rails application with nothing in it but Active Record,
# Active Job and Solid Queue's own engine, then load Solid Queue's own schema
# template. If this gem's understanding of the schema drifts from the gem that
# owns it, the specs stop.

ENV["RAILS_ENV"] ||= "test"

require "rails"
require "active_record/railtie"
require "active_job/railtie"
# The error-reporting specs drive real requests through the same application
# (see spec/support/errors.rb), so it boots with Action Controller and with
# the engine loaded as an app would load it.
require "action_controller/railtie"
require "solid_queue"
require "estate/monitor"

module EstateMonitorSpec
  class Application < Rails::Application
    config.eager_load = false
    config.logger = Logger.new(IO::NULL)
    config.root = File.expand_path("../dummy", __dir__)
  end
end

Rails.application.initialize!

ActiveRecord::Schema.verbose = false
load File.join(
  Gem.loaded_specs.fetch("solid_queue").full_gem_path,
  "lib/generators/solid_queue/install/templates/db/queue_schema.rb"
)

# Solid Queue validates that a recurring task names a job class that exists.
class SpecJob < ActiveJob::Base
  def perform(*); end
end

module SolidQueueHelpers
  TABLES = %w[
    solid_queue_jobs solid_queue_ready_executions solid_queue_claimed_executions
    solid_queue_failed_executions solid_queue_recurring_executions
    solid_queue_recurring_tasks solid_queue_processes
  ].freeze

  def truncate_solid_queue!
    TABLES.each { |t| ActiveRecord::Base.connection.execute("DELETE FROM #{t}") }
  end

  def job!(class_name: "SpecJob", queue: "default", created_at: Time.current, finished_at: nil)
    SolidQueue::Job.create!(
      class_name: class_name, queue_name: queue, arguments: [],
      created_at: created_at, updated_at: created_at, finished_at: finished_at
    )
  end

  def failure!(job:, exception_class:, message:, created_at: Time.current)
    SolidQueue::FailedExecution.create!(
      job_id: job.id,
      error: { exception_class: exception_class, message: message, backtrace: nil },
      created_at: created_at
    )
  end
end

RSpec.configure do |config|
  config.include SolidQueueHelpers
  config.before { truncate_solid_queue! }
end
