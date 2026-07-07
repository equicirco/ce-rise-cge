# CE-RISE Circular Economy CGE
Computable general equilibrium model developed to support Task 3.5 of the CE-RISE research project.

## Repository Structure

- `scripts/input/`: data-preparation, validation, and benchmark-SAM construction workflow.
- `data/disaggregation/parent_and_disaggregated_rows_sup_and_use.csv`: required CE-RISE disaggregation input used by the workflow.
- `data/mappings/`: region and sector mapping tables.
- `data/artifacts/`: persisted workflow outputs from the initial source bundle to the closed benchmark SAM.
- `article/`: separate git repository for the manuscript and model-building notes.

## Public Data Scope

This public repository keeps only the disaggregation file required by the workflow from the project-specific source exchange, together with the derived benchmark artifacts needed to inspect and reproduce the model database.

Large raw FIGARO extracts in `data/raw/`, generated working tables in `data/interim/`, and the unused spreadsheet from the original exchange are excluded from version control and can be regenerated locally from the scripts.

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
