# Kubernetes architecture diagrams

The `.excalidraw` files are the editable sources. The matching SVG files are
exported previews embedded in [the Kubernetes guide](../kubernetes.md). Keep each
pair in the same commit so Git history records both the model and its rendering.

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
   mode. Replace the matching preview without changing its filename.
4. Check the embedded preview in `docs/kubernetes.md` for clipping, overlapping
   connectors, and readable labels. Do not add credentials or private key data.

No renderer dependency is required by this repository. SVGs scale without
blurring and display directly in GitHub Markdown, including in dark mode.

## Visual conventions

- **Type:** Helvetica, with 36 px titles, 24–26 px section headings, 20 px body
  labels, and 18 px connection labels. Use sentence case and left alignment.
- **Blue (`#2563eb`):** Kubernetes control plane and application services.
- **Teal (`#0f766e`):** edge listeners, internal flow collection, and TLS delivery.
- **Amber (`#a16207`):** external clients, HAProxy, DNS, and trust boundaries.
- **Dark ink (`#16324a`):** body text; muted slate (`#536779`) for notes.
- **Structure:** straight connectors, restrained borders, pale fills, generous
  spacing, and a dashed boundary for the edge-node selector. Labels identify
  roles and protocols so color is not the only way to understand the diagrams.

Nodes and their labels are grouped in the sources. Principal connectors are
bound to their endpoints for easier editing. SVGs include titles and descriptions;
Markdown embeds also provide descriptive alternative text.
