# Kubernetes architecture diagrams

The `.excalidraw` files are the editable sources. The matching SVG files are
exported previews embedded in [the Kubernetes guide](../kubernetes.md). Keep each
pair in the same commit so Git history records both the source and its preview.

| Diagram | Editable source | Preview |
| --- | --- | --- |
| Cluster topology and edge placement | [Excalidraw](kubernetes-topology.excalidraw) | [SVG](kubernetes-topology.svg) |
| Gateway traffic, client identity, and Hubble | [Excalidraw](kubernetes-gateway.excalidraw) | [SVG](kubernetes-gateway.svg) |
| Cloudflare DNS-01 and certificate renewal | [Excalidraw](kubernetes-certificates.excalidraw) | [SVG](kubernetes-certificates.svg) |

## Edit and export

1. Open a source file in [Excalidraw](https://excalidraw.com/) using **Open**.
2. Update the relevant nodes, labels, and connections. Gateway placement follows
   the `k8s_edge` inventory group and the `node-role.kubernetes.io/edge` label.
3. Save the `.excalidraw` file, then export SVG with a white background and light
   mode. Embed the scene and fonts in the SVG. Replace the matching preview
   without changing its filename.
4. Check the embedded preview in `docs/kubernetes.md` for clipping, overlapping
   connectors, and readable labels. Do not add credentials or private key data.

No renderer dependency is required by this repository. SVGs scale without
blurring and display directly in GitHub Markdown, including in dark mode.

## Visual conventions

- Type: Nunito, with 40 px titles, 24 to 26 px headings, 22 px body text, and
  20 px connection labels. Use Cascadia at 20 px for DNS and credential paths.
  Keep sentence case and left alignment.
- Blue (`#2563eb`): Kubernetes control plane and application services.
- Teal (`#0f766e`): edge listeners, internal flow collection, and TLS delivery.
- Amber (`#a16207`): external clients, HAProxy, DNS, and trust boundaries.
- Dark ink (`#16324a`): body text; muted slate (`#536779`) for notes.
- Structure: square nodes with neutral borders and colored top edges. Reserve
  pale fills for cluster groups and explanatory notes. Use straight or
  right-angled connectors with filled arrowheads, and keep protocol labels beside
  their lines. The edge-node selector has a dashed boundary. Labels identify
  roles and protocols so color is not the only way to understand the diagrams.

Nodes, labels, and top edges are grouped in the sources. Main connectors are
bound to their endpoints for easier editing. SVGs embed the fonts and editable
scene and include accessible titles and descriptions; Markdown embeds also
provide descriptive alternative text. Check each preview at an 800 px display
width as well as at full size.
