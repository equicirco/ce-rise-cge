# CE-RISE Circular Economy CGE
This repository develops a Julia-based computable general equilibrium model for analysing circular-economy strategies in European electronics value chains under the CE-RISE project.

## Contents

- `data/disaggregation/`: CE-RISE disaggregation input used in the data workflow.
- `data/mappings/`: regional, sectoral, and model-configuration mappings.
- `data/artifacts/`: persisted supply-use, input-output, and social-accounting-matrix artifacts.
- `scripts/input/`: data preparation, balancing, validation, and calibration-data construction scripts.
- `src/`: the Julia implementation of the CGE model.
- `test/`: model and calibration tests.
- `Project.toml` and `Manifest.toml`: the Julia environment.

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
