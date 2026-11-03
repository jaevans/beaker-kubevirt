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
| `kubevirt_storage_class` | Storage class for the root disk's DataVolume, used when `kubevirt_vm_image` is an `http(s)://` URL or a PVC to clone. Unset uses the cluster's default storage class. A `docker://`/`oci://` containerDisk has no DataVolume and ignores it. Cloning a PVC into a different class may make CDI copy the data instead of using a CSI clone. A non-empty `BEAKER_kubevirt_storage_class` environment variable overrides the host and CONFIG values. | No | cluster default | `BEAKER_kubevirt_storage_class`, HOSTS (per-host), CONFIG |
| `kubevirt_cloud_init` | Custom cloud-init YAML | No | Auto-generated | HOSTS (per-host) |
| `kubevirt_vm_ssh_port` | SSH port inside the VM | No | `22` | HOSTS (per-host) |
| `kubevirt_readiness_probe_disabled` | Skip the VMI SSH readinessProbe. Default is `false` for pod-network modes and `true` for `multus` (where a probe from the virt-launcher netns typically can't reach a bridge-only guest). | No | mode-dependent | HOSTS (per-host), CONFIG |
| `kubevirt_readiness_probe` | Probe tuning hash (snake_case keys): `initial_delay_seconds` (30), `period_seconds` (10), `timeout_seconds` (3), `failure_threshold` (60), `success_threshold` (1). The default failure budget (600s) accommodates slow Windows first-boots. When the probe is enabled, `timeout` is auto-raised to cover this budget. | No | see description | HOSTS (per-host), CONFIG |
| `kubevirt_unschedulable_grace` | Seconds the virt-launcher pod may stay unschedulable (`PodScheduled=False`, reason `Unschedulable` or `SchedulerError`) before provisioning gives up and reports the scheduler's own message. Cannot be immediate — an unschedulable pod is precisely what tells a cluster autoscaler to add a node. Bounded by the effective `timeout`, which this does not raise. | No | `300` | HOSTS (per-host), CONFIG |
| `kubevirt_image_pull_grace` | Seconds a containerDisk pull may sit in `ImagePullBackOff`/`ErrImagePull` before provisioning gives up. kubelet retries pulls, so a cold pull-through cache, a slow upstream registry or a dropped connection normally clears on a later attempt. Bounded by the effective `timeout` (which this does not raise), and skipped when the failure is definitive — unknown manifest, `unauthorized`, `denied` — so a typo'd tag still fails immediately. Set it to `0` to switch the window off and fail on the first backoff, as provisioning did before this option existed. The first backoff seen for each container is logged as a warning, so a run that reaches `timeout` before the window ends still records why. | No | `600` | HOSTS (per-host), CONFIG |
| `kubevirt_disable_virtio` | Disable virtio devices (for Windows compatibility). If set to true the disk bus will be set to `sata` and the network adapter will be model `e1000` | No | `false` | HOSTS (per-host) |
| `kubevirt_disk_cache` | Cache mode for the root disk: `none`, `writethrough` or `writeback`. Unset leaves the choice to KubeVirt (`none` when the backing store supports O_DIRECT). `writeback` lets the virt-launcher's page cache absorb guest writes until the guest flushes; use it for throwaway test VMs on slow or shared storage, where a lost VM only costs a re-run. A non-empty `BEAKER_kubevirt_disk_cache` environment variable overrides both. | No | unset | `BEAKER_kubevirt_disk_cache`, HOSTS (per-host), CONFIG |
| `kubevirt_node_selector` | Hash of node labels the VM's pod must match, e.g. `{ 'node-pool.example.com/ci' => 'true' }`. Select a group of nodes by a label they share, not a single node by name. Quote values that look like decimals (`'1.10'`): an unquoted float is refused, since YAML would read `1.10` as `1.1`. `BEAKER_kubevirt_node_selector`, a comma-separated list of `key=value` pairs, replaces the host and CONFIG values when non-empty. | No | unset | `BEAKER_kubevirt_node_selector`, HOSTS (per-host), CONFIG |
| `kubevirt_tolerations` | List of taints the VM's pod tolerates. Each entry is a hash with `key`, `effect` (`NoSchedule`, `PreferNoSchedule` or `NoExecute`) and an optional `value`; an entry without a value tolerates the key whatever its value. Other fields (`operator`, `tolerationSeconds`) are refused rather than ignored. Tolerating a taint only allows the VM onto those nodes; pair it with `kubevirt_node_selector` to keep it on them. `BEAKER_kubevirt_tolerations`, a comma-separated list of `key=value:Effect` or `key:Effect` entries, replaces the host and CONFIG values when non-empty. | No | unset | `BEAKER_kubevirt_tolerations`, HOSTS (per-host), CONFIG |

**Important**: The `namespace`, `kubeconfig`, and `kubecontext` options must be specified in the global `CONFIG` section, not per-host. All VMs will be created in the same Kubernetes namespace.

Notes:
- Several per-host options support global fallbacks via `CONFIG` (e.g., `kubevirt_cpus`, `kubevirt_memory`, `kubevirt_vm_ssh_port`).
- The `networks` key for Multus is intentionally unprefixed (use `networks`, not `kubevirt_networks`).
- `kubevirt_cpus` sets the guest's core count, which is not the same thing as the pod's CPU request. Left to itself, KubeVirt divides the core count by the cluster's `cpuAllocationRatio` — 10 by default — so a 2-core guest lands in a burstable pod requesting `200m`. On a busy node that guest is throttled to roughly a tenth of what it advertises, and a slow first boot can outlast the readiness probe's failure budget while nothing anywhere reports an error. Set `kubevirt_cpu_request` when boot time matters; Windows guests are the usual case.
- A virt-launcher pod the scheduler cannot place used to be invisible: its phase is `Pending`, not `Failed`, and it carries no container statuses at all, so provisioning waited out the full `timeout` and reported `Timeout waiting for VM ... to be ready` — indistinguishable from a slow guest boot. It now reports the scheduler's own message (`0/8 nodes are available: 5 Insufficient cpu`) as soon as the state is seen, and fails after `kubevirt_unschedulable_grace`. Raise `kubevirt_memory_request` or a CPU request beyond what a node can offer and this is the error you will get.
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

### Supplying the test-group identifier

By default the test-group identifier is `beaker-<random hex>`, generated per process. Set `BEAKER_KUBEVIRT_TEST_GROUP` to choose it instead:

```bash
BEAKER_KUBEVIRT_TEST_GROUP="beaker-ci-${CI_JOB_ID}" bundle exec rake beaker
```

This matters when something outside the beaker process has to clean up after it. In CI, a cancelled job can be killed before beaker tears anything down, and with a random identifier the job has no way to name the resources it leaked. With a known identifier the job can delete by `beaker/test-group=<its own identifier>` once beaker is gone, without disturbing other runs that share the namespace:

```bash
kubectl -n "$namespace" delete vm,dv,secret,svc -l "beaker/test-group=beaker-ci-${CI_JOB_ID}"
```

The identifier must be unique to each run that can be live at the same time. It names the VMs, DataVolumes and Secrets as well as labelling them, so two runs that share it collide on create, and either run's cleanup deletes the other's resources. `CI_JOB_ID` is unique per job on GitLab. On GitHub Actions, `GITHUB_RUN_ID` is not: every job and matrix leg of a run shares it, and so do re-run attempts. Combine it with the attempt, the job and the matrix index, keeping the result within 63 characters (a longer value is refused rather than truncated, since truncation would cut off the part that tells runs apart):

```yaml
env:
  BEAKER_KUBEVIRT_TEST_GROUP: beaker-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}-${{ strategy.job-index }}
```

Values that are not valid Kubernetes label values are sanitized (and a warning is logged), so prefer an identifier that is already label-safe — otherwise the label will not be the string you set.

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
