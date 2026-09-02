# Beaker::KubeVirt

A Beaker hypervisor provider for [KubeVirt](https://kubevirt.io), enabling automated acceptance testing of Puppet code using virtual machines running inside Kubernetes clusters.

## Features

- Deploy VMs using KubeVirt's `VirtualMachine` objects
- Support for multiple image sources (PVC, ContainerDisk, DataVolume)
- Cloud-init configuration injection for user setup and SSH keys
- Multiple networking modes (port-forward, NodePort, Multus)
- Automatic VM lifecycle management (provision, test, cleanup)
- Integration with existing Beaker workflows

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'beaker-kubevirt'
```

And then execute:

```bash
bundle install
```

Or install it yourself as:

```bash
gem install beaker-kubevirt
```

## Configuration

### Prerequisites

- A Kubernetes cluster with KubeVirt installed
- Valid kubeconfig file with cluster access
- SSH public key for VM access

### Beaker Host Configuration

Configure your Beaker hosts file to use the KubeVirt hypervisor:

```yaml
HOSTS:
  centos-vm:
    platform: el-8-x86_64
    hypervisor: kubevirt
    kubevirt_vm_image: docker://quay.io/kubevirt/fedora-cloud-container-disk-demo
    kubevirt_network_mode: port-forward
    kubevirt_ssh_key: ~/.ssh/id_rsa.pub
    kubevirt_cpus: 2
    kubevirt_memory: 4Gi

CONFIG:
  # Global KubeVirt configuration
  kubeconfig: <%= ENV.fetch('KUBECONFIG', '~/.kube/config') %>
  kubecontext: my-context  # optional
  namespace: beaker-tests  # required - namespace for all VMs
  kubevirt_service_account: beaker-kubevirt-sa  # optional - required for cross-namespace PVC cloning
  ssh:
    password: beaker
    auth_methods: ['publickey', 'password']
```

### Configuration Options

| Option | Description | Required | Default | Location |
|--------|-------------|----------|---------|----------|
| `kubeconfig` | Path to kubeconfig file | Yes | `$KUBECONFIG` or `~/.kube/config` | CONFIG (global) |
| `kubecontext` | Kubernetes context to use | No | Current context | CONFIG (global) |
| `namespace` | Kubernetes namespace for VMs | **Yes** | `default` | **CONFIG (global)** |
| `kubevirt_service_account` | Service account for cross-namespace PVC cloning | No | `default` | CONFIG (global) |
| `kubevirt_vm_image` | VM image specification | Yes | - | HOSTS (per-host) |
| `kubevirt_network_mode` | Networking mode | No | `port-forward` | HOSTS (per-host) |
| `networks` | Custom network configuration | No | Auto-generated | HOSTS (per-host) |
| `kubevirt_ssh_key` | SSH public key path or content | Yes | Auto-detect from `~/.ssh/` | HOSTS (per-host) |
| `kubevirt_cpus` | CPU cores for VM | No | `1` | HOSTS (per-host) |
| `kubevirt_cpu_request` | CPU request for the VM pod, as a Kubernetes CPU quantity (`2`, `1500m`). Unset leaves KubeVirt to derive it from `kubevirt_cpus` divided by the cluster's `cpuAllocationRatio`. Set it for guests that must not be throttled while booting. | No | unset | HOSTS (per-host), CONFIG |
| `kubevirt_cpu_limit` | CPU limit for the VM pod, as a Kubernetes CPU quantity. Unset leaves the compute container burstable. | No | unset | HOSTS (per-host), CONFIG |
| `kubevirt_memory` | Memory for VM | No | `2Gi` | HOSTS (per-host) |
| `kubevirt_memory_overhead` | Extra memory added to the guest for the virt-launcher container memory limit. Raise this for Windows guests that OOMKill with the default. | No | `512Mi` | HOSTS (per-host), CONFIG |
| `kubevirt_memory_request` | Memory request for the VM pod. | No | Same as `kubevirt_memory` | HOSTS (per-host), CONFIG |
| `kubevirt_disk_size` | Size of the root disk | No | `10Gi` | HOSTS (per-host) |
| `kubevirt_cloud_init` | Custom cloud-init YAML | No | Auto-generated | HOSTS (per-host) |
| `kubevirt_vm_ssh_port` | SSH port inside the VM | No | `22` | HOSTS (per-host) |
| `kubevirt_readiness_probe_disabled` | Skip the VMI SSH readinessProbe. Default is `false` for pod-network modes and `true` for `multus` (where a probe from the virt-launcher netns typically can't reach a bridge-only guest). | No | mode-dependent | HOSTS (per-host), CONFIG |
| `kubevirt_readiness_probe` | Probe tuning hash (snake_case keys): `initial_delay_seconds` (30), `period_seconds` (10), `timeout_seconds` (3), `failure_threshold` (60), `success_threshold` (1). The default failure budget (600s) accommodates slow Windows first-boots. When the probe is enabled, `timeout` is auto-raised to cover this budget. | No | see description | HOSTS (per-host), CONFIG |
| `kubevirt_disable_virtio` | Disable virtio devices (for Windows compatibility). If set to true the disk bus will be set to `sata` and the network adapter will be model `e1000` | No | `false` | HOSTS (per-host) |

**Important**: The `namespace`, `kubeconfig`, and `kubecontext` options must be specified in the global `CONFIG` section, not per-host. All VMs will be created in the same Kubernetes namespace.

Notes:
- Several per-host options support global fallbacks via `CONFIG` (e.g., `kubevirt_cpus`, `kubevirt_memory`, `kubevirt_vm_ssh_port`).
- The `networks` key for Multus is intentionally unprefixed (use `networks`, not `kubevirt_networks`).
- `kubevirt_cpus` sets the guest's core count, which is not the same thing as the pod's CPU request. Left to itself, KubeVirt divides the core count by the cluster's `cpuAllocationRatio` — 10 by default — so a 2-core guest lands in a burstable pod requesting `200m`. On a busy node that guest is throttled to roughly a tenth of what it advertises, and a slow first boot can outlast the readiness probe's failure budget while nothing anywhere reports an error. Set `kubevirt_cpu_request` when boot time matters; Windows guests are the usual case.
- Long-running commands aren't killed by idle-timeout drops, even when output streams in only one direction (e.g., a Windows scanner running for many minutes). The `port-forward` proxy no longer enforces a client-side read-silence timeout (it relied on net-ssh keepalive packets that net-ssh suppresses while server output is flowing) and instead sends a WebSocket protocol ping every 60s to keep the upstream tunnel alive. net-ssh keepalive defaults are also tightened to `keepalive_interval: 60`, `keepalive_maxcount: 5` — Beaker already enables `keepalive: true` — which protects `multus` and `nodeport` modes against NAT/conntrack timeouts. Override per-host under `ssh:` if needed.

### VM Image Formats

The `kubevirt_vm_image` option supports several formats:

- **Container image**: `docker://quay.io/kubevirt/fedora-cloud-container-disk-demo` or `oci://quay.io/kubevirt/fedora-cloud-container-disk-demo`
- **PVC reference**: `pvc:my-vm-disk`, `my-vm-disk` (uses current namespace), or `namespace/pvc-name` (cross-namespace PVC)
- **DataVolume**: `http://example.com/my-datavolume.img` or `https://example.com/my-datavolume.img` NOTE: [KubeVirt CDI](https://github.com/kubevirt/containerized-data-importer) must be installed in the cluster for DataVolume support.

### Cross-Namespace PVC Cloning

When cloning PVCs from a different namespace than where the VMs run, you must configure a service account with appropriate RBAC permissions. This is required because the DataVolume controller needs authorization to read PVCs in the source namespace.

#### Setup

1. **Create the service account and RBAC resources:**

    ```bash
    kubectl create serviceaccount beaker-kubevirt -n beaker-tests
    ```
    Save the following RBAC configuration to `cluster-role.yaml`:
    
    ```yaml
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: beaker-kubevirt:volumes:clone
    rules:
      - apiGroups: 
          - cdi.kubevirt.io
        resources: 
          - datavolumes/source
        verbs: 
          - '*'
    ```

    Then apply it:
    
    ```bash
    kubectl apply -f cluster-role.yaml
    ```

    Save the following RoleBinding configuration to `pvc-clone-rbac.yaml`:

    ```yaml
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: RoleBinding
    metadata:
      name: beaker-kubevirt:volumes:clone-binding
      namespace: source-namespace
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: beaker-kubevirt:volumes:clone
    subjects:
      - kind: ServiceAccount
        name: beaker-kubevirt
        namespace: destination-namespace
    ```

    Apply the RoleBinding (replace `source-namespace` and `destination-namespace` with your actual namespaces):

    ```bash
    kubectl apply -f pvc-clone-rbac.yaml
    ```

  This creates a `beaker-kubevirt` service account in the beaker test namespace with permissions to update DataVolumes to indicate a clone source in the specified source namespace.

2. **Configure beaker to use the service account:**

   ```yaml
   CONFIG:
     namespace: beaker-tests
     kubevirt_service_account: beaker-kubevirt
   ```

3. **Reference PVCs from other namespaces:**

   ```yaml
   HOSTS:
     test-vm:
       kubevirt_vm_image: other-namespace/source-pvc-name
   ```

This configuration allows Beaker to create VMs that clone PVCs from different namespaces with the minimum required permissions.

### Network Modes

- **port-forward**: Uses `kubectl port-forward` (default, works everywhere)
- **nodeport**: Creates a NodePort service (requires node access)
- **multus**: Uses Multus bridge networking (requires Multus CNI)

#### Multus networks example

When using `kubevirt_network_mode: multus`, specify one or more Multus attachments via an unprefixed `networks:` array. Each item requires a unique `name` and the Multus `networkName` provided as `multus_network_name`.

```yaml
HOSTS:
  multus-vm:
    platform: el-8-x86_64
    hypervisor: kubevirt
    kubevirt_vm_image: docker://quay.io/kubevirt/fedora-cloud-container-disk-demo
    kubevirt_network_mode: multus
    kubevirt_ssh_key: ~/.ssh/id_rsa.pub
    networks:
      - name: ext0
        multus_network_name: my-bridge-network
      - name: ext1
        multus_network_name: another-network
```

## Usage Example

```yaml
# beaker-hosts.yaml
HOSTS:
  puppet-agent:
    platform: el-8-x86_64
    hypervisor: kubevirt
    kubevirt_vm_image: docker://quay.io/kubevirt/centos-stream8-container-disk-demo
    kubevirt_network_mode: port-forward
    kubevirt_ssh_key: ~/.ssh/id_rsa.pub
    kubevirt_cpus: 2
    kubevirt_memory: 4Gi
CONFIG:
  # Global KubeVirt configuration
  kubeconfig: ~/.kube/config
  namespace: beaker-tests
  ssh:
    auth_methods: ['publickey']
```

```ruby
# spec/acceptance/basic_spec.rb
require 'spec_helper_acceptance'

describe 'basic functionality' do
  context 'on KubeVirt VM' do
    it 'should provision successfully' do
      expect(fact_on(default, 'kernel')).to eq('Linux')
    end

    it 'should have SSH access' do
      result = on(default, 'echo "Hello from KubeVirt VM"')
      expect(result.stdout.strip).to eq('Hello from KubeVirt VM')
    end
  end
end
```

## Labels and Cleanup

All resources created are labeled for traceability and cleanup:
- `beaker/test-group`: Identifies the run (e.g., `beaker-<hex>`)
- `beaker/host`: Host name from your Beaker inventory

These labels are used during `cleanup` to remove VMs, secrets, and services associated with the test group.

## Requirements

- KubeVirt and Kubernetes cluster access via `kubeconfig`
- For `port-forward` networking mode: `kubectl` access to the cluster nodes and permission to port-forward

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/voxpupuli/beaker-kubevirt.

## License

The gem is available as open source under the terms of the [GNU Affero General Public License](https://www.gnu.org/licenses/agpl-3.0.en.html) as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
