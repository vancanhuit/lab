# Kubernetes

The kubeadm cluster has one control plane and three workers, all Debian 13 Incus
VMs with 2 vCPUs and 4 GiB RAM. Kubernetes runs on containerd and runc with the
systemd cgroup driver and the unified cgroup v2 hierarchy. Cilium replaces
kube-proxy; kubeadm skips the proxy addon and records `proxy.disabled: true` for
subsequent kubeadm operations.

| Node | DNS hostname | Initial IPv4 address |
| --- | --- | --- |
| Control plane | `k8s-control-plane.lab.canhdinh.com` | `10.205.234.106` |
| Worker 1 | `k8s-node-01.lab.canhdinh.com` | `10.205.234.107` |
| Worker 2 | `k8s-node-02.lab.canhdinh.com` | `10.205.234.108` |
| Worker 3 | `k8s-node-03.lab.canhdinh.com` | `10.205.234.109` |

The API endpoint is `k8s-control-plane.lab.canhdinh.com:6443`. Ansible also connects
using DNS names. **Keep the control-plane IP stable**, preferably with a
Technitium DHCP reservation. DNS alone does not handle renumbering: kubeadm's API
server and etcd static manifests embed the bootstrap IP address.

## Versions and networking

Pins and SHA-256 checksums are in
`ansible/roles/kubernetes/defaults/main.yaml`: Kubernetes 1.36.5, containerd 2.4.2,
runc 1.5.2, CNI plugins 1.9.1, crictl 1.36.0, Cilium 1.20.3, Cilium CLI 0.20.1,
and Hubble CLI 1.20.2.
Kubernetes 1.36 is in Cilium 1.20's tested compatibility matrix. The node binaries,
including runc and the standard CNI plugins, come from official upstream releases,
not distribution packages. This avoids a package dependency replacing the manually
installed CNI plugins. Manage their security updates explicitly.

- Pod CIDR: **`10.244.0.0/16`**, with a `/24` per node allocated by Kubernetes.
- Service CIDR: `10.96.0.0/12`.
- Cilium IPAM: `kubernetes`, using each Node's PodCIDR.
- Envoy: standalone `cilium-envoy` DaemonSet (`envoy.enabled: true`), not embedded
  in the Cilium agent.
- Hubble: enabled with Relay as an internal ClusterIP Service. Agent-to-Relay
  connections use mTLS, with automatic certificate renewal through certgen's CronJob.
- Routing: VXLAN overlay; no Pod routes are needed on the Incus bridge.
- Cilium connects directly to the DNS API endpoint during bootstrap, before
  Kubernetes Service routing exists.

All nodes need outbound HTTPS and working DNS to download binaries and images.
Allow TCP 6443 to the control plane, TCP 10250 between nodes, UDP 8472 for VXLAN,
TCP 4240 and ICMP between nodes for Cilium health checks. Keep etcd TCP 2379–2380
restricted to the control plane. Do not expose the API or kubelet publicly.
Allow TCP 4244 from Hubble Relay to each node for the mTLS-protected Hubble API.
If using NodePort Services, permit only the needed ports in TCP/UDP 30000–32767.

## Deploy and verify

From `ansible/`:

```sh
mise exec -- ansible-playbook kubernetes.yaml
mise exec -- ansible-playbook verify-kubernetes.yaml
mise exec -- ansible-playbook kubernetes.yaml
```

The repeat deployment should report `changed=0`. The playbook never resets a
cluster or reruns a worker join when `/etc/kubernetes/kubelet.conf` already exists.
It refuses an implicit Kubernetes version change or adoption of a different
installation. A partial failed initialization needs investigation, not an
automatic `kubeadm reset`, because reset can destroy cluster state.

Worker join commands are generated only for unjoined workers. Their tokens expire
after 15 minutes, are hidden from Ansible output, and are revoked after the join stage.
No bootstrap token or kubeconfig is committed to the repository. Kubernetes
nodes are outside the inventory's `lab` group and do not inherit its Cloudflare
credential.

