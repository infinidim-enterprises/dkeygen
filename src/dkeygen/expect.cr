module Dkeygen
  module Expect
    extend self
    Log = ::Log.for(self)

    PIPE_READ_TIMEOUT = 5.seconds

    # ameba:disable Metrics/CyclomaticComplexity
    def interactive_process(command : String,
                            config : GpgCommandConfig,
                            env : Process::Env = nil) : NamedTuple(status: Process::Status, output: String, error: String)
      Log.trace { "Starting interactive process: #{command} #{config.args.join(" ")}" }

      process = Process.new(
        command,
        config.args,
        env: env,
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe
      )

      stdin = process.input
      stdout = process.output
      stderr_pipe = process.error

      full_output_buffer = IO::Memory.new
      error_output_buffer = IO::Memory.new

      stderr_done_channel = Channel(Nil).new

      spawn do
        begin
          Log.trace { "stderr fiber started." }
          IO.copy(stderr_pipe, error_output_buffer)
          Log.trace { "stderr fiber: IO.copy finished." }
        rescue ex : IO::Error
          Log.warn { "Error copying stderr in process: #{ex.class} - #{ex.message}" }
        ensure
          Log.trace { "stderr fiber ensuring channel send." }
          Log.trace { "stderr fiber finished." } # Moved before send
          stderr_done_channel.send(nil)
        end
      end

      current_step = 0
      interactions_list = config.interactions

      Log.debug { "Expecting #{interactions_list.size} interactions." }

      begin
        stdout.each_line do |line|
          full_output_buffer << line # Accumulate all stdout
          Log.trace { "(#{current_step + 1}/#{interactions_list.size}): line < #{line.chomp.inspect}" }

          if current_step >= interactions_list.size
            Log.trace { "All interactions completed or no interactions to process. Continuing to read stdout." } if interactions_list.size > 0
            next
          end

          current_interaction_config = interactions_list[current_step]
          pattern_to_match = current_interaction_config["pattern"]?
          response_to_send = current_interaction_config["response"]?

          unless pattern_to_match && response_to_send
            Log.error { "(#{current_step + 1}/#{interactions_list.size}): (config index #{current_step}): Invalid, missing 'pattern' or 'response'." }
            current_step += 1
            next
          end

          Log.trace { "(#{current_step + 1}/#{interactions_list.size}): Checking for pattern #{pattern_to_match.inspect}" }
          if line.includes?(pattern_to_match)
            Log.trace { "(#{current_step + 1}/#{interactions_list.size}): Found: #{pattern_to_match.inspect}" }
            begin
              stdin.puts(response_to_send)
              stdin.flush
              Log.debug { "#{"✓".colorize(:green)} (#{current_step + 1}/#{interactions_list.size}): #{pattern_to_match.inspect} <=- #{response_to_send.inspect}" }
              current_step += 1
            rescue ex : IO::Error
              Log.error { "(#{current_step + 1}/#{interactions_list.size}): Failed to send response '#{response_to_send.inspect}' due to IO::Error: #{ex.class} - #{ex.message}. Terminating interaction attempts." }
              current_step = interactions_list.size
            end
          end
        end
        Log.trace { "stdout.each_line loop finished (EOF or break)." }
      rescue ex : IO::Error
        Log.warn { "Error during stdout.each_line: #{ex.class} - #{ex.message}" }
      ensure
        Log.trace { "stdout.each_line ensure block." }
      end

      Log.trace { "Closing process stdin." }
      stdin.close rescue Log.warn { "Warning: Error closing process stdin, possibly already closed." }

      Log.trace { "Waiting for process to exit." }
      status = process.wait
      Log.trace { "Process has exited. Waiting for stderr fiber." }

      stderr_done_channel.receive
      Log.trace { "Stderr fiber completed." }

      stdout.close rescue nil
      stderr_pipe.close rescue nil

      final_output = full_output_buffer.to_s
      final_error_output = error_output_buffer.to_s

      Log.trace { "process exited with status: #{status.exit_code}" }
      Log.trace { "process output: \n#{final_output}" } if final_output.bytesize > 0
      if final_error_output.bytesize > 0 && status.exit_code != 2 && status.exit_code != 0
        # NOTE: gpg writes to stderr on desctructive ops
        Log.error { "process error output: #{final_error_output}" } unless final_error_output.to_s.includes?("Note:")
      end

      {
        status: status,
        output: final_output,
        error:  final_error_output,
      }
    end

    def none_interactive_process(command : String,
                                 args : Array(String),
                                 env : Process::Env = nil) : NamedTuple(status: Process::Status, output: String, error: String)
      Log.trace { "Starting non-interactive process: #{command} #{args.join(" ")}" }

      process = Process.new(
        command,
        args,
        env: env,
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe
      )

      full_output_buffer = IO::Memory.new
      error_output_buffer = IO::Memory.new

      stdout_done = Channel(Nil).new
      stderr_done = Channel(Nil).new

      process.input.close rescue nil

      spawn do
        loop do
          char = process.output.read_char
          break if char.nil?
          full_output_buffer << char
        end
        stdout_done.send(nil)
      end

      spawn do
        loop do
          char = process.error.read_char
          break if char.nil?
          error_output_buffer << char
        end
        stderr_done.send(nil)
      end

      status = process.wait
      stdout_done.receive
      stderr_done.receive
      process.output.close rescue nil
      process.error.close rescue nil

      final_error_output = error_output_buffer.to_s
      Log.trace { "Process exited with status: #{status.exit_code}" }
      Log.trace { "Output: \n#{full_output_buffer}" } if full_output_buffer.to_s.bytesize > 0
      if final_error_output.bytesize > 0 && status.exit_code != 2
        # NOTE: gpg writes to stderr
        Log.error { "process error output: #{final_error_output}" } unless final_error_output.to_s =~ /trustdb created|gpg: keybox|imported|inserting/i
      end

      {
        status: status,
        output: full_output_buffer.to_s,
        error:  final_error_output,
      }
    end
  end
end
