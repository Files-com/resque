module Resque
  class VerboseFormatter
    def call(_serverity, _datetime, _progname, msg)
      "*** #{msg}\n"
    end
  end
end
