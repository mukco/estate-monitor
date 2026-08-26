# frozen_string_literal: true

require "spec_helper"
require "support/solid_queue"
require "estate/monitor/sources/solid_queue"

RSpec.describe Estate::Monitor::SolidQueueSource do
  subject(:source) { described_class }

  # The one test that would have caught all of this. Every section is wrapped
  # in `safe`, so a section that raises reports a sentence instead of a number
  # and the panel renders a plausible-looking nothing. Three of the four
  # sections below did exactly that in production for the life of the gem.
  describe ".snapshot" do
    it "answers every section without falling back to an error string" do
      unavailable = source.snapshot.select { |_, v| v.is_a?(Hash) && v.key?(:unavailable) }
      expect(unavailable).to be_empty
    end
  end

  describe "finished work" do
    it "counts a job that finished inside the window" do
      job!(finished_at: 2.hours.ago)
      expect(source.totals[:finished_last_24h]).to eq(1)
    end

    it "does not count a job that has not finished" do
      job!(finished_at: nil)
      expect(source.totals[:finished_last_24h]).to eq(0)
    end

    it "does not count a job that finished before the window" do
      job!(finished_at: 3.days.ago)
      expect(source.totals[:finished_last_24h]).to eq(0)
    end

    it "reports turnaround for the last hour" do
      job!(created_at: 10.minutes.ago, finished_at: 10.minutes.ago + 4)
      timing = source.timing
      expect(timing[:finished_last_hour]).to eq(1)
      expect(timing[:turnaround_ms][:max]).to be_within(50).of(4_000)
    end

    it "names the slowest class rather than the slowest row" do
      job!(class_name: "SlowJob", created_at: 5.minutes.ago, finished_at: 5.minutes.ago + 30)
      job!(class_name: "SlowJob", created_at: 5.minutes.ago, finished_at: 5.minutes.ago + 20)
      expect(source.timing[:slowest].first).to include(class_name: "SlowJob", count: 2)
    end
  end

  describe ".recent" do
    it "lists what has finished, newest first, with how long it took" do
      job!(class_name: "OldJob", created_at: 3.hours.ago, finished_at: 3.hours.ago + 1)
      job!(class_name: "NewJob", created_at: 1.hour.ago, finished_at: 1.hour.ago + 2)

      rows = source.recent[:rows]
      expect(rows.map { |r| r[:class_name] }).to eq(%w[NewJob OldJob])
      expect(rows.first[:turnaround_ms]).to be_within(50).of(2_000)
    end

    it "leaves out work that has not finished" do
      job!(class_name: "StillGoing", finished_at: nil)
      expect(source.recent[:rows]).to be_empty
    end
  end

  describe ".recurring" do
    let!(:task) do
      SolidQueue::RecurringTask.create!(
        key: "warm_cache", schedule: "every hour at minute 12", class_name: "SpecJob"
      )
    end

    # The bug this replaces read `last_enqueued_at` off the task row behind a
    # respond_to? guard. There is no such column, so the guard held and every
    # task on every app reported "no last run" for ever.
    it "takes the last run from the recurring executions, not from the task row" do
      run_at = 30.minutes.ago
      SolidQueue::RecurringExecution.create!(job_id: job!.id, task_key: "warm_cache", run_at: run_at)

      row = source.recurring.first
      expect(row[:last_enqueued_at]).to eq(run_at.utc.iso8601)
    end

    it "reports no last run when nothing has been recorded" do
      expect(source.recurring.first[:last_enqueued_at]).to be_nil
    end

    it "reports the most recent run when a task has fired more than once" do
      SolidQueue::RecurringExecution.create!(job_id: job!.id, task_key: "warm_cache", run_at: 3.hours.ago)
      SolidQueue::RecurringExecution.create!(job_id: job!.id, task_key: "warm_cache", run_at: 1.hour.ago)

      expect(source.recurring.first[:last_enqueued_at]).to eq(1.hour.ago.utc.iso8601)
    end

    # The fact the reader needs beside the last run: "due at 14:12, last ran at
    # 13:12" is a missed tick, and neither half of that sentence is a judgement.
    it "says when the schedule last came due" do
      expect(Time.iso8601(source.recurring.first[:due_at])).to be <= Time.now.utc
    end

    it "survives a schedule it cannot parse" do
      allow_any_instance_of(SolidQueue::RecurringTask).to receive(:previous_time).and_raise(ArgumentError)
      expect(source.recurring.first[:due_at]).to be_nil
    end
  end

  describe ".failures" do
    # Solid Queue's own message for a job whose worker was killed contains a
    # colon-space, at "last heartbeat at: ". The old code split the serialised
    # error there and called the halves a class and a message, which is why the
    # panel showed a title ending mid-sentence and a body starting mid-date.
    let(:pruned_message) do
      "Process was found dead and pruned (last heartbeat at: 2026-08-26 10:51:59 -0400)"
    end

    it "reads the class and the message rather than splitting the stored hash" do
      failure!(job: job!, exception_class: "SolidQueue::Processes::ProcessPrunedError",
               message: pruned_message)

      row = source.failures.first
      expect(row[:error_class]).to eq("SolidQueue::Processes::ProcessPrunedError")
      expect(row[:error_message]).to eq(pruned_message)
    end

    it "marks a lost container apart from a job that threw" do
      failure!(job: job!, exception_class: "SolidQueue::Processes::ProcessPrunedError",
               message: pruned_message)
      failure!(job: job!, exception_class: "ActiveRecord::RecordInvalid", message: "Name can't be blank")

      expect(source.failures.map { |f| f[:pruned] }).to contain_exactly(true, false)
    end

    it "carries the queue and class of the job that failed" do
      failure!(job: job!(class_name: "WarmCacheJob", queue: "cache_warming"),
               exception_class: "RuntimeError", message: "nope")

      expect(source.failures.first).to include(queue: "cache_warming", class_name: "WarmCacheJob")
    end
  end

  describe ".failure_counts" do
    before do
      failure!(job: job!, exception_class: "RuntimeError", message: "today", created_at: 2.hours.ago)
      failure!(job: job!, exception_class: "RuntimeError", message: "this week", created_at: 3.days.ago)
      failure!(job: job!, exception_class: "SolidQueue::Processes::ProcessPrunedError",
               message: "pruned", created_at: 30.days.ago)
    end

    # Nothing deletes a failed execution, so the lifetime total is an archive.
    # The windows are what makes it readable: three failures, one of them
    # today, one of them a lost container a month ago.
    it "separates what happened lately from what has ever happened" do
      counts = source.failure_counts
      expect(counts[:total]).to eq(3)
      expect(counts[:last_24h]).to eq(1)
      expect(counts[:last_7d]).to eq(2)
    end

    it "counts the ones that were only a worker going away" do
      expect(source.failure_counts[:pruned]).to eq(1)
    end
  end

  describe ".retention" do
    it "says how far back the history can see" do
      expect(source.retention[:finished_jobs_after_seconds]).to eq(SolidQueue.clear_finished_jobs_after.to_i)
    end
  end
end
