#
# Support for calling commands in threads.
#
#

module Async

@@requests = 0
@@max_requests = 16

def Async.run(irc = nil)
  if @@requests >= @@max_requests
    irc.reply 'Too many outstanding requests. Try again in a moment.'
    false
  else
    Thread.new do
      begin
        @@requests += 1
        yield
      ensure
        @@requests -= 1
      end
    end
    true
  end
end

end
