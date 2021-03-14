# Files.com's Fork of Resque

Resque is awesome, and it's original README is available at its main
repository at https://github.com/resque/resque

We've used Resque in production for nearly 10 years, but we want to be
able to run millions of jobs per minute, so we've redesigned Resque
for enhanced performance.


## Acknowledgements and A Warning

First, a Huge Thank You to Chris Wanstrath and GitHub for all their work
on Resque thus far.  We are truly standing on the shoulders of giants
with this work.

As with most forks maintained by Files.com, we've explictly removed
functionality not needed for our applications.  We find that it's easier
to take a radically new direction when we aren't encumbered by having to
support backwards compatibility.

If there is interest from the community, we are happy to work in
the future on re-introducing this functionality.

Many of the changes in this fork are experimental.  We use this fork in
production at Files.com, but it has not been stress tested in the way
the original Resque code has been.


## Hybrid Process/Thread Model

We've moved the concurrency model of Resque to a three-tiered system.

There is now a Master Process, which forks off Worker Processes, which
run Worker Threads.

Each Worker Process regularly exits and is replaced by a new Worker
Process.  This preserves the original Resque behavior of memory
management while allowing additional scale.  In production we are able
to run thousands of jobs per FORK syscall, rather than the 1 job per
fork syscall that the stock Resque provides.

In addition to massively reducing the number of system calls required,
this structure also has the benefit of allowing a single Rake task to be
integrated to your system's service management infrastructure.


## Configuration

This fork adds a few new configuration variables, which are passed via
the ENV, just like stock Resque.

* `WORKER_COUNT` - default 1 - number of worker processes to run
* `THREAD_COUNT` - default 1 - number of threads to run per worker
  process
* `JOBS_PER_FORK` - default 1 - number of jobs to run each time a worker
  process is forked

The default values of 1/1/1 emulate stock Resque fairly well.  In
Production at Action Verb, we run a worker count equal to the number of
cores on the machine, a thread count of 4-16, and a `JOBS_PER_FORK`
of about 100-1000.


### Statsd Reporting

This fork can report jobs to Statsd when processed.  Just set the
following ENVs:

* `STATSD_HOST` - statsd server hostname
* `STATSD_PORT` - statsd server port
* `STATSD_KEY` - key prefix for statsd counters (job name will be appended)

## Signals

Because workers now run multiple jobs at once, the signal responses have
been changed as well.

* TERM/INT: Shutdown immediately, kill current jobs immediately.
* QUIT: Shutdown after the current jobs have finished processing.
* USR1: Kill current jobs immediately, continue processing jobs.
* USR2: Don't process any new jobs
* CONT: Start processing jobs again after a USR2

If you want to gracefully shutdown a Resque worker, use `QUIT`.

If you want to stop processing jobs, but want to leave the worker running
(for example, to temporarily alleviate load), use `USR2` to stop processing,
then `CONT` to start it again.

If you want to kill stale or stuck job(s), use `USR2` to stop the
processing of new jobs.  Wait for the unstuck jobs to finish, then use
`USR1` to simultaneously kill the stuck job(s) and restart processing.

Signals sent to the Master Process will affect all Worker Processes and
Worker Threads.  Signals sent to a specific Worker Process will affect
that Worker Process only.


## Internal Changes

The Worker class was being overloaded to refer to both an active worker
(parent and child) and the representation of a worker on another machine
when viewing the Web UI.  This has been detangled.  We now have a
Worker, WorkerThread, WorkerManager, and WorkerStatus.


# LongJob

LongJob is a framework for making long running jobs sane.  On Files.com, we have
some jobs such as Region moves, restores, etc., that can run for hours or even days.

Additionally we have Remote server syncs which already number well into the dozens
that run evety 5-15 minutes.

At Files.com, we run a forked version of Resque that is multi-threaded, where we run
several jobs at once in the same Ruby VM.  One downside to this is that a single long
running job can prevent the entire app from restarting.

As a company that believes in continuous deployment where a typical workday will see
potentially 10 or more deploys, its a problem if a single long running job can block deployments.

Other problems with jobs that run too long include:

- too much RAM usage
- no way to easily share resources equitably between customers/jobs when resources are scarce
- inability to recover from failures, such as machine reboots, etc.

LongJob solves this by creating a framework for jobs that could be long running (though they may not have to be) where we break the job down into smaller Resque jobs that are designed to run for just 15 seconds.

LongJob maintains *state* for each job that is stored in Redis
in between the smaller Resque jobs.  LongJob handles scheduling the smaller Resque jobs,
and provides a DSL that makes it easy to save the state needed between the smaller jobs.

By targeting 15 seconds for the smaller Resque jobs, we ensure that the smaller Resque
job will never be force-killed by Files.com's Resque restart process, which kills any
Resque job that has runs for longer than 60 seconds.  Additionally we can detect failures of those smaller jobs and restart the LongJob from where we left off.

