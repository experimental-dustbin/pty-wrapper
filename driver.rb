require 'pty'
require 'fiber'

class PtyDriver
  # The command argument is what is passed to spawn, e.g.
  # `PtyDriver.new("gnutls-cli --insecure -s -p 587 smtp.gmail.com")`
  # Some instance variables are exposed in case upstream callers need
  # to interact with read side of the IO pipes and the current buffer
  attr_reader :leader, :err_read, :buffer
  def initialize(command)
    @leader, follower = PTY.open
    # This will be used to interact with the standarnd input of the program.
    # The read end will not be used.
    read, @write = IO.pipe
    # Standard error streams. Similar to the above but the write end will be unused.
    @err_read, err_write = IO.pipe
    # Now we spawn the program that we want to control/drive
    @pid = spawn(command, in: read, out: follower, err: err_write)
    # Close the unused pipes
    [follower, read, err_write].each(&:close)
    # We need a thread to wait on the process otherwise we will get a zombie PID.
    @reaper_thread = Thread.new { Process.waitpid(@pid) }
    # We'll be using a fiber to read the output from the spawned program
    # in a non-blocking way and accumulating it in a buffer. This is the
    # default value of how much to read but when resuming the reader fiber
    # upstream callers can set the length to some other value
    output_buffer_length = 1000
    # We need to store the buffer output because it is possible whatever
    # we are trying to match wasn't fully captured. Flushing the buffer
    # is application specific and is left to the upstream caller
    @buffer = ""
    @output_reader = Fiber.new do |read_length|
      # As long as the reaper thread is alive we assume that the spawned
      # program is also alive
      while @reaper_thread.alive?
        begin
          output = @leader.read_nonblock(read_length || output_buffer_length)
          @buffer << output
        rescue IO::WaitReadable
          # Nothing to do
        end
        read_length = Fiber.yield
      end
      # Once the reaper thread has reaped the process ID we flush whatever
      # is left in the pipe one last time
      begin
        loop do
          output = @leader.read_nonblock(read_length || output_buffer_length)
          @buffer << output
        end
      rescue IO::WaitReadable
        # Nothing to do because there is nothing left to read
      end
    end
  end
  # This flushes the output buffer by setting it to the empty string.
  # If a block is given then it is called with the buffer before
  # it is reset
  def flush!(&blk)
    blk.call(@buffer) if blk
    @buffer = ""
  end
  # When driving the program we'll need to wait on some output with
  # regex patterns so this method does that by reading from the output.
  # There is also an optional parameter that specifies how much to read
  # from the output. The default value is `nil` which falls back to the
  # default read length when the reader fiber is initialized. It's
  # unlikely that callers will need to set the read length but it is there
  # in case it's needed.
  def wait(pattern, read_length = nil)
    wait_time = 0.1
    # Make sure the process is alive.
    unless @reaper_thread.alive?
      raise StandardError, "Can not wait on output from a dead process: #@pid"
    end
    # Make sure the output reader fiber is alive
    unless @output_reader.alive?
      raise StandardError, "Can not resume a dead fiber"
    end
    # If the process is alive we try to get the output from the fiber and match
    # it against the pattern we are waiting for
    loop do
      begin
        @output_reader.resume(read_length)
        break if pattern =~ @buffer
        sleep(wait_time)
      rescue FiberError => e
        # The fiber is dead so we break out of the loop
        break
      end
    end
  end
  # Interacting with the program requires writing to its standard input so
  # this method does that. The assumption is that the argument can be safely
  # written to an IO pipe
  def write(w)
    # Make sure the process is alive
    unless @reaper_thread.alive?
      raise StandardError, "Can not write to a pipe of a dead process: #@pid"
    end
    # There is a race condition, even if the process is alive it can die when
    # we try to write to it so we have to catch broken pipe errors as well
    begin
      @write.write(w)
    rescue Errno::EPIPE => e
      nil
    end
  end
  # Sometimes we need to send signals to the controlled process so this method does that
  def signal(sig)
    Process.kill(sig, @pid)
  end
end
