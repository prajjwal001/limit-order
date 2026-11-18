# Evidence map

This is a location index. Full quotes, dimensions and statement levels are in [statements.json](statements.json); document metadata is in [entries.json](entries.json). The [judging guidelines §2](judging-guidelines.md#2-order-of-authority) state how statements apply.

## Engagement context

All sections below are in [OLO Contracts — Audit Context](context_doc_open_limit_order.md).

| Subject | Source section |
| --- | --- |
| Repository snapshot and scope tables | [§0](context_doc_open_limit_order.md#0-scope--repository-snapshot), [In scope](context_doc_open_limit_order.md#in-scope), [Out of scope](context_doc_open_limit_order.md#out-of-scope) |
| Architecture, actors and user flows | [§1](context_doc_open_limit_order.md#1-protocol-overview) |
| Component mechanics, expected inputs and intentional behavior | [§2](context_doc_open_limit_order.md#2-detailed-breakdown-by-component) |
| Chains and mempool assumptions | [§3.1](context_doc_open_limit_order.md#31-supported-chains) |
| Tokens and token qualification conditions | [§3.2](context_doc_open_limit_order.md#32-tokens) |
| Integrations and dependencies | [§3.3](context_doc_open_limit_order.md#33-external-integrations--dependencies) |
| Role trust and permissions | [§4.1](context_doc_open_limit_order.md#41-privileged-roles) |
| Parameter bounds and production values | [§4.2](context_doc_open_limit_order.md#42-configurable-parameters--valid-ranges) |
| Operational assumptions | [§4.3](context_doc_open_limit_order.md#43-olo-book-components--operational-assumptions) |
| Previous audits | [§5](context_doc_open_limit_order.md#5-previous-audits) |
| Build, tests and PoC setup | [§7](context_doc_open_limit_order.md#7-build-test--poc-setup) |
| Component topic tables | [Appendix A](context_doc_open_limit_order.md#appendix-a--topics-by-component-type) |

## Disclosures and design material

These links locate every component group in engagement context §6. They do not replace the source's triggers, impacts, limits or exceptions. The complete lookup across all sources is the `known` query in the [context map](README.md).

| Source section | Statement IDs in that section |
| --- | --- |
| [Takes](context_doc_open_limit_order.md#takes-24) | S68–S78 |
| [Pool orders and batch slots](context_doc_open_limit_order.md#pool-orders-22-and-batch-slots-23) | S79–S81 |
| [Accounts, fees and settlement](context_doc_open_limit_order.md#accounts-fees--settlement-21) | S82–S86 |
| [Tokens](context_doc_open_limit_order.md#tokens-32) | S87–S88 |
| [Extension: listing and admin](context_doc_open_limit_order.md#extension-listing--admin-27) | S89–S95 |
| [Owner timelock](context_doc_open_limit_order.md#owner-timelock-29) | S96–S101 |
| [Proprietary markets](context_doc_open_limit_order.md#proprietary-markets-210) | S102–S109 |
| [Price grid](context_doc_open_limit_order.md#price-grid-25) | S110–S111 |
| [Minor behaviours](context_doc_open_limit_order.md#minor-behaviours-kept) | S112–S117 |
| [Tests](context_doc_open_limit_order.md#tests) | S118 |
| [Design decisions](context_doc_open_limit_order.md#62-design-decisions-not-findings) | S119–S124 |

## Repository statement sources

Repository sources remain at their code paths. Each row corresponds to one document in the inventory. The engagement context occupies S1–S142; the remaining statement sources are listed below.

| Source | Statement IDs |
| --- | --- |
| [sentinel/IOloSentinel.sol](../limitorder-org__v1-core/sentinel/IOloSentinel.sol) | S143–S145 |
| [sentinel/OloSentinel.sol](../limitorder-org__v1-core/sentinel/OloSentinel.sol) | S146–S147 |
| [src/OloBook.sol](../limitorder-org__v1-core/src/OloBook.sol) | S148–S150 |
| [src/OloBookExt.sol](../limitorder-org__v1-core/src/OloBookExt.sol) | S151–S153 |
| [src/OloTypes.sol](../limitorder-org__v1-core/src/OloTypes.sol) | S154–S155 |
| [src/base/OloBookAssets.sol](../limitorder-org__v1-core/src/base/OloBookAssets.sol) | S156 |
| [src/base/OloBookBatches.sol](../limitorder-org__v1-core/src/base/OloBookBatches.sol) | S157 |
| [src/base/OloBookTakes.sol](../limitorder-org__v1-core/src/base/OloBookTakes.sol) | S158–S160 |
| [src/interfaces/IOloBookExt.sol](../limitorder-org__v1-core/src/interfaces/IOloBookExt.sol) | S161 |
| [src/interfaces/IOloFlashCallback.sol](../limitorder-org__v1-core/src/interfaces/IOloFlashCallback.sol) | S162 |
| [src/libraries/PriceGrid.sol](../limitorder-org__v1-core/src/libraries/PriceGrid.sol) | S163 |
| [Repository README](../limitorder-org__v1-core/README.md) | S164 |
| [docs/ASSEMBLY.md](../limitorder-org__v1-core/docs/ASSEMBLY.md) | S165–S174 |
| [docs/LINT.md](../limitorder-org__v1-core/docs/LINT.md) | S175–S212 |
