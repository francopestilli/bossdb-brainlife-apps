# BossDB Contactome

<!-- brainlife-app:begin (generated from the App manifest; edit the manifest, not this block) -->

> **Computes a contactome (contact-area graph between touching segmented objects) from a BossDB precomputed segmentation with Cloudome, writing a SQLite database.**

Resolves a BossDB segmentation channel to its precomputed CloudVolume location, splits it into cuboid tasks, runs Cloudome workers locally and sums per-cuboid contacts into contactome.db (table contactome_edges: graph_id, location, pre, post, weight in square nanometres). Use it to build a contact graph between neighbouring objects in an EM segmentation. The input must be a segmentation where objects touch; the output directory and databases must not already exist.

| | |
|---|---|
| 📥 **Inputs** | `neuro/bossdb` |
| 📤 **Outputs** | `raw` |
| 🐳 **Container** | `ghcr.io/jhuapl-boss/bossdb-brainlife-apps:cloudome` |
| 🔗 **Run it** | [doi.org/10.25663/brainlife.app.971](https://doi.org/10.25663/brainlife.app.971) |

#### 📥 Inputs

| Input | Datatype | Required | Description |
|---|---|---|---|
| `seg` | `neuro/bossdb` | yes | BossDB segmentation channel reference of the form bossdb://collection/experiment/channel. Public channel stored as precomputed CloudVolume data, containing a segmentation whose objects touch. |

#### 📤 Outputs

| Output | Datatype | Description |
|---|---|---|
| `output` | `raw` | SQLite database contactome.db (table contactome_edges with graph_id, location, pre, post, weight in square nanometres) and a contactome.log. |

<details>
<summary><b>⚙️ Parameters</b> (8)</summary>

| Parameter | Type | Default | Description |
|---|---|---|---|
| `output_directory` | string | `outputs` | Directory in which output will be written |
| `graph_id` | string | `contactome-example` | When storing more than one contactome in the same DB, this parameter differentiates them |
| `mip` | string |  | The resolution of the segmentation at which the contactome should be calculated |
| `block_size` | string | `64,64,32` | Computations are calculated blockwise; this parameter specifies how large blocks should be. Scale this based on the memory capacity of the target machine |
| `z_start` | number |  | Subset the computation so that it starts at a specific z slice |
| `z_end` | number |  | Subset the computation so that it ends at a specific z slice |
| `enqueue_limit` | number |  | For testing, truncate the queue so that only this many blocks are computed |
| `workers` | number | `1` | Number of local Cloudome worker processes that drain the task queue. |

</details>

📚 **References used by this App:**
- Matelsky et al. 2026. [doi:10.64898/2026.05.08.723866](https://doi.org/10.64898/2026.05.08.723866)

<!-- brainlife-app:end -->

