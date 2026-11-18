# OLO v1 Core security engagement

The audited code is [limitorder-org/v1-core](limitorder-org__v1-core/). The [scope manifest](context/scope.json) pins `main` at `0f7ab6a141ac82f768702cfd9da0c72e61db6403` and lists 26 files. This snapshot has no Git metadata; the revision is recorded by the manifest.

## Engagement references

| Reference | Contents |
| --- | --- |
| [Statements](context/statements.json) · [Document inventory](context/entries.json) | Engagement decisions on accepted behavior, scope and known issues, with statement IDs and levels; document descriptions, declarations and source locations. |
| [Context map](context/README.md) | JSON formats and queries for finding statements and documents. |
| [Evidence map](context/evidence-map.md) | Section links for qualification conditions, prior disclosures, design material and repository references. |
| [Repository scope rule](context/scope-rules/limitorder-org__v1-core.md) | The platform's scope rule for this repository. |
| [Judging guidelines](context/judging-guidelines.md) | Authority, validity, scope, known status, severity measurement, duplication, PoC requirements and submission mechanics. |
| [Severity set](context/severity-set.json) · [Readable definitions](context/severities.md) | Complete ordered severity definitions, including all conditions for Medium. |
| [Deduplication guidelines](context/deduplication-guidelines.md) | Source-referenced comparison requirements and grouping conditions. |
| [Finding report standard](context/finding-report-standard.md) | Guidance for writing each finding field. Judging and deduplication assess a finding's content, not whether it follows this standard. |

Statement quotes and levels are in the statements file; cite the statement ID and apply the [order of authority](context/judging-guidelines.md#2-order-of-authority). The inventory describes documents and locates their evidence.

## Protocol and code references

The [engagement context](context/context_doc_open_limit_order.md) covers the protocol, deployment environment, roles, caller responsibilities, prior disclosures and setup. Its [disclosure and design sections](context/context_doc_open_limit_order.md#6-known-issues-accepted-risks--design-decisions) contain conditions and exceptions needed when assessing a match; the [evidence map](context/evidence-map.md) locates those sections and the other statement sources.

Code entry points are [OloBook](limitorder-org__v1-core/src/OloBook.sol), [OloBookExt](limitorder-org__v1-core/src/OloBookExt.sol), and [OloSentinel](limitorder-org__v1-core/sentinel/OloSentinel.sol). Component descriptions and test locations are in the [repository README](limitorder-org__v1-core/README.md). Build and PoC setup are in [engagement context §7](context/context_doc_open_limit_order.md#7-build-test--poc-setup), the [repository build instructions](limitorder-org__v1-core/README.md#build-and-test), and [foundry.toml](limitorder-org__v1-core/foundry.toml).
