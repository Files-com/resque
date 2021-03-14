class LongJobRun < ApplicationRecord
  include RedisBacked
  attr_accessor :existing_run

  property :args_hash, type: :string, limit: 255
  property :elapsed_time, type: :float
  property :finished_at, type: :datetime
  property :in_progress, type: :boolean, default: true
  property :job, type: :string, limit: 255
  property :last_checkin_at, type: :datetime
  property :last_regional_checkin_at, type: :datetime
  property :queued_at, type: :datetime
  property :message, type: :text
  property :most_recent, type: :boolean, default: "0", null: false
  property :rerun_at_completion, type: :boolean, default: "0", null: false
  property :runs, type: :integer, default: "0", null: false
  property :state_cleared, type: :boolean, default: "0", null: false
  property :uuid, type: :string, limit: 255
  property :work_units, type: :integer, default: "0", null: false
  property :work_unit_average_time, type: :float
  property :work_unit_total_time, type: :float
  json_property :args
  property :state, type: :text, limit: (2**32) - 1
  serialize :state, Serializers::JSON
  enum_property :status, [ :queued, :running, :completed, :failed ], default: :queued
  timestamps

  add_index [ :in_progress, :job ], name: :index_in_progress_job_b3
  add_index [ :most_recent, :shard_id, :job, :args_hash ], name: :index_most_recent_b3
  add_index [ :status, :most_recent, :args_hash ], name: :index_status_args
  add_index [ :status, :created_at ], name: :index_status_created_at
  add_index [ :state_cleared, :created_at ], name: :index_state_cleared_at_created_at
  add_index [ :uuid ], name: :index_uuid

  before_create :set_vars
  after_create :update_overlapping_jobs
  after_create :enqueue_job

  redis_index :job, :in_progress
  redis_index :job, :most_recent
  redis_index :job, :shard_id, :args_hash, :most_recent
  redis_index :state_cleared, :created_at
  redis_index :status, :created_at
  redis_index :status, :most_recent, :created_at
  redis_index :status, :last_checkin_at
  redis_index :status, :most_recent
  redis_index :status, :queued_at
  redis_index :uuid

  compress_column :state

  def enqueue_job
    Resque.enqueue_to job.constantize.enqueue_to_queue, job.constantize, uuid
  end

  def failed?
    status == :failed
  end

  def has_args?
    args.is_a?(Array) and !args.empty?
  end

  def requeue_job
    LongJobRun.create(job: job, queued_at: Time.now, most_recent: true, args: args, state: state, shard: shard)
  end

  def set_vars
    self.args_hash = self.class.hash_from_args(args) if has_args?
    self.uuid = SecureRandom.uuid
  end

  def update_overlapping_jobs
    query_params = {
      job: job,
      shard_id: shard_id,
      args_hash: args_hash,
      most_recent: true
    }
    LongJobRun.update_all(query_params, { most_recent: false, state: nil, state_cleared: true }, { exclude_ids: [ id ] })
  end

  def enqueue_unique_key
    LongJobRun.enqueue_unique_key(job, shard_id, args_hash)
  end

  def self.enqueue_unique_key(*search)
    "LongJob::EnqueueUnique::#{search.map(&:to_s).join("-")}"
  end

  def self.get_for_resque_status(uuids)
    get_by_uuid(uuids, select_fields: [ :args, :shard_id, :uuid, :id ])
  end

  def self.hash_from_args(args)
    Digest::MD5.hexdigest(JSON.dump(args))
  end

  def self.purge
    updates = {
      state: nil,
      state_cleared: true,
      status: :failed,
      finished_at: Time.now,
      in_progress: false
    }
    stalled_runs =
      range_update_all({ status: :running, last_checkin_at: 0 }, { status: :running, last_checkin_at: 5.minutes.ago.to_i }, { message: "Failed by LongJobRun.purge for running too long." }.merge(updates), returning_records: true) +
      range_update_all({ status: :queued, queued_at: 0 }, { status: :queued, queued_at: 1.hour.ago.to_i }, { message: "Failed by LongJobRun.purge for being queued too long." }.merge(updates), returning_records: true)

    requeue_stalled_runs(stalled_runs)

    scan_delete_by_status_most_recent_created_at("completed:false:0", "completed:false:#{15.minutes.ago.to_i}")
    scan_delete_by_status_most_recent_created_at("completed:true:0", "completed:true:#{8.days.ago.to_i}")
    scan_delete_by_status_most_recent_created_at("failed:false:0", "failed:false:#{15.minutes.ago.to_i}")

    most_recent_failures = get_by_status_most_recent(:failed, true)
    deleted_shard_ids = shard.with_deleted.select(:id).where(id: most_recent_failures.map(&:shard_id)).deleted.all.map(&:id)
    run_ids_to_delete = []

    most_recent_failures.each do |r|
      if r.shard_id and deleted_shard_ids.include?(r.shard_id)
        run_ids_to_delete << r.id
      else
        r.requeue_job unless r.args_hash.nil?
      end
    end

    delete_by_ids(run_ids_to_delete)
  end

  def self.requeue_stalled_runs(stalled_runs)
    stalled_runs.each do |stalled_run|
      stalled_run.requeue_job if stalled_run.has_args?
    end
  end
end
