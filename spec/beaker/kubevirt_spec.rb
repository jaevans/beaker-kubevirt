# frozen_string_literal: true

RSpec.describe Beaker::Kubevirt do
  let(:options) do
    {
      logger: instance_double(Logger).as_null_object,
      kubeconfig: '/tmp/kubeconfig',
      namespace: 'beaker-test',
      kubevirt_vm_image: 'docker://quay.io/kubevirt/fedora-cloud-container-disk-demo',
      kubevirt_ssh_key: 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQ...',
    }
  end

  let(:hosts) do
    [
      {
        'name' => 'test-host',
        'platform' => 'el-8-x86_64',
        'hypervisor' => 'kubevirt',
      },
    ]
  end

  let(:kubevirt_helper) { instance_double(Beaker::KubevirtHelper) }

  before do
    allow(Beaker::KubevirtHelper).to receive(:new).and_return(kubevirt_helper)
    allow(kubevirt_helper).to receive(:namespace).and_return('beaker-test')
  end

  describe '#initialize' do
    let(:hypervisor) { described_class.new(hosts, options) }
    # Pin BEAKER_KUBEVIRT_TEST_GROUP for every example here, so a value in the
    # developer's own environment cannot change the identifier under test.
    let(:env_value) { nil }

    around do |example|
      previous = ENV.fetch('BEAKER_KUBEVIRT_TEST_GROUP', nil)
      ENV['BEAKER_KUBEVIRT_TEST_GROUP'] = env_value
      example.run
      ENV['BEAKER_KUBEVIRT_TEST_GROUP'] = previous
    end

    def identifier_for(opts = options)
      described_class.new(hosts, opts).instance_variable_get(:@test_group_identifier)
    end

    it 'is a Kubevirt hypervisor' do
      expect(hypervisor).to be_instance_of(described_class)
    end

    it 'sets the hosts' do
      expect(hypervisor.instance_variable_get(:@hosts)).to eq(hosts)
    end

    it 'sets the options' do
      expect(hypervisor.instance_variable_get(:@options)).to eq(options)
    end

    it 'sets the namespace' do
      expect(hypervisor.instance_variable_get(:@namespace)).to eq('beaker-test')
    end

    it 'requires namespace to be specified' do
      options_without_namespace = options.dup
      options_without_namespace.delete(:namespace)

      expect do
        described_class.new(hosts, options_without_namespace)
      end.to raise_error('Namespace must be specified in options')
    end

    it 'generates a test group identifier' do
      hypervisor = described_class.new(hosts, options)
      test_group_id = hypervisor.instance_variable_get(:@test_group_identifier)

      expect(test_group_id).to match(/^beaker-[a-f0-9]{8}$/)
    end

    context 'when BEAKER_KUBEVIRT_TEST_GROUP is set' do
      let(:env_value) { 'beaker-ci-12345' }

      it 'uses the supplied identifier' do
        expect(identifier_for).to eq('beaker-ci-12345')
      end
    end

    context 'when BEAKER_KUBEVIRT_TEST_GROUP is blank' do
      let(:env_value) { '   ' }

      it 'falls back to a generated identifier' do
        expect(identifier_for).to match(/^beaker-[a-f0-9]{8}$/)
      end
    end

    context 'when BEAKER_KUBEVIRT_TEST_GROUP is not a valid label value' do
      let(:env_value) { 'beaker/ci run!' }
      let(:logger) { instance_double(Logger).as_null_object }

      it 'sanitizes it so the label can be selected on' do
        expect(identifier_for(options.merge(logger: logger))).to eq('beaker-ci-run')
      end

      it 'warns that the identifier was changed' do
        identifier_for(options.merge(logger: logger))

        expect(logger).to have_received(:warn).with(/not usable as a Kubernetes label value/)
      end
    end

    it 'rejects namespaces that contain path separators' do
      bad_options = options.merge(namespace: 'foo/../bar')
      expect do
        described_class.new(hosts, bad_options)
      end.to raise_error(ArgumentError, /RFC 1123 DNS label/)
    end

    it 'rejects uppercase namespaces' do
      bad_options = options.merge(namespace: 'FOO')
      expect do
        described_class.new(hosts, bad_options)
      end.to raise_error(ArgumentError, /RFC 1123 DNS label/)
    end
  end

  describe '#provision' do
    let(:hypervisor) { described_class.new(hosts, options) }

    before do
      allow(hypervisor).to receive(:create_vm)
      allow(hypervisor).to receive(:wait_for_vm_ready)
    end

    context 'when provisioning' do
      before do
        allow(hypervisor).to receive_messages(create_vm: true, wait_for_vm_ready: true, setup_networking: true, setup_port_forward: true)
        hypervisor.provision
      end

      it 'creates the vm' do
        expect(hypervisor).to have_received(:create_vm).with(hosts[0])
      end

      it 'waits for the vm to be ready' do
        expect(hypervisor).to have_received(:wait_for_vm_ready).with(hosts[0])
      end

      it 'sets up networking' do
        expect(hypervisor).to have_received(:setup_networking).with(hosts[0])
      end
    end
  end

  describe '#cleanup' do
    context 'when cleaning up without port forwards' do
      let(:hypervisor) { described_class.new(hosts, options) }

      before do
        allow(kubevirt_helper).to receive(:cleanup_vms)
        allow(kubevirt_helper).to receive(:cleanup_secrets)
        allow(kubevirt_helper).to receive(:cleanup_services)
        allow(kubevirt_helper).to receive(:cleanup_temp_files)
        allow(kubevirt_helper).to receive(:cleanup_data_volumes)
        hypervisor.cleanup
      end

      it 'cleans up vms' do
        expect(kubevirt_helper).to have_received(:cleanup_vms).with(anything)
      end

      it 'cleans up data volumes' do
        expect(kubevirt_helper).to have_received(:cleanup_data_volumes).with(anything)
      end

      it 'cleans up data volumes after vms and before secrets' do
        expect(kubevirt_helper).to have_received(:cleanup_vms).ordered
        expect(kubevirt_helper).to have_received(:cleanup_data_volumes).ordered
        expect(kubevirt_helper).to have_received(:cleanup_secrets).ordered
      end

      it 'cleans up secrets' do
        expect(kubevirt_helper).to have_received(:cleanup_secrets).with(anything)
      end

      it 'cleans up services' do
        expect(kubevirt_helper).to have_received(:cleanup_services).with(anything)
      end

      it 'cleans up temp files' do
        expect(kubevirt_helper).to have_received(:cleanup_temp_files)
      end
    end

    context 'when an earlier cleanup step raises an error' do
      let(:hypervisor) { described_class.new(hosts, options) }

      before do
        allow(kubevirt_helper).to receive(:cleanup_vms).and_raise(StandardError, 'VM cleanup failed')
        allow(kubevirt_helper).to receive(:cleanup_secrets)
        allow(kubevirt_helper).to receive(:cleanup_services)
        allow(kubevirt_helper).to receive(:cleanup_temp_files)
        allow(kubevirt_helper).to receive(:cleanup_data_volumes)
      end

      it 'still cleans up temp files when cleanup_vms raises' do
        hypervisor.cleanup
        expect(kubevirt_helper).to have_received(:cleanup_temp_files)
      end

      it 'still cleans up remaining resources when cleanup_vms raises' do
        hypervisor.cleanup
        expect(kubevirt_helper).to have_received(:cleanup_secrets)
        expect(kubevirt_helper).to have_received(:cleanup_services)
      end
    end

    context 'when running a port forwarder' do
      require 'beaker/hypervisor/port_forward'

      let(:hosts_with_port_forward) do
        [
          {
            'name' => 'test-host',
            'platform' => 'el-8-x86_64',
            'hypervisor' => 'kubevirt',
            'port_forwarder' => instance_double(KubeVirtPortForwarder),
          },
        ]
      end
      let(:hypervisor_with_port_forward) { described_class.new(hosts_with_port_forward, options) }

      before do
        forwarder = hosts_with_port_forward[0]['port_forwarder']

        allow(forwarder).to receive(:stop)
        allow(forwarder).to receive(:state).and_return(:running, :running, :stopped)
        allow(kubevirt_helper).to receive(:cleanup_vms)
        allow(kubevirt_helper).to receive(:cleanup_secrets)
        allow(kubevirt_helper).to receive(:cleanup_services)
        allow(kubevirt_helper).to receive(:cleanup_temp_files)
        allow(kubevirt_helper).to receive(:cleanup_data_volumes)
        hypervisor_with_port_forward.cleanup(delay: 0.25)
      end

      it 'cleans up port forwarders' do
        forwarder = hosts_with_port_forward[0]['port_forwarder']

        expect(forwarder).to have_received(:stop)
      end
    end

    context 'when a stopped port forwarder' do
      require 'beaker/hypervisor/port_forward'

      let(:hosts_with_port_forward) do
        [
          {
            'name' => 'test-host',
            'platform' => 'el-8-x86_64',
            'hypervisor' => 'kubevirt',
            'port_forwarder' => instance_double(KubeVirtPortForwarder),
          },
        ]
      end
      let(:hypervisor_with_port_forward) { described_class.new(hosts_with_port_forward, options) }

      before do
        forwarder = hosts_with_port_forward[0]['port_forwarder']

        allow(forwarder).to receive(:stop)
        allow(forwarder).to receive(:state).and_return(:stopped)
        allow(kubevirt_helper).to receive(:cleanup_vms)
        allow(kubevirt_helper).to receive(:cleanup_secrets)
        allow(kubevirt_helper).to receive(:cleanup_services)
        allow(kubevirt_helper).to receive(:cleanup_temp_files)
        allow(kubevirt_helper).to receive(:cleanup_data_volumes)
        hypervisor_with_port_forward.cleanup
      end

      it 'cleans up port forwarders' do
        forwarder = hosts_with_port_forward[0]['port_forwarder']

        expect(forwarder).to have_received(:stop)
      end
    end

    context 'when unable to stop a port forwarder in time' do
      require 'beaker/hypervisor/port_forward'

      let(:hosts_with_port_forward) do
        [
          {
            'name' => 'test-host',
            'platform' => 'el-8-x86_64',
            'hypervisor' => 'kubevirt',
            'port_forwarder' => instance_double(KubeVirtPortForwarder),
          },
        ]
      end
      let(:hypervisor_with_port_forward) { described_class.new(hosts_with_port_forward, options) }

      before do
        forwarder = hosts_with_port_forward[0]['port_forwarder']

        allow(forwarder).to receive(:stop)
        allow(forwarder).to receive(:state).and_return(:running)
        allow(kubevirt_helper).to receive(:cleanup_vms)
        allow(kubevirt_helper).to receive(:cleanup_secrets)
        allow(kubevirt_helper).to receive(:cleanup_services)
        allow(kubevirt_helper).to receive(:cleanup_temp_files)
        allow(kubevirt_helper).to receive(:cleanup_data_volumes)
      end

      it 'does not raise and continues with cluster-side cleanup' do
        expect do
          hypervisor_with_port_forward.cleanup(timeout: 0.25, delay: 0.5)
        end.not_to raise_error

        expect(kubevirt_helper).to have_received(:cleanup_vms)
        expect(kubevirt_helper).to have_received(:cleanup_secrets)
        expect(kubevirt_helper).to have_received(:cleanup_services)
      end
    end
  end

  describe '#generate_vm_spec' do
    let(:vm_spec_args) do
      {
        hypervisor: described_class.new(hosts, options),
        host: hosts[0],
        vm_name: 'test-vm',
        cloud_init_data: 'base64-encoded-cloud-init',
      }
    end
    let(:vm_spec) { vm_spec_args[:hypervisor].send(:generate_vm_spec, vm_spec_args[:host], vm_spec_args[:vm_name], vm_spec_args[:cloud_init_data]) }

    it 'has the correct apiVersion' do
      expect(vm_spec['apiVersion']).to eq('kubevirt.io/v1')
    end

    it 'has the correct kind' do
      expect(vm_spec['kind']).to eq('VirtualMachine')
    end

    it 'has the correct name' do
      expect(vm_spec['metadata']['name']).to eq(vm_spec_args[:vm_name])
    end

    it 'has the correct namespace' do
      expect(vm_spec['metadata']['namespace']).to eq('beaker-test')
    end

    it 'has the correct runStrategy' do
      expect(vm_spec['spec']['runStrategy']).to eq('Once')
    end

    it 'includes cloud-init configuration' do
      volumes = vm_spec.dig('spec', 'template', 'spec', 'volumes')
      cloud_init_volume = volumes.find { |v| v['name'] == 'cidata' }

      expect(cloud_init_volume).not_to be_nil
    end

    it 'references the cloud-init secret' do
      volumes = vm_spec.dig('spec', 'template', 'spec', 'volumes')
      cloud_init_volume = volumes.find { |v| v['name'] == 'cidata' }
      expect(cloud_init_volume.dig('cloudInitNoCloud', 'secretRef', 'name')).to eq(vm_spec_args[:cloud_init_data])
    end

    context 'with explicit resource requests/limits' do
      let(:options) do
        {
          logger: instance_double(Logger).as_null_object,
          kubeconfig: '/tmp/kubeconfig',
          namespace: 'beaker-test',
          kubevirt_vm_image: 'docker://example/img',
          kubevirt_memory: '4Gi',
        }
      end

      it 'sets memory limit to guest plus default 512Mi overhead' do
        expect(vm_spec.dig('spec', 'template', 'spec', 'domain', 'resources', 'limits', 'memory')).to eq('4608Mi')
      end

      it 'defaults memory request to the guest value' do
        expect(vm_spec.dig('spec', 'template', 'spec', 'domain', 'resources', 'requests', 'memory')).to eq('4Gi')
      end

      it 'respects an overridden kubevirt_memory_overhead' do
        options[:kubevirt_memory_overhead] = '1Gi'
        expect(vm_spec.dig('spec', 'template', 'spec', 'domain', 'resources', 'limits', 'memory')).to eq('5120Mi')
      end

      it 'respects a per-host kubevirt_memory_overhead' do
        hosts[0]['kubevirt_memory_overhead'] = '256Mi'
        expect(vm_spec.dig('spec', 'template', 'spec', 'domain', 'resources', 'limits', 'memory')).to eq('4352Mi')
      end

      it 'respects an overridden kubevirt_memory_request' do
        options[:kubevirt_memory_request] = '2Gi'
        expect(vm_spec.dig('spec', 'template', 'spec', 'domain', 'resources', 'requests', 'memory')).to eq('2Gi')
      end
    end

    context 'with the SSH readinessProbe' do
      let(:probe) { vm_spec.dig('spec', 'template', 'spec', 'readinessProbe') }

      it 'emits a tcpSocket probe on port 22 by default' do
        expect(probe).to include(
          'tcpSocket' => { 'port' => 22 },
          'initialDelaySeconds' => 30,
          'periodSeconds' => 10,
          'timeoutSeconds' => 3,
          'failureThreshold' => 60,
          'successThreshold' => 1,
        )
      end

      it 'uses the configured kubevirt_vm_ssh_port' do
        hosts[0]['kubevirt_vm_ssh_port'] = 2222
        expect(probe.dig('tcpSocket', 'port')).to eq(2222)
      end

      it 'omits the probe entirely when the host uses multus networking' do
        hosts[0]['kubevirt_network_mode'] = 'multus'
        expect(vm_spec.dig('spec', 'template', 'spec')).not_to have_key('readinessProbe')
      end

      it 'can be force-enabled under multus via opt-in' do
        hosts[0]['kubevirt_network_mode'] = 'multus'
        hosts[0]['kubevirt_readiness_probe_disabled'] = false
        expect(probe).not_to be_nil
      end

      it 'can be disabled explicitly via options' do
        options[:kubevirt_readiness_probe_disabled] = true
        expect(vm_spec.dig('spec', 'template', 'spec')).not_to have_key('readinessProbe')
      end

      it 'merges caller overrides over defaults' do
        options[:kubevirt_readiness_probe] = { period_seconds: 5, failure_threshold: 120 }
        expect(probe).to include('periodSeconds' => 5, 'failureThreshold' => 120,
                                 'initialDelaySeconds' => 30)
      end

      it 'prefers per-host readiness_probe overrides over global options' do
        options[:kubevirt_readiness_probe] = { period_seconds: 5 }
        hosts[0]['kubevirt_readiness_probe'] = { period_seconds: 15 }
        expect(probe['periodSeconds']).to eq(15)
      end
    end
  end

  describe '#wait_for_vm_ready' do
    let(:hypervisor) { described_class.new(hosts, options.merge(timeout: 600)) }
    let(:host) { { 'vm_name' => 'test-vm' } }
    let(:vm_object) { { 'metadata' => { 'name' => 'test-vm' } } }
    let(:ready_true) { { 'type' => 'Ready', 'status' => 'True' } }
    let(:ready_false) { { 'type' => 'Ready', 'status' => 'False', 'reason' => 'GuestNotRunning' } }

    before do
      stub_const('Beaker::Kubevirt::SLEEPWAIT', 0)
      allow(kubevirt_helper).to receive_messages(get_vm: vm_object, get_virt_launcher_pod: nil)
    end

    it 'returns when the VMI is Running and Ready=True' do
      allow(kubevirt_helper).to receive(:get_vmi)
        .and_return('status' => { 'phase' => 'Running', 'conditions' => [ready_true] })
      expect { hypervisor.send(:wait_for_vm_ready, host) }.not_to raise_error
    end

    it 'keeps waiting when phase is Running but Ready=False, then returns when Ready flips' do
      not_ready = { 'status' => { 'phase' => 'Running', 'conditions' => [ready_false] } }
      ready = { 'status' => { 'phase' => 'Running', 'conditions' => [ready_true] } }
      allow(kubevirt_helper).to receive(:get_vmi).and_return(not_ready, not_ready, ready)
      expect { hypervisor.send(:wait_for_vm_ready, host) }.not_to raise_error
      expect(kubevirt_helper).to have_received(:get_vmi).at_least(3).times
    end

    it 'returns on phase=Running alone when the probe is disabled' do
      host['kubevirt_readiness_probe_disabled'] = true
      allow(kubevirt_helper).to receive(:get_vmi).and_return('status' => { 'phase' => 'Running' })
      expect { hypervisor.send(:wait_for_vm_ready, host) }.not_to raise_error
    end

    it 'returns on phase=Running alone in multus mode (probe skipped by default)' do
      host['kubevirt_network_mode'] = 'multus'
      allow(kubevirt_helper).to receive(:get_vmi).and_return('status' => { 'phase' => 'Running' })
      expect { hypervisor.send(:wait_for_vm_ready, host) }.not_to raise_error
    end

    it 'raises immediately when the compute container was OOMKilled' do
      allow(kubevirt_helper).to receive_messages(
        get_vmi: { 'status' => { 'phase' => 'Scheduling' } },
        get_virt_launcher_pod: {
          'status' => {
            'phase' => 'Running',
            'containerStatuses' => [
              {
                'name' => 'compute',
                'lastState' => { 'terminated' => { 'reason' => 'OOMKilled', 'exitCode' => 137 } },
                'state' => { 'waiting' => { 'reason' => 'CrashLoopBackOff' } },
              },
            ],
          },
        },
      )
      expect { hypervisor.send(:wait_for_vm_ready, host) }.to raise_error(/CrashLoopBackOff|OOMKilled/)
    end

    it 'surfaces OOMKilled with an overhead hint when the container is not yet waiting' do
      allow(kubevirt_helper).to receive_messages(
        get_vmi: { 'status' => { 'phase' => 'Scheduling' } },
        get_virt_launcher_pod: {
          'status' => {
            'phase' => 'Running',
            'containerStatuses' => [
              {
                'name' => 'compute',
                'state' => { 'terminated' => { 'reason' => 'OOMKilled', 'exitCode' => 137 } },
              },
            ],
          },
        },
      )
      expect { hypervisor.send(:wait_for_vm_ready, host) }
        .to raise_error(/OOMKilled.*kubevirt_memory_overhead/)
    end

    it 'raises when the VMI reaches a terminal phase' do
      allow(kubevirt_helper).to receive(:get_vmi).and_return({ 'status' => { 'phase' => 'Failed' } })
      expect { hypervisor.send(:wait_for_vm_ready, host) }
        .to raise_error(/terminal phase Failed/)
    end

    describe 'effective timeout' do
      it 'auto-raises the outer timeout to fit the probe budget' do
        hypervisor = described_class.new(hosts, options.merge(timeout: 5))
        # Tight probe budget: 0 + 0 * 3 + 60 = 60 > 5
        host['kubevirt_readiness_probe'] = { initial_delay_seconds: 0, period_seconds: 0, failure_threshold: 3 }
        expect(Timeout).to receive(:timeout).with(60).and_call_original
        allow(kubevirt_helper).to receive(:get_vmi)
          .and_return('status' => { 'phase' => 'Running', 'conditions' => [ready_true] })
        hypervisor.send(:wait_for_vm_ready, host)
      end

      it 'keeps the configured timeout when the probe is disabled' do
        hypervisor = described_class.new(hosts, options.merge(timeout: 42))
        host['kubevirt_readiness_probe_disabled'] = true
        expect(Timeout).to receive(:timeout).with(42).and_call_original
        allow(kubevirt_helper).to receive(:get_vmi).and_return('status' => { 'phase' => 'Running' })
        hypervisor.send(:wait_for_vm_ready, host)
      end
    end
  end

  describe '#generate_cloud_init' do
    let(:hypervisor) { described_class.new(hosts, options) }

    before do
      allow(hypervisor).to receive(:find_ssh_public_key).and_return('ssh-rsa test-key')
    end

    context 'when using Linux hosts' do
      let(:host) { { 'name' => 'test-host', 'user' => 'testuser', platform: 'debian-11-x86_64' } }

      it 'is a cloud-config' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        expect(cloud_init_data).to include('#cloud-config')
      end

      it 'includes the user' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        expect(cloud_init_data).to include('testuser')
      end

      it 'includes the ssh key' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        expect(cloud_init_data).to include('ssh-rsa test-key')
      end

      it 'includes sudo configuration' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        expect(cloud_init_data).to include('sudo: ALL=(ALL) NOPASSWD:ALL')
      end

      it 'includes bash shell' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        expect(cloud_init_data).to include('shell: "/bin/bash"')
      end

      it 'includes ssh_pwauth false' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        expect(cloud_init_data).to include('ssh_pwauth: false')
      end

      it 'includes disable_root false' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        expect(cloud_init_data).to include('disable_root: false')
      end

      it 'includes chpasswd configuration' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        aggregate_failures do
          expect(cloud_init_data).to include('chpasswd:')
          expect(cloud_init_data).to include('expire: false')
        end
      end
    end

    context 'when using Windows hosts' do
      let(:host) { { 'name' => 'win-host', 'user' => 'winuser', platform: 'windows-2019-x86_64' } }

      it 'is a cloud-config' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        expect(cloud_init_data).to include('#cloud-config')
      end

      it 'includes the user' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        expect(cloud_init_data).to include('winuser')
      end

      it 'includes the ssh key' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        expect(cloud_init_data).to include('ssh-rsa test-key')
      end

      it 'includes primary_group Administrators' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        expect(cloud_init_data).to include('primary_group: Administrators')
      end

      it 'includes powershell shell' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        expect(cloud_init_data).to include('shell: powershell.exe')
      end

      it 'does not include sudo configuration' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        expect(cloud_init_data).not_to include('sudo:')
      end

      it 'does not include ssh_pwauth' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        expect(cloud_init_data).not_to include('ssh_pwauth:')
      end

      it 'does not include disable_root' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        expect(cloud_init_data).not_to include('disable_root:')
      end

      it 'does not include chpasswd' do
        cloud_init_data = hypervisor.send(:generate_cloud_init, host)
        expect(cloud_init_data).not_to include('chpasswd:')
      end
    end
  end

  describe '#find_ssh_public_key' do
    let(:hypervisor) { described_class.new(hosts, options) }

    context 'when ssh_key is provided' do
      it 'returns the provided ssh key' do
        expect(hypervisor.send(:find_ssh_public_key)).to eq(options[:kubevirt_ssh_key])
      end

      it 'returns the contents of the file if it exists' do
        allow(File).to receive(:exist?).with(options[:kubevirt_ssh_key]).and_return(true)
        allow(File).to receive(:read).with(options[:kubevirt_ssh_key]).and_return('ssh-rsa test-key')

        expect(hypervisor.send(:find_ssh_public_key)).to eq('ssh-rsa test-key')
      end

      it 'returns the provided content of the key when it does not exist' do
        allow(File).to receive(:exist?).with(options[:kubevirt_ssh_key]).and_return(false)

        expect(hypervisor.send(:find_ssh_public_key)).to eq(options[:kubevirt_ssh_key])
      end
    end

    context 'when the key is not found' do
      let(:options) { super().dup.tap { |opts| opts.delete(:kubevirt_ssh_key) } }

      before do
        allow(File).to receive(:exist?).and_return(false)
      end

      it 'raises an error' do
        expect { hypervisor.send(:find_ssh_public_key) }.to raise_error(RuntimeError, /No matching SSH key pair found/)
      end
    end

    context 'when the id_ecdsa key is found' do
      let(:options) { super().dup.tap { |opts| opts.delete(:kubevirt_ssh_key) } }

      before do
        allow(File).to receive(:exist?).and_return(false)
        ecdsa_private_key_path = File.join(Dir.home, '.ssh', 'id_ecdsa')
        ecdsa_key_path = File.join(Dir.home, '.ssh', 'id_ecdsa.pub')
        allow(File).to receive(:exist?).with(ecdsa_private_key_path).and_return(true)
        allow(File).to receive(:exist?).with(ecdsa_key_path).and_return(true)
        allow(File).to receive(:read).with(ecdsa_key_path).and_return('ssh-ed25519 test-key')
      end

      it 'returns the id_ecdsa key' do
        expect(hypervisor.send(:find_ssh_public_key)).to eq('ssh-ed25519 test-key')
      end
    end
  end

  describe '#find_ssh_key_pair' do
    let(:hypervisor) { described_class.new(hosts, options) }

    context 'when ssh_key is provided as a file path' do
      let(:options) do
        super().merge(kubevirt_ssh_key: '/home/user/.ssh/id_test.pub')
      end

      it 'returns the public key content and matching private key path' do
        allow(File).to receive(:exist?).with('/home/user/.ssh/id_test.pub').and_return(true)
        allow(File).to receive(:exist?).with('/home/user/.ssh/id_test').and_return(true)
        allow(File).to receive(:read).with('/home/user/.ssh/id_test.pub').and_return('ssh-rsa test-key')
        result = hypervisor.send(:find_ssh_key_pair)
        aggregate_failures do
          expect(result[:public_key]).to eq('ssh-rsa test-key')
          expect(result[:private_key_path]).to eq('/home/user/.ssh/id_test')
        end
      end

      it 'raises an error when private key does not exist' do
        allow(File).to receive(:exist?).with('/home/user/.ssh/id_test.pub').and_return(true)
        allow(File).to receive(:read).with('/home/user/.ssh/id_test.pub').and_return('ssh-rsa test-key')
        allow(File).to receive(:exist?).with('/home/user/.ssh/id_test').and_return(false)

        expect { hypervisor.send(:find_ssh_key_pair) }.to raise_error(/Private key not found/)
      end
    end

    context 'when ssh_key is provided as content' do
      let(:options) do
        super().merge(kubevirt_ssh_key: 'ssh-rsa direct-content')
      end

      it 'returns the public key content with nil private key path' do
        allow(File).to receive(:exist?).with('ssh-rsa direct-content').and_return(false)
        result = hypervisor.send(:find_ssh_key_pair)
        aggregate_failures do
          expect(result[:public_key]).to eq('ssh-rsa direct-content')
          expect(result[:private_key_path]).to be_nil
        end
      end
    end

    context 'when searching for default keys' do
      let(:options) { super().dup.tap { |opts| opts.delete(:kubevirt_ssh_key) } }

      it 'finds matching ed25519 key pair' do
        ed25519_path = File.join(Dir.home, '.ssh', 'id_ed25519')
        allow(File).to receive(:exist?).and_return(false)
        allow(File).to receive(:exist?).with(ed25519_path).and_return(true)
        allow(File).to receive(:exist?).with("#{ed25519_path}.pub").and_return(true)
        allow(File).to receive(:read).with("#{ed25519_path}.pub").and_return('ssh-ed25519 test-key')
        result = hypervisor.send(:find_ssh_key_pair)
        aggregate_failures do
          expect(result[:public_key]).to eq('ssh-ed25519 test-key')
          expect(result[:private_key_path]).to eq(ed25519_path)
        end
      end

      it 'finds matching rsa key pair when ed25519 not available' do
        rsa_path = File.join(Dir.home, '.ssh', 'id_rsa')
        allow(File).to receive(:exist?).and_return(false)
        allow(File).to receive(:exist?).with(rsa_path).and_return(true)
        allow(File).to receive(:exist?).with("#{rsa_path}.pub").and_return(true)
        allow(File).to receive(:read).with("#{rsa_path}.pub").and_return('ssh-rsa test-key')
        result = hypervisor.send(:find_ssh_key_pair)
        aggregate_failures do
          expect(result[:public_key]).to eq('ssh-rsa test-key')
          expect(result[:private_key_path]).to eq(rsa_path)
        end
      end

      it 'raises an error when no matching key pairs found' do
        allow(File).to receive(:exist?).and_return(false)

        expect { hypervisor.send(:find_ssh_key_pair) }.to raise_error(/No matching SSH key pair found/)
      end
    end
  end

  describe '#configure_ssh_keys' do
    let(:hypervisor) { described_class.new(hosts, options) }
    let(:host) { hosts[0] }

    before do
      host['ssh'] = {}
    end

    context 'when private key path is available' do
      it 'configures the host ssh keys array' do
        key_pair = { public_key: 'ssh-rsa test-key', private_key_path: '/home/user/.ssh/id_rsa' }
        allow(hypervisor).to receive(:find_ssh_key_pair).and_return(key_pair)

        hypervisor.send(:configure_ssh_keys, host)
        expect(host['ssh']['keys']).to eq(['/home/user/.ssh/id_rsa'])
      end
    end

    context 'when private key path is not available' do
      it 'does not set the keys array' do
        key_pair = { public_key: 'ssh-rsa test-key', private_key_path: nil }
        allow(hypervisor).to receive(:find_ssh_key_pair).and_return(key_pair)

        hypervisor.send(:configure_ssh_keys, host)
        expect(host['ssh']['keys']).to be_nil
      end
    end

    context 'with SSH keepalive defaults' do
      before do
        key_pair = { public_key: 'ssh-rsa test-key', private_key_path: '/home/user/.ssh/id_rsa' }
        allow(hypervisor).to receive(:find_ssh_key_pair).and_return(key_pair)
      end

      it 'enables keepalive with sensible defaults when host has no overrides' do
        hypervisor.send(:configure_ssh_keys, host)
        expect(host['ssh']).to include(
          'keepalive' => true,
          'keepalive_interval' => 60,
          'keepalive_maxcount' => 5,
        )
      end

      it 'sets keepalive defaults even when no private key was found' do
        allow(hypervisor).to receive(:find_ssh_key_pair).and_return(public_key: 'k', private_key_path: nil)

        hypervisor.send(:configure_ssh_keys, host)
        expect(host['ssh']).to include(
          'keepalive' => true,
          'keepalive_interval' => 60,
          'keepalive_maxcount' => 5,
        )
      end

      it 'preserves user-supplied keepalive_interval' do
        host['ssh'] = { 'keepalive_interval' => 30 }
        hypervisor.send(:configure_ssh_keys, host)
        expect(host['ssh']['keepalive_interval']).to eq(30)
        expect(host['ssh']['keepalive']).to be(true)
        expect(host['ssh']['keepalive_maxcount']).to eq(5)
      end

      it 'preserves an explicit keepalive: false from the user' do
        host['ssh'] = { 'keepalive' => false }
        hypervisor.send(:configure_ssh_keys, host)
        expect(host['ssh']['keepalive']).to be(false)
      end
    end
  end

  describe '#sanitize_k8s_name' do
    let(:hypervisor) { described_class.new(hosts, options) }

    it 'sanitizes a valid name' do
      expect(hypervisor.send(:sanitize_k8s_name, 'valid-name')).to eq('valid-name')
    end

    it 'sanitizes a name with invalid characters' do
      expect(hypervisor.send(:sanitize_k8s_name, 'invalid@name')).to eq('invalid-name')
    end

    it 'trims the name to 63 characters' do
      long_name = 'a' * 70
      expect(hypervisor.send(:sanitize_k8s_name, long_name).length).to eq(63)
    end

    it 'handles names that end in a hyphen' do
      expect(hypervisor.send(:sanitize_k8s_name, 'bad-sanitized-')).to eq('bad-sanitized-0')
    end

    it 'handles names that do not start with a letter' do
      expect(hypervisor.send(:sanitize_k8s_name, '1invalid-name')).to eq('x1invalid-name')
    end
  end

  describe '#sanitize_k8s_label_value' do
    let(:hypervisor) { described_class.new(hosts, options) }

    it 'passes through a simple name' do
      expect(hypervisor.send(:sanitize_k8s_label_value, 'foo')).to eq('foo')
    end

    it 'preserves case, dots, and underscores' do
      expect(hypervisor.send(:sanitize_k8s_label_value, 'My.Host_01')).to eq('My.Host_01')
    end

    it 'replaces disallowed characters with hyphens' do
      expect(hypervisor.send(:sanitize_k8s_label_value, 'foo/bar')).to eq('foo-bar')
    end

    it 'strips leading non-alphanumeric characters' do
      expect(hypervisor.send(:sanitize_k8s_label_value, '-leading')).to eq('leading')
    end

    it 'strips trailing non-alphanumeric characters' do
      expect(hypervisor.send(:sanitize_k8s_label_value, 'trailing-')).to eq('trailing')
    end

    it 'caps length at 63 characters' do
      expect(hypervisor.send(:sanitize_k8s_label_value, 'a' * 100).length).to eq(63)
    end

    it 'falls back to sanitize_k8s_name when nothing alphanumeric remains' do
      expect(hypervisor.send(:sanitize_k8s_label_value, '!!')).to eq(hypervisor.send(:sanitize_k8s_name, '!!'))
    end
  end

  describe '#generate_root_volume_dvtemplate' do
    let(:hypervisor) { described_class.new(hosts, options) }
    let(:vm_name) { 'test-vm-123' }
    let(:host) { { 'name' => 'test-host', 'platform' => 'el-8-x86_64' } }

    context 'when host has no dv_name' do
      it 'returns nil' do
        result = hypervisor.send(:generate_root_volume_dvtemplate, 'http://example.com/image.qcow2', host)
        expect(result).to be_nil
      end
    end

    context 'with HTTP URL source' do
      let(:vm_image) { 'http://example.com/my-image.qcow2' }
      let(:host) do
        {
          'name' => 'test-host',
          'platform' => 'el-8-x86_64',
          'dv_name' => "#{vm_name}-my-image-dv",
        }
      end

      it 'creates a DataVolume with HTTP source' do
        result = hypervisor.send(:generate_root_volume_dvtemplate, vm_image, host)
        expect(result).to be_an(Array)
        expect(result.length).to eq(1)
        dv = result[0]
        expect(dv['spec']['source']['http']['url']).to eq(vm_image)
      end

      it 'includes metadata with name and labels' do
        result = hypervisor.send(:generate_root_volume_dvtemplate, vm_image, host)
        dv = result[0]
        expect(dv['metadata']['name']).to eq("#{vm_name}-my-image-dv")
        expect(dv['metadata']['namespace']).to eq('beaker-test')
        expect(dv['metadata']['labels']).to include('beaker/test-group', 'beaker/host')
      end

      it 'sets storage access mode to ReadWriteOnce' do
        result = hypervisor.send(:generate_root_volume_dvtemplate, vm_image, host)
        dv = result[0]
        expect(dv['spec']['storage']['accessModes']).to eq(['ReadWriteOnce'])
      end

      it 'sets default storage size of 10Gi for HTTP sources' do
        result = hypervisor.send(:generate_root_volume_dvtemplate, vm_image, host)
        dv = result[0]
        expect(dv['spec']['storage']['resources']['requests']['storage']).to eq('10Gi')
      end

      it 'respects explicit disk_size when provided' do
        host['disk_size'] = '20Gi'
        result = hypervisor.send(:generate_root_volume_dvtemplate, vm_image, host)
        dv = result[0]
        expect(dv['spec']['storage']['resources']['requests']['storage']).to eq('20Gi')
      end
    end

    context 'with HTTPS URL source' do
      let(:vm_image) { 'https://example.com/secure-image.qcow2' }
      let(:host) do
        {
          'name' => 'test-host',
          'platform' => 'el-8-x86_64',
          'dv_name' => "#{vm_name}-secure-image-dv",
        }
      end

      it 'creates a DataVolume with HTTPS source' do
        result = hypervisor.send(:generate_root_volume_dvtemplate, vm_image, host)
        dv = result[0]
        expect(dv['spec']['source']['http']['url']).to eq(vm_image)
      end

      it 'sets default storage size of 10Gi for HTTPS sources' do
        result = hypervisor.send(:generate_root_volume_dvtemplate, vm_image, host)
        dv = result[0]
        expect(dv['spec']['storage']['resources']['requests']['storage']).to eq('10Gi')
      end
    end

    context 'with PVC source' do
      let(:vm_image) { 'my-source-pvc' }
      let(:host) do
        {
          'name' => 'test-host',
          'platform' => 'el-8-x86_64',
          'dv_name' => "#{vm_name}-my-source-pvc",
          'source_pvc' => 'my-source-pvc',
        }
      end

      it 'creates a DataVolume with PVC source' do
        result = hypervisor.send(:generate_root_volume_dvtemplate, vm_image, host)
        dv = result[0]
        expect(dv['spec']['source']['pvc']['name']).to eq('my-source-pvc')
        expect(dv['spec']['source']['pvc']['namespace']).to eq('beaker-test')
      end

      it 'omits storage size to inherit from source PVC' do
        result = hypervisor.send(:generate_root_volume_dvtemplate, vm_image, host)
        dv = result[0]
        expect(dv['spec']['storage']['resources']).to be_nil
      end

      it 'respects explicit disk_size for PVC sources' do
        host['disk_size'] = '15Gi'
        result = hypervisor.send(:generate_root_volume_dvtemplate, vm_image, host)
        dv = result[0]
        expect(dv['spec']['storage']['resources']['requests']['storage']).to eq('15Gi')
      end
    end

    context 'with PVC source in different namespace' do
      let(:vm_image) { 'other-namespace/source-pvc' }
      let(:host) do
        {
          'name' => 'test-host',
          'platform' => 'el-8-x86_64',
          'dv_name' => "#{vm_name}-source-pvc",
          'source_pvc' => 'other-namespace/source-pvc',
        }
      end

      it 'parses namespace and PVC name correctly' do
        result = hypervisor.send(:generate_root_volume_dvtemplate, vm_image, host)
        dv = result[0]
        expect(dv['spec']['source']['pvc']['namespace']).to eq('other-namespace')
        expect(dv['spec']['source']['pvc']['name']).to eq('source-pvc')
      end
    end

    context 'when explicit disk_size is provided' do
      let(:vm_image) { 'http://example.com/image.qcow2' }
      let(:host) do
        {
          'name' => 'test-host',
          'platform' => 'el-8-x86_64',
          'dv_name' => "#{vm_name}-image-dv",
          'disk_size' => '25Gi',
        }
      end

      it 'uses explicit disk_size over default' do
        result = hypervisor.send(:generate_root_volume_dvtemplate, vm_image, host)
        dv = result[0]
        expect(dv['spec']['storage']['resources']['requests']['storage']).to eq('25Gi')
      end
    end

    context 'with DataVolume metadata' do
      let(:vm_image) { 'http://example.com/image.qcow2' }
      let(:host) do
        {
          'name' => 'test-host',
          'platform' => 'el-8-x86_64',
          'dv_name' => "#{vm_name}-image-dv",
        }
      end

      it 'includes correct apiVersion' do
        result = hypervisor.send(:generate_root_volume_dvtemplate, vm_image, host)
        dv = result[0]
        expect(dv['metadata']['name']).not_to be_nil
        expect(dv['metadata']['namespace']).to eq('beaker-test')
      end

      it 'includes beaker labels' do
        result = hypervisor.send(:generate_root_volume_dvtemplate, vm_image, host)
        dv = result[0]
        labels = dv['metadata']['labels']
        expect(labels['beaker/host']).to eq('test-host')
        expect(labels).to have_key('beaker/test-group')
      end
    end

    context 'with storage configuration' do
      let(:vm_image) { 'http://example.com/image.qcow2' }
      let(:host) do
        {
          'name' => 'test-host',
          'platform' => 'el-8-x86_64',
          'dv_name' => "#{vm_name}-image-dv",
        }
      end

      it 'sets ReadWriteOnce access mode to prevent live migration' do
        result = hypervisor.send(:generate_root_volume_dvtemplate, vm_image, host)
        dv = result[0]
        expect(dv['spec']['storage']['accessModes']).to eq(['ReadWriteOnce'])
      end

      it 'includes storage size in requests' do
        result = hypervisor.send(:generate_root_volume_dvtemplate, vm_image, host)
        dv = result[0]
        expect(dv['spec']['storage']['resources']['requests']).to have_key('storage')
      end
    end
  end

  describe '#generate_root_volume_spec' do
    let(:hypervisor) { described_class.new(hosts, options) }
    let(:vm_name) { 'test-vm-123' }
    let(:host) { { 'name' => 'test-host', 'platform' => 'el-8-x86_64' } }

    context 'with container disk image (docker://)' do
      let(:vm_image) { 'docker://quay.io/kubevirt/fedora-cloud-container-disk-demo' }

      it 'creates a containerDisk volume spec' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result).to have_key('containerDisk')
        expect(result).to have_key('name')
        expect(result['name']).to eq('rootdisk')
      end

      it 'strips the docker:// protocol prefix from image' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result['containerDisk']['image']).to eq('quay.io/kubevirt/fedora-cloud-container-disk-demo')
      end

      it 'preserves full image reference with registry and tag' do
        image_with_tag = 'docker://registry.example.com:5000/my-image:v1.0'
        result = hypervisor.send(:generate_root_volume_spec, image_with_tag, host)
        expect(result['containerDisk']['image']).to eq('registry.example.com:5000/my-image:v1.0')
      end

      it 'does not include dataVolume key' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result).not_to have_key('dataVolume')
      end

      it 'does not include persistentVolumeClaim key' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result).not_to have_key('persistentVolumeClaim')
      end
    end

    context 'with container disk image (oci://)' do
      let(:vm_image) { 'oci://registry.example.com/my-image:latest' }

      it 'creates a containerDisk volume spec' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result).to have_key('containerDisk')
        expect(result['name']).to eq('rootdisk')
      end

      it 'strips the oci:// protocol prefix from image' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result['containerDisk']['image']).to eq('registry.example.com/my-image:latest')
      end
    end

    context 'with DataVolume (HTTP/HTTPS source)' do
      let(:vm_image) { 'http://example.com/image.qcow2' }
      let(:host) do
        {
          'name' => 'test-host',
          'platform' => 'el-8-x86_64',
          'dv_name' => "#{vm_name}-image-dv",
        }
      end

      it 'creates a dataVolume volume spec' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result).to have_key('dataVolume')
        expect(result['name']).to eq('rootdisk')
      end

      it 'references the correct DataVolume name' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result['dataVolume']['name']).to eq("#{vm_name}-image-dv")
      end

      it 'does not include containerDisk key' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result).not_to have_key('containerDisk')
      end

      it 'does not include persistentVolumeClaim key' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result).not_to have_key('persistentVolumeClaim')
      end
    end

    context 'with DataVolume (HTTPS source)' do
      let(:vm_image) { 'https://secure.example.com/image.qcow2' }
      let(:host) do
        {
          'name' => 'test-host',
          'platform' => 'el-8-x86_64',
          'dv_name' => "#{vm_name}-image-dv",
        }
      end

      it 'creates a dataVolume volume spec' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result).to have_key('dataVolume')
      end

      it 'references the correct DataVolume name' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result['dataVolume']['name']).to eq("#{vm_name}-image-dv")
      end
    end

    context 'with DataVolume (PVC source)' do
      let(:vm_image) { 'my-source-pvc' }
      let(:host) do
        {
          'name' => 'test-host',
          'platform' => 'el-8-x86_64',
          'dv_name' => "#{vm_name}-my-source-pvc",
          'source_pvc' => 'my-source-pvc',
        }
      end

      it 'creates a dataVolume volume spec' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result).to have_key('dataVolume')
        expect(result['name']).to eq('rootdisk')
      end

      it 'references the correct DataVolume name' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result['dataVolume']['name']).to eq("#{vm_name}-my-source-pvc")
      end
    end

    context 'with PVC fallback (direct reference)' do
      let(:vm_image) { 'my-pvc' }
      let(:host) { { 'name' => 'test-host', 'platform' => 'el-8-x86_64' } }

      it 'creates a persistentVolumeClaim volume spec' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result).to have_key('persistentVolumeClaim')
        expect(result['name']).to eq('rootdisk')
      end

      it 'references the PVC by name' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result['persistentVolumeClaim']['claimName']).to eq('my-pvc')
      end

      it 'does not include dataVolume key' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result).not_to have_key('dataVolume')
      end

      it 'does not include containerDisk key' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result).not_to have_key('containerDisk')
      end
    end

    context 'with PVC fallback with pvc:// prefix' do
      let(:vm_image) { 'pvc://my-pvc' }
      let(:host) { { 'name' => 'test-host', 'platform' => 'el-8-x86_64' } }

      it 'strips pvc:// prefix and references the PVC' do
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result['persistentVolumeClaim']['claimName']).to eq('my-pvc')
      end
    end

    context 'when setting volume spec name' do
      it 'always sets name to rootdisk for container disk' do
        vm_image = 'docker://example.com/image'
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result['name']).to eq('rootdisk')
      end

      it 'always sets name to rootdisk for PVC' do
        vm_image = 'my-pvc'
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result['name']).to eq('rootdisk')
      end
    end

    context 'when prioritizing volume sources' do
      let(:host) do
        {
          'name' => 'test-host',
          'platform' => 'el-8-x86_64',
          'dv_name' => 'test-dv',
          'source_pvc' => 'test-pvc',
        }
      end

      it 'prioritizes dv_name (DataVolume) when present' do
        vm_image = 'http://example.com/image.qcow2'
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host)
        expect(result).to have_key('dataVolume')
        expect(result).not_to have_key('persistentVolumeClaim')
      end

      it 'uses container disk when dv_name not set but image is docker://' do
        host_no_dv = host.merge('dv_name' => nil)
        vm_image = 'docker://example.com/image'
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host_no_dv)
        expect(result).to have_key('containerDisk')
        expect(result).not_to have_key('dataVolume')
      end

      it 'falls back to PVC when no dv_name and not container image' do
        host_no_dv = host.merge('dv_name' => nil)
        vm_image = 'my-pvc'
        result = hypervisor.send(:generate_root_volume_spec, vm_image, host_no_dv)
        expect(result).to have_key('persistentVolumeClaim')
        expect(result).not_to have_key('dataVolume')
      end
    end
  end

  describe '#generate_service_account_volume_spec' do
    context 'when service account is not set' do
      let(:hypervisor) { described_class.new(hosts, options) }

      it 'returns nil' do
        result = hypervisor.send(:generate_service_account_volume_spec)
        expect(result).to be_nil
      end
    end

    context 'when service account is set' do
      let(:options_with_sa) do
        options.merge(kubevirt_service_account: 'beaker-kubevirt-sa')
      end
      let(:hypervisor) { described_class.new(hosts, options_with_sa) }

      it 'returns a volume spec hash' do
        result = hypervisor.send(:generate_service_account_volume_spec)
        expect(result).to be_a(Hash)
      end

      it 'sets the volume name to service-account-volume' do
        result = hypervisor.send(:generate_service_account_volume_spec)
        expect(result['name']).to eq('service-account-volume')
      end

      it 'includes serviceAccount key' do
        result = hypervisor.send(:generate_service_account_volume_spec)
        expect(result).to have_key('serviceAccount')
      end

      it 'sets the serviceAccountName in the serviceAccount section' do
        result = hypervisor.send(:generate_service_account_volume_spec)
        expect(result['serviceAccount']['serviceAccountName']).to eq('beaker-kubevirt-sa')
      end

      it 'includes the correct service account name from options' do
        result = hypervisor.send(:generate_service_account_volume_spec)
        expect(result).to eq(
          {
            'name' => 'service-account-volume',
            'serviceAccount' => {
              'serviceAccountName' => 'beaker-kubevirt-sa',
            },
          },
        )
      end
    end
  end

  describe '#wait_for_vm_ready (legacy: VM existence polling)' do
    let(:vm_name) { 'beaker-abc123-test-host' }
    let(:hypervisor) { described_class.new(hosts, options.merge(timeout: 5)) }
    let(:host) { hosts[0].merge('vm_name' => vm_name) }
    let(:vm_object) { { 'metadata' => { 'name' => vm_name } } }
    let(:running_vmi) do
      {
        'status' => {
          'phase' => 'Running',
          'conditions' => [{ 'type' => 'Ready', 'status' => 'True' }],
        },
      }
    end

    before do
      allow(hypervisor).to receive(:sleep)
      allow(kubevirt_helper).to receive(:get_virt_launcher_pod).and_return(nil)
    end

    context 'when VM eventually exists and remains available' do
      before do
        allow(kubevirt_helper).to receive(:get_vm).with(vm_name).and_return(nil, vm_object, vm_object, vm_object)
        allow(kubevirt_helper).to receive(:get_vmi).with(vm_name).and_return(nil, running_vmi)
      end

      it 'waits until the VMI is running and Ready' do
        expect { hypervisor.send(:wait_for_vm_ready, host) }.not_to raise_error
        expect(kubevirt_helper).to have_received(:get_vm).with(vm_name).at_least(:twice)
        expect(kubevirt_helper).to have_received(:get_vmi).with(vm_name).at_least(:once)
      end
    end

    context 'when VM disappears while waiting for VMI readiness' do
      before do
        allow(kubevirt_helper).to receive(:get_vm).with(vm_name).and_return(vm_object, vm_object, nil)
        allow(kubevirt_helper).to receive(:get_vmi).with(vm_name).and_return(nil)
      end

      it 'raises an error indicating the VM was deleted' do
        expect { hypervisor.send(:wait_for_vm_ready, host) }.to raise_error("VM #{vm_name} was deleted unexpectedly")
        expect(kubevirt_helper).to have_received(:get_vm).with(vm_name).at_least(:twice)
      end
    end
  end

  describe '#create_vm' do
    let(:hypervisor) { described_class.new(hosts, options) }
    let(:host) do
      {
        'name' => 'test-host',
        'platform' => 'el-8-x86_64',
      }
    end

    before do
      # Mock the host to respond to .name for the logger call
      def host.name
        self['name']
      end
      allow(hypervisor).to receive_messages(
        generate_vm_name: 'beaker-abc123-test-host',
        generate_cloud_init: '#cloud-config\nhostname: test',
        create_cloud_init_secret: 'secret-name',
        generate_vm_spec: {},
      )
      allow(kubevirt_helper).to receive(:create_vm)
    end

    context 'with HTTP image source' do
      let(:vm_image) { 'http://example.com/fedora-disk.qcow2' }

      before do
        options[:kubevirt_vm_image] = vm_image
      end

      it 'sets dv_name for HTTP URL sources' do
        hypervisor.send(:create_vm, host)
        expect(host['dv_name']).to match(/^beaker-abc123-test-host-fedora-disk-qcow2-dv$/)
      end

      it 'does not set source_pvc for HTTP sources' do
        hypervisor.send(:create_vm, host)
        expect(host).not_to have_key('source_pvc')
      end
    end

    context 'with HTTPS image source' do
      let(:vm_image) { 'https://example.com/ubuntu-disk.img' }

      before do
        options[:kubevirt_vm_image] = vm_image
      end

      it 'sets dv_name for HTTPS URL sources' do
        hypervisor.send(:create_vm, host)
        expect(host['dv_name']).to match(/ubuntu-disk-img-dv$/)
      end
    end

    context 'with PVC source' do
      let(:vm_image) { 'my-pvc' }

      before do
        options[:kubevirt_vm_image] = vm_image
      end

      it 'sets dv_name for PVC sources' do
        hypervisor.send(:create_vm, host)
        expect(host['dv_name']).to match(/my-pvc$/)
      end

      it 'sets source_pvc for PVC sources' do
        hypervisor.send(:create_vm, host)
        expect(host['source_pvc']).to eq('my-pvc')
      end

      it 'extracts namespace from cross-namespace PVC reference' do
        options[:kubevirt_vm_image] = 'images/ubuntu-disk'
        hypervisor.send(:create_vm, host)
        expect(host['source_pvc']).to eq('images/ubuntu-disk')
      end
    end

    context 'with docker:// container image' do
      let(:vm_image) { 'docker://quay.io/kubevirt/fedora-cloud-container-disk-demo' }

      before do
        options[:kubevirt_vm_image] = vm_image
      end

      it 'does not set dv_name for container images' do
        hypervisor.send(:create_vm, host)
        expect(host).not_to have_key('dv_name')
      end

      it 'does not set source_pvc for container images' do
        hypervisor.send(:create_vm, host)
        expect(host).not_to have_key('source_pvc')
      end
    end

    context 'with oci:// container image' do
      let(:vm_image) { 'oci://quay.io/kubevirt/fedora-cloud-container-disk-demo' }

      before do
        options[:kubevirt_vm_image] = vm_image
      end

      it 'does not set dv_name for OCI images' do
        hypervisor.send(:create_vm, host)
        expect(host).not_to have_key('dv_name')
      end
    end

    context 'when vm_name is set' do
      it 'sets vm_name on host' do
        hypervisor.send(:create_vm, host)
        expect(host['vm_name']).to eq('beaker-abc123-test-host')
      end
    end

    context 'when cloud-init is generated' do
      it 'calls generate_cloud_init' do
        hypervisor.send(:create_vm, host)
        expect(hypervisor).to have_received(:generate_cloud_init).with(host)
      end

      it 'creates cloud-init secret with generated data' do
        hypervisor.send(:create_vm, host)
        expect(hypervisor).to have_received(:create_cloud_init_secret).with(host, '#cloud-config\nhostname: test')
      end
    end

    context 'when creating VM spec' do
      it 'calls generate_vm_spec with vm_name and secret_name' do
        hypervisor.send(:create_vm, host)
        expect(hypervisor).to have_received(:generate_vm_spec).with(host, 'beaker-abc123-test-host', 'secret-name')
      end

      it 'calls kubevirt_helper.create_vm with the spec' do
        hypervisor.send(:create_vm, host)
        expect(kubevirt_helper).to have_received(:create_vm).with({})
      end
    end
  end

  describe '#generate_vm_name' do
    let(:hypervisor) { described_class.new(hosts, options) }

    context 'with standard host name' do
      let(:host) { { 'name' => 'test-host' } }

      it 'includes test group identifier' do
        result = hypervisor.send(:generate_vm_name, host)
        expect(result).to match(/^beaker-[a-f0-9]{8}-/)
      end

      it 'includes host name' do
        result = hypervisor.send(:generate_vm_name, host)
        expect(result).to end_with('-test-host')
      end

      it 'converts to lowercase' do
        host_upper = { 'name' => 'TEST-HOST' }
        result = hypervisor.send(:generate_vm_name, host_upper)
        expect(result).to include('test-host')
      end
    end

    context 'with special characters in host name' do
      let(:host) { { 'name' => 'test@host!#$' } }

      it 'replaces special characters with hyphens' do
        result = hypervisor.send(:generate_vm_name, host)
        expect(result).to match(/^beaker-[a-f0-9]{8}-test-host/)
      end
    end

    context 'when host is an object with name method' do
      it 'calls name method on host object' do
        host_obj = double(name: 'object-host')
        result = hypervisor.send(:generate_vm_name, host_obj)
        expect(result).to include('object-host')
      end
    end
  end

  describe '#get_labels' do
    let(:hypervisor) { described_class.new(hosts, options) }
    let(:host) { { 'name' => 'test-host' } }

    it 'includes beaker/test-group label' do
      result = hypervisor.send(:get_labels, host)
      expect(result['beaker/test-group']).to match(/^beaker-[a-f0-9]{8}$/)
    end

    it 'includes beaker/host label with host name' do
      result = hypervisor.send(:get_labels, host)
      expect(result['beaker/host']).to eq('test-host')
    end

    it 'sanitizes hostnames that are invalid as k8s label values' do
      result = hypervisor.send(:get_labels, { 'name' => 'foo/bar' })
      expect(result['beaker/host']).to eq('foo-bar')
    end

    it 'uses host name from name method when available' do
      host_obj = double(name: 'object-host')
      result = hypervisor.send(:get_labels, host_obj)
      expect(result['beaker/host']).to eq('object-host')
    end

    it 'returns hash with exactly 2 labels' do
      result = hypervisor.send(:get_labels, host)
      expect(result.size).to eq(2)
    end

    context 'when test group is consistent' do
      it 'uses the same test group for multiple hosts' do
        host1 = { 'name' => 'host1' }
        host2 = { 'name' => 'host2' }
        labels1 = hypervisor.send(:get_labels, host1)
        labels2 = hypervisor.send(:get_labels, host2)
        expect(labels1['beaker/test-group']).to eq(labels2['beaker/test-group'])
      end
    end
  end

  describe '#disk_bus' do
    let(:hypervisor) { described_class.new(hosts, options) }

    context 'with virtio enabled (default)' do
      let(:host) { { 'name' => 'test-host', 'platform' => 'el-8-x86_64' } }

      it 'returns virtio bus type' do
        result = hypervisor.send(:disk_bus, host)
        expect(result).to eq('virtio')
      end
    end

    context 'with virtio disabled' do
      let(:host) { { 'name' => 'test-host', 'platform' => 'windows-2019', 'kubevirt_disable_virtio' => true } }

      it 'returns sata bus type' do
        result = hypervisor.send(:disk_bus, host)
        expect(result).to eq('sata')
      end
    end

    context 'with explicit false for disable_virtio' do
      let(:host) { { 'name' => 'test-host', 'kubevirt_disable_virtio' => false } }

      it 'returns virtio bus type' do
        result = hypervisor.send(:disk_bus, host)
        expect(result).to eq('virtio')
      end
    end

    context 'when disable_virtio is not set' do
      let(:host) { { 'name' => 'test-host' } }

      it 'defaults to virtio' do
        result = hypervisor.send(:disk_bus, host)
        expect(result).to eq('virtio')
      end
    end
  end

  describe '#eth_model' do
    let(:hypervisor) { described_class.new(hosts, options) }

    context 'with virtio enabled (default)' do
      let(:host) { { 'name' => 'test-host', 'platform' => 'el-8-x86_64' } }

      it 'returns virtio network model' do
        result = hypervisor.send(:eth_model, host)
        expect(result).to eq('virtio')
      end
    end

    context 'with virtio disabled' do
      let(:host) { { 'name' => 'test-host', 'platform' => 'windows-2019', 'kubevirt_disable_virtio' => true } }

      it 'returns e1000 network model' do
        result = hypervisor.send(:eth_model, host)
        expect(result).to eq('e1000')
      end
    end

    context 'with explicit false for disable_virtio' do
      let(:host) { { 'name' => 'test-host', 'kubevirt_disable_virtio' => false } }

      it 'returns virtio network model' do
        result = hypervisor.send(:eth_model, host)
        expect(result).to eq('virtio')
      end
    end

    context 'when disable_virtio is not set' do
      let(:host) { { 'name' => 'test-host' } }

      it 'defaults to virtio' do
        result = hypervisor.send(:eth_model, host)
        expect(result).to eq('virtio')
      end
    end
  end

  describe '#generate_hardware_spec' do
    let(:hypervisor) { described_class.new(hosts, options) }
    let(:host) { { 'name' => 'test-host', 'platform' => 'el-8-x86_64' } }

    context 'with virtio enabled' do
      it 'includes root disk with virtio bus' do
        result = hypervisor.send(:generate_hardware_spec, host)
        expect(result['disks'][0]['disk']['bus']).to eq('virtio')
      end

      it 'includes cloud-init disk with sata bus' do
        result = hypervisor.send(:generate_hardware_spec, host)
        expect(result['disks'][1]['disk']['bus']).to eq('sata')
      end

      it 'includes network interface with virtio model' do
        result = hypervisor.send(:generate_hardware_spec, host)
        expect(result['interfaces'][0]['model']).to eq('virtio')
      end
    end

    context 'with virtio disabled' do
      let(:host) { { 'name' => 'test-host', 'platform' => 'windows-2019', 'kubevirt_disable_virtio' => true } }

      it 'includes root disk with sata bus' do
        result = hypervisor.send(:generate_hardware_spec, host)
        expect(result['disks'][0]['disk']['bus']).to eq('sata')
      end

      it 'includes network interface with e1000 model' do
        result = hypervisor.send(:generate_hardware_spec, host)
        expect(result['interfaces'][0]['model']).to eq('e1000')
      end
    end

    context 'with proper structure' do
      let(:result) { hypervisor.send(:generate_hardware_spec, host) }

      it 'includes disks array' do
        expect(result).to have_key('disks')
        expect(result['disks']).to be_an(Array)
      end

      it 'includes interfaces array' do
        expect(result).to have_key('interfaces')
        expect(result['interfaces']).to be_an(Array)
      end

      it 'includes inputs array' do
        expect(result).to have_key('inputs')
        expect(result['inputs']).to be_an(Array)
      end

      it 'includes exactly 2 disks' do
        expect(result['disks'].size).to eq(2)
      end

      it 'includes exactly 1 network interface' do
        expect(result['interfaces'].size).to eq(1)
      end

      it 'includes exactly 1 input device (tablet)' do
        expect(result['inputs'].size).to eq(1)
      end

      it 'root disk is named rootdisk' do
        expect(result['disks'][0]['name']).to eq('rootdisk')
      end

      it 'cloud-init disk is named cidata' do
        expect(result['disks'][1]['name']).to eq('cidata')
      end

      it 'network interface is named default' do
        expect(result['interfaces'][0]['name']).to eq('default')
      end

      it 'tablet input has correct properties' do
        tablet = result['inputs'][0]
        expect(tablet['bus']).to eq('usb')
        expect(tablet['type']).to eq('tablet')
        expect(tablet['name']).to eq('tablet')
      end
    end
  end

  describe '#generate_networks_spec' do
    let(:hypervisor) { described_class.new(hosts, options) }

    context 'with default network mode (port-forward)' do
      let(:host) { { 'name' => 'test-host', 'platform' => 'el-8-x86_64' } }

      it 'returns default pod network' do
        result = hypervisor.send(:generate_networks_spec, host)
        expect(result).to eq([{ 'name' => 'default', 'pod' => {} }])
      end
    end

    context 'with explicit port-forward network mode' do
      let(:host) { { 'name' => 'test-host', 'kubevirt_network_mode' => 'port-forward' } }

      it 'returns default pod network' do
        result = hypervisor.send(:generate_networks_spec, host)
        expect(result).to eq([{ 'name' => 'default', 'pod' => {} }])
      end
    end

    context 'with nodeport network mode' do
      let(:host) { { 'name' => 'test-host', 'kubevirt_network_mode' => 'nodeport' } }

      it 'returns default pod network' do
        result = hypervisor.send(:generate_networks_spec, host)
        expect(result).to eq([{ 'name' => 'default', 'pod' => {} }])
      end
    end

    context 'with multus network mode and single network' do
      let(:host) do
        {
          'name' => 'test-host',
          'kubevirt_network_mode' => 'multus',
          'networks' => [
            {
              'name' => 'ext0',
              'multus_network_name' => 'my-bridge-network',
            },
          ],
        }
      end

      it 'returns multus network configuration' do
        result = hypervisor.send(:generate_networks_spec, host)
        expect(result.size).to eq(1)
        expect(result[0]['name']).to eq('ext0')
        expect(result[0]['multus']['networkName']).to eq('my-bridge-network')
      end

      it 'does not include pod network' do
        result = hypervisor.send(:generate_networks_spec, host)
        expect(result[0]).not_to have_key('pod')
      end
    end

    context 'with multus network mode and multiple networks' do
      let(:host) do
        {
          'name' => 'test-host',
          'kubevirt_network_mode' => 'multus',
          'networks' => [
            {
              'name' => 'ext0',
              'multus_network_name' => 'my-bridge-network',
            },
            {
              'name' => 'ext1',
              'multus_network_name' => 'another-network',
            },
          ],
        }
      end

      it 'returns all multus networks' do
        result = hypervisor.send(:generate_networks_spec, host)
        expect(result.size).to eq(2)
      end

      it 'maps all network configurations correctly' do
        result = hypervisor.send(:generate_networks_spec, host)
        expect(result[0]['name']).to eq('ext0')
        expect(result[0]['multus']['networkName']).to eq('my-bridge-network')
        expect(result[1]['name']).to eq('ext1')
        expect(result[1]['multus']['networkName']).to eq('another-network')
      end
    end

    context 'with multus network mode and no networks array' do
      let(:host) do
        {
          'name' => 'test-host',
          'kubevirt_network_mode' => 'multus',
        }
      end

      it 'returns empty array' do
        result = hypervisor.send(:generate_networks_spec, host)
        expect(result).to eq([])
      end
    end

    context 'with proper network structure' do
      let(:host) do
        {
          'name' => 'test-host',
          'kubevirt_network_mode' => 'multus',
          'networks' => [
            {
              'name' => 'ext0',
              'multus_network_name' => 'test-network',
            },
          ],
        }
      end

      it 'includes network name' do
        result = hypervisor.send(:generate_networks_spec, host)
        expect(result[0]).to have_key('name')
      end

      it 'includes multus configuration' do
        result = hypervisor.send(:generate_networks_spec, host)
        expect(result[0]).to have_key('multus')
      end

      it 'multus has networkName key' do
        result = hypervisor.send(:generate_networks_spec, host)
        expect(result[0]['multus']).to have_key('networkName')
      end
    end
  end

  describe 'at_exit cleanup handler' do
    let(:hypervisor) { described_class.new(hosts, options) }

    before do
      allow(kubevirt_helper).to receive(:cleanup_vms)
      allow(kubevirt_helper).to receive(:cleanup_secrets)
      allow(kubevirt_helper).to receive(:cleanup_services)
      allow(kubevirt_helper).to receive(:cleanup_temp_files)
      allow(kubevirt_helper).to receive(:cleanup_data_volumes)
    end

    describe '#initialize' do
      it 'does not register at_exit handler during tests' do
        # The at_exit handler should NOT be registered during RSpec tests
        # to avoid issues with mock objects being accessed outside the test lifecycle
        # We can verify that cleanup_on_exit is still defined as a private method
        expect(hypervisor.private_methods).to include(:cleanup_on_exit)
      end

      it 'initializes cleanup_called flag to false' do
        expect(hypervisor.instance_variable_get(:@cleanup_called)).to be false
      end

      it 'initializes a cleanup mutex' do
        expect(hypervisor.instance_variable_get(:@cleanup_mutex)).to be_a(Mutex)
      end
    end

    describe '#cleanup' do
      it 'sets cleanup_called flag to true' do
        hypervisor.cleanup
        expect(hypervisor.instance_variable_get(:@cleanup_called)).to be true
      end

      it 'only performs cleanup once when called multiple times' do
        hypervisor.cleanup
        hypervisor.cleanup
        hypervisor.cleanup

        # Should only be called once
        expect(kubevirt_helper).to have_received(:cleanup_vms).once
        expect(kubevirt_helper).to have_received(:cleanup_secrets).once
        expect(kubevirt_helper).to have_received(:cleanup_services).once
        expect(kubevirt_helper).to have_received(:cleanup_temp_files).once
      end

      it 'calls cleanup_impl to perform actual cleanup' do
        allow(hypervisor).to receive(:cleanup_impl)
        hypervisor.cleanup
        expect(hypervisor).to have_received(:cleanup_impl)
      end
    end

    context 'when cleanup has already been called' do
      before do
        hypervisor.cleanup
      end

      it 'cleanup_on_exit does not perform cleanup again' do
        # Mock cleanup_impl to verify it's not called
        allow(hypervisor).to receive(:cleanup_impl)

        hypervisor.send(:cleanup_on_exit)

        # cleanup_impl should not be called since cleanup was already called
        expect(hypervisor).not_to have_received(:cleanup_impl)
      end
    end

    context 'when BEAKER_destroy is set to no' do
      before do
        ENV['BEAKER_destroy'] = 'no'
      end

      after do
        ENV.delete('BEAKER_destroy')
      end

      it 'cleanup_on_exit does not perform cleanup' do
        hypervisor.send(:cleanup_on_exit)

        expect(kubevirt_helper).not_to have_received(:cleanup_vms)
        expect(kubevirt_helper).not_to have_received(:cleanup_secrets)
        expect(kubevirt_helper).not_to have_received(:cleanup_services)
      end

      it 'cleanup_on_exit logs preservation message with BEAKER_destroy value' do
        logger = options[:logger]
        expect(logger).to receive(:info).with('Preserving KubeVirt resources (BEAKER_destroy=no)')
        hypervisor.send(:cleanup_on_exit)
      end
    end

    context 'when BEAKER_destroy is set to never' do
      before do
        ENV['BEAKER_destroy'] = 'never'
      end

      after do
        ENV.delete('BEAKER_destroy')
      end

      it 'cleanup_on_exit does not perform cleanup' do
        hypervisor.send(:cleanup_on_exit)

        expect(kubevirt_helper).not_to have_received(:cleanup_vms)
        expect(kubevirt_helper).not_to have_received(:cleanup_secrets)
        expect(kubevirt_helper).not_to have_received(:cleanup_services)
      end
    end

    context 'when BEAKER_destroy is set to onpass' do
      before do
        ENV['BEAKER_destroy'] = 'onpass'
      end

      after do
        ENV.delete('BEAKER_destroy')
      end

      it 'cleanup_on_exit does not perform cleanup' do
        hypervisor.send(:cleanup_on_exit)

        expect(kubevirt_helper).not_to have_received(:cleanup_vms)
        expect(kubevirt_helper).not_to have_received(:cleanup_secrets)
        expect(kubevirt_helper).not_to have_received(:cleanup_services)
      end
    end

    context 'when preserve_hosts option is set to true' do
      let(:options_with_preserve) do
        options.merge(preserve_hosts: true)
      end
      let(:hypervisor_with_preserve) { described_class.new(hosts, options_with_preserve) }

      before do
        allow(kubevirt_helper).to receive(:cleanup_vms)
        allow(kubevirt_helper).to receive(:cleanup_secrets)
        allow(kubevirt_helper).to receive(:cleanup_services)
        allow(kubevirt_helper).to receive(:cleanup_temp_files)
        allow(kubevirt_helper).to receive(:cleanup_data_volumes)
      end

      it 'cleanup_on_exit does not perform cleanup' do
        hypervisor_with_preserve.send(:cleanup_on_exit)

        expect(kubevirt_helper).not_to have_received(:cleanup_vms)
        expect(kubevirt_helper).not_to have_received(:cleanup_secrets)
        expect(kubevirt_helper).not_to have_received(:cleanup_services)
      end

      it 'cleanup_on_exit logs preservation message about preserve_hosts option' do
        logger = options_with_preserve[:logger]
        expect(logger).to receive(:info).with('Preserving KubeVirt resources (preserve_hosts option is set)')
        hypervisor_with_preserve.send(:cleanup_on_exit)
      end
    end

    context 'when cleanup has not been called and preservation is not requested' do
      it 'cleanup_on_exit performs cleanup' do
        hypervisor.send(:cleanup_on_exit)

        expect(kubevirt_helper).to have_received(:cleanup_vms)
        expect(kubevirt_helper).to have_received(:cleanup_secrets)
        expect(kubevirt_helper).to have_received(:cleanup_services)
        expect(kubevirt_helper).to have_received(:cleanup_temp_files)
      end

      it 'cleanup_on_exit logs at_exit cleanup message' do
        logger = options[:logger]
        expect(logger).to receive(:info).with('at_exit: Performing cleanup of KubeVirt resources')
        hypervisor.send(:cleanup_on_exit)
      end

      it 'cleanup_on_exit sets cleanup_called flag to true' do
        hypervisor.send(:cleanup_on_exit)
        expect(hypervisor.instance_variable_get(:@cleanup_called)).to be true
      end
    end

    context 'when cleanup_impl raises an error' do
      before do
        allow(hypervisor).to receive(:cleanup_impl).and_raise(StandardError, 'Cleanup failed')
      end

      it 'cleanup_on_exit catches the error and logs it' do
        logger = options[:logger]
        expect(logger).to receive(:error).with('Error during at_exit cleanup: Cleanup failed')
        expect(logger).to receive(:debug)

        expect { hypervisor.send(:cleanup_on_exit) }.not_to raise_error
      end

      it 'cleanup_on_exit does not raise the error' do
        expect { hypervisor.send(:cleanup_on_exit) }.not_to raise_error
      end
    end

    context 'with thread safety' do
      it 'only allows cleanup to run once even with concurrent calls' do
        # Simulate concurrent calls to cleanup_on_exit
        threads = Array.new(10) do
          Thread.new do
            hypervisor.send(:cleanup_on_exit)
          end
        end

        threads.each(&:join)

        # Should only be called once despite 10 concurrent calls
        expect(kubevirt_helper).to have_received(:cleanup_vms).once
        expect(kubevirt_helper).to have_received(:cleanup_secrets).once
        expect(kubevirt_helper).to have_received(:cleanup_services).once
        expect(kubevirt_helper).to have_received(:cleanup_temp_files).once
      end
    end

    describe 'constants' do
      it 'defines DEFAULT_BEAKER_DESTROY' do
        expect(described_class::DEFAULT_BEAKER_DESTROY).to eq('yes')
      end

      it 'defines BEAKER_DESTROY_PRESERVE_VALUES' do
        expect(described_class::BEAKER_DESTROY_PRESERVE_VALUES).to eq(%w[no never onpass])
      end

      it 'freezes BEAKER_DESTROY_PRESERVE_VALUES' do
        expect(described_class::BEAKER_DESTROY_PRESERVE_VALUES).to be_frozen
      end
    end
  end
end