This DSL is key to having LongJob be a great developer experience and powerful tool, but
you have to understand how it works under the hood or you will create bad code.

So let's talk about the DSL.


### Defining a LongJob job

```
class MyJob < LongJob
  def self.long_job_perform(runner, site, *args)

  end
end
```

Currently, the notion of a Site is hardcoded into LongJob.  At some point we will likely
refactor LongJob into its own gem that is independent from files-rails and Site will
likely lose its status as something special.  But for now, you create a LongJob by creating a class in `app/jobs` that inherits from LongJob.  By convention, we name the jobs after the class that they relate to and the action they do on that class.

Generally, by convention, also tend to keep most of the logic out of the job class and simply pass the runner into the main object being operated on.  For example:

```
class SiteDoThingJob < LongJob
  def self.long_job_perform(runner, site, *args)
    site.do_thing(runner)
  end
end
```

#### The Runner Object

The runner object makes available several methods that make it easy to manage the
LongJob lifecycle.

The first method to be aware of is the `#state` method, which saves and retrieves state
in the Runner:

```
class SiteDoThingJob < LongJob
  def self.long_job_perform(runner, site, *args)
    runner.state("foo", "bar") # sets state `foo` to `bar`
    runner.state("foo") # => "bar"
  end
end
```

#### Work Unit

The next important concept is the Work Unit.  `Runner#work_unit` is a DSL method that
accepts a block representing a single unit of "Work".  The intention is that a work unit
should represent 100-1000ms worth of work.  Less is ok (but potentially wasteful), and more is not ideal.

If a job has been running for more than 15 seconds, the job will terminate at the
beginning of a work_unit block.  If you are using `work_unit` directly, you are
responsible for maintaining state that will allow the job to pick up where you
left off upon restart.

Some jobs don't require any *state* to be able to this, for example, imagine a job type
that pops a thing off an external queue and then does something to it.  In this case
the necessary state (the queue) is already stored externally.

Such a job could be written as follows:


```
class SiteDoThingJob < LongJob
  def self.long_job_perform(runner, site, *args)
    loop do
      break unless runner.work_unit do
        next unless data = ExternalQueue.pop

        data.process
      end
    end
  end
end
```

This is a complete LongJob for this sort of task.  It will run in a single Resque job
for up to 15 seconds, then that Resque job will terminate and a new one will be
enqueued where it will pick up as it left off.

Note that we pop from the external queue and process that data within one work unit block.  We avoid writing it where the pop is outside the block and the processing is inside the block, because in that scenario, the pop could succeed but the block may
not run.  This would result in unperformed work.


#### Work Once

Work Once is a DSL method that internally uses state to ensure that the given block
only runs a single time per LongJob run (not per Resque run).

```
class SiteDoThingJob < LongJob
  def self.long_job_perform(runner, site, *args)
    runner.work_once("setup") { site.setup }
    runner.work_once("finalize") { site.finalize }
  end
end
```

In this scenario, if `site.setup` takes > 15 seconds to run, then `site.setup` will
have run on the first Resque job run and `site.finalize` will run on the second
Resque job run.  If `site.setup` were faster, it would run all in one Resque run.


#### Work Each

Work Each works like Work Once but it runs once for each item in the provided array.
For example:

```
class SiteDoThingJob < LongJob
  def self.long_job_perform(runner, site, *args)
    runner.work_each([ "setup", "finalize" ]) { |method| site.send(method) }
  end
end
```

This code is the equivalent of the above.

Work each is usually used with dynamic array content.


### Preventing Unnecessary (or dangerously) Duplicate Jobs

LongJob provides 2 separate mechanisms for enqueueing jobs in a manner that
prevents duplicate jobs from running at the same time.

The mechanism to use depends on your use case / need.


#### Enqueue Unique

`LongJob.enqueue_unique` will ensure that the job is either queued or currently running.
If it is currently running, a new job will not be enqueued again.

#### Enqueue Debounce

`LongJob.enqueue_debounce` will ensure that the job is either queued or currently running.
If it is currently running, it will be run again once the currently running job is completed.
However, multiple calls to `LongJob.enqueue_debounce` while the same job is running will result
in only one additional run once the job is completed.


### ActiveRecord Extensions

We created some extensions that make it easy to combine the Work Unit DSL with
ActiveRecord queries.


#### Scan Delete and Scan Destroy

`Relation#scan_delete` and `Relation#scan_destroy` will delete or destroy from
a provided relation, breaking up the operation into multiple work units as necessary.

Internally, each batch of 1000 records is worked inside a single work unit.


#### Reviewing Select Loop

`Relation#reviewing_select_loop` will loop through objects that match a query and
run a block for each matching object.  Again, we use work units appropriately.
