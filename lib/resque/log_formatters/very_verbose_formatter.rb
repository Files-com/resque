module Resque
  class VeryVerboseFormatter
    def call(_serverity, _datetime, _progname, msg)
      time = Time.now.strftime('%H:%M:%S %Y-%m-%d')
      "** [#{time}] #{$PROCESS_ID}: #{msg}\n"
    end
  end
end
