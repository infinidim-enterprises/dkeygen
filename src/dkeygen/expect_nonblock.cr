module Expect
  extend self
  private def wait_readable(ios : Array(IO), timeout : Time::Span? = nil)
    channel = Channel(IO).new

    ios.each do |io|
      spawn do
        # Crystal's event loop will resume this fiber when data is available
        begin
          # Ensure the IO is not already closed before waiting
          next if io.closed?
          # The error indicates IO::FileDescriptor does not have its own wait_readable method.
          # We will call the event loop's wait_readable directly.
          # This expects a Crystal::System::FileDescriptor, and IO::FileDescriptor is one.
          # We cast `io` (which is typed as IO) to IO::FileDescriptor.
          Crystal::EventLoop.current.wait_readable(io.as(::IO::FileDescriptor))
          # Send only if the IO is still open after waiting
          # Also ensure channel itself is not closed, though unlikely here.
          channel.send(io) if !io.closed? && !channel.closed?
        rescue ex : IO::Error
          # Robust logging for IO::Error in wait_readable's helper fiber
          # Avoid complex operations on ex.message directly in the log string template
          # to minimize risk of the logger itself failing.
          err_msg = ex.message || "No message"
          Log.trace { "IO::Error in wait_readable helper for #{io.class} (id: #{io.object_id}): #{err_msg}" }
        # Do not send to channel if an error occurred, timeout will handle it.
        rescue ex # Catch any other unexpected exception
          # Log any other non-IO::Error exception type
          err_msg = ex.message || "No message"
          Log.error { "Non-IO::Error in wait_readable helper for #{io.class} (id: #{io.object_id}): #{ex.class} - #{err_msg}" }
        end
      end
    end

    select
    when ready_io = channel.receive
      [ready_io] # Return as an array
    when timeout(timeout)
      [] of IO
    end
  end

  # Changed signature to accept GpgCommandConfig
  # Assuming GpgCommandConfig is defined elsewhere and accessible here.
  # If GpgCommandConfig is not in the same scope, you might need a `require` statement
  # at the top of this file, e.g., `require "./dkeygen/cli_cmd_dump"` if it's defined there
  # and that file defines the class at the top level.
  # For now, we'll assume it's resolvable by the compiler.
  def interactive_process_nonblock(command : String,
                                   config : GpgCommandConfig)
    Log.debug { "Starting non-blocking interactive process: #{command} #{config.args.join(" ")}" }


    process = Process.new(
      command,
      config.args, # MODIFIED: Use args from config
      input: Process::Redirect::Pipe,  # Crystal interacts with PTY master via a pipe
      output: Process::Redirect::Pipe, # Crystal interacts with PTY master via a pipe
      error: Process::Redirect::Pipe,  # Crystal interacts with PTY master via a pipe for stderr
      # env: env_vars # Add modified environment
    )

    # Try an initial flush on the input pipe.
    # This is speculative, to see if it affects GPG's perception of the pipe's readiness
    # or prevents it from considering it immediately at EOF or empty.
    begin
      process.input.flush
    rescue ex : IO::Error
      Log.warn { "Warning: Initial flush on process.input failed: #{ex.class} - #{ex.message}" }
    end

    full_output_buffer = IO::Memory.new
    error_output_buffer = IO::Memory.new

    # Channels to synchronize fiber completion
    stdout_done = Channel(Nil).new
    stderr_done = Channel(Nil).new

    interactions_list = config.interactions
    initial_interaction_offset = 0

    # Pre-emptively send the first command if interactions are defined.
    if interactions_list.size > 0
      first_interaction = interactions_list[0]
      first_response = first_interaction["response"]?
      if first_response
        Log.info { "Pre-emptively sending first response: #{first_response.inspect}" }
        begin
          process.input.puts(first_response)
          process.input.flush
          initial_interaction_offset = 1 # Start main loop from the second interaction
        rescue ex : IO::Error
          Log.error { "Failed to send pre-emptive first response '#{first_response.inspect}' due to IO::Error: #{ex.class} - #{ex.message}. Terminating interactions early." }
          # If sending the first command fails, likely no point in continuing.
          # We'll let the interaction loop start with index 0 but it will likely fail or timeout.
          # Alternatively, could set interactions_list to empty or directly exit. For now, log and continue.
        end
      else
        Log.warn { "First interaction is missing a 'response', cannot send pre-emptively." }
      end
    end

    # Fiber to handle stdout and interactions
    spawn do
      # Buffer to accumulate raw bytes from process.output
      # This can contain partial lines or multiple full lines.
      output_accumulator = IO::Memory.new
      interaction_index = initial_interaction_offset # Start from 0 or 1 based on pre-emptive send
      Log.debug { "Starting stdout interaction loop. Expecting #{interactions_list.size} interactions. Starting at index #{interaction_index}." }

      # Outer loop: iterates through each configured interaction
      while interaction_index < interactions_list.size
        current_interaction_config = interactions_list[interaction_index]
        pattern_to_match = current_interaction_config["pattern"]?
        response_to_send = current_interaction_config["response"]?

        unless pattern_to_match && response_to_send
          Log.error { "Interaction ##{interaction_index + 1} (config index #{interaction_index}): Invalid, missing 'pattern' or 'response'." }
          interaction_index += 1 # Skip this faulty interaction configuration
          output_accumulator.clear # Clear accumulator, start fresh for next interaction
          next # Continue to the next interaction in the outer while loop
        end

        Log.trace { "Interaction ##{interaction_index + 1}: Target pattern: #{pattern_to_match.inspect}. Accumulator state: #{output_accumulator.to_s.inspect}" }

        # Inner loop: processes data from output_accumulator and reads more if needed.
        # This loop continues until the current interaction is matched or an error/timeout occurs.
        loop do
          accumulator_string = output_accumulator.to_s
          newline_pos = accumulator_string.index('\n')

          if newline_pos
            # A full line is present in the accumulator
            line_extracted = accumulator_string[0..newline_pos] # Includes '\n'
            Log.trace { "Interaction ##{interaction_index + 1}: Processing line from accumulator: #{line_extracted.inspect}" }

            # Remove the extracted line from the accumulator
            remaining_accumulator_content = accumulator_string[(newline_pos + 1)..-1]
            output_accumulator.clear
            output_accumulator << remaining_accumulator_content

            # Check if the extracted line contains the pattern
            if line_extracted.includes?(pattern_to_match)
              begin
                Log.info { "Interaction ##{interaction_index + 1}: Matched pattern in line: #{line_extracted.inspect}. Sending response: #{response_to_send.inspect}" }
                process.input.puts(response_to_send)
                process.input.flush

                interaction_index += 1 # Move to the next interaction
                # The output_accumulator now contains data that came after the matched line.
                # This is generally fine, as it might be the start of the next prompt's output.
                break # Exit inner 'loop do', to proceed to the next interaction via the outer 'while' loop
              rescue ex : IO::Error
                Log.error { "Interaction ##{interaction_index + 1}: Failed to send response '#{response_to_send.inspect}' due to IO::Error: #{ex.class} - #{ex.message}. Terminating interactions." }
                interaction_index = interactions_list.size # Force outer loop to terminate
                break # Exit inner 'loop do'
              end
            else
              # Line extracted, but no match for current interaction's pattern.
              Log.trace { "Interaction ##{interaction_index + 1}: Line did not match pattern. Discarding line. Continuing with accumulator: #{output_accumulator.to_s.inspect}"}
              # The line is now removed from accumulator. Loop again in inner 'loop do'
              # to check remaining accumulator or trigger a read if it's empty.
              next
            end
          else
            # No full line in accumulator, need to read more data
            Log.trace { "Interaction ##{interaction_index + 1}: No full line in accumulator. Waiting for more output." }
            ready_ios = wait_readable([process.output], PIPE_READ_TIMEOUT)

            if ready_ios.empty?
              Log.warn { "Stdout read timeout for interaction ##{interaction_index + 1}. Accumulator: #{output_accumulator.to_s.inspect}. Terminating interactions." }
              interaction_index = interactions_list.size # Force outer loop to terminate
              break # Exit inner 'loop do'
            end

            # Output is readable, attempt to read
            begin
              temp_buffer = Bytes.new(1024) # Read up to 1KB at a time
              bytes_read = Crystal::EventLoop.current.read(process.output, temp_buffer)

              if bytes_read > 0
                chunk = String.new(temp_buffer[0, bytes_read])
                Log.trace { "Interaction ##{interaction_index + 1}: Read chunk: #{chunk.inspect}" }
                full_output_buffer << chunk    # Log all output to the main buffer
                output_accumulator << chunk    # Add to our working accumulator
              # Loop back in inner 'loop do' to try extracting lines again from the now larger accumulator
              else
                # bytes_read == 0 (EOF)
                Log.debug { "Interaction ##{interaction_index + 1}: Read 0 bytes (EOF) from process.output." }
                interaction_index = interactions_list.size # Force outer loop to terminate
                break # Exit inner 'loop do'
              end
            rescue ex : IO::EOFError
              Log.info { "Interaction ##{interaction_index + 1}: EOF reached on process.output." }
              interaction_index = interactions_list.size # Force outer loop to terminate
              break # Exit inner 'loop do'
            rescue ex : IO::Error # Includes "Closed stream"
              Log.warn { "Interaction ##{interaction_index + 1}: Error reading from process.output: #{ex.class} - #{ex.message}. Accumulator: #{output_accumulator.to_s.inspect}. Terminating interactions." }
              interaction_index = interactions_list.size # Force outer loop to terminate
              break # Exit inner 'loop do'
            end
          end
        end # End of inner 'loop do' (processing/reading for current interaction)

        # If inner loop broke due to EOF/error/timeout, interaction_index was set to terminate outer loop.
      end # End of outer 'while' loop (iterating through interactions)

      Log.debug { "Finished stdout interaction loop." }

      # Read any remaining output from stdout
      # This part remains largely the same, but uses output_accumulator if you want to log its final state,
      # though full_output_buffer is the primary record of all stdout.
      Log.debug { "Now reading any remaining stdout..." }
      loop do
        # Use a very short timeout or no timeout for flushing remaining output
        ready_ios = wait_readable([process.output], 0.1.seconds)

        if ready_ios.empty?
          Log.trace { "No more immediate remaining stdout." }
          break
        end

        begin
          temp_buffer = Bytes.new(4096) # Larger buffer for remaining output
          # IO::FileDescriptor is a Crystal::System::FileDescriptor
          bytes_read = Crystal::EventLoop.current.read(process.output, temp_buffer)
          if bytes_read > 0
            chunk = String.new(temp_buffer[0, bytes_read])
            Log.trace { "Read remaining stdout chunk: #{chunk.inspect}" }
            full_output_buffer << chunk
          else # 0 bytes read, means EOF
            Log.debug { "EOF on remaining stdout read (0 bytes from read_nonblock)." }
            break
          end
        rescue ex : IO::EOFError
          Log.debug { "EOF on remaining stdout read (EOFError)." }
          break
        rescue ex : IO::Error
          Log.warn { "Error reading remaining stdout: #{ex.class} - #{ex.message}" }
          break
        end
      end
      Log.debug { "Finished reading remaining stdout." }
      stdout_done.send(nil)
    end

    # Fiber to handle stderr
    spawn do
      loop do
        # Wait for data on stderr with a timeout
        # Use a slightly shorter timeout or same as stdout, adjust as needed
        ready_ios = wait_readable([process.error], PIPE_READ_TIMEOUT - 1.second)

        if ready_ios.empty?
          Log.trace { "Stderr read timeout or no more data. Breaking stderr fiber." }
          break # Exit the loop to prevent indefinite hang
        end

        begin
          temp_buffer = Bytes.new(1024)
          bytes_read = Crystal::EventLoop.current.read(process.error, temp_buffer)
          if bytes_read > 0
            chunk = String.new(temp_buffer[0, bytes_read])
            Log.trace { "Read stderr chunk: #{chunk.inspect}" }
            error_output_buffer << chunk
          else # 0 bytes read, means EOF
            Log.debug { "EOF on stderr read (0 bytes from read)." }
            break
          end
        rescue ex : IO::EOFError
          Log.debug { "EOF on stderr read (EOFError)." }
          break
        rescue ex : IO::Error
          Log.warn { "Error reading stderr: #{ex.class} - #{ex.message}" }
          break
        end
      end
      stderr_done.send(nil)
    end

    status = process.wait
    process.input.close rescue nil
    stdout_done.receive
    stderr_done.receive
    process.output.close rescue nil
    process.error.close rescue nil

    final_error_output = error_output_buffer.to_s
    Log.debug { "Process exited with status: #{status.exit_code}" }
    Log.debug { "Error output: #{final_error_output.inspect}" } if final_error_output.bytesize > 0

    {
      status: status,
      output: full_output_buffer.to_s,
      error: final_error_output
    }
  end
end
