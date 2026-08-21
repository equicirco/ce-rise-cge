# CE-RISE Circular Economy CGE Changelog
All notable changes to this project will be documented in this file.
Releases use semantic versioning as in 'MAJOR.MINOR.PATCH'.

## Change entries
Added: For new features that have been added.
Changed: For changes in existing functionality.
Deprecated: For once-stable features removed in upcoming releases.
Removed: For features removed in this release.
Fixed: For any bug fixes.
Security: For vulnerabilities.

## [0.1.0] - Unreleased
### Added
- Initial public repository structure for the CE-RISE CGE benchmark-construction workflow.
- Julia scripts to construct staged benchmark artifacts from FIGARO-based supply and use data and the CE-RISE disaggregation input.
- Persisted public workflow outputs covering the initial source bundle, integrated SUT, final explicit SUT, balanced SUT, core SAM, and closed SAM.
- Validation reports for the staged artifact chain and public-data scope curation for the repository.
- Generic normalized physical-flow links for the 78 directly observed CE-RISE flows, with base-year tonne anchors and scenario projection through JCGEOutput.
- Baseline tests covering physical-flow links, anchors, projections, and calibration-driver diagnostics.
- Checkpointed policy-grid execution with one persistent status record and result file per sensitivity profile, plus a command-line status report for live monitoring and safe restart.

### Changed
- Replaced bilateral intra-European Armington/CET trade with common EU product markets for primary and manufactured products. Regional services retain fixed calibrated net EU balances and do not relocate endogenously across regions.
- Updated the model environment to the registered JCGEBlocks 0.1.7 and JCGEOutput 0.1.4 releases.
- Tightened the data-configured Ipopt convergence tolerances used for calibration replication.
- Policy scenarios now retain per-point solver time and retry counts, while a configured Ipopt CPU-time limit records hard points as numerical rejections instead of allowing a worker to run indefinitely.
