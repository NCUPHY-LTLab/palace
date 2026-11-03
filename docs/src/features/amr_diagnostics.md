# Native AMR diagnostics

Enable `Model.Refinement.SaveAdaptDiagnostics` to inspect which cells were marked,
which original parents were actually split, and how each electrostatic terminal
and recovery projection solve converged. Diagnostics are disabled by default and
leave the estimator, marking, refinement, solver, and stopping rules unchanged.

```json
{
  "Model": {
    "Refinement": {
      "SaveAdaptDiagnostics": true
    }
  }
}
```

The output is `<Problem.Output>/amr-diagnostics/manifest.json`. This directory stays
at the output root when `SaveAdaptIterations` archives solution files. Diagnostic
mesh snapshots are written independently of `SaveAdaptMesh`, so enabling diagnostics
adds mesh storage and I/O costs.

## Read an attempt and its solution

The manifest identifies the format with `schema: "palace.amr_diagnostics"` and
`schema_version: 1`. Each JSON record also has a `record_type`. Follow the manifest's
`solves` and `transitions` paths, then the paths listed inside those records. All
paths are relative to the `amr-diagnostics` directory; unlisted files can belong to
an earlier invocation in the same output directory.
The manifest's `files` array is the complete explicit inventory of record and
mesh paths. It excludes `manifest.json` itself. A receipt can hash the manifest
and this inventory without searching the output directory.

| Record | Path pattern | Contents |
|---|---|---|
| Manifest | `manifest.json` | MPI size, coordinate units, exact solve and transition record lists |
| Solve attempt | `solves/solve-N.json` | Iteration, mesh identity, global owned cells, true DOFs, terminal records and capacitance attribution |
| Terminal | `terminals/solve-N-terminal-T.json` | Native terminal index, matrix column, main linear solve and recovery projection status |
| Transition | `transitions/transition-N.json` | Marking, actual parent counts, pre/post counts, conformity and rank-record paths |
| Transition rank | `transitions/transition-N-rank-R.json` | Exact local marked and refined-parent sets and owned fine-to-coarse map |
| Rank mesh | `meshes/solve-N-rank-R.mesh`, `meshes/refined-N-rank-R.mesh` | MFEM parallel mesh snapshots before a solve and immediately after refinement |

`N` is the one-based native solve iteration: the initial solve is 1. A transition
from iteration `N` attempts solve `N+1`. Its `pre_mesh_id` is `solve-N`, its
`refined_mesh_id` is `refined-N`, and its `next_mesh_id` is `solve-(N+1)`.
Mesh coordinates use Palace's nondimensional coordinates; use the resolved model
length scale for dimensional interpretation.

A solve record is discoverable as `started` before snapshot I/O or solver work
begins. It becomes `completed` when the driver returns, or `failed` when an
exception or an existing driver failure is reported. An interrupted process can
leave a `started` record, missing snapshots or unavailable terminal statistics.
JSON and mesh files replace their destinations atomically; temporary files ending
in `.tmp` are incomplete output.

`completed` describes control flow, while `statistics.main.converged` and
`statistics.recovery.converged` describe the two numerical solves. Electrostatic
output retains its existing behavior of writing a capacitance matrix even when
the linear solver reports nonconvergence. Keep that matrix with its reported
status when examining results.

Bind a capacitance matrix only when `capacitance_written` is true and
`capacitance_iteration` matches the solve record's `iteration`.
`capacitance_terminal_order` gives both row and column terminal IDs in native
order; a terminal record's `statistics.capacitance_column` is zero-based.
A started or failed next attempt with `capacitance_written: false` has no
attributable matrix, even if a previous iteration's CSV remains accessible at
the output root. The existing `palace.json` `Problem.Iteration` and archived
solution bytes retain their normal meanings.

## Distinguish marking from actual refinement

For one transition, let `M` be the marked pre-step cells, `P` the distinct original
pre-step parents actually split, and `N_pre` the global owned pre-step cell count.
The rank records preserve both sets as zero-based coarse-local indices.
An element identity is the tuple `(pre_mesh_id, rank, coarse_local_index)`;
it does not persist through rebalancing or later refinement.

