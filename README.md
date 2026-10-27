# CE-RISE Circular Economy CGE
This repository develops a Julia-based computable general equilibrium model for analysing circular-economy strategies in European electronics value chains under the CE-RISE project.

Primary and manufactured products clear through common EU markets with one EU price per product. Repair, refurbishment, reuse, waste treatment, construction, and other services remain regional; their observed net EU service balances are retained as fixed calibration terms. Trade with the rest of the world remains price-taking.

## Contents

- `data/disaggregation/`: the supplied electronics SUT extract, family-production totals from the [BONSAI V2 archive](https://doi.org/10.5281/zenodo.23342753), and discarded-equipment treatment records from the [2016 supply table](https://doi.org/10.5281/zenodo.23157221). Julia importers are in `scripts/input/`.
- `data/mappings/`: regional, sectoral, model-configuration and intervention-design inputs.
- `data/artifacts/`: persisted supply-use, input-output, and social-accounting-matrix artifacts, plus 18 verified family-production mass anchors.
- `scripts/input/`: data preparation, balancing, validation, and calibration-data construction scripts.
- `scripts/analysis/`: policy-sensitivity analysis and reproducible solution workflows.
- `src/`: the Julia implementation of the CGE model.
- `test/`: model and calibration tests.
- `equations.tex`: standalone equation listing generated directly from the model.
- `Project.toml` and `Manifest.toml`: the Julia environment.

## Reproduce policy-sensitivity solutions

Run the fiscal-instrument sweep and its documented numerical continuation workflow with:

```bash
julia --project=. scripts/analysis/reproduce_policy_sensitivity_solutions.jl --workers 10
```

The script solves the 43,740 declared policy points (2,187 sensitivity profiles,
five instruments and four wedge levels), applies numerical recovery,
and compiles `results/data/policy_outcomes.duckdb` from the saved outputs. It
retains complete economic, fiscal and physical outcomes, solved variable values,
zero-policy references, and diagnostics for unresolved points.

The information-intervention specification is in
`data/mappings/information_parameter_grid.tsv`. `policy_experiment_design()`
enumerates the 55 agreed fiscal, information and joint cases;
`policy_experiment_comparisons()` defines their matched comparisons. The
information and joint cases are specified for implementation; the current
numerical runner covers the fiscal-instrument sweep.

Repeat the same command after an interruption to resume verified checkpoints,
including completed points within a partially finished sensitivity profile.
Checksums identify damaged files; the run-input record prevents mixing different
model code or calibration inputs. A new experiment requires an empty result
directory, selectable with `--output-dir`.

Rebuild the database from the saved files independently with:

```bash
julia --project=. scripts/analysis/compile_policy_outcomes_database.jl
```

## License

Licensed under the [European Union Public Licence v1.2 (EUPL-1.2)](LICENSE).

---

<a href="https://europa.eu" target="_blank" rel="noopener noreferrer">
  <img src="https://ce-rise.eu/wp-content/uploads/2023/01/EN-Funded-by-the-EU-PANTONE-e1663585234561-1-1.png" alt="EU emblem" width="200"/>
</a>

Funded by the European Union under Grant Agreement No. 101092281 — CE-RISE.  
Views and opinions expressed are those of the author(s) only and do not necessarily reflect those of the European Union or the granting authority (HADEA).
Neither the European Union nor the granting authority can be held responsible for them.

© 2026 CE-RISE consortium.  
Licensed under the [European Union Public Licence v1.2 (EUPL-1.2)](LICENSE).  
Attribution: CE-RISE project (Grant Agreement No. 101092281) and the individual authors/partners as indicated.

<a href="https://www.nilu.com" target="_blank" rel="noopener noreferrer">
  <img src="https://nilu.no/wp-content/uploads/2023/12/nilu-logo-seagreen-rgb-300px.png" alt="NILU logo" height="20"/>
</a>

Developed by NILU (Riccardo Boero — ribo@nilu.no) within the CE-RISE project.
