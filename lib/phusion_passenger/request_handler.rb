# encoding: binary
#  Phusion Passenger - https://www.phusionpassenger.com/
#  Copyright (c) 2010-2014 Phusion
#
#  "Phusion Passenger" is a trademark of Hongli Lai & Ninh Bui.
#
#  See LICENSE file for license information.

require 'socket'
require 'fcntl'
PhusionPassenger.require_passenger_lib 'constants'
PhusionPassenger.require_passenger_lib 'public_api'
PhusionPassenger.require_passenger_lib 'message_client'
PhusionPassenger.require_passenger_lib 'debug_logging'
PhusionPassenger.require_passenger_lib 'native_support'
PhusionPassenger.require_passenger_lib 'utils'
PhusionPassenger.require_passenger_lib 'utils/tmpdir'
PhusionPassenger.require_passenger_lib 'ruby_core_enhancements'
PhusionPassenger.require_passenger_lib 'request_handler/thread_handler'

module PhusionPassenger


class RequestHandler
	include DebugLogging
	include Utils
	
	# Signal which will cause the Rails application to exit immediately.
	HARD_TERMINATION_SIGNAL = "SIGTERM"
	# Signal which will cause the Rails application to exit as soon as it's done processing a request.
	SOFT_TERMINATION_SIGNAL = "SIGUSR1"
	BACKLOG_SIZE    = 500
	
	# String constants which exist to relieve Ruby's garbage collector.
	IGNORE              = 'IGNORE'              # :nodoc:
	DEFAULT             = 'DEFAULT'             # :nodoc:
	
	# A hash containing all server sockets that this request handler listens on.
	# The hash is in the form of:
	#
	#   {
	#      name1 => [socket_address1, socket_type1, socket1],
	#      name2 => [socket_address2, socket_type2, socket2],
	#      ...
	#   }
	#
	# +name+ is a Symbol. +socket_addressx+ is the address of the socket,
	# +socket_typex+ is the socket's type (either 'unix' or 'tcp') and
	# +socketx+ is the actual socket IO objec.
	# There's guaranteed to be at least one server socket, namely one with the
	# name +:main+.
	attr_reader :server_sockets

	attr_reader :concurrency
	
	# If a soft termination signal was received, then the main loop will quit
	# the given amount of seconds after the last time a connection was accepted.
	# Defaults to 3 seconds.
	attr_accessor :soft_termination_linger_time
	
	# A password with which clients must authenticate. Default is unauthenticated.
	attr_accessor :connect_password
	
	# Create a new RequestHandler with the given owner pipe.
	# +owner_pipe+ must be the readable part of a pipe IO object.
	#
	# Additionally, the following options may be given:
	# - detach_key
	# - connect_password
	# - pool_account_username
	# - pool_account_password_base64
	def initialize(owner_pipe, options = {})
		require_option(options, "app_group_name")
		install_options_as_ivars(self, options,
			"app",
			"app_group_name",
			"connect_password",
			"detach_key",
			"union_station_core",
			"pool_account_username"
		)

		@force_http_session = ENV["_PASSENGER_FORCE_HTTP_SESSION"] == "true"
		if @force_http_session
			@connect_password = nil
		end
		@thread_handler = options["thread_handler"] || ThreadHandler
		@concurrency = 1
		if options["pool_account_password_base64"]
			@pool_account_password = options["pool_account_password_base64"].unpack('m').first
		end

		#############

		if options["concurrency_model"] == "thread"
			@concurrency = options.fetch("thread_count", 1).to_i
		end
		
		#############

		@server_sockets = {}
		
		if should_use_unix_sockets?
			@main_socket_address, @main_socket = create_unix_socket_on_filesystem(options)
		else
			@main_socket_address, @main_socket = create_tcp_socket
		end
		@server_sockets[:main] = {
			:address     => @main_socket_address,
			:socket      => @main_socket,
			:protocol    => @force_http_session ? :http_session : :session,
			:concurrency => @concurrency
		}

		@http_socket_address, @http_socket = create_tcp_socket
		@server_sockets[:http] = {
			:address     => @http_socket_address,
			:socket      => @http_socket,
			:protocol    => :http,
			:concurrency => 1
		}

		@owner_pipe = owner_pipe
		@options = options
		@previous_signal_handlers = {}
		@main_loop_generation  = 0
		@main_loop_thread_lock = Mutex.new
		@main_loop_thread_cond = ConditionVariable.new
		@threads = []
		@threads_mutex = Mutex.new
		@soft_termination_linger_time = 3
		@main_loop_running  = false
		
		#############

		if options["debugger"]
			if defined?(Debugger)
				@server_sockets[:ruby_debug_cmd] = {
					:address     => "tcp://127.0.0.1:#{Debugger.cmd_port}",
					:protocol    => :ruby_debug_cmd,
					:concurrency => 1
				}
				@server_sockets[:ruby_debug_ctrl] = {
					:address     => "tcp://127.0.0.1:#{Debugger.ctrl_port}",
					:protocol    => :ruby_debug_ctrl,
					:concurrency => 1
				}
			else
				@server_sockets[:byebug] = {
					:address     => "tcp://127.0.0.1:#{Byebug.actual_port}",
					:protocol    => :byebug,
					:concurrency => 1
				}
			end
		end

		@async_irb_socket_address, @async_irb_socket =
			create_unix_socket_on_filesystem(options)
		@server_sockets[:async_irb] = {
			:address     => @async_irb_socket_address,
			:socket      => @async_irb_socket,
			:protocol    => :irb,
			:concurrency => 0
		}
		@async_irb_mutex = Mutex.new
	end
	
	# Clean up temporary stuff created by the request handler.
	#
	# If the main loop was started by #main_loop, then this method may only
	# be called after the main loop has exited.
	#
	# If the main loop was started by #start_main_loop_thread, then this method
	# may be called at any time, and it will stop the main loop thread.
	def cleanup
		if @main_loop_thread
			@main_loop_thread_lock.synchronize do
				@graceful_termination_pipe[1].close rescue nil
			end
			@main_loop_thread.join
		end
		@server_sockets.each_value do |info|
			socket = info[:socket]
			type = get_socket_address_type(info[:address])

			socket.close if !socket.closed?
			if type == :unix
				filename = info[:address].sub(/^unix:/, '')
				File.unlink(filename) rescue nil
			end
		end
		@owner_pipe.close rescue nil
	end
	
	# Check whether the main loop's currently running.
	def main_loop_running?
		@main_loop_thread_lock.synchronize do
			return @main_loop_running
		end
	end
	
	# Enter the request handler's main loop.
	def main_loop
		debug("Entering request handler main loop")
		reset_signal_handlers
		begin
			@graceful_termination_pipe = IO.pipe
			@graceful_termination_pipe[0].close_on_exec!
			@graceful_termination_pipe[1].close_on_exec!
			
			@main_loop_thread_lock.synchronize do
				@main_loop_generation += 1
				@main_loop_running = true
				@main_loop_thread_cond.broadcast
				
				@select_timeout = nil
				
				@selectable_sockets = []
				@server_sockets.each_value do |value|
					socket = value[2]
					@selectable_sockets << socket if socket
				end
				@selectable_sockets << @owner_pipe
				@selectable_sockets << @graceful_termination_pipe[0]

				@selectable_sockets.delete(@async_irb_socket)
				start_async_irb_server
			end
			
			install_useful_signal_handlers
			start_threads
			wait_until_termination_requested
			wait_until_all_threads_are_idle
			terminate_threads
			debug("Request handler main loop exited normally")

		rescue EOFError
			# Exit main loop.
			trace(2, "Request handler main loop interrupted by EOFError exception")
		rescue Interrupt
			# Exit main loop.
			trace(2, "Request handler main loop interrupted by Interrupt exception")
		rescue SignalException => signal
			trace(2, "Request handler main loop interrupted by SignalException")
			if signal.message != HARD_TERMINATION_SIGNAL &&
			   signal.message != SOFT_TERMINATION_SIGNAL
				raise
			end
		rescue Exception => e
			trace(2, "Request handler main loop interrupted by #{e.class} exception")
			raise
		ensure
			debug("Exiting request handler main loop")
			revert_signal_handlers
			@main_loop_thread_lock.synchronize do
				@graceful_termination_pipe[1].close rescue nil
				stop_async_irb_server
				@graceful_termination_pipe[0].close rescue nil
				@selectable_sockets = []
				@main_loop_generation += 1
				@main_loop_running = false
				@main_loop_thread_cond.broadcast
			end
		end
	end
	
	# Start the main loop in a new thread. This thread will be stopped by #cleanup.
	def start_main_loop_thread
		current_generation = @main_loop_generation
		@main_loop_thread = Thread.new do
			begin
				main_loop
			rescue Exception => e
				print_exception(self.class, e)
			end
		end
		@main_loop_thread_lock.synchronize do
			while @main_loop_generation == current_generation
				@main_loop_thread_cond.wait(@main_loop_thread_lock)
			end
		end
	end
	
	# Remove this request handler from the application pool so that no
	# new connections will come in. Then make the main loop quit a few
	# seconds after the last time a connection came in. This all is to
	# ensure that no connections come in while we're shutting down.
	#
	# May only be called while the main loop is running. May be called
	# from any thread.
	def soft_shutdown
		@soft_termination_linger_thread ||= Thread.new do
			debug("Soft termination initiated")
			if @detach_key && @pool_account_username && @pool_account_password
				client = MessageClient.new(@pool_account_username, @pool_account_password)
				begin
					client.pool_detach_process_by_key(@detach_key)
				ensure
					client.close
				end
			end
			wait_until_all_threads_are_idle
			debug("Soft terminating in #{@soft_termination_linger_time} seconds")
			sleep @soft_termination_linger_time
			@graceful_termination_pipe[1].close rescue nil
		end
	end