Immediately after `GeneralRefinement` and before rebalancing, the producer reads
`GetRefinementTransforms`. It groups owned, non-ghost fine leaves by their original
coarse parent and includes a parent in `P` when it has multiple leaves. This
includes conforming closure and nonconforming level-limit propagation, including
parents split more than once in that operation. Element-count growth is recorded
separately.

| Transition field | Meaning |
|---|---|
| `marked_count` | Global number of cells in `M` |
| `refined_parent_count` | Global number of distinct parents in `P` |
| `extra_refined_parent_count` | Global number of parents in `P` but not `M` |
| `owned_global_cells_pre` | Sum of owned pre-step cells across MPI ranks |
| `owned_global_cells_post_refinement` | Owned fine cells before rebalancing |
| `owned_global_cells_post_rebalance` | Owned cells after rebalancing |
| `threshold` | Actual threshold used by the existing marking predicate |
| `theta_requested` | Requested `UpdateFraction` |
| `eta_squared_total`, `eta_squared_marked` | Global sums of squared native indicators, over all and marked cells |
| `marked_error_fraction` | `eta_squared_marked / eta_squared_total` |
| `mesh_conformity`, `max_nc_levels` | `C` or `NC`, and the requested NC level cap |

If the total squared indicator is zero, `marked_error_fraction` is null and
`marked_error_fraction_reason` is `zero_total_indicator`. Otherwise the reason
is null. The rank record's `fine_to_coarse` entries map each owned post-refinement
`fine` index to its original pre-step `coarse` index; `refined_mesh_paths` identify
the corresponding pre-rebalance meshes. The next solve's meshes describe the
partition used for its solution.

For example, marking 10 cells and splitting 30 original parents gives a closure
factor of `30 / 10 = 3`. This measures how widely refinement spreads. Evaluate it
alongside DOFs, time and solution changes when judging refinement cost.

## Interpret residuals and the ZZ indicator

Each terminal's `main` and `recovery` objects begin with `available: false` until
that solve has returned. Available records contain:

| Field | Meaning |
|---|---|
| `algorithm`, `residual_norm` | Solver and actual norm used by its convergence test |
| `iterations`, `maximum_iterations` | Executed Krylov iterations and configured limit |
| `initial_residual` | Native residual norm before the first iteration |
| `final_residual` | Native final residual norm or recursive estimate |
| `final_residual_is_estimate` | Whether the reported residual is obtained recursively |
| `reference_residual`, `reference_residual_source` | Convergence normalization, sourced from `rhs` or `initial_residual` |
| `relative_tolerance`, `absolute_tolerance` | Native stopping tolerances |
| `converged` | Native solver convergence result |

CG uses `sqrt(abs(r^H B r))`, where `B` is the applied inverse preconditioner.
For real SPD systems this is `sqrt(r^T B r)`. Left-preconditioned GMRES uses
`||B r||_2`; right-preconditioned GMRES and FGMRES use `||r||_2`. The recorded norm
string identifies the active case. These observations do not recompute a separate
unpreconditioned residual. Nonfinite residuals are encoded explicitly as `"NaN"`,
`"Infinity"`, or `"-Infinity"`.

The solve record's `indicator_norm` is the native global ZZ indicator. For each
terminal, the gradient estimator scales its integrated elementwise flux discrepancy
with `sqrt(0.5 / total_field_energy)` when the energy is positive, or scale 1
otherwise. It combines terminal samples by the elementwise root mean square:

```text
eta_K = sqrt((1 / n_samples) * sum_n eta_Kn^2)
indicator_norm = sqrt(sum_K eta_K^2)
```

The indicator is an energy-normalized flux recovery estimate. It is distinct from
a capacitance error or an accuracy reference. Read its main and recovery solve
statuses together with its value.

The installed `scripts/schema/amr-diagnostics-v1.schema.json` file defines the
JSON fields, optional fields during partial attempts, and record types.
