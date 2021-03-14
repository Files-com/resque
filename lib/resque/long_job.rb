class LongJob < Resque::Job
  CHECKIN_INTERVAL = 30
  ENQUEUE_INTERVAL = 5.minutes
  TARGET_LENGTH = 15.seconds

  @queue = :high

  def self.long_job_perform(*_args)
    raise "This class is not meant to be invoked directly as a job.  Enqueue a child class."
  end

  def self.perform(uuid)
    if run = LongJobRun.get_by_uuid(uuid).first
      Runner.new(run, self).perform
    end
  end

  def self.needed_for_ui?
    false
  end

  def self.enqueue_to_queue
    needed_for_ui? ? :statused : :medium
  end

  def self.requeue_to_queue
    needed_for_ui? ? :statused : :low
  end

  def self.enqueue(job, shard_id = nil, *args)
    args = nil if args.empty?
    LongJobRun.create(job: job.to_s, shard_id: shard_id, args: args, queued_at: Time.now, most_recent: true)
  end

  def self.enqueue_unique(job, shard_id = nil, *args)
    args = nil if args.empty?
    search = [ job.to_s, shard_id.to_s, LongJobRun.hash_from_args(args) ]
    CriticalSection.with_exclusive_lock(LongJobRun.enqueue_unique_key(*search)) do
      existing_run = LongJobRun.get_by_job_shard_id_args_hash_most_recent(*search, true).first
      if existing_run and [ :queued, :running ].include? existing_run.status
        existing_run.existing_run = true
        existing_run
      else
        LongJobRun.create(job: job.to_s, shard_id: shard_id, args: args, queued_at: Time.now, most_recent: true)
      end
    end
  end

  def self.enqueue_debounce(job, shard_id = nil, *args)
    run = enqueue_unique(job, shard_id, *args)
    run.update(rerun_at_completion: true) if run.existing_run and !run.rerun_at_completion?
    run
  end

  def self.enqueue_bulk(job, shard_id = nil, *args)
    args = nil if args.empty?
    args_hash = (args ? LongJobRun.hash_from_args(args) : nil)
    uuid = SecureRandom.uuid
    { job: job.to_s, uuid: uuid, shard_id: shard_id, args: args, args_hash: args_hash, queued_at: Time.now, most_recent: true }
  end

  def self.config
    @config ||= Rails.configuration.long_job
  end

  def self.configured_jobs
    LongJob.config.jobs.map(&:first)
  end

  def self.job(name, options)
    config.jobs << [ name, options ]
  end

  def self.job_configuration(job, enqueuer, last, in_progress)
    LongJob.config.jobs.select { |name, _options| name == job }.map { |name, options|
      JobConfiguration.new(name, options, enqueuer, last, in_progress)
    }
  end

  def self.scheduled_job?(job)
    configured_jobs.include?(job)
  end

  # Disables adding to the Resque failed queue, so LongJob will handle retries on its own.
  def skip_failed_queue?
    true
  end
end