private
	def should_use_unix_sockets?
		# Historical note:
		# There seems to be a bug in MacOS X Leopard w.r.t. Unix server
		# sockets file descriptors that are passed to another process.
		# Usually Unix server sockets work fine, but when they're passed
		# to another process, then clients that connect to the socket
		# can incorrectly determine that the client socket is closed,
		# even though that's not actually the case. More specifically:
		# recv()/read() calls on these client sockets can return 0 even
		# when we know EOF is not reached.
		#
		# The ApplicationPool infrastructure used to connect to a backend
		# process's Unix socket in the helper server process, and then
		# pass the connection file descriptor to the web server, which
		# triggers this kernel bug. We used to work around this by using
		# TCP sockets instead of Unix sockets; TCP sockets can still fail
		# with this fake-EOF bug once in a while, but not nearly as often
		# as with Unix sockets.
		#
		# This problem no longer applies today. The web server now passes
		# all I/O through the HelperAgent, and the bug is no longer
		# triggered. Nevertheless, we keep this function intact so that
		# if something like this ever happens again, we know why, and we
		# can easily reactivate the workaround. Or maybe if we just need
		# TCP sockets for some other reason.
		
		#return RUBY_PLATFORM !~ /darwin/

		ruby_engine = defined?(RUBY_ENGINE) ? RUBY_ENGINE : "ruby"
		# Unix domain socket implementation on JRuby
		# is still bugged as of version 1.7.0. They can
		# cause unexplicable freezes when used in combination
		# with threading.
		return !@force_http_session && ruby_engine != "jruby"
	end

	def create_unix_socket_on_filesystem(options)
		if defined?(NativeSupport)
			unix_path_max = NativeSupport::UNIX_PATH_MAX
		else
			unix_path_max = options.fetch('UNIX_PATH_MAX', 100)
		end
		if options['generation_dir']
			socket_dir = "#{options['generation_dir']}/backends"
			socket_prefix = "ruby"
		else
			socket_dir = Dir.tmpdir
			socket_prefix = "PsgRubyApp"
		end

		retry_at_most(128, Errno::EADDRINUSE) do
			socket_address = "#{socket_dir}/#{socket_prefix}.#{generate_random_id(:base64)}"
			socket_address = socket_address.slice(0, unix_path_max - 10)
			socket = UNIXServer.new(socket_address)
			socket.listen(BACKLOG_SIZE)
			socket.close_on_exec!
			File.chmod(0600, socket_address)
			["unix:#{socket_address}", socket]
		end
	end
	
	def create_tcp_socket
		# We use "127.0.0.1" as address in order to force
		# TCPv4 instead of TCPv6.
		socket = TCPServer.new('127.0.0.1', 0)
		socket.listen(BACKLOG_SIZE)
		socket.close_on_exec!
		socket_address = "tcp://127.0.0.1:#{socket.addr[1]}"
		return [socket_address, socket]
	end

	# Reset signal handlers to their default handler, and install some
	# special handlers for a few signals. The previous signal handlers
	# will be put back by calling revert_signal_handlers.
	def reset_signal_handlers
		Signal.list_trappable.each_key do |signal|
			begin
				prev_handler = trap(signal, DEFAULT)
				if prev_handler != DEFAULT
					@previous_signal_handlers[signal] = prev_handler
				end
			rescue ArgumentError
				# Signal cannot be trapped; ignore it.
			end
		end
		trap('HUP', IGNORE)
		PhusionPassenger.call_event(:after_installing_signal_handlers)
	end
	
	def install_useful_signal_handlers
		trappable_signals = Signal.list_trappable
		
		trap(SOFT_TERMINATION_SIGNAL) do
			begin
				soft_shutdown
			rescue => e
				print_exception("Passenger RequestHandler soft shutdown routine", e)
			end
		end if trappable_signals.has_key?(SOFT_TERMINATION_SIGNAL.sub(/^SIG/, ''))
		
		trap('ABRT') do
			print_status_report
		end if trappable_signals.has_key?('ABRT')
		trap('QUIT') do
			print_status_report
		end if trappable_signals.has_key?('QUIT')
	end
	
	def revert_signal_handlers
		@previous_signal_handlers.each_pair do |signal, handler|
			trap(signal, handler)
		end
	end

	def print_status_report
		warn(Utils.global_backtrace_report)
		warn("Threads: #{@threads.inspect}")
	end

	def start_threads
		common_options = {
			:app              => @app,
			:app_group_name   => @app_group_name,
			:connect_password => @connect_password,
			:union_station_core => @union_station_core
		}
		main_socket_options = common_options.merge(
			:server_socket => @main_socket,
			:socket_name => "main socket",
			:protocol => @server_sockets[:main][:protocol] == :session ?
				:session :
				:http
		)
		http_socket_options = common_options.merge(
			:server_socket => @http_socket,
			:socket_name => "HTTP socket",
			:protocol => :http
		)

		# Used for marking threads that have finished initializing,
		# or failed during initialization. Threads that are not yet done
		# are not in `initialization_state`. Threads that have succeeded
		# set their own state to true. Threads that have failed set their
		# own state to false.
		initialization_state_mutex = Mutex.new
		initialization_state_cond = ConditionVariable.new
		initialization_state = {}
		set_initialization_state = lambda do |value|
			initialization_state_mutex.synchronize do
				initialization_state[Thread.current] = value
				initialization_state_cond.signal
			end
		end
		set_initialization_state_to_true = lambda do
			set_initialization_state.call(true)
		end

		# Actually start all the threads.
		thread_handler = @thread_handler
		expected_nthreads = 0

		@threads_mutex.synchronize do
			@concurrency.times do |i|
				thread = Thread.new(i) do |number|
					Thread.current.abort_on_exception = true
					begin
						Thread.current[:name] = "Worker #{number + 1}"
						handler = thread_handler.new(self, main_socket_options)
						handler.install
						handler.main_loop(set_initialization_state_to_true)
					ensure
						set_initialization_state.call(false)
						unregister_current_thread
					end
				end
				@threads << thread
				expected_nthreads += 1
			end

			thread = Thread.new do
				Thread.current.abort_on_exception = true
				begin
					Thread.current[:name] = "HTTP helper worker"
					handler = thread_handler.new(self, http_socket_options)
					handler.install
					handler.main_loop(set_initialization_state_to_true)
				ensure
					set_initialization_state.call(false)
					unregister_current_thread
				end
			end
			@threads << thread
			expected_nthreads += 1
		end

		# Wait until all threads have finished starting.
		initialization_state_mutex.synchronize do
			while initialization_state.size != expected_nthreads
				initialization_state_cond.wait(initialization_state_mutex)
			end
		end
	end

	def unregister_current_thread
		@threads_mutex.synchronize do
			@threads.delete(Thread.current)
		end
	end

	def wait_until_termination_requested
		ruby_engine = defined?(RUBY_ENGINE) ? RUBY_ENGINE : "ruby"
		if ruby_engine == "jruby"
			# On JRuby, selecting on an input TTY always returns, so
			# we use threads to do the job.
			owner_pipe_watcher = IO.pipe
			owner_pipe_watcher_thread = Thread.new do
				Thread.current.abort_on_exception = true
				Thread.current[:name] = "Owner pipe waiter"
				begin
					@owner_pipe.read(1)
				ensure
					owner_pipe_watcher[1].write('x')
				end
			end
			begin
				ios = select([owner_pipe_watcher[0], @graceful_termination_pipe[0]])[0]
				if ios.include?(owner_pipe_watcher[0])
					trace(2, "Owner pipe closed")
				else
					trace(2, "Graceful termination pipe closed")
				end
			ensure
				owner_pipe_watcher_thread.kill
				owner_pipe_watcher_thread.join
				owner_pipe_watcher[0].close if !owner_pipe_watcher[0].closed?
				owner_pipe_watcher[1].close if !owner_pipe_watcher[1].closed?
			end
		else
			ios = select([@owner_pipe, @graceful_termination_pipe[0]])[0]
			if ios.include?(@owner_pipe)
				trace(2, "Owner pipe closed")
			else
				trace(2, "Graceful termination pipe closed")
			end
		end
	end

	def wakeup_all_threads
		threads = []
		if get_socket_address_type(@server_sockets[:main][:address]) == :unix &&
		   !File.exist?(@server_sockets[:main][:address].sub(/^unix:/, ''))
			# It looks like someone deleted the Unix domain socket we listen on.
			# This makes it impossible to wake up the worker threads gracefully,
			# so we hard kill them.
			warn("Unix domain socket gone; force aborting all threads")
			@threads_mutex.synchronize do
				@threads.each do |thread|
					thread.raise(RuntimeError.new("Force abort"))
				end
			end
		else
			@concurrency.times do
				Thread.abort_on_exception = true
				threads << Thread.new(@server_sockets[:main][:address]) do |address|
					begin
						debug("Shutting down worker thread by connecting to #{address}")
						connect_to_server(address).close
					rescue Errno::ECONNREFUSED
						debug("Worker thread listening on #{address} already exited")
					rescue SystemCallError, IOError => e
						debug("Error shutting down worker thread (#{address}): #{e} (#{e.class})")
					end
				end
			end
		end
		threads << Thread.new(@server_sockets[:http][:address]) do |address|
			Thread.abort_on_exception = true
			begin
				debug("Shutting down HTTP thread by connecting to #{address}")
				connect_to_server(address).close
			rescue Errno::ECONNREFUSED
				debug("Worker thread listening on #{address} already exited")
			rescue SystemCallError, IOError => e
				debug("Error shutting down HTTP thread (#{address}): #{e} (#{e.class})")
			end
		end
		return threads
	end

	def terminate_threads
		debug("Stopping all threads")
		threads = @threads_mutex.synchronize do
			@threads.dup
		end
		threads.each do |thr|
			thr.raise(ThreadHandler::Interrupted.new)
		end
		threads.each do |thr|
			thr.join
		end
		debug("All threads stopped")
	end
	
	def wait_until_all_threads_are_idle
		debug("Waiting until all threads have become idle...")

		# We wait until 100 ms have passed since all handlers have become
		# interruptable and remained in the same iterations.
		
		done = false

		while !done
			handlers = @threads_mutex.synchronize do
				@threads.map do |thr|
					thr[:passenger_thread_handler]
				end
			end
			debug("There are currently #{handlers.size} threads")
			if handlers.empty?
				# There are no threads, so we're done.
				done = true
				break
			end

			# Record initial state.
			handlers.each { |h| h.stats_mutex.lock }
			iterations = handlers.map { |h| h.iteration }
			handlers.each { |h| h.stats_mutex.unlock }

			start_time = Time.now
			sleep 0.01
			
			while true
				if handlers.size != @threads_mutex.synchronize { @threads.size }
					debug("The number of threads changed. Restarting waiting algorithm")
					break
				end

				# Record current state.
				handlers.each { |h| h.stats_mutex.lock }
				all_interruptable = handlers.all? { |h| h.interruptable }
				new_iterations    = handlers.map  { |h| h.iteration }

				# Are all threads interruptable and has there been no activity
				# since last time we checked?
				if all_interruptable && new_iterations == iterations
					# Yes. If enough time has passed then we're done.
					handlers.each { |h| h.stats_mutex.unlock }
					if Time.now >= start_time + 0.1
						done = true
						break
					end
				else
					# No. We reset the timer and check again later.
					handlers.each { |h| h.stats_mutex.unlock }
					iterations = new_iterations
					start_time = Time.now
					sleep 0.01
				end
			end
		end

		debug("All threads are now idle")
	end

	class IrbContext
		def initialize(channel)
			@channel = channel
			@mutex   = Mutex.new
			@binding = binding
		end

		def _eval(code)
			eval(code, @binding, '(passenger-irb)')
		end
		
		def help
			puts "Available commands:"
			puts
			puts "  p OBJECT    Inspect an object."
			puts "  pp OBJECT   Inspect an object, with pretty printing."
			puts "  backtraces  Show the all threads' backtraces (requires Ruby Enterprise"
			puts "              Edition or Ruby 1.9)."
			puts "  debugger    Enter a ruby-debug console."
			puts "  help        Show this help message."
			puts
			puts "Available variables:"
			puts
			puts "  app         The Rack application object."
			return
		end
		
		def puts(*args)
			@mutex.synchronize do
				io = StringIO.new
				io.puts(*args)
				@channel.write('puts', [io.string].pack('m'))
				return nil
			end
		end

		def p(object)
			@mutex.synchronize do
				io = StringIO.new
				io.puts(object.inspect)
				@channel.write('puts', [io.string].pack('m'))
				return nil
			end
		end

		def pp(object)
			require 'pp' if !defined?(PP)
			@mutex.synchronize do
				io = StringIO.new
				PP.pp(object, io)
				@channel.write('puts', [io.string].pack('m'))
				return nil
			end
		end
		
		def backtraces
			puts Utils.global_backtrace_report
			return nil
		end

		def app
			return PhusionPassenger::App.app
		end
	end
	
	def start_irb_session(socket)
		channel = MessageChannel.new(socket)
		irb_context = IrbContext.new(channel)
		
		password = channel.read_scalar
		if password.nil?
			return
		elsif password == @connect_password
			channel.write("ok")
		else
			channel.write("Invalid connect password.")
		end
		
		while !socket.eof?
			code = channel.read_scalar
			break if code.nil?
			begin
				result = irb_context._eval(code)
				if result.respond_to?(:inspect)
					result_str = "=> #{result.inspect}"
				else
					result_str = "(result object doesn't respond to #inspect)"
				end
			rescue SignalException
				raise
			rescue SyntaxError => e
				result_str = "SyntaxError:\n#{e}"
			rescue Exception => e
				end_of_trace = nil
				e.backtrace.each_with_index do |trace, i|
					if trace =~ /^\(passenger-irb\)/
						end_of_trace = i
						break
					end
				end
				if end_of_trace
					e.set_backtrace(e.backtrace[0 .. end_of_trace])
				end
				result_str = e.backtrace_string("passenger-irb")
			end
			channel.write('end', [result_str].pack('m'))
		end
	end
	
	def start_async_irb_server
		@async_irb_worker_threads = []
		@async_irb_thread = Thread.new do
			Thread.current[:name] = "IRB acceptor"
			Thread.current.abort_on_exception = true
			while true
				ios = select([@async_irb_socket, @graceful_termination_pipe[0]]).first
				if ios.include?(@async_irb_socket)
					socket = @async_irb_socket.accept
					@async_irb_mutex.synchronize do
						@async_irb_worker_threads << Thread.new do
							Thread.current[:name] = "IRB worker"
							Thread.current.abort_on_exception = true
							async_irb_worker_main(socket)
						end
					end
				else
					break
				end
			end
		end
	end
	
	def async_irb_worker_main(socket)
		start_irb_session(socket)
	rescue Exception => e
		print_exception("passenger-irb", e)
	ensure
		socket.close if !socket.closed?
		@async_irb_mutex.synchronize do
			@async_irb_worker_threads.delete(Thread.current)
		end
	end
	
	def stop_async_irb_server
		if @async_irb_worker_threads
			@async_irb_thread.join
			threads = nil
			@async_irb_mutex.synchronize do
				threads = @async_irb_worker_threads
				@async_irb_worker_threads = []
			end
			threads.each do |thread|
				thread.terminate
				thread.join
			end
		end
	end
end

end # module PhusionPassenger
