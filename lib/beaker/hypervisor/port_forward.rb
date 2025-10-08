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
# It is designed to be resilient, handling retries internally so that a client
# (like Beaker's SSH client) can connect to the local port and simply wait
# until the VMI is ready.
#
# See the bottom of this file for a complete usage example.
#
class KubeVirtPortForwarder
  class << self
    def reactor_mutex
      @reactor_mutex ||= Mutex.new
    end

    def ensure_reactor!
      thread_started = false

      reactor_mutex.synchronize do
        @active_forwarders ||= 0

        # Check reactor status inside mutex to prevent race conditions
        unless @reactor_thread&.alive? && EventMachine.reactor_running?
          @reactor_thread = Thread.new { EventMachine.run }
          thread_started = true
        end

        @active_forwarders += 1
      end

      # Wait for reactor to be ready if we just started it
      return unless thread_started

      timeout = Time.now + 10 # 10 second timeout
      sleep 0.01 until EventMachine.reactor_running? || Time.now > timeout
      raise 'EventMachine reactor failed to start within timeout' unless EventMachine.reactor_running?
    end

    def release_reactor!
      thread_to_join = nil

      reactor_mutex.synchronize do
        return unless @active_forwarders&.positive?

        @active_forwarders -= 1
        return unless @active_forwarders.zero?

        if @reactor_thread&.alive?
          EventMachine.stop if EventMachine.reactor_running?
          thread_to_join = @reactor_thread
          @reactor_thread = nil
        end
      end

      # Join with timeout to prevent hanging
      return unless thread_to_join
      return if thread_to_join.join(5) # 5 second timeout

      thread_to_join.kill
      thread_to_join.join
    end
  end

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

  # @param kube_client [Kubeclient::Client] An initialized kubeclient client.
  # @param namespace [String] The Kubernetes namespace of the VMI.
  # @param vmi_name [String] The name of the VirtualMachineInstance.
  # @param target_port [Integer] The port inside the VMI to connect to (e.g., 22 for SSH).
  # @param local_port [Integer] The local TCP port to listen on.
  # @param logger [Logger] An optional logger instance.
  # @param on_error [Proc] An optional callback (proc or lambda) to handle errors.
  # @param options [Hash] Optional configuration (max_connections: Integer)
  def initialize(kube_client:, namespace:, vmi_name:, target_port:, local_port:, logger: nil, on_error: nil, options: {})
    # Validate inputs to prevent injection attacks
    validate_kubernetes_name(namespace, 'namespace')
    validate_kubernetes_name(vmi_name, 'vmi_name')
    validate_port(target_port, 'target_port')
    validate_port(local_port, 'local_port')

    @kube_client = kube_client
    @namespace = namespace.freeze
    @vmi_name = vmi_name.freeze
    @target_port = target_port.to_i
    @local_port = local_port.to_i
    @on_error = on_error
    @logger = logger || Logger.new($stdout, level: :info)

    @state = :new
    @mutex = Mutex.new
    @server_thread = nil
    @connection_threads = []
    @reactor_registered = false
    @max_connections = options[:max_connections] || 10
  end

  # Starts the local TCP server and the EventMachine reactor in background threads.
  def start
    return unless state_transition_to(:starting)

    @logger.info("Starting local proxy on 127.0.0.1:#{@local_port} for vmi://#{@namespace}/#{@vmi_name}:#{@target_port}")

    self.class.ensure_reactor!
    @reactor_registered = true

    @server = TCPServer.new('127.0.0.1', @local_port)
    state_transition_to(:running)

    @server_thread = Thread.new do
      loop do
        break if @state == :stopping

        begin
          # Accept a connection from a client (e.g., Beaker's SSH).
          client_socket = @server.accept

          # Check connection limit to prevent DoS attacks
          current_connections = 0
          @mutex.synchronize { current_connections = @connection_threads.size }

          if current_connections >= @max_connections
            @logger.warn("Connection limit (#{@max_connections}) reached, rejecting new connection")
            client_socket.close
            next
          end

          @logger.debug("Accepted connection from #{client_socket.peeraddr.join(':')}")

          # Handle the entire KubeVirt connection lifecycle in a new thread.
          conn_thread = Thread.new { handle_connection(client_socket) }
          @mutex.synchronize { @connection_threads << conn_thread }
        rescue IOError
          # This is expected when @server.close is called in stop()
          @logger.info("Server on port #{@local_port} is shutting down.")
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

    # Close the main server socket to stop accepting new connections.
    @server&.close
    @server = nil

    # Wait for the main server thread to finish.
    @server_thread&.join

    # Clean up any active connection threads gracefully
    threads_to_join = []
    @mutex.synchronize do
      threads_to_join = @connection_threads.dup
      @connection_threads.clear
    end

    threads_to_join.each do |thread|
      next unless thread.alive?

      # Request graceful shutdown first
      thread.exit

      # Wait with timeout, then force kill if necessary
      next if thread.join(3) # 3 second timeout per thread

      @logger.warn('Forcefully terminating unresponsive connection thread')
      thread.kill
      begin
        thread.join
      rescue StandardError
        nil
      end
    end

    if @reactor_registered
      self.class.release_reactor!
      @reactor_registered = false
    end

    @logger.info('Port forwarder stopped.')
    state_transition_to(:stopped)
  end

  private

  # Validate Kubernetes resource names to prevent injection attacks
  def validate_kubernetes_name(name, param_name)
    raise ArgumentError, "#{param_name} cannot be nil or empty" if name.nil? || name.empty?
    raise ArgumentError, "#{param_name} contains invalid characters" unless name.match?(/\A[a-z0-9]([-a-z0-9]*[a-z0-9])?\z/)
    raise ArgumentError, "#{param_name} is too long" if name.length > 253
  end

  # Validate port numbers
  def validate_port(port, param_name)
    port_int = port.to_i
    raise ArgumentError, "#{param_name} must be between 1 and 65535" unless (1..65_535).cover?(port_int)
  end

  # Handles a single client connection from start to finish.
  # @param client_socket [TCPSocket] The socket connected to the client.
  def handle_connection(client_socket)
    websocket = establish_websocket_with_retry(client_socket)
    if websocket
      @logger.info('Connection to VMI established. Proxying traffic.')
      proxy_traffic(client_socket, websocket)
    else
      @logger.error('Failed to establish connection to VMI after multiple retries. Closing client socket.')
      client_socket.close
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

  # Attempts to establish the WebSocket connection, retrying on failure.
  # This is the core of the "wait for VM" logic.
  # @param client_socket [TCPSocket] The client socket, used to check if the client is still connected.
  # @return [Faye::WebSocket::Client, nil] The connected WebSocket client or nil if it fails.
  def establish_websocket_with_retry(client_socket, retries: 10, initial_delay: 1)
    uri = @kube_client.api_endpoint
    server_root = uri.dup
    server_root.path = uri.path.match(%r{^/k8s/clusters/[^/]+|^/api|^/apis/|/}).to_s.chomp('/')
    base_http_url = server_root.to_s
    base_ws_url = base_http_url.sub(/^http/, 'ws')

    # Properly encode URL components to prevent injection attacks
    encoded_namespace = URI.encode_www_form_component(@namespace)
    encoded_vmi_name = URI.encode_www_form_component(@vmi_name)
    url = "#{base_ws_url}/apis/subresources.kubevirt.io/v1/namespaces/#{encoded_namespace}/virtualmachineinstances/#{encoded_vmi_name}/portforward/#{@target_port}"
    @logger.debug('Constructed WebSocket URL (namespace/vmi redacted for security)')

    auth_token = @kube_client.auth_options[:bearer_token]
    headers = { 'Authorization' => "Bearer #{auth_token}" }

    retries.times do |i|
      return nil if client_socket.closed?

      @logger.info("Attempt #{i + 1}: Connecting to VMI '#{@vmi_name}'...")

      connection_status_q = Queue.new

      EventMachine.schedule do
        protocols = [PLAIN_STREAM_PROTOCOL]
        ws = Faye::WebSocket::Client.new(url, protocols, headers: headers, tls: @kube_client.ssl_options)

        ws.on :open do |_event|
          @logger.debug("WebSocket connection opened. Negotiated protocol: '#{ws.protocol}'.")
          connection_status_q.push(ws)
        end

        # --- Improved Error Reporting ---
        # This handler now attempts to parse the HTTP response body on a 500 error
        # to provide a more specific reason for the failure.
        ws.on :close do |event|
          # Sanitize error messages to prevent information leakage

          # Only log basic connection status, avoid exposing internal details
          err_msg = case event.code
                    when 1000..1015
                      "WebSocket closed normally (code: #{event.code})"
                    when 4000..4999
                      'WebSocket closed due to client error'
                    when 5000..5999
                      'WebSocket closed due to server error'
                    else
                      "WebSocket connection failed with code: #{event.code}"
                    end

          @logger.warn(err_msg)
          connection_status_q.push(RuntimeError.new(err_msg)) if connection_status_q.num_waiting.positive?
        end
        # --- End of Fix ---
      end

      result = connection_status_q.pop

      return result if result.is_a?(Faye::WebSocket::Client)

      # Use exponential backoff for retries
      delay = initial_delay * (2**i)
      max_delay = 30 # Cap at 30 seconds
      delay = [delay, max_delay].min

      @logger.warn("Attempt #{i + 1} failed. Retrying in #{delay} seconds...")
      sleep delay
    end
    nil # All retries failed.
  end

  # Proxies data in both directions between the client and the WebSocket.
  # @param client_socket [TCPSocket] The socket for the local client.
  # @param websocket [Faye::WebSocket::Client] The connected WebSocket.
  def proxy_traffic(client_socket, websocket)
    use_channels = (websocket.protocol == STREAM_PROTOCOL)
    if use_channels
      @logger.info("Using multiplexed stream protocol: #{STREAM_PROTOCOL}")
    else
      @logger.info("Using raw stream protocol (negotiated: '#{websocket.protocol || 'none'}')")
    end

    to_ws = Thread.new do
      loop do
        data = client_socket.readpartial(4096)
        if use_channels
          websocket.send(DATA_CHANNEL + data)
        else
          websocket.send(data)
        end
      end
    rescue StandardError => e
      case e
      when Errno::ECONNRESET
        @logger.debug('Client connection reset. Shutting down proxy.')
      when IOError, EOFError
        @logger.debug('Client socket closed. Shutting down proxy.')
      else
        @logger.warn("Unexpected error in proxy thread: #{e.class}: #{e.message}")
      end

      begin
        websocket.close
      rescue StandardError
        nil
      end
    end

    websocket.on :message do |event|
      payload = event.data

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
    end

    websocket.on :close do |event|
      @logger.info("WebSocket connection closed. Code: #{event.code}, Reason: #{event.reason}")
      begin
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
    log_message += "#{error.class}: #{error.message}\n#{error.backtrace.join("\n")}"
    @logger.error(log_message)
    @on_error&.call(error)
  end

  # Manages state transitions with thread safety.
  def state_transition_to(new_state)
    @mutex.synchronize do
      case new_state
      when :starting
        return false unless %i[new stopped].include?(@state)
      when :running
        return false unless [:starting].include?(@state)
      when :stopping
        # Allow stopping from starting, running, or error states
        return false unless %i[starting running error].include?(@state)
      when :stopped
        return false unless [:stopping].include?(@state)
      when :error
        # Allow error from any state except stopped
        return false if @state == :stopped
      end
      @state = new_state
    end
    true
  end
end
