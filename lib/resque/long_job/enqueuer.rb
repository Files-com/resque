class LongJob
  class Enqueuer
    def initialize(job)
      @job = job
    end

    def in_progress_count
      LongJobRun.count_by_job_in_progress(@job, true)
    end

    def most_recent
      LongJobRun.get_by_job_most_recent(@job, true)
    end

    def perform
      if @job
        LongJob.job_configuration(@job, self, most_recent, in_progress_count).each(&:enqueue)
      else
        LongJobRun.purge
        LongJob.configured_jobs.each do |job|
          Resque.enqueue LongJobEnqueueJob, job
        end
      end
    end

    def runs_per_day
      1.day / ENQUEUE_INTERVAL
    end
  end
end
