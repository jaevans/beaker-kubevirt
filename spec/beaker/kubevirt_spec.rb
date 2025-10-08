# frozen_string_literal: true

RSpec.describe Beaker::Kubevirt do
  let(:options) do
    {
      logger: instance_double(Logger).as_null_object,
      kubeconfig: '/tmp/kubeconfig',
      namespace: 'beaker-test',
      vm_image: 'quay.io/kubevirt/fedora-cloud-container-disk-demo',
      ssh_key: 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQ...',
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
    allow(kubevirt_helper).to receive(:setup_port_forward)
  end

  describe '#initialize' do
    let(:hypervisor) { described_class.new(hosts, options) }

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
  end

  describe '#provision' do
    let(:hypervisor) { described_class.new(hosts, options) }

    before do
      allow(hypervisor).to receive(:create_vm)
      allow(hypervisor).to receive(:wait_for_vm_ready)
      allow(hypervisor).to receive(:setup_ssh_access)
    end

    context 'when provisioning' do
      before do
        allow(hypervisor).to receive(:create_vm)
        allow(hypervisor).to receive(:wait_for_vm_ready)
        allow(hypervisor).to receive(:setup_networking)
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
    let(:hypervisor) { described_class.new(hosts, options) }

    context 'when cleaning up' do
      before do
        allow(kubevirt_helper).to receive(:cleanup_vms)
        allow(kubevirt_helper).to receive(:cleanup_secrets)
        allow(kubevirt_helper).to receive(:cleanup_services)
        hypervisor.cleanup
      end

      it 'cleans up vms' do
        expect(kubevirt_helper).to have_received(:cleanup_vms).with(anything)
      end

      it 'cleans up secrets' do
        expect(kubevirt_helper).to have_received(:cleanup_secrets).with(anything)
      end

      it 'cleans up services' do
        expect(kubevirt_helper).to have_received(:cleanup_services).with(anything)
      end
    end
  end

  describe '#generate_vm_spec' do
    let(:vm_spec_args) do
      {
        hypervisor: described_class.new(hosts, options),
        host: hosts[0],
        vm_name: 'test-vm',
        cloud_init_secret: 'test-secret',
      }
    end
    let(:vm_spec) { vm_spec_args[:hypervisor].send(:generate_vm_spec, vm_spec_args[:host], vm_spec_args[:vm_name], vm_spec_args[:cloud_init_secret]) }

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

    it 'is running' do
      expect(vm_spec['spec']['running']).to be true
    end

    it 'includes cloud-init configuration' do
      volumes = vm_spec.dig('spec', 'template', 'spec', 'volumes')
      cloud_init_volume = volumes.find { |v| v['name'] == 'cloudinitdisk' }

      expect(cloud_init_volume).not_to be_nil
    end

    it 'references the cloud-init secret' do
      volumes = vm_spec.dig('spec', 'template', 'spec', 'volumes')
      cloud_init_volume = volumes.find { |v| v['name'] == 'cloudinitdisk' }
      expect(cloud_init_volume.dig('cloudInitNoCloud', 'secretRef', 'name')).to eq(vm_spec_args[:cloud_init_secret])
    end
  end

  describe '#generate_cloud_init' do
    let(:cloud_init_args) do
      {
        hypervisor: described_class.new(hosts, options),
        host: { 'name' => 'test-host', 'user' => 'testuser' },
      }
    end
    let(:cloud_init_data) { cloud_init_args[:hypervisor].send(:generate_cloud_init, cloud_init_args[:host]) }

    before do
      allow(cloud_init_args[:hypervisor]).to receive(:find_ssh_public_key).and_return('ssh-rsa test-key')
    end

    it 'is a cloud-config' do
      expect(cloud_init_data).to include('#cloud-config')
    end

    it 'includes the user' do
      expect(cloud_init_data).to include('testuser')
    end

    it 'includes the ssh key' do
      expect(cloud_init_data).to include('ssh-rsa test-key')
    end
  end
end
