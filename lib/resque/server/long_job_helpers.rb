Resque::Server.helpers do
  def long_job_enabled?
    Object.const_defined?(:LongJob) && LongJobRun.respond_to?(:get_for_resque_status)
  end

  def long_job?(args)
    return false unless long_job_enabled?
    return false unless args&.size == 1

    UUID.validate(args[0])
  end

  def get_uuid(args)
    return unless long_job?(args)

    args[0]
  end

  def get_long_job(args)
    uuid = args[0]

    LongJobRun.get_for_resque_status(uuid).first
  end

  def smart_args(args)
    return args unless long_job?(args)

    get_long_job(args)&.args
  end

  def long_job_site_id(args)
    return nil unless long_job?(args)

    get_long_job(args)&.site_id
  end

  def add_long_job_to_jobs_running(jobs_running)
    return jobs_running unless long_job_enabled?

    uuids = jobs_running.map { |_thread, job| get_uuid(job.dig('payload', 'args')) }.compact
    long_jobs = LongJobRun.get_for_resque_status(uuids).to_a
    jobs_running.each do |_thread, job|
      job['long_job'] = long_jobs.find { |lj| lj[:uuid] == get_uuid(job.dig('payload', 'args')) }
    end

    jobs_running
  end

  def add_long_job_to_resque_peek(jobs)
    return jobs unless long_job_enabled?

    uuids = jobs.map { |job| get_uuid(job.dig('args')) }.compact
    long_jobs = LongJobRun.get_for_resque_status(uuids).to_a
    jobs.each do |job|
      job['long_job'] = long_jobs.find { |lj| lj[:uuid] == get_uuid(job.dig('args')) }
    end

    jobs
  end
end
