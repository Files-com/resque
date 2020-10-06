module Resque
  class QuietFormatter
    def call(_serverity, _datetime, _progname, _msg)
      ''
    end
  end
end
