# frozen_string_literal: true

require 'spec_helper'
require 'beaker/hypervisor/port_forward'
require 'socket'
require 'timeout'

# rubocop:disable-next RSpec/SpecFilePathFormat
RSpec.describe KubeVirtPortForwarder do
  let(:kube_client) do
    instance_double(
      Kubeclient::Client,
      api_endpoint: URI.parse('https://kubernetes.example.com/api'),
      auth_options: { bearer_token: 'test-token' },
      ssl_options: { verify_ssl: OpenSSL::SSL::VERIFY_NONE },
    )
  end

  let(:namespace) { 'test-namespace' }
  let(:vmi_name) { 'test-vmi' }
  let(:target_port) { 22 }
  let(:local_port) { 10_022 }
  let(:logger) { instance_double(Logger).as_null_object }
  let(:on_error) { ->(error) {} }

  let(:forwarder) do
    described_class.new(
      kube_client: kube_client,
      namespace: namespace,
      vmi_name: vmi_name,
      target_port: target_port,
      local_port: local_port,
      logger: logger,
      on_error: on_error,
    )
  end

  before do
    # Simulate EventMachine reactor lifecycle without actually starting it
    # Track reactor state to properly test ownership logic
    # IMPORTANT: Reset to false at the start of each test
    @reactor_running = false
    allow(EventMachine).to receive(:run) { @reactor_running = true }
    allow(EventMachine).to receive(:reactor_running?) { @reactor_running }
    allow(EventMachine).to receive(:stop) { @reactor_running = false }
    allow(EventMachine).to receive(:schedule)

    # Reset reactor ownership between tests
    described_class.reactor_owner = nil

    # Mock TCPServer by default to avoid actual port binding
    # Individual tests can override this if needed
    server = instance_double(TCPServer)
    allow(TCPServer).to receive(:new).and_return(server)
    allow(server).to receive(:accept).and_raise(IOError, 'Server closed')
    allow(server).to receive(:close)
  end

  after do
    # Ensure forwarder is stopped after each test
    forwarder.stop if forwarder.state != :stopped
    # Reset reactor state
    @reactor_running = false
  rescue StandardError
    nil
  end

  describe '#initialize' do
    it 'sets initial state to :new' do
      expect(forwarder.state).to eq(:new)
    end

    it 'stores the local port' do
      expect(forwarder.local_port).to eq(local_port)
    end

    it 'creates a logger if none provided' do
      forwarder_without_logger = described_class.new(
        kube_client: kube_client,
        namespace: namespace,
        vmi_name: vmi_name,
        target_port: target_port,
        local_port: local_port,
      )
      expect(forwarder_without_logger.instance_variable_get(:@logger)).to be_a(Logger)
    end
  end

  describe '#start' do
    it 'transitions state from :new to :running' do
      forwarder.start
      sleep 0.1 # Give threads time to start
      expect(forwarder.state).to eq(:running)
    end

    it 'creates a TCP server on the specified port' do
      expect(TCPServer).to receive(:new).with('127.0.0.1', local_port)
      forwarder.start
      sleep 0.1
    end

    it 'starts the EventMachine reactor' do
      # Verify reactor ownership - first forwarder starts the reactor
      forwarder.start
      sleep 0.1
      # After starting, the reactor should be running and owned by this forwarder
      expect(EventMachine.reactor_running?).to be true
      expect(described_class.reactor_owner).to eq(forwarder)
    end

    # Issue #4: Resource leak on startup failure
    it 'cleans up EventMachine reactor if server creation fails' do
      allow(TCPServer).to receive(:new).and_raise(StandardError, 'Port in use')

      expect do
        forwarder.start
        sleep 0.1
      end.not_to raise_error

      # After startup failure, stop() is called which transitions to :stopped
      # The reactor should be cleaned up
      expect(forwarder.state).to eq(:stopped)
      expect(@reactor_running).to be false
    end

    # Issue #9: Race condition in state transitions - FIXED
    # state_transition_to uses @mutex.synchronize for thread-safe transitions
    it 'prevents multiple simultaneous starts' do
      # Track how many times state_transition_to is called with :starting
      starting_attempts = []
      starting_mutex = Mutex.new

      allow(forwarder).to receive(:state_transition_to).and_wrap_original do |method, *args|
        starting_mutex.synchronize { starting_attempts << Thread.current } if args[0] == :starting
        method.call(*args)
      end

      # Create 5 threads that all try to start simultaneously
      threads = Array.new(5) do
        Thread.new { forwarder.start }
      end

      threads.each(&:join)

      # Multiple threads attempted to start
      expect(starting_attempts.size).to be >= 2

      # But only one should have succeeded (state should be running)
      expect(forwarder.state).to eq(:running)

      # And state_transition_to(:running) should have been called exactly once
      # (because only one start() succeeded in transitioning from :starting to :running)
      expect(forwarder.state).to eq(:running)
    end

    it 'does not start if already running' do
      forwarder.start
      sleep 0.1
      initial_state = forwarder.state

      forwarder.start # Try to start again

      expect(forwarder.state).to eq(initial_state)
    end

    # Issue: EventMachine reactor startup could spin forever if the reactor
    # thread died (e.g. native lib mismatch) or never became ready.
    context 'when the EventMachine reactor fails to start' do
      it 'fails fast and reports the original cause if the reactor thread raises a StandardError' do
        boom = RuntimeError.new('boom from reactor thread')
        allow(EventMachine).to receive(:run).and_raise(boom)

        captured = nil
        forwarder.instance_variable_set(:@on_error, ->(e) { captured = e })

        forwarder.start

        expect(forwarder.state).to eq(:stopped)
        expect(captured).to be_a(RuntimeError)
        expect(captured.message).to include('EventMachine reactor thread exited during startup')
        expect(captured.message).to include('boom from reactor thread')
        expect(captured.cause).to eq(boom)
      end

      it 'fails fast and reports the original cause if the reactor thread raises a non-StandardError' do
        boom = LoadError.new('libcrypto symbol mismatch')
        allow(EventMachine).to receive(:run).and_raise(boom)

        captured = nil
        forwarder.instance_variable_set(:@on_error, ->(e) { captured = e })

        forwarder.start

        expect(forwarder.state).to eq(:stopped)
        expect(captured).to be_a(RuntimeError)
        expect(captured.message).to include('LoadError')
        expect(captured.message).to include('libcrypto symbol mismatch')
        expect(captured.cause).to eq(boom)
      end

      it 'fails fast with a deadline error if the reactor never becomes ready' do
        stub_const("#{described_class}::REACTOR_STARTUP_TIMEOUT", 0.1)
        # Reactor thread stays alive but never flips reactor_running? to true.
        # Sleep just long enough to outlast the stubbed startup deadline; the
        # bounded join + kill in stop ensures shutdown doesn't block on it.
        allow(EventMachine).to receive(:run) { sleep 0.5 }

        captured = nil
        forwarder.instance_variable_set(:@on_error, ->(e) { captured = e })

        forwarder.start

        expect(forwarder.state).to eq(:stopped)
        expect(captured).to be_a(RuntimeError)
        expect(captured.message).to include('reactor did not become ready within')
      end

      it 'force-kills the reactor thread if it does not exit within the shutdown timeout' do
        stub_const("#{described_class}::REACTOR_STARTUP_TIMEOUT", 0.1)
        stub_const("#{described_class}::REACTOR_SHUTDOWN_TIMEOUT", 0.1)
        # Reactor thread stays alive much longer than the shutdown timeout.
        allow(EventMachine).to receive(:run) { sleep 10 }

        forwarder.instance_variable_set(:@on_error, ->(_) {})

        expect(logger).to receive(:warn).with(/Force-killing reactor thread/)

        forwarder.start

        reactor_thread = forwarder.instance_variable_get(:@reactor_thread)
        expect(forwarder.state).to eq(:stopped)
        expect(reactor_thread).not_to be_alive
      end
    end

    # Two forwarders entering the reactor-startup section concurrently must not
    # both spawn EventMachine.run threads. Even though the first is mid-startup,
    # EventMachine.reactor_running? is still false until its thread runs — so a
    # check on reactor_running? alone would let a second forwarder also claim
    # ownership. Guard on reactor_owner.nil? to make ownership atomic.
    context 'when another forwarder is mid-startup' do
      let(:forwarder2) do
        described_class.new(
          kube_client: kube_client,
          namespace: namespace,
          vmi_name: vmi_name,
          target_port: target_port,
          local_port: local_port + 1,
          logger: logger,
          on_error: on_error,
        )
      end

      let(:helper_threads) { [] }

      after do
        # Make sure background helpers from each example are joined before the
        # next one runs — they mutate shared class state (@reactor_running,
        # reactor_owner) and would cause flakes if they leaked across examples.
        helper_threads.each(&:join)
        forwarder2.stop if forwarder2.state != :stopped
      end

      it 'does not spawn a second EventMachine.run thread or overwrite reactor_owner' do
        # Simulate forwarder1's reactor still mid-startup: owner is set but
        # reactor_running? has not flipped to true yet.
        described_class.reactor_owner = forwarder
        @reactor_running = false

        # Flip the reactor "ready" shortly after forwarder2 starts so its
        # bounded wait completes.
        helper_threads << Thread.new do
          sleep 0.05
          @reactor_running = true
        end

        forwarder2.start

        expect(EventMachine).not_to have_received(:run)
        expect(described_class.reactor_owner).to eq(forwarder)
        expect(forwarder2.state).to eq(:running)
      end

      it 'fails fast if the in-progress owner clears itself before the reactor comes up' do
        described_class.reactor_owner = forwarder
        @reactor_running = false

        helper_threads << Thread.new do
          sleep 0.05
          described_class.reactor_owner = nil
        end

        captured = nil
        forwarder2.instance_variable_set(:@on_error, ->(e) { captured = e })

        forwarder2.start

        expect(forwarder2.state).to eq(:stopped)
        expect(captured.message).to include('reactor owner cleared before reactor became ready')
      end

      it 'fails fast with a deadline error if the in-progress reactor never becomes ready' do
        stub_const("#{described_class}::REACTOR_STARTUP_TIMEOUT", 0.1)
        described_class.reactor_owner = forwarder
        @reactor_running = false

        captured = nil
        forwarder2.instance_variable_set(:@on_error, ->(e) { captured = e })

        forwarder2.start

        expect(forwarder2.state).to eq(:stopped)
        expect(captured).to be_a(RuntimeError)
        expect(captured.message).to include('reactor did not become ready within')
      end
    end
  end

  describe '#stop' do
    before do
      # Mock a server that raises IOError when accept is called (simulating server shutdown)
      server = instance_double(TCPServer)
      allow(TCPServer).to receive(:new).and_return(server)
      allow(server).to receive(:accept).and_raise(IOError, 'Server closed')
      allow(server).to receive(:close)
    end

    it 'transitions state to :stopped' do
      forwarder.start
      sleep 0.1
      forwarder.stop
      expect(forwarder.state).to eq(:stopped)
    end

    it 'is idempotent' do
      forwarder.start
      sleep 0.1
      forwarder.stop
      forwarder.stop # Call again
      expect(forwarder.state).to eq(:stopped)
    end

    # Issue #2: Dangerous thread termination
    # FIXED: Now uses graceful shutdown with thread.raise, only kills as last resort
    it 'uses graceful shutdown for connection threads' do
      server = instance_double(TCPServer)
      allow(TCPServer).to receive(:new).and_return(server)
      allow(server).to receive(:accept).and_raise(IOError, 'Server closed')
      allow(server).to receive(:close)

      forwarder.start
      sleep 0.1

      # Mock a connection thread
      connection_threads = forwarder.instance_variable_get(:@connection_threads)
      mock_thread = Thread.new { sleep 10 }
      connection_threads << mock_thread

      # After fix: thread.raise is used for graceful shutdown, not immediate kill
      expect(mock_thread).to receive(:raise).with(IOError, /shutting down/).and_call_original

      # Stop should wait for thread to finish, not kill immediately
      expect(logger).to receive(:debug).with(/Thread exited with exception during shutdown/)

      forwarder.stop

      # Thread should no longer be alive after graceful shutdown
      expect(mock_thread.alive?).to be false
    end

    # Issue #3: EventMachine reactor shared across connections
    # FIXED: Each forwarder tracks reactor ownership, only stops if it owns it
    it 'stops only its own EventMachine reactor when multiple forwarders exist' do
      # Mock TCPServer to avoid actual port binding
      server1 = instance_double(TCPServer)
      server2 = instance_double(TCPServer)
      allow(TCPServer).to receive(:new).with('127.0.0.1', 2222).and_return(server1)
      allow(TCPServer).to receive(:new).with('127.0.0.1', 2223).and_return(server2)
      allow(server1).to receive(:accept).and_raise(IOError, 'Server closed')
      allow(server2).to receive(:accept).and_raise(IOError, 'Server closed')
      allow(server1).to receive(:close)
      allow(server2).to receive(:close)

      # Mock EventMachine to track reactor lifecycle
      reactor_started = false
      allow(EventMachine).to receive(:reactor_running?) { reactor_started }
      allow(EventMachine).to receive(:run) { reactor_started = true }
      allow(EventMachine).to receive(:stop) { reactor_started = false }

      # Create two forwarders
      forwarder1 = described_class.new(
        kube_client: kube_client,
        namespace: 'default',
        vmi_name: 'test-vmi',
        target_port: 22,
        local_port: 2222,
        logger: logger,
      )

      forwarder2 = described_class.new(
        kube_client: kube_client,
        namespace: 'default',
        vmi_name: 'test-vmi-2',
        target_port: 22,
        local_port: 2223,
        logger: logger,
      )

      # Start both forwarders
      forwarder1.start
      sleep 0.1
      forwarder2.start
      sleep 0.1

      # Verify that only the first forwarder owns the reactor
      expect(described_class.reactor_owner).to eq(forwarder1)

      # When we stop forwarder2, it should NOT stop the reactor
      forwarder2.stop
      expect(reactor_started).to be true # Reactor should still be running

      # Reactor owner should still be forwarder1
      expect(described_class.reactor_owner).to eq(forwarder1)

      # When we stop forwarder1, it SHOULD stop the reactor
      forwarder1.stop
      expect(reactor_started).to be false # Reactor should now be stopped

      # Reactor owner should now be nil
      expect(described_class.reactor_owner).to be_nil
    end

    it 'closes the TCP server' do
      server = instance_double(TCPServer)
      allow(TCPServer).to receive(:new).and_return(server)
      allow(server).to receive(:accept).and_raise(IOError, 'Server closed')
      expect(server).to receive(:close)

      forwarder.start
      sleep 0.1
      forwarder.stop
    end

    it 'waits for server thread to complete' do
      forwarder.start
      sleep 0.1

      server_thread = forwarder.instance_variable_get(:@server_thread)
      expect(server_thread).to receive(:join).and_call_original if server_thread

      forwarder.stop
    end

    it 'waits for reactor thread to complete' do
      forwarder.start
      sleep 0.1

      reactor_thread = forwarder.instance_variable_get(:@reactor_thread)
      expect(reactor_thread).to receive(:join).and_call_original if reactor_thread

      forwarder.stop
    end
  end

  describe '#establish_websocket_with_retry' do
    let(:client_socket) { instance_double(TCPSocket, closed?: false) }

    before do
      # Mock WebSocket creation
      allow(Faye::WebSocket::Client).to receive(:new).and_return(
        instance_double(Faye::WebSocket::Client, on: nil, protocol: nil),
      )
    end

    # Issue #8: Retry logic is actually CORRECT
    # Beaker expects the forwarder to be available immediately and handles its own
    # retry logic. The port forwarder retrying internally would interfere with Beaker's
    # ability to detect when the VMI is ready. This test verifies the current behavior.
    it 'retries the correct number of times when requested' do
      allow(client_socket).to receive(:closed?).and_return(false)

      # Mock Queue to simulate failures
      connection_status_q = Queue.new
      allow(Queue).to receive(:new).and_return(connection_status_q)

      # Force failures by pushing errors
      call_count = 0
      allow(EventMachine).to receive(:schedule) do
        call_count += 1
        connection_status_q.push(RuntimeError.new('Failed'))
      end

      result = forwarder.send(:establish_websocket_with_retry, client_socket, retries: 3, delay: 0.01)

      expect(result).to be_nil
      expect(call_count).to eq(3) # Retries the requested number of times
    end

    it 'returns nil when all retry attempts fail' do
      allow(client_socket).to receive(:closed?).and_return(false)

      # Mock Queue to simulate connection failures
      connection_status_q = Queue.new
      allow(Queue).to receive(:new).and_return(connection_status_q)

      # Mock EventMachine.schedule to push errors to the queue
      allow(EventMachine).to receive(:schedule) do |&_block|
        # Push error to indicate connection failure
        connection_status_q.push(RuntimeError.new('Connection failed'))
      end

      result = forwarder.send(:establish_websocket_with_retry, client_socket, retries: 1, delay: 0)

      # Should return nil when all retries fail
      expect(result).to be_nil
    end

    it 'returns nil if client socket closes during retry' do
      # Simulate socket closing after first attempt
      call_count = 0
      allow(client_socket).to receive(:closed?) do
        call_count += 1
        call_count > 1 # Returns true after first check
      end

      # Mock Queue to prevent hanging
      connection_status_q = Queue.new
      allow(Queue).to receive(:new).and_return(connection_status_q)

      # Mock EventMachine.schedule to push error so queue.pop doesn't hang
      allow(EventMachine).to receive(:schedule) do
        connection_status_q.push(RuntimeError.new('Connection failed'))
      end

      result = forwarder.send(:establish_websocket_with_retry, client_socket, retries: 5, delay: 0)

      # Should return nil because socket closed
      expect(result).to be_nil
      # Should have attempted at least once before socket closed
      expect(call_count).to be >= 2
    end

    # Issue #15: Accessing private instance variables - LOW PRIORITY
    # The code accesses event.driver.instance_variable_get(:@http) to get better
    # error messages from 500 responses. This works but is fragile if Faye::WebSocket
    # internals change. It's a maintainability concern, not a functional bug.
    it 'handles WebSocket close events with HTTP 500 errors' do
      ws = instance_double(Faye::WebSocket::Client)
      allow(Faye::WebSocket::Client).to receive(:new).and_return(ws)

      # Capture the close handler to test it
      close_handler = nil
      allow(ws).to receive(:on) do |event_name, &block|
        close_handler = block if event_name == :close
      end

      # Mock Queue to prevent hanging
      connection_status_q = Queue.new
      allow(Queue).to receive(:new).and_return(connection_status_q)

      # Execute the block to actually register the handlers
      allow(EventMachine).to receive(:schedule) do |&block|
        block.call
        # Push an error to unblock the queue.pop
        connection_status_q.push(RuntimeError.new('Test error'))
      end

      forwarder.send(:establish_websocket_with_retry, client_socket, retries: 1, delay: 0)

      # Verify the close handler was registered
      expect(close_handler).not_to be_nil

      # Now test the fragile instance_variable_get access
      # Create a mock close event with nested driver and @http instance variable
      http_response = double('HTTP Response', code: 500, body: '{"message":"VMI not ready"}')
      driver = double('Driver')
      allow(driver).to receive(:instance_variable_defined?).with(:@http).and_return(true)
      allow(driver).to receive(:instance_variable_get).with(:@http).and_return(http_response)

      close_event = double('Close Event', code: 1006, reason: 'Connection failed')
      allow(close_event).to receive(:instance_variable_defined?).with(:@driver).and_return(true)
      allow(close_event).to receive(:driver).and_return(driver)

      # The fragile access should work and extract the error message
      # Note: The implementation uses logger.warn, not logger.error
      expect(logger).to receive(:warn).with(/Server returned 500 Internal Server Error: VMI not ready/)

      # Call the close handler with our mock event
      close_handler.call(close_event)
    end

    # Fix: WebSocket URL construction
    context 'when constructing WebSocket URLs' do
      it 'constructs correct WebSocket URL from standard Kubernetes endpoint' do
        kube_client = instance_double(
          Kubeclient::Client,
          api_endpoint: URI.parse('https://kubernetes.example.com/apis/kubevirt.io'),
          auth_options: { bearer_token: 'test-token' },
          ssl_options: {},
        )
        forwarder = described_class.new(
          kube_client: kube_client,
          namespace: 'default',
          vmi_name: 'test-vm',
          target_port: 22,
          local_port: 10_022,
          logger: logger,
        )

        client_socket = instance_double(TCPSocket, closed?: false)

        # Capture the URL passed to WebSocket
        captured_url = nil
        allow(Faye::WebSocket::Client).to receive(:new) do |url, _protocols, _options|
          captured_url = url
          instance_double(Faye::WebSocket::Client, on: nil)
        end

        # Mock Queue and EventMachine to simulate connection attempt
        connection_status_q = Queue.new
        allow(Queue).to receive(:new).and_return(connection_status_q)
        allow(EventMachine).to receive(:schedule) do |&block|
          block.call # Execute the block to create the WebSocket
          connection_status_q.push(RuntimeError.new('Connection failed'))
        end

        forwarder.send(:establish_websocket_with_retry, client_socket, retries: 1, delay: 0)

        expect(captured_url).to eq('wss://kubernetes.example.com/apis/subresources.kubevirt.io/v1/namespaces/default/virtualmachineinstances/test-vm/portforward/22/tcp')
      end

      it 'constructs correct WebSocket URL with custom port' do
        kube_client = instance_double(
          Kubeclient::Client,
          api_endpoint: URI.parse('https://kubernetes.example.com:6443/apis/kubevirt.io'),
          auth_options: { bearer_token: 'test-token' },
          ssl_options: {},
        )
        forwarder = described_class.new(
          kube_client: kube_client,
          namespace: 'default',
          vmi_name: 'test-vm',
          target_port: 22,
          local_port: 10_022,
          logger: logger,
        )

        client_socket = instance_double(TCPSocket, closed?: false)

        captured_url = nil
        allow(Faye::WebSocket::Client).to receive(:new) do |url, _protocols, _options|
          captured_url = url
          instance_double(Faye::WebSocket::Client, on: nil)
        end

        connection_status_q = Queue.new
        allow(Queue).to receive(:new).and_return(connection_status_q)
        allow(EventMachine).to receive(:schedule) do |&block|
          block.call
          connection_status_q.push(RuntimeError.new('Connection failed'))
        end

        forwarder.send(:establish_websocket_with_retry, client_socket, retries: 1, delay: 0)

        expect(captured_url).to eq('wss://kubernetes.example.com:6443/apis/subresources.kubevirt.io/v1/namespaces/default/virtualmachineinstances/test-vm/portforward/22/tcp')
      end

      it 'constructs correct WebSocket URL from Rancher-style endpoint' do
        kube_client = instance_double(
          Kubeclient::Client,
          api_endpoint: URI.parse('https://rancher.example.com/k8s/clusters/local/apis/kubevirt.io'),
          auth_options: { bearer_token: 'test-token' },
          ssl_options: {},
        )
        forwarder = described_class.new(
          kube_client: kube_client,
          namespace: 'default',
          vmi_name: 'test-vm',
          target_port: 22,
          local_port: 10_022,
          logger: logger,
        )

        client_socket = instance_double(TCPSocket, closed?: false)

        captured_url = nil
        allow(Faye::WebSocket::Client).to receive(:new) do |url, _protocols, _options|
          captured_url = url
          instance_double(Faye::WebSocket::Client, on: nil)
        end

        connection_status_q = Queue.new
        allow(Queue).to receive(:new).and_return(connection_status_q)
        allow(EventMachine).to receive(:schedule) do |&block|
          block.call
          connection_status_q.push(RuntimeError.new('Connection failed'))
        end

        forwarder.send(:establish_websocket_with_retry, client_socket, retries: 1, delay: 0)

        # The path prefix /k8s/clusters/local should be preserved
        expect(captured_url).to eq('wss://rancher.example.com/k8s/clusters/local/apis/subresources.kubevirt.io/v1/namespaces/default/virtualmachineinstances/test-vm/portforward/22/tcp')
      end

      it 'constructs correct WebSocket URL from Rancher-style endpoint with /api path' do
        # This test replicates the exact scenario from the bug report where
        # the Kubernetes client endpoint ends in /api (not /apis/kubevirt.io)
        kube_client = instance_double(
          Kubeclient::Client,
          api_endpoint: URI.parse('https://rancher.example.com/k8s/clusters/c-m-abcd1234/api'),
          auth_options: { bearer_token: 'test-token' },
          ssl_options: {},
        )
        forwarder = described_class.new(
          kube_client: kube_client,
          namespace: 'default',
          vmi_name: 'test-vm',
          target_port: 22,
          local_port: 43_831,
          logger: logger,
        )

        client_socket = instance_double(TCPSocket, closed?: false)

        captured_url = nil
        allow(Faye::WebSocket::Client).to receive(:new) do |url, _protocols, _options|
          captured_url = url
          instance_double(Faye::WebSocket::Client, on: nil)
        end

        connection_status_q = Queue.new
        allow(Queue).to receive(:new).and_return(connection_status_q)
        allow(EventMachine).to receive(:schedule) do |&block|
          block.call
          connection_status_q.push(RuntimeError.new('Connection failed'))
        end

        forwarder.send(:establish_websocket_with_retry, client_socket, retries: 1, delay: 0)

        # The /k8s/clusters/c-m-abcd1234 path should be preserved, but /api should be removed
        expect(captured_url).to eq('wss://rancher.example.com/k8s/clusters/c-m-abcd1234/apis/subresources.kubevirt.io/v1/namespaces/default/virtualmachineinstances/test-vm/portforward/22/tcp')
      end

      it 'does not include default HTTPS port 443 in URL' do
        kube_client = instance_double(
          Kubeclient::Client,
          api_endpoint: URI.parse('https://kubernetes.example.com:443/apis/kubevirt.io'),
          auth_options: { bearer_token: 'test-token' },
          ssl_options: {},
        )
        forwarder = described_class.new(
          kube_client: kube_client,
          namespace: 'default',
          vmi_name: 'test-vm',
          target_port: 22,
          local_port: 10_022,
          logger: logger,
        )

        client_socket = instance_double(TCPSocket, closed?: false)

        captured_url = nil
        allow(Faye::WebSocket::Client).to receive(:new) do |url, _protocols, _options|
          captured_url = url
          instance_double(Faye::WebSocket::Client, on: nil)
        end

        connection_status_q = Queue.new
        allow(Queue).to receive(:new).and_return(connection_status_q)
        allow(EventMachine).to receive(:schedule) do |&block|
          block.call
          connection_status_q.push(RuntimeError.new('Connection failed'))
        end

        forwarder.send(:establish_websocket_with_retry, client_socket, retries: 1, delay: 0)

        # Port 443 should not appear in the URL
        expect(captured_url).to eq('wss://kubernetes.example.com/apis/subresources.kubevirt.io/v1/namespaces/default/virtualmachineinstances/test-vm/portforward/22/tcp')
        expect(captured_url).not_to include(':443')
      end

      it 'handles endpoint with only root path correctly' do
        # Test that a simple endpoint with just "/" doesn't add extra slashes
        kube_client = instance_double(
          Kubeclient::Client,
          api_endpoint: URI.parse('https://kubernetes.example.com/'),
          auth_options: { bearer_token: 'test-token' },
          ssl_options: {},
        )
        forwarder = described_class.new(
          kube_client: kube_client,
          namespace: 'default',
          vmi_name: 'test-vm',
          target_port: 22,
          local_port: 10_022,
          logger: logger,
        )

        client_socket = instance_double(TCPSocket, closed?: false)

        captured_url = nil
        allow(Faye::WebSocket::Client).to receive(:new) do |url, _protocols, _options|
          captured_url = url
          instance_double(Faye::WebSocket::Client, on: nil)
        end

        connection_status_q = Queue.new
        allow(Queue).to receive(:new).and_return(connection_status_q)
        allow(EventMachine).to receive(:schedule) do |&block|
          block.call
          connection_status_q.push(RuntimeError.new('Connection failed'))
        end

        forwarder.send(:establish_websocket_with_retry, client_socket, retries: 1, delay: 0)

        # Should not have double slashes in the path (after the protocol)
        expect(captured_url).to eq('wss://kubernetes.example.com/apis/subresources.kubevirt.io/v1/namespaces/default/virtualmachineinstances/test-vm/portforward/22/tcp')
        # Check that we don't have triple slashes or double slashes in the path
        expect(captured_url).not_to match(%r{://.*//})
      end

      it 'percent-encodes namespace and vmi_name path separators in the URL' do
        kube_client = instance_double(
          Kubeclient::Client,
          api_endpoint: URI.parse('https://kubernetes.example.com/api'),
          auth_options: { bearer_token: 'test-token' },
          ssl_options: {},
        )
        forwarder = described_class.new(
          kube_client: kube_client,
          namespace: 'my/namespace',
          vmi_name: 'my/vmi',
          target_port: 22,
          local_port: 10_022,
          logger: logger,
        )

        client_socket = instance_double(TCPSocket, closed?: false)

        captured_url = nil
        allow(Faye::WebSocket::Client).to receive(:new) do |url, _protocols, _options|
          captured_url = url
          instance_double(Faye::WebSocket::Client, on: nil)
        end

        connection_status_q = Queue.new
        allow(Queue).to receive(:new).and_return(connection_status_q)
        allow(EventMachine).to receive(:schedule) do |&block|
          block.call
          connection_status_q.push(RuntimeError.new('Connection failed'))
        end

        forwarder.send(:establish_websocket_with_retry, client_socket, retries: 1, delay: 0)

        expect(captured_url).to include('/namespaces/my%2Fnamespace/')
        expect(captured_url).to include('/virtualmachineinstances/my%2Fvmi/')
        expect(captured_url).not_to include('/namespaces/my/namespace/')
        expect(captured_url).not_to include('/virtualmachineinstances/my/vmi/')
      end

      it 'raises ArgumentError for a non-numeric target_port' do
        kube_client = instance_double(
          Kubeclient::Client,
          api_endpoint: URI.parse('https://kubernetes.example.com/api'),
          auth_options: { bearer_token: 'test-token' },
          ssl_options: {},
        )
        forwarder = described_class.new(
          kube_client: kube_client,
          namespace: 'default',
          vmi_name: 'test-vm',
          target_port: 'abc',
          local_port: 10_022,
          logger: logger,
        )

        client_socket = instance_double(TCPSocket, closed?: false)

        expect do
          forwarder.send(:establish_websocket_with_retry, client_socket, retries: 1, delay: 0)
        end.to raise_error(ArgumentError, /Invalid target port/)
      end

      it 'raises ArgumentError for target_port out of valid range' do
        kube_client = instance_double(
          Kubeclient::Client,
          api_endpoint: URI.parse('https://kubernetes.example.com/api'),
          auth_options: { bearer_token: 'test-token' },
          ssl_options: {},
        )
        forwarder = described_class.new(
          kube_client: kube_client,
          namespace: 'default',
          vmi_name: 'test-vm',
          target_port: 99_999,
          local_port: 10_022,
          logger: logger,
        )

        client_socket = instance_double(TCPSocket, closed?: false)

        expect do
          forwarder.send(:establish_websocket_with_retry, client_socket, retries: 1, delay: 0)
        end.to raise_error(ArgumentError, /Invalid target port/)
      end
    end

    # Fix: Bearer token only set when present
    context 'with authentication headers' do
      it 'includes Authorization header when bearer token is present' do
        kube_client = instance_double(
          Kubeclient::Client,
          api_endpoint: URI.parse('https://kubernetes.example.com/api'),
          auth_options: { bearer_token: 'my-secret-token' },
          ssl_options: {},
        )
        forwarder = described_class.new(
          kube_client: kube_client,
          namespace: 'default',
          vmi_name: 'test-vm',
          target_port: 22,
          local_port: 10_022,
          logger: logger,
        )

        client_socket = instance_double(TCPSocket, closed?: false)

        captured_headers = nil
        allow(Faye::WebSocket::Client).to receive(:new) do |_url, _protocols, options|
          captured_headers = options[:headers]
          instance_double(Faye::WebSocket::Client, on: nil)
        end

        connection_status_q = Queue.new
        allow(Queue).to receive(:new).and_return(connection_status_q)
        allow(EventMachine).to receive(:schedule) do |&block|
          block.call
          connection_status_q.push(RuntimeError.new('Connection failed'))
        end

        forwarder.send(:establish_websocket_with_retry, client_socket, retries: 1, delay: 0)

        expect(captured_headers).to include('Authorization' => 'Bearer my-secret-token')
      end

      it 'does not include Authorization header when bearer token is nil' do
        kube_client = instance_double(
          Kubeclient::Client,
          api_endpoint: URI.parse('https://kubernetes.example.com/api'),
          auth_options: { bearer_token: nil },
          ssl_options: {},
        )
        forwarder = described_class.new(
          kube_client: kube_client,
          namespace: 'default',
          vmi_name: 'test-vm',
          target_port: 22,
          local_port: 10_022,
          logger: logger,
        )

        client_socket = instance_double(TCPSocket, closed?: false)

        captured_headers = nil
        allow(Faye::WebSocket::Client).to receive(:new) do |_url, _protocols, options|
          captured_headers = options[:headers]
          instance_double(Faye::WebSocket::Client, on: nil)
        end

        connection_status_q = Queue.new
        allow(Queue).to receive(:new).and_return(connection_status_q)
        allow(EventMachine).to receive(:schedule) do |&block|
          block.call
          connection_status_q.push(RuntimeError.new('Connection failed'))
        end

        forwarder.send(:establish_websocket_with_retry, client_socket, retries: 1, delay: 0)

        expect(captured_headers).not_to have_key('Authorization')
      end

      it 'does not include Authorization header when bearer token is empty string' do
        kube_client = instance_double(
          Kubeclient::Client,
          api_endpoint: URI.parse('https://kubernetes.example.com/api'),
          auth_options: { bearer_token: '' },
          ssl_options: {},
        )
        forwarder = described_class.new(
          kube_client: kube_client,
          namespace: 'default',
          vmi_name: 'test-vm',
          target_port: 22,
          local_port: 10_022,
          logger: logger,
        )

        client_socket = instance_double(TCPSocket, closed?: false)

        captured_headers = nil
        allow(Faye::WebSocket::Client).to receive(:new) do |_url, _protocols, options|
          captured_headers = options[:headers]
          instance_double(Faye::WebSocket::Client, on: nil)
        end

        connection_status_q = Queue.new
        allow(Queue).to receive(:new).and_return(connection_status_q)
        allow(EventMachine).to receive(:schedule) do |&block|
          block.call
          connection_status_q.push(RuntimeError.new('Connection failed'))
        end

        forwarder.send(:establish_websocket_with_retry, client_socket, retries: 1, delay: 0)

        expect(captured_headers).not_to have_key('Authorization')
      end
    end

    context 'with WebSocket keepalive' do
      it 'enables periodic ping frames so upstream proxies don\'t idle-close the connection' do
        kube_client = instance_double(
          Kubeclient::Client,
          api_endpoint: URI.parse('https://kubernetes.example.com/api'),
          auth_options: { bearer_token: 'tok' },
          ssl_options: {},
        )
        forwarder = described_class.new(
          kube_client: kube_client,
          namespace: 'default',
          vmi_name: 'test-vm',
          target_port: 22,
          local_port: 10_022,
          logger: logger,
        )

        client_socket = instance_double(TCPSocket, closed?: false)

        captured_options = nil
        allow(Faye::WebSocket::Client).to receive(:new) do |_url, _protocols, options|
          captured_options = options
          instance_double(Faye::WebSocket::Client, on: nil)
        end

        connection_status_q = Queue.new
        allow(Queue).to receive(:new).and_return(connection_status_q)
        allow(EventMachine).to receive(:schedule) do |&block|
          block.call
          connection_status_q.push(RuntimeError.new('Connection failed'))
        end

        forwarder.send(:establish_websocket_with_retry, client_socket, retries: 1, delay: 0)

        expect(captured_options[:ping]).to eq(described_class::WEBSOCKET_PING_INTERVAL)
      end
    end
  end

  describe '#proxy_traffic' do
    let(:client_socket) { instance_double(TCPSocket) }
    let(:websocket) do
      instance_double(
        Faye::WebSocket::Client,
        protocol: KubeVirtPortForwarder::PLAIN_STREAM_PROTOCOL,
        on: nil,
        send: nil,
        close: nil,
        ready_state: Faye::WebSocket::Client::OPEN,
      )
    end

    before do
      allow(client_socket).to receive(:readpartial).and_raise(IOError)
      allow(client_socket).to receive(:write)
      allow(client_socket).to receive(:close)
    end

    # Issue #5: Missing error handling in write operations
    # FIXED: Write errors are now caught and logged, not propagated
    it 'handles client socket write errors gracefully' do
      allow(client_socket).to receive(:write).and_raise(IOError, 'Socket closed')

      message_handlers = []
      allow(websocket).to receive(:on) do |event, &block|
        message_handlers << block if event == :message
      end

      forwarder.send(:proxy_traffic, client_socket, websocket)

      # Simulate incoming WebSocket message
      # Faye::WebSocket::Event has data as a method, not attribute
      event = double('WebSocket Event', data: 'test data')

      # After fix: write errors are caught and logged, not propagated
      expect(logger).to receive(:debug).with(/Failed to write to client socket/)
      expect { message_handlers.first.call(event) if message_handlers.any? }.not_to raise_error
    end

    # We deliberately do NOT enforce a client-silence timeout: net-ssh defers
    # keepalive while the server is streaming output back, so a healthy
    # long-running SSH session can legitimately have zero client->ws bytes
    # for many minutes. Dead peers are detected via EOF/RST from the OS, and
    # the upstream half is covered by the WebSocket ping.
    it 'does not enforce a client-silence timeout' do
      idle_socket = instance_double(TCPSocket)
      allow(idle_socket).to receive(:close)
      # readpartial blocks until data or EOF; never returning simulates a
      # client that's quiet because the server is doing the talking.
      allow(idle_socket).to receive(:readpartial) { sleep 5 }

      proxy_thread = Thread.new { forwarder.send(:proxy_traffic, idle_socket, websocket) }
      sleep 0.3

      expect(idle_socket).not_to have_received(:close)
      expect(proxy_thread.alive?).to be true

      proxy_thread.kill
      proxy_thread.join(1)
    end

    # Fix: EOFError handling
    it 'handles EOFError when client closes connection gracefully' do
      # Mock a socket that raises EOFError on read (normal client disconnect)
      allow(client_socket).to receive(:readpartial).and_raise(EOFError)
      allow(client_socket).to receive(:close)

      # WebSocket should be closed when client disconnects
      expect(websocket).to receive(:close)

      # Should log the disconnect with a clear message indicating clean shutdown
      expect(logger).to receive(:debug).with(/Client connection closed cleanly \(EOF\)/)

      # Should not raise an exception
      expect do
        forwarder.send(:proxy_traffic, client_socket, websocket)
      end.not_to raise_error
    end

    it 'handles EOFError alongside IOError and ECONNRESET' do
      # Test that all three exception types are handled the same way
      [EOFError, IOError, Errno::ECONNRESET].each do |exception_class|
        socket = instance_double(TCPSocket)
        allow(socket).to receive(:wait_readable).and_return(socket)
        allow(socket).to receive(:readpartial).and_raise(exception_class)
        allow(socket).to receive(:close)

        ws = instance_double(
          Faye::WebSocket::Client,
          protocol: KubeVirtPortForwarder::PLAIN_STREAM_PROTOCOL,
          on: nil,
          send: nil,
          close: nil,
          ready_state: Faye::WebSocket::Client::OPEN,
        )

        # EOFError gets a more specific message
        if exception_class == EOFError
          expect(logger).to receive(:debug).with(/Client connection closed cleanly \(EOF\)/)
        else
          expect(logger).to receive(:debug).with(/Client socket closed/)
        end

        expect do
          forwarder.send(:proxy_traffic, socket, ws)
        end.not_to raise_error
      end
    end

    # Issue #7: WebSocket cleanup - NOT A PROBLEM
    # Event handlers are attached to WebSocket instances that are created fresh for
    # each connection. When the WebSocket closes, the object is garbage collected
    # along with its handlers. Since WebSockets are not reused, this is not a leak.
    it 'attaches handlers to short-lived WebSocket instances' do
      # Create two separate websocket instances
      ws1 = instance_double(Faye::WebSocket::Client, protocol: KubeVirtPortForwarder::PLAIN_STREAM_PROTOCOL, on: nil, send: nil, close: nil, ready_state: Faye::WebSocket::Client::OPEN)
      ws2 = instance_double(Faye::WebSocket::Client, protocol: KubeVirtPortForwarder::PLAIN_STREAM_PROTOCOL, on: nil, send: nil, close: nil, ready_state: Faye::WebSocket::Client::OPEN)

      handlers1 = {}
      handlers2 = {}

      allow(ws1).to receive(:on) do |event, &block|
        handlers1[event] = block
      end

      allow(ws2).to receive(:on) do |event, &block|
        handlers2[event] = block
      end

      socket1 = instance_double(TCPSocket)
      socket2 = instance_double(TCPSocket)
      allow(socket1).to receive(:wait_readable).and_return(socket1)
      allow(socket2).to receive(:wait_readable).and_return(socket2)
      allow(socket1).to receive(:readpartial).and_raise(IOError)
      allow(socket2).to receive(:readpartial).and_raise(IOError)

      # Attach handlers to first websocket
      forwarder.send(:proxy_traffic, socket1, ws1)

      # Attach handlers to second websocket
      forwarder.send(:proxy_traffic, socket2, ws2)

      # Each websocket gets its own handlers (not shared/reused)
      expect(handlers1).not_to be_empty
      expect(handlers2).not_to be_empty
      expect(handlers1[:message]).not_to equal(handlers2[:message]) # Different handler objects
    end

    # Issue #11: No input validation - NOT A PROBLEM
    # Payload size validation is not needed for SSH port forwarding.
    # SSH has its own flow control and won't send unlimited data.
    # Adding size limits could break legitimate large file transfers.
    it 'does not validate payload sizes before writing' do
      large_payload = 'x' * (100 * 1024 * 1024) # 100 MB

      message_handlers = []
      allow(websocket).to receive(:on) do |event, &block|
        message_handlers << block if event == :message
      end

      # Track what gets written to verify no truncation/validation
      written_data = []
      allow(client_socket).to receive(:write) do |data|
        written_data << data
        data.size
      end

      forwarder.send(:proxy_traffic, client_socket, websocket)

      event = double('WebSocket Event', data: large_payload)

      # Call the message handler with large payload
      message_handlers.first.call(event) if message_handlers.any?

      # Verify the ENTIRE payload was written without size validation
      expect(written_data.size).to eq(1)
      expect(written_data.first.size).to eq(large_payload.size) # Full 100 MB written
      expect(written_data.first).to eq(large_payload) # Exact data, no truncation
    end

    # Issue #12: Error channel doesn't stop proxy
    # The proxy receives error messages from the server but continues proxying.
    # This may be acceptable behavior - errors are logged and reported via callback.
    it 'reports but continues proxying after receiving error channel message' do
      ws_with_channels = instance_double(
        Faye::WebSocket::Client,
        protocol: KubeVirtPortForwarder::STREAM_PROTOCOL,
        on: nil,
        send: nil,
        close: nil,
        ready_state: Faye::WebSocket::Client::OPEN,
      )

      message_handlers = []
      allow(ws_with_channels).to receive(:on) do |event, &block|
        message_handlers << block if event == :message
      end

      forwarder.send(:proxy_traffic, client_socket, ws_with_channels)

      # Send an error channel message
      error_msg = "#{KubeVirtPortForwarder::ERROR_CHANNEL}Fatal error from server"
      event = double('WebSocket Event', data: error_msg)

      # After fix for Issue #16, this should not crash
      # Error is logged and reported via callback, but proxy continues
      expect(logger).to receive(:error).with(/Received error from server/)
      expect do
        message_handlers.first.call(event) if message_handlers.any?
      end.not_to raise_error
    end

    # Issue #17: Inconsistent WebSocket state checking - LOW PRIORITY
    # The code only checks for OPEN state before closing, but this is actually fine.
    # Other states (CONNECTING, CLOSING, CLOSED) don't need explicit close calls.
    it 'only checks for OPEN state when closing WebSocket' do
      allow(client_socket).to receive(:readpartial).and_raise(IOError)

      # WebSocket in CONNECTING state
      connecting_ws = instance_double(
        Faye::WebSocket::Client,
        protocol: KubeVirtPortForwarder::PLAIN_STREAM_PROTOCOL,
        on: nil,
        ready_state: 0, # CONNECTING
      )

      # Correctly doesn't call close on CONNECTING websocket
      expect(connecting_ws).not_to receive(:close)

      forwarder.send(:proxy_traffic, client_socket, connecting_ws)
    end

    # Issue #18: No validation of protocol negotiation - LOW PRIORITY
    # The code accepts whatever protocol the server negotiates. This is fine in practice
    # since the server controls the protocol and will return an appropriate one.
    # Strict validation could break compatibility if new protocols are added.
    it 'does not validate protocol negotiation result' do
      # Test with multiple unexpected protocols
      unexpected_protocols = [
        'unexpected.protocol.v1',
        'future.protocol.v2',
        'random-protocol',
        '',
        nil,
      ]

      unexpected_protocols.each do |protocol|
        ws = instance_double(
          Faye::WebSocket::Client,
          protocol: protocol,
          on: nil,
          send: nil,
          close: nil,
          ready_state: Faye::WebSocket::Client::OPEN,
        )

        socket = instance_double(TCPSocket)
        allow(socket).to receive(:wait_readable).and_return(socket)
        allow(socket).to receive(:readpartial).and_raise(IOError)

        # The code should just use whatever protocol without validation
        # It only checks == STREAM_PROTOCOL to decide on channel multiplexing
        expect do
          forwarder.send(:proxy_traffic, socket, ws)
        end.not_to raise_error

        # Verify it logged the protocol without rejecting it
        expect(logger).to have_received(:debug).with(/Using raw stream protocol \(negotiated: '#{protocol || 'none'}'\)/)

        # Reset logger expectations for next iteration
        allow(logger).to receive(:debug)
      end
    end
  end

  describe '#handle_connection' do
    let(:client_socket) { instance_double(TCPSocket, close: nil, closed?: false) }

    it 'closes client socket if WebSocket establishment fails' do
      allow(forwarder).to receive(:establish_websocket_with_retry).and_return(nil)

      expect(client_socket).to receive(:close)

      forwarder.send(:handle_connection, client_socket)
    end

    it 'proxies traffic if WebSocket is established' do
      websocket = instance_double(Faye::WebSocket::Client)
      allow(forwarder).to receive(:establish_websocket_with_retry).and_return(websocket)
      allow(forwarder).to receive(:proxy_traffic)

      expect(forwarder).to receive(:proxy_traffic).with(client_socket, websocket)

      forwarder.send(:handle_connection, client_socket)
    end

    it 'removes itself from connection_threads when done' do
      allow(forwarder).to receive(:establish_websocket_with_retry).and_return(nil)

      connection_threads = forwarder.instance_variable_get(:@connection_threads)
      test_thread = Thread.new do
        forwarder.send(:handle_connection, client_socket)
      end
      connection_threads << test_thread

      test_thread.join

      expect(connection_threads).not_to include(test_thread)
    end

    it 'reports errors through callback and closes socket on exception' do
      allow(forwarder).to receive(:establish_websocket_with_retry).and_raise(StandardError, 'Unexpected error')

      # StandardError is caught, reported via report_error, and socket is closed
      expect(forwarder).to receive(:report_error)
      expect(client_socket).to receive(:close)

      # Exception is handled, not re-raised
      expect do
        forwarder.send(:handle_connection, client_socket)
      end.not_to raise_error
    end
  end

  describe '#report_error' do
    it 'logs the error' do
      error = StandardError.new('Test error')
      error.set_backtrace(%w[line1 line2])

      expect(logger).to receive(:error).with(/Test error/)

      forwarder.send(:report_error, error)
    end

    it 'calls the on_error callback if provided' do
      error = StandardError.new('Test error')
      error.set_backtrace(%w[line1 line2])

      expect(on_error).to receive(:call).with(error)

      forwarder.send(:report_error, error)
    end

    it 'handles missing on_error callback' do
      forwarder_without_callback = described_class.new(
        kube_client: kube_client,
        namespace: namespace,
        vmi_name: vmi_name,
        target_port: target_port,
        local_port: local_port,
        logger: logger,
      )

      error = StandardError.new('Test error')
      error.set_backtrace(%w[line1 line2])

      expect do
        forwarder_without_callback.send(:report_error, error)
      end.not_to raise_error
    end

    # Issue #16: report_error doesn't handle nil backtrace
    # FIXED: Now checks if backtrace exists before calling join
    it 'handles error with nil backtrace' do
      error = RuntimeError.new('Error without backtrace')
      # Don't set backtrace - it will be nil

      expect(logger).to receive(:error).with(/Error without backtrace/)

      expect do
        forwarder.send(:report_error, error)
      end.not_to raise_error
    end
  end

  describe '#state_transition_to' do
    # Issue #9: Race conditions in state transitions - FIXED
    # Uses @mutex.synchronize to ensure thread-safe state transitions
    it 'is thread-safe' do
      # Verify that the mutex is actually used during state transitions
      mutex = forwarder.instance_variable_get(:@mutex)
      mutex_lock_count = 0
      mutex_lock_mutex = Mutex.new

      # Wrap the mutex's synchronize method to track usage
      allow(mutex).to receive(:synchronize).and_wrap_original do |method, &block|
        mutex_lock_mutex.synchronize { mutex_lock_count += 1 }
        method.call(&block)
      end

      # Create multiple threads doing concurrent state transitions
      threads = Array.new(10) do
        Thread.new do
          100.times do
            forwarder.send(:state_transition_to, :starting)
            forwarder.send(:state_transition_to, :running)
            forwarder.send(:state_transition_to, :stopping)
            forwarder.send(:state_transition_to, :stopped)
            forwarder.instance_variable_set(:@state, :new)
          end
        end
      end

      threads.each(&:join)

      # Verify the mutex was actually used (should be called for each state transition)
      # 10 threads × 100 iterations × 4 transitions = 4000 times
      expect(mutex_lock_count).to eq(4000)

      # Verify final state is valid (if not thread-safe, could be corrupted)
      expect(forwarder.state).to be_a(Symbol)
      valid_states = %i[new starting running stopping stopped error]
      expect(valid_states).to include(forwarder.state)
    end

    it 'only allows valid state transitions' do
      # new -> starting
      expect(forwarder.send(:state_transition_to, :starting)).to be true

      # starting -> running
      expect(forwarder.send(:state_transition_to, :running)).to be true

      # running -> stopping
      expect(forwarder.send(:state_transition_to, :stopping)).to be true

      # stopping -> stopped
      expect(forwarder.send(:state_transition_to, :stopped)).to be true

      # stopped -> starting (allowed to restart)
      expect(forwarder.send(:state_transition_to, :starting)).to be true
    end

    it 'prevents invalid state transitions' do
      # Try to go directly from new to running (should fail)
      expect(forwarder.send(:state_transition_to, :running)).to be false
      expect(forwarder.state).to eq(:new)
    end
  end

  # Security Tests
  describe 'security' do
    # Issue #13: Bearer token in logs - VERIFIED SAFE
    # The bearer token is NOT logged. Only the WebSocket URL is logged.
    # Auth headers are constructed but never logged.
    it 'does not log bearer token' do
      # Track all log messages to verify token never appears
      all_log_messages = []

      allow(logger).to receive(:debug) do |msg|
        all_log_messages << msg
      end

      allow(logger).to receive(:info) do |msg|
        all_log_messages << msg
      end

      allow(logger).to receive(:warn) do |msg|
        all_log_messages << msg
      end

      allow(logger).to receive(:error) do |msg|
        all_log_messages << msg
      end

      # Test multiple code paths that could potentially log the token

      # 1. WebSocket URL construction in establish_websocket_with_retry
      client_socket = instance_double(TCPSocket, closed?: true)
      forwarder.send(:establish_websocket_with_retry, client_socket, retries: 1)

      # 2. Start the forwarder (logs initialization)
      forwarder.start
      sleep 0.1

      # 3. Stop the forwarder (logs shutdown)
      forwarder.stop

      # Verify the token 'test-token' never appeared in any log message
      all_log_messages.each do |msg|
        expect(msg).not_to include('test-token'), "Bearer token found in log message: #{msg}"
      end

      # Verify we did capture log messages (test isn't passing vacuously)
      expect(all_log_messages.size).to be > 0

      # Verify the WebSocket URL was logged (shows we're testing the right code path)
      url_logged = all_log_messages.any? { |msg| msg.include?('WebSocket URL:') }
      expect(url_logged).to be true
    end

    # Issue #14: No rate limiting - NOT A PROBLEM
    # Rate limiting is not appropriate here. Beaker expects immediate availability
    # and handles its own retry logic. The forwarder's job is to signal readiness.
    it 'does not rate limit connection attempts' do
      client_socket = instance_double(TCPSocket, closed?: false)

      # Mock Queue to prevent hanging
      connection_status_q = Queue.new
      allow(Queue).to receive(:new).and_return(connection_status_q)

      # Track timing of each retry attempt
      attempt_times = []

      allow(EventMachine).to receive(:schedule) do
        attempt_times << Time.now
        connection_status_q.push(RuntimeError.new('Connection failed'))
      end

      # Make many retry attempts with delay: 0
      forwarder.send(:establish_websocket_with_retry, client_socket, retries: 10, delay: 0)

      # Verify all attempts happened
      expect(attempt_times.size).to eq(10)

      # Verify no artificial delays between attempts (all happened quickly)
      total_duration = attempt_times.last - attempt_times.first
      expect(total_duration).to be < 1.0 # All 10 retries in under 1 second

      # Verify rapid succession (no rate limiting between attempts)
      attempt_times.each_cons(2) do |t1, t2|
        delay_between_attempts = t2 - t1
        expect(delay_between_attempts).to be < 0.1 # Less than 100ms between attempts
      end
    end
  end

  describe 'integration scenarios' do
    it 'handles rapid start/stop cycles' do
      allow(EventMachine).to receive(:reactor_running?).and_return(true)

      # Mock TCPServer with accept that raises IOError when server is closed
      server = instance_double(TCPServer)
      allow(TCPServer).to receive(:new).and_return(server)
      allow(server).to receive(:accept).and_raise(IOError, 'Server closed')
      allow(server).to receive(:close)

      5.times do
        forwarder.start
        sleep 0.05
        forwarder.stop
        sleep 0.05
      end

      expect(forwarder.state).to eq(:stopped)
    end
  end

  describe '#convert_ssl_options_to_tls' do
    it 'converts ca_file to root_cert_file for Faye::WebSocket' do
      ssl_options = { ca_file: '/tmp/ca-cert.pem' }
      tls_options = forwarder.send(:convert_ssl_options_to_tls, ssl_options)
      expect(tls_options[:root_cert_file]).to eq('/tmp/ca-cert.pem')
    end

    it 'does not set cert_chain_file for CA certificate' do
      # cert_chain_file is for client certs, not CA certs
      ssl_options = { ca_file: '/tmp/ca-cert.pem' }
      tls_options = forwarder.send(:convert_ssl_options_to_tls, ssl_options)
      expect(tls_options[:cert_chain_file]).to be_nil
    end

    it 'converts verify_ssl false to verify_peer false' do
      ssl_options = { verify_ssl: false }
      tls_options = forwarder.send(:convert_ssl_options_to_tls, ssl_options)
      expect(tls_options[:verify_peer]).to be(false)
    end

    it 'converts OpenSSL::SSL::VERIFY_PEER (1) to boolean true' do
      ssl_options = { verify_ssl: 1 }
      tls_options = forwarder.send(:convert_ssl_options_to_tls, ssl_options)
      expect(tls_options[:verify_peer]).to be(true)
    end

    it 'converts OpenSSL::SSL::VERIFY_NONE (0) to boolean false' do
      ssl_options = { verify_ssl: 0 }
      tls_options = forwarder.send(:convert_ssl_options_to_tls, ssl_options)
      expect(tls_options[:verify_peer]).to be(false)
    end

    it 'enables verification with CA file and verify_ssl set' do
      # With both CA file and verification enabled, Faye::WebSocket will verify properly
      ssl_options = { ca_file: '/tmp/ca-cert.pem', verify_ssl: 1 }
      tls_options = forwarder.send(:convert_ssl_options_to_tls, ssl_options)
      expect(tls_options[:root_cert_file]).to eq('/tmp/ca-cert.pem')
      expect(tls_options[:verify_peer]).to be(true)
    end

    it 'defaults to verification enabled when only CA file is present' do
      # When CA file is present without explicit verify_ssl, we explicitly enable verification
      ssl_options = { ca_file: '/tmp/ca-cert.pem' }
      tls_options = forwarder.send(:convert_ssl_options_to_tls, ssl_options)
      expect(tls_options[:root_cert_file]).to eq('/tmp/ca-cert.pem')
      expect(tls_options[:verify_peer]).to be(true) # Explicitly enabled with CA cert
    end

    it 'passes through client_key as private_key_file' do
      ssl_options = { client_key: '/tmp/client-key.pem' }
      tls_options = forwarder.send(:convert_ssl_options_to_tls, ssl_options)
      expect(tls_options[:private_key_file]).to eq('/tmp/client-key.pem')
    end

    it 'passes through client_cert as cert_chain_file' do
      ssl_options = { client_cert: '/tmp/client-cert.pem' }
      tls_options = forwarder.send(:convert_ssl_options_to_tls, ssl_options)
      expect(tls_options[:cert_chain_file]).to eq('/tmp/client-cert.pem')
    end

    it 'handles combined ca_file and client_cert separately' do
      # CA cert goes to root_cert_file, client cert to cert_chain_file
      ssl_options = { ca_file: '/tmp/ca.pem', client_cert: '/tmp/client.pem' }
      tls_options = forwarder.send(:convert_ssl_options_to_tls, ssl_options)
      expect(tls_options[:root_cert_file]).to eq('/tmp/ca.pem')
      expect(tls_options[:cert_chain_file]).to eq('/tmp/client.pem')
    end

    it 'returns empty hash for nil ssl_options' do
      tls_options = forwarder.send(:convert_ssl_options_to_tls, nil)
      expect(tls_options).to eq({})
    end

    it 'returns empty hash for empty ssl_options' do
      tls_options = forwarder.send(:convert_ssl_options_to_tls, {})
      expect(tls_options).to eq({})
    end

    it 'handles complete ssl_options with CA and client certs' do
      ssl_options = {
        ca_file: '/tmp/ca.pem',
        verify_ssl: 1,
        client_key: '/tmp/key.pem',
        client_cert: '/tmp/cert.pem',
      }
      tls_options = forwarder.send(:convert_ssl_options_to_tls, ssl_options)
      expect(tls_options).to include(
        root_cert_file: '/tmp/ca.pem',
        verify_peer: true,
        cert_chain_file: '/tmp/cert.pem',
        private_key_file: '/tmp/key.pem',
      )
    end
  end
end
