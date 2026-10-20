# Lab architecture diagrams

The `.excalidraw` files are the editable sources. The matching SVG files are
exported previews embedded in [the architecture guide](../architecture.md) and
[the Kubernetes guide](../kubernetes.md). Keep each
pair in the same commit so Git history records both the source and its preview.

| Diagram | Editable source | Preview |
| --- | --- | --- |
| Whole-lab guest placement | [Excalidraw](lab-overview.excalidraw) | [SVG](lab-overview.svg) |
| Private networking, DNS, and DHCP | [Excalidraw](lab-network-dns.excalidraw) | [SVG](lab-network-dns.svg) |
| PostgreSQL metadata and recovery | [Excalidraw](lab-postgresql.excalidraw) | [SVG](lab-postgresql.svg) |
| SeaweedFS S3 internals and storage | [Excalidraw](lab-object-storage.excalidraw) | [SVG](lab-object-storage.svg) |
| Code, artifacts, and configuration delivery | [Excalidraw](lab-delivery.excalidraw) | [SVG](lab-delivery.svg) |
| OIDC identity and Vault / ESO secrets | [Excalidraw](lab-identity-secrets.excalidraw) | [SVG](lab-identity-secrets.svg) |
| Host TLS, Kuma, and notifications | [Excalidraw](lab-operations.excalidraw) | [SVG](lab-operations.svg) |
| Storage and recovery boundaries | [Excalidraw](lab-storage.excalidraw) | [SVG](lab-storage.svg) |
| Cluster topology and edge placement | [Excalidraw](kubernetes-topology.excalidraw) | [SVG](kubernetes-topology.svg) |
| Kubernetes runtime and packet paths | [Excalidraw](lab-kubernetes-runtime.excalidraw) | [SVG](lab-kubernetes-runtime.svg) |
| Gateway traffic, client identity, and Hubble | [Excalidraw](kubernetes-gateway.excalidraw) | [SVG](kubernetes-gateway.svg) |
| Cloudflare DNS-01 and certificate renewal | [Excalidraw](kubernetes-certificates.excalidraw) | [SVG](kubernetes-certificates.svg) |

## Edit and export

1. Open a source file in [Excalidraw](https://excalidraw.com/) using **Open**.
2. Update the relevant nodes, labels, and connections. Check host groups against
   `ansible/inventory.yaml`, service paths and ports against role configuration,
   and application ownership against `kubernetes/README.md`. Gateway placement
   follows `k8s_edge` and the `node-role.kubernetes.io/edge` label.
3. Save the `.excalidraw` file, then export SVG with a white background and light
   mode. Embed the scene and fonts in the SVG. Replace the matching preview
   without changing its filename.
4. Check the embedded previews in `docs/architecture.md`, `docs/kubernetes.md`,
   and the root README for clipping, overlapping connectors, and readable labels.
   Do not add credentials or private key data.

No renderer dependency is required by this repository. SVGs scale without
blurring and display directly in GitHub Markdown, including in dark mode.

## Visual conventions

- Type: Nunito, with 40 px titles, 22 to 26 px headings, 22 px body text, and
  20 px connection labels. Use Cascadia at 20 px for DNS and credential paths.
  Keep sentence case and left alignment.
- Blue (`#2563eb`): control planes, applications, and API operations.
- Teal (`#0f766e`): storage, edge listeners, internal flows, and secret/TLS delivery.
- Amber (`#a16207`): external clients, HAProxy, DNS, and trust boundaries.
- Dark ink (`#16324a`): body text; muted slate (`#536779`) for notes.
- Structure: square nodes with neutral borders and colored top edges. Reserve
  pale fills for cluster groups and explanatory notes. Use straight or
  right-angled connectors with filled arrowheads, and keep protocol labels beside
  their lines. The edge-node selector has a dashed boundary. Labels identify
  roles and protocols so color is not the only way to understand the diagrams.
- Pale panels group hosts or responsibilities. Explicitly label access and
  failure boundaries. Name the operation on each flow; a DNS lookup is separate
  from the connection made to its result. Avoid implying automated CI deployment
  or off-host backups where no such configuration exists.

Nodes, labels, and top edges are grouped in the sources. Main connectors are
bound to their endpoints for easier editing. SVGs embed the fonts and editable
scene and include accessible titles and descriptions; Markdown embeds also
provide descriptive alternative text. Check each preview at an 800 px display
width as well as at full size.