The administrator kubeconfig is installed with mode `0600` at
`/home/admin/.kube/config` on the control plane. Use it without copying credentials
to the Ansible controller:

```sh
ssh admin@k8s-control-plane.lab.canhdinh.com 'kubectl get nodes -o wide'
ssh admin@k8s-control-plane.lab.canhdinh.com 'kubectl get pods -A -o wide'
ssh admin@k8s-control-plane.lab.canhdinh.com 'cilium status --wait'
```

Verification checks all four nodes, control-plane membership, CRI health, binary
versions, systemd cgroups, cgroup v2, CoreDNS, absence of the kube-proxy DaemonSet
and ConfigMap, full kube-proxy replacement on every Cilium agent, and Hubble Relay
connectivity to all four nodes.
Run connectivity tests separately; they create workloads and network policies,
unlike the read-only verification playbook. On the control plane as `admin`:

```sh
ssh admin@k8s-control-plane.lab.canhdinh.com
cilium connectivity test --hubble=false \
  --test 'no-policies|client-ingress-knp|all-egress-deny-knp|echo-ingress-l7|client-egress-l7-method'
relay_ip=$(kubectl -n kube-system get service hubble-relay -o jsonpath='{.spec.clusterIP}')
cilium connectivity test --hubble-server "$relay_ip:80" \
  --flow-validation strict --test 'client-egress-l7-method/'
cilium connectivity test --cleanup
```

The dataplane check passed 8 tests / 183 actions, and the strict Hubble L7 check
passed 1 test / 18 actions. The full 135-test suite was not completed.
Strict Pod-to-Service flow matching timed out: the matcher expected a TCP SYN
addressed to the Service IP, while Hubble recorded the socket-LB pre-translation
event and the backend Pod's TCP SYN. Service requests themselves succeeded.
Do not disable socket load balancing merely to satisfy this flow expectation.

Controller-local template and network-overlap tests:

```sh
mise exec -- ansible-playbook -i localhost, roles/kubernetes/tests/render-config.yml
```

## Observe flows with Hubble

The Hubble CLI is installed on the control plane. Start a loopback-only forward
to Relay, leaving this command running:

```sh
ssh admin@k8s-control-plane.lab.canhdinh.com 'cilium hubble port-forward'
```

In a second terminal:

```sh
ssh admin@k8s-control-plane.lab.canhdinh.com 'hubble status'
ssh admin@k8s-control-plane.lab.canhdinh.com 'hubble observe --last 20'
```

Stop the forward with Ctrl-C. Hubble UI, an Ingress, and public access are not
enabled. Network flow metadata can be sensitive; keep Relay access restricted.

## Limits

This is not an HA cluster: losing the control plane makes the Kubernetes API and
scheduling unavailable. There is no etcd backup automation, storage provisioner,
Ingress controller, external LoadBalancer implementation, or monitoring stack in
this deployment. Add backups before storing important cluster state. Incus root
disks hold `/var/lib/etcd` and `/var/lib/containerd`.

Changing version pins is not a rolling-upgrade procedure. Follow the upstream
kubeadm and Cilium upgrade guides, back up etcd, and drain workers as appropriate.

## References

- [Create a kubeadm cluster](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [Install kubeadm and node binaries](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [Container runtimes and systemd cgroups](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)
- [Official containerd, runc, and CNI installation](https://github.com/containerd/containerd/blob/v2.4.2/docs/getting-started.md)
- [Cilium without kube-proxy](https://docs.cilium.io/en/v1.20/network/kubernetes/kubeproxy-free/)
- [Cilium Kubernetes compatibility](https://docs.cilium.io/en/v1.20/network/kubernetes/requirements/)
- [Cilium Kubernetes IPAM](https://docs.cilium.io/en/v1.20/network/concepts/ipam/kubernetes/)
- [Hubble TLS and certificate renewal](https://docs.cilium.io/en/v1.20/observability/hubble/configuration/tls/)
