# frozen_string_literal: true

require 'kubeclient'
require 'faye/websocket'
require 'eventmachine'
require 'socket'
require 'logger'
require 'json'
require 'uri'

# KubeVirtPortForwarder acts as a local TCP proxy for a port on a KubeVirt VMI.
# It handles the entire lifecycle of discovering the VMI, establishing a
# WebSocket connection via the Kubernetes API, and proxying data.
#
# Each accepted client connection makes a single attempt to open the WebSocket
# to the VMI. If that attempt fails, the client socket is closed so the caller
# (e.g. Beaker's SSH client) sees the connection failure promptly and learns
# the real state of the port, rather than waiting behind an internal retry loop.
#
# See the bottom of this file for a complete usage example.
#
class KubeVirtPortForwarder
  attr_reader :state, :local_port

  # The subprotocol required by the Kubernetes API for multiplexed streaming.
  # This protocol defines channels for stdin, stdout, stderr, and a special
  # error channel, which allows for out-of-band error reporting.
  STREAM_PROTOCOL = 'v4.channel.k8s.io'

  # A KubeVirt-specific subprotocol for a raw, un-multiplexed data stream.
  PLAIN_STREAM_PROTOCOL = 'plain.kubevirt.io'

  # The channel byte for the primary data stream (stdin/stdout).
  DATA_CHANNEL = "\x00"

  # The channel byte for the error stream from the server.
  ERROR_CHANNEL = "\x01"

  # Upper bound on how long we'll wait for EventMachine.reactor_running? to
  # become true after kicking off EventMachine.run in its own thread. Healthy
  # startup is well under 100ms; five seconds is only reached when something
  # is wrong (native-ext load failure, incompatible libcrypto, etc.).
  REACTOR_STARTUP_TIMEOUT = 5

  # Upper bound on how long we'll wait for the reactor thread to exit during
  # shutdown after EventMachine.stop. If startup timed out, the reactor thread
  # is alive but hung and EventMachine.stop is a no-op, so we must kill it
  # rather than block forever on join.
  REACTOR_SHUTDOWN_TIMEOUT = 5

  # Send a WebSocket ping every N seconds. SSH keepalive packets are payload
  # frames that some upstream WS-aware proxies don't count against their idle
  # timer; protocol-level pings always do.
  WEBSOCKET_PING_INTERVAL = 60

  # Class-level tracking of EventMachine reactor ownership
  # EventMachine has a single global reactor, so we need to track which
  # forwarder instance started it to avoid stopping it prematurely
  @reactor_owner_mutex = Mutex.new
  @reactor_owner = nil

  class << self
    attr_accessor :reactor_owner_mutex, :reactor_owner
  end

  # @param kube_client [Kubeclient::Client] An initialized kubeclient client.
  # @param namespace [String] The Kubernetes namespace of the VMI.
  # @param vmi_name [String] The name of the VirtualMachineInstance.
  # @param target_port [Integer] The port inside the VMI to connect to (e.g., 22 for SSH).
  # @param local_port [Integer] The local TCP port to listen on.
  # @param logger [Logger] An optional logger instance.
  # @param on_error [Proc] An optional callback (proc or lambda) to handle errors.
  # @param ssl_options [Hash] Optional SSL options to use instead of kube_client's (to preserve :ca_file)
  def initialize(kube_client:, namespace:, vmi_name:, target_port:, local_port:, logger: nil, on_error: nil, ssl_options: nil)
    @kube_client = kube_client
    @namespace = namespace
    @vmi_name = vmi_name
    @target_port = target_port
    @local_port = local_port
    @on_error = on_error
    @logger = logger || Logger.new($stdout, level: :info)
    @ssl_options = ssl_options # Use provided ssl_options if available

    @state = :new
    @mutex = Mutex.new
    @server_thread = nil
    @reactor_thread = nil
    @connection_threads = []
    @shutdown = false
  end

  # Starts the local TCP server and the EventMachine reactor in background threads.
  def start
    return unless state_transition_to(:starting)

    @logger.info("Starting local proxy on 127.0.0.1:#{@local_port} for vmi://#{@namespace}/#{@vmi_name}:#{@target_port}")

    # Reset shutdown flag
    @shutdown = false

    # Start the EventMachine reactor in a dedicated thread to handle WebSocket I/O.
    # EventMachine has a single global reactor, so we need to check if it's already
    # running. Guarding only on EventMachine.reactor_running? would race: a second
    # forwarder entering this block before the first reactor thread has actually
    # become "running" would also see false, set itself as owner, and spawn a
    # second EventMachine.run thread. Guard on reactor_owner.nil? as well so the
    # owner is locked in atomically — a non-owner just waits for the in-progress
    # reactor to become ready.
    start_reactor = false
    self.class.reactor_owner_mutex.synchronize do
      if self.class.reactor_owner.nil? && !EventMachine.reactor_running?
        start_reactor = true
        self.class.reactor_owner = self
      end
    end

    if start_reactor
      @reactor_thread = Thread.new { EventMachine.run }
      wait_for_reactor_ready
      @logger.debug('Started EventMachine reactor (owned by this forwarder)')
    else
      wait_for_existing_reactor_ready
      @logger.debug('Using existing EventMachine reactor (owned by another forwarder)')
    end

    @server = TCPServer.new('127.0.0.1', @local_port)
    state_transition_to(:running)

    @server_thread = Thread.new do
      loop do
        break if @state == :stopping || @shutdown

        begin
          # Accept a connection from a client (e.g., Beaker's SSH).
          client_socket = @server.accept
          peer_ip, peer_port = client_socket.peeraddr(false).values_at(3, 1)
          @logger.debug("Accepted connection from #{peer_ip}:#{peer_port}")

          # Handle the entire KubeVirt connection lifecycle in a new thread.
          conn_thread = Thread.new { handle_connection(client_socket) }
          @mutex.synchronize { @connection_threads << conn_thread }
        rescue IOError
          # This is expected when @server.close is called in stop()
          @logger.debug("Server on port #{@local_port} stopped accepting connections.")
          break
        end
      end
    end
  rescue StandardError => e
    report_error(e)
    state_transition_to(:error)
    stop # Attempt a clean shutdown on startup failure
  end

  # Stops the server, closes all active connections, and cleans up threads.
  # This method is designed to be idempotent.
  def stop
    return unless state_transition_to(:stopping)

    @logger.info("Stopping port forwarder for vmi://#{@namespace}/#{@vmi_name}:#{@target_port}")

    # Set shutdown flag to signal threads to stop gracefully
    @shutdown = true

    # Close the main server socket to stop accepting new connections.
    @server&.close
    @server = nil

    # Wait for the main server thread to finish.
    @server_thread&.join

    # Clean up any active connection threads.
    threads_to_join = []
    @mutex.synchronize do
      threads_to_join = @connection_threads.dup
      @connection_threads.clear
    end

    # Give threads a chance to terminate gracefully
    threads_to_join.each do |thread|
      # Raise an exception in the thread to interrupt blocking I/O
      thread.raise(IOError, 'Port forwarder shutting down') if thread.alive?
    end

    # Wait for threads to finish with a timeout
    deadline = Time.now + 5
    threads_to_join.each do |thread|
      remaining = deadline - Time.now
      if remaining.positive?
        # Wait for thread to finish, but don't wait longer than the deadline
        begin
          thread.join(remaining)
        rescue StandardError => e
          # Thread may raise an exception when we called thread.raise
          @logger.debug("Thread exited with exception during shutdown: #{e.class}: #{e.message}")
        end
      end

      # If thread is still alive after timeout, kill it as last resort
      next unless thread.alive?

      @logger.warn("Force-killing connection thread that didn't shut down gracefully")
      thread.kill
      begin
        thread.join
      rescue StandardError
        nil
      end
    end

    # Stop the EventMachine reactor only if this instance owns it.
    # EventMachine has a single global reactor, so we must not stop it
    # if other forwarders are still using it.
    should_stop_reactor = false
    self.class.reactor_owner_mutex.synchronize do
      if self.class.reactor_owner == self
        should_stop_reactor = true
        self.class.reactor_owner = nil
      end
    end

    if should_stop_reactor
      EventMachine.stop if EventMachine.reactor_running?
      shut_down_reactor_thread
      @logger.debug('Stopped EventMachine reactor (owned by this forwarder)')
    else
      @logger.debug('Not stopping EventMachine reactor (owned by another forwarder)')
    end

    @logger.info('Port forwarder stopped.')
    state_transition_to(:stopped)
  end

  private

  # Wait for the reactor thread to exit, with a bounded timeout and a
  # last-resort kill. Mirrors the connection-thread shutdown logic above.
  # The reactor thread's exception (if any) was already surfaced via
  # Thread#value in wait_for_reactor_ready, so swallowing the same class
  # here during teardown is safe; signals (Interrupt/SystemExit) propagate.
  def shut_down_reactor_thread
    reactor_thread = @reactor_thread
    return unless reactor_thread

    begin
      joined = reactor_thread.join(REACTOR_SHUTDOWN_TIMEOUT)
    rescue StandardError, ScriptError => e
      @logger.debug("Reactor thread terminated with exception during shutdown: #{e.class}: #{e.message}")
      return
    end

    return if joined

    @logger.warn("Force-killing reactor thread that didn't shut down within #{REACTOR_SHUTDOWN_TIMEOUT}s")
    reactor_thread.kill
    # Thread#kill won't interrupt an uninterruptible native call, so bound this
    # join too — we'd rather leak a hung thread than block shutdown forever.
    begin
      joined = reactor_thread.join(REACTOR_SHUTDOWN_TIMEOUT)
    rescue StandardError, ScriptError
      joined = true
    end
    return if joined

    @logger.error("Reactor thread still alive #{REACTOR_SHUTDOWN_TIMEOUT}s after kill; abandoning it (likely stuck in a native call)")
  end

  # Block until EventMachine.reactor_running? becomes true, or fail fast
  # if the reactor thread died during startup or the deadline elapses.
  def wait_for_reactor_ready
    deadline = monotonic_now + REACTOR_STARTUP_TIMEOUT
    until EventMachine.reactor_running?
      unless @reactor_thread.alive?
        begin
          @reactor_thread.value # re-raises the thread's exception, if any
        # The reactor thread typically dies from non-StandardError causes such as
        # LoadError (native extension failure) or other ScriptError subclasses.
        # Rescue Exception so we can wrap and re-raise *any* cause with context;
        # we do not swallow it (raise below preserves :cause and backtrace).
        rescue Exception => e # rubocop:disable Lint/RescueException
          startup_error = RuntimeError.new(
            "EventMachine reactor thread exited during startup: #{e.class}: #{e.message}",
          )
          startup_error.set_backtrace(e.backtrace)
          raise startup_error, cause: e
        end
        raise 'EventMachine reactor thread exited during startup with no exception'
      end
      raise "EventMachine reactor did not become ready within #{REACTOR_STARTUP_TIMEOUT}s" if (monotonic_now > deadline) && !EventMachine.reactor_running?

      sleep 0.1
    end
  end

  # Wait (bounded) for a reactor that another forwarder is starting to become
  # ready. If the owning forwarder's startup fails, it clears reactor_owner in
  # its rescue/stop path; if that happens before the reactor came up, we bail
  # out rather than wait the full deadline.
  def wait_for_existing_reactor_ready
    deadline = monotonic_now + REACTOR_STARTUP_TIMEOUT
    until EventMachine.reactor_running?
      raise 'EventMachine reactor owner cleared before reactor became ready' if self.class.reactor_owner.nil?
      raise "EventMachine reactor did not become ready within #{REACTOR_STARTUP_TIMEOUT}s" if (monotonic_now > deadline) && !EventMachine.reactor_running?

      sleep 0.1
    end
  end

  # Monotonic clock for deadline arithmetic. Time.now is wall-clock and can
  # jump forwards/backwards on NTP adjustments, producing spurious timeouts
  # or longer-than-expected waits.
  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Handles a single client connection from start to finish.
  # @param client_socket [TCPSocket] The socket connected to the client.
  def handle_connection(client_socket)
    websocket = establish_websocket_with_retry(client_socket, retries: 1)
    if websocket
      @logger.debug('Connection to VMI established, proxying traffic')
      proxy_traffic(client_socket, websocket)
    else
      @logger.error('Failed to establish connection to VMI. Closing client socket.')
      client_socket.close
    end
  rescue IOError => e
    # IOError is raised during shutdown - this is expected
    if e.is_a?(EOFError)
      @logger.debug('Connection closed cleanly (EOF) - normal shutdown')
    elsif e.message.include?('shutting down')
      @logger.debug('Connection handler shutting down gracefully')
    else
      report_error(e, 'Error in connection handler thread')
    end
    begin
      client_socket.close
    rescue StandardError
      nil
    end
  rescue StandardError => e
    report_error(e, 'Error in connection handler thread')
    begin
      client_socket.close
    rescue StandardError
      nil
    end
  ensure
    @mutex.synchronize { @connection_threads.delete(Thread.current) }
  end

  # Attempts to establish the WebSocket connection. The retry loop is retained
  # for flexibility, but callers pass retries: 1 so a failure is reported to
  # the client immediately rather than masked by internal waiting.
  # @param client_socket [TCPSocket] The client socket, used to check if the client is still connected.
  # @return [Faye::WebSocket::Client, nil] The connected WebSocket client or nil if it fails.
  def establish_websocket_with_retry(client_socket, retries: 10, delay: 5)
    uri = @kube_client.api_endpoint
    # Build base URL preserving any path prefix (e.g., /k8s/clusters/xyz in Rancher)
    base_url = "#{uri.scheme}://#{uri.host}"
    base_url += ":#{uri.port}" if uri.port && ![80, 443].include?(uri.port)
    # Preserve the path prefix if it exists, removing any trailing API paths
    path_prefix = uri.path.to_s.sub(%r{/api.*$}, '')
    base_url += path_prefix unless path_prefix.empty? || path_prefix == '/'
    base_ws_url = base_url.sub(/^http/, 'ws')
    ns = URI.encode_www_form_component(@namespace)
    vmi = URI.encode_www_form_component(@vmi_name)
    target_port = Integer(@target_port, exception: false)
    raise ArgumentError, "Invalid target port: #{@target_port.inspect}. Expected an integer between 1 and 65535." unless target_port&.between?(1, 65_535)

    # Use the protocol-suffixed `/portforward/<port>/tcp` form. Both this and
    # the bare `/portforward/<port>` route are registered in KubeVirt 1.7+,
    # but some API-aggregation paths (notably Rancher's cluster proxy against
    # KubeVirt 1.8) return 404 on the bare form. The `/tcp` form is what
    # `virtctl port-forward` sends and works on every supported version.
    url = "#{base_ws_url}/apis/subresources.kubevirt.io/v1/namespaces/#{ns}/virtualmachineinstances/#{vmi}/portforward/#{target_port}/tcp"
    @logger.debug("WebSocket URL: #{url}")

    auth_token = @kube_client.auth_options[:bearer_token]
    @logger.debug("Using auth token: #{auth_token ? 'present' : 'absent'}")
    headers = {}
    headers['Authorization'] = "Bearer #{auth_token}" if auth_token && !auth_token.empty?

    # Convert kubeclient SSL options to Faye::WebSocket/EventMachine TLS options
    # Use provided ssl_options if available (to preserve :ca_file), otherwise use kube_client's
    ssl_opts = @ssl_options || @kube_client.ssl_options
    tls_options = convert_ssl_options_to_tls(ssl_opts)

    retries.times do |_i|
      return nil if client_socket.closed?

      @logger.debug("Opening WebSocket to VMI '#{@vmi_name}' port #{@target_port}")

      connection_status_q = Queue.new

      EventMachine.schedule do
        protocols = [PLAIN_STREAM_PROTOCOL]
        ws = Faye::WebSocket::Client.new(url, protocols,
                                         headers: headers,
                                         tls: tls_options,
                                         ping: WEBSOCKET_PING_INTERVAL)

        ws.on :open do |_event|
          @logger.debug("WebSocket open to VMI '#{@vmi_name}' (protocol: #{ws.protocol || 'none'})")
          connection_status_q.push(ws)
        end

        # This handler now attempts to parse the HTTP response body on a 500 error
        # to provide a more specific reason for the failure.
        ws.on :close do |event|
          if event.code == 1000 # Normal closure
            @logger.debug('WebSocket connection closed normally.')
          else
            err_msg = "WebSocket closed unexpectedly. Code: #{event.code}, Reason: #{event.reason}"

            # Check for the HTTP response object within the close event,
            # which faye-websocket provides on handshake failure.
            if event.instance_variable_defined?(:@driver) && event.driver.instance_variable_defined?(:@http)
              http_response = event.driver.instance_variable_get(:@http)
              if http_response && http_response.code == 500 && http_response.body
                begin
                  error_body = JSON.parse(http_response.body)
                  if error_body['message']
                    # This is the actual root cause from the server.
                    err_msg = "Server returned 500 Internal Server Error: #{error_body['message']}"
                  end
                rescue JSON::ParserError
                  # Body was not valid JSON, stick with the original error.
                end
              end
            end

            @logger.warn(err_msg)
            connection_status_q.push(RuntimeError.new(err_msg))
          end
        end
      rescue StandardError => e
        err_msg = "Failed to establish WebSocket connection: #{e.class}: #{e.message}"
        @logger.error(err_msg)
        connection_status_q.push(RuntimeError.new(err_msg))
      end

      result = connection_status_q.pop

      return result if result.is_a?(Faye::WebSocket::Client)

      unless retries == 1
        @logger.warn("WebSocket connect attempt failed. Retrying in #{delay} seconds...")
        sleep delay
      end
    end
    nil # All retries failed.
  end

  # Proxies data in both directions between the client and the WebSocket.
  # @param client_socket [TCPSocket] The socket for the local client.
  # @param websocket [Faye::WebSocket::Client] The connected WebSocket.
  def proxy_traffic(client_socket, websocket)
    use_channels = (websocket.protocol == STREAM_PROTOCOL)
    if use_channels
      @logger.debug("Using multiplexed stream protocol: #{STREAM_PROTOCOL}")
    else
      @logger.debug("Using raw stream protocol (negotiated: '#{websocket.protocol || 'none'}')")
    end

    # Mutex to synchronize access to client_socket from multiple threads
    socket_mutex = Mutex.new

    # No client-silence timeout: net-ssh defers keepalive while output is
    # streaming server->client, so long-running commands legitimately go
    # minutes without any client->ws bytes. We rely on EOF/RST from the OS
    # when the SSH client dies, and on the WS ping above to detect the
    # upstream half going away.
    to_ws = Thread.new do
      loop do
        data = client_socket.readpartial(4096)
        if use_channels
          websocket.send(DATA_CHANNEL + data)
        else
          websocket.send(data)
        end
      end
    rescue Errno::ECONNRESET, IOError => e
      if e.is_a?(EOFError)
        @logger.debug('Client connection closed cleanly (EOF). Shutting down proxy.')
      else
        @logger.debug("Client socket closed (#{e.class}: #{e.message}). Shutting down proxy.")
      end
      begin
        Timeout.timeout(5) do
          websocket.close if websocket.ready_state == Faye::WebSocket::Client::OPEN
        end
      rescue Timeout::Error
        @logger.warn('Timeout while closing WebSocket. It may have already been closed.')
      rescue StandardError => e
        @logger.warn("Failed to close WebSocket properly: #{e.message}")
        nil
      end
    end

    websocket.on :message do |event|
      payload = event.data

      # Synchronize writes to client_socket
      socket_mutex.synchronize do
        if use_channels
          channel = payload[0]
          case channel
          when DATA_CHANNEL
            client_socket.write(payload[1..])
          when ERROR_CHANNEL
            report_error(RuntimeError.new("Received error from server: #{payload[1..].inspect}"))
          else
            @logger.warn("Received message on unknown channel: #{channel.inspect}. Treating as raw data.")
            client_socket.write(payload)
          end
        else
          client_socket.write(payload)
        end
      rescue IOError, Errno::EPIPE, Errno::ECONNRESET => e
        @logger.debug("Failed to write to client socket: #{e.class}: #{e.message}")
        # Socket is closed or broken, ignore the error
      end
    end

    websocket.on :close do |event|
      @logger.debug("WebSocket connection closed. Code: #{event.code}, Reason: #{event.reason}")
      socket_mutex.synchronize do
        client_socket.close
      rescue StandardError
        nil
      end
    end

    to_ws.join
  end

  # Centralized error reporting.
  def report_error(error, context = nil)
    log_message = "ERROR: #{context}: " if context
    log_message ||= 'ERROR: '
    log_message += "#{error.class}: #{error.message}"
    # Backtrace may be nil for manually constructed errors
    log_message += "\n#{error.backtrace.join("\n")}" if error.backtrace
    @logger.error(log_message)
    @on_error&.call(error)
  end

  # Manages state transitions with thread safety.
  # rubocop:disable-next Naming/PredicateMethod
  def state_transition_to(new_state)
    @mutex.synchronize do
      case new_state
      when :starting
        return false unless %i[new stopped].include?(@state)
      when :running
        return false unless [:starting].include?(@state)
      when :stopping
        return false unless %i[running error].include?(@state)
      when :stopped
        return false unless [:stopping].include?(@state)
      end
      @state = new_state
    end
    true
  end

  # Convert kubeclient SSL options to Faye::WebSocket/EventMachine TLS options.
  # @param ssl_options [Hash] The SSL options from kubeclient
  # @return [Hash] TLS options compatible with Faye::WebSocket::Client
  def convert_ssl_options_to_tls(ssl_options)
    return {} if ssl_options.nil? || ssl_options.empty?

    tls_options = {}

    # Faye::WebSocket (built on EventMachine) supports custom CA certificates via the
    # :root_cert_file option. This enables proper SSL verification for in-cluster connections
    # with self-signed certificates.
    #
    # Note: :cert_chain_file is for client certificates, :root_cert_file is for CA certs

    # Pass CA certificate file for server verification
    if ssl_options[:ca_file]
      tls_options[:root_cert_file] = ssl_options[:ca_file]
      @logger.debug("Using CA certificate: #{ssl_options[:ca_file]}")

      # Explicitly enable verification when we have a CA cert, unless explicitly disabled
      tls_options[:verify_peer] = true unless ssl_options.key?(:verify_ssl) && !ssl_options[:verify_ssl]
    end

    # Handle explicit SSL verification setting
    # Faye::WebSocket uses :verify_peer (boolean), while kubeclient uses :verify_ssl (may be OpenSSL constant)
    if ssl_options.key?(:verify_ssl)
      verify_value = ssl_options[:verify_ssl]
      # Convert OpenSSL constants to boolean
      # OpenSSL::SSL::VERIFY_NONE = 0, OpenSSL::SSL::VERIFY_PEER = 1
      tls_options[:verify_peer] = if verify_value.is_a?(Integer)
                                    (verify_value != 0)
                                  else
                                    verify_value ? true : false
                                  end
      @logger.debug("SSL verification: #{[false, 0].include?(verify_value) ? 'disabled' : 'enabled'}")
    end

    # Pass through client certificates if present (for mutual TLS authentication)
    tls_options[:private_key_file] = ssl_options[:client_key] if ssl_options[:client_key]
    tls_options[:cert_chain_file] = ssl_options[:client_cert] if ssl_options[:client_cert]

    tls_options
  end
end
