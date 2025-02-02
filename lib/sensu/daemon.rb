require "rubygems"

gem "multi_json", "1.11.0"

gem "sensu-em", "2.5.2"
gem "sensu-logger", "1.0.0"
gem "sensu-settings", "1.9.0"
gem "sensu-extension", "1.1.2"
gem "sensu-extensions", "1.2.0"
gem "sensu-transport", "3.0.0"
gem "sensu-spawn", "1.2.0"

require "time"
require "uri"

require "sensu/logger"
require "sensu/settings"
require "sensu/extensions"
require "sensu/transport"
require "sensu/spawn"

require "sensu/constants"
require "sensu/utilities"
require "sensu/cli"
require "sensu/redis"

# Symbolize hash keys when parsing JSON.
MultiJson.load_options = {:symbolize_keys => true}

module Sensu
  module Daemon
    include Utilities

    attr_reader :start_time

    # Initialize the Sensu process. Set the start time, initial
    # service state, set up the logger, load settings, load
    # extensions, and optionally daemonize the process and/or create a
    # PID file. A subclass may override this method.
    #
    # @param options [Hash]
    def initialize(options={})
      @start_time = Time.now.to_i
      @state = :initializing
      @timers = {:run => []}
      setup_logger(options)
      load_settings(options)
      load_extensions(options)
      setup_process(options)
    end

    # Set up the Sensu logger and its process signal traps for log
    # rotation and debug log level toggling. This method creates the
    # logger instance variable: `@logger`.
    #
    # https://github.com/sensu/sensu-logger
    #
    # @param options [Hash]
    def setup_logger(options={})
      @logger = Logger.get(options)
      @logger.setup_signal_traps
    end

    # Log setting or extension loading concerns, sensitive information
    # is redacted.
    #
    # @param concerns [Array] to be logged.
    # @param level [Symbol] to log the concerns at.
    def log_concerns(concerns=[], level=:warn)
      concerns.each do |concern|
        message = concern.delete(:message)
        @logger.send(level, message, redact_sensitive(concern))
      end
    end

    # Load Sensu settings and validate them. If there are validation
    # failures, log them (concerns), then cause the Sensu process to
    # exit (2). This method creates the settings instance variable:
    # `@settings`.
    #
    # https://github.com/sensu/sensu-settings
    #
    # @param options [Hash]
    def load_settings(options={})
      @settings = Settings.get(options)
      log_concerns(@settings.warnings)
      failures = @settings.validate
      unless failures.empty?
        @logger.fatal("invalid settings")
        log_concerns(failures, :fatal)
        @logger.fatal("SENSU NOT RUNNING!")
        exit 2
      end
    end

    # Load Sensu extensions and log any concerns. Set the logger and
    # settings for each extension instance. This method creates the
    # extensions instance variable: `@extensions`.
    #
    # https://github.com/sensu/sensu-extensions
    # https://github.com/sensu/sensu-extension
    #
    # @param options [Hash]
    def load_extensions(options={})
      @extensions = Extensions.get(options)
      log_concerns(@extensions.warnings)
      extension_settings = @settings.to_hash.dup
      @extensions.all.each do |extension|
        extension.logger = @logger
        extension.settings = extension_settings
      end
    end

    # Manage the current process, optionally daemonize and/or write
    # the current process ID to a PID file.
    #
    # @param options [Hash]
    def setup_process(options)
      daemonize if options[:daemonize]
      write_pid(options[:pid_file]) if options[:pid_file]
    end

    # Start the Sensu service and set the service state to `:running`.
    # This method will likely be overridden by a subclass.
    def start
      @state = :running
    end

    # Pause the Sensu service and set the service state to `:paused`.
    # This method will likely be overridden by a subclass.
    def pause
      @state = :paused
    end

    # Resume the paused Sensu service and set the service state to
    # `:running`. This method will likely be overridden by a subclass.
    def resume
      @state = :running
    end

    # Stop the Sensu service and set the service state to `:stopped`.
    # This method will likely be overridden by a subclass. This method
    # should stop the EventMachine event loop.
    def stop
      @state = :stopped
      @logger.warn("stopping reactor")
      EM::stop_event_loop
    end

    # Set up process signal traps. This method uses the `STOP_SIGNALS`
    # constant to determine which process signals will result in a
    # graceful service stop. A periodic timer must be used to poll for
    # received signals, as Mutex#lock cannot be used within the
    # context of `trap()`.
    def setup_signal_traps
      @signals = []
      (STOP_SIGNALS + RELOAD_SIGNALS).each do |signal|
        Signal.trap(signal) do
          @signals << signal
        end
      end
      EM::PeriodicTimer.new(1) do
        signal = @signals.shift
        if STOP_SIGNALS.include?(signal)
          @logger.warn("received signal", :signal => signal)
          stop
        elsif RELOAD_SIGNALS.include?(signal)
          @logger.warn('received signal', {
            :signal => signal
          })
          pause
          reload_settings
          resume
        end
      end
    end

    # Set up the Sensu transport connection. Sensu uses a transport
    # API, allowing it to use various message brokers. By default,
    # Sensu will use the built-in "rabbitmq" transport. The Sensu
    # service will stop gracefully in the event of a transport error,
    # and pause/resume in the event of connectivity issues. This
    # method creates the transport instance variable: `@transport`.
    #
    # https://github.com/sensu/sensu-transport
    def setup_transport
      transport_name = @settings[:transport][:name]
      transport_settings = @settings[transport_name]
      @logger.debug("connecting to transport", {
        :name => transport_name,
        :settings => transport_settings
      })
      Transport.logger = @logger
      @transport = Transport.connect(transport_name, transport_settings)
      @transport.on_error do |error|
        @logger.fatal("transport connection error", :error => error.to_s)
        if @settings[:transport][:reconnect_on_error]
          @transport.reconnect
        else
          stop
        end
      end
      @transport.before_reconnect do
        unless testing?
          @logger.warn("reconnecting to transport")
          pause
        end
      end
      @transport.after_reconnect do
        @logger.info("reconnected to transport")
        resume
      end
    end

    # Set up the Redis connection. Sensu uses Redis as a data store,
    # to store the client registry, current events, etc. The Sensu
    # service will stop gracefully in the event of a Redis error, and
    # pause/resume in the event of connectivity issues. This method
    # creates the Redis instance variable: `@redis`.
    def setup_redis
      @logger.debug("connecting to redis", :settings => @settings[:redis])
      @redis = Redis.connect(@settings[:redis])
      @redis.on_error do |error|
        @logger.fatal("redis connection error", :error => error.to_s)
        stop
      end
      @redis.before_reconnect do
        unless testing?
          @logger.warn("reconnecting to redis")
          pause
        end
      end
      @redis.after_reconnect do
        @logger.info("reconnected to redis")
        resume
      end
    end

    private

    # Write the current process ID (PID) to a file (PID file). This
    # method will cause the Sensu service to exit (2) if the PID file
    # cannot be written to.
    #
    # @param file [String] to write the current PID to.
    def write_pid(file)
      begin
        File.open(file, "w") do |pid_file|
          pid_file.puts(Process.pid)
        end
      rescue
        @logger.fatal("could not write to pid file", :pid_file => file)
        @logger.fatal("SENSU NOT RUNNING!")
        exit 2
      end
    end

    # Daemonize the current process. Seed the random number generator,
    # fork (& exit), detach from controlling terminal, ignore SIGHUP,
    # fork (& exit), use root '/' as the current working directory,
    # and close STDIN/OUT/ERR since the process is no longer attached
    # to a terminal.
    def daemonize
      Kernel.srand
      exit if Kernel.fork
      unless Process.setsid
        @logger.fatal("cannot detach from controlling terminal")
        @logger.fatal("SENSU NOT RUNNING!")
        exit 2
      end
      exit if Kernel.fork
      Dir.chdir("/")
      ObjectSpace.each_object(IO) do |io|
        unless [STDIN, STDOUT, STDERR].include?(io)
          begin
            io.close unless io.closed?
          rescue; end
        end
      end
    end
  end
end
