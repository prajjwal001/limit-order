# Deduplication guidelines

The selected [Sherlock judging guidelines §4](judging-guidelines.md#4-duplication-guidelines) govern duplication. Engagement context cannot override these rules. The following instructions refer to a **target issue** and a **potential duplicate** of that target.

## Conditions for merging

Merge the potential duplicate with the target only when the **potential duplicate** meets all three requirements:

1. Identifies the root cause.
2. Identifies at least a Low impact.
3. Identifies a valid attack path or vulnerability path.

When all three requirements are met, all duplicates are awarded the highest severity identified among them. If the potential duplicate fails any requirement, do not group it with that target. Assess whether it duplicates another issue separately, and assess its True Finding, scope, known and severity verdicts under their respective rules. [Source: §4, requirements and consequences](judging-guidelines.md#4-duplication-guidelines).

Apply the complete [severity set](severity-set.json) to the impact requirement, with the measurement rules in [§3.4](judging-guidelines.md#34-severity). The meanings of root cause, attack path and vulnerability path are in the [glossary](judging-guidelines.md#6-glossary).

## Root cause groupings

Occurrences in multiple places, including different components, may share a root cause when they have the same logic mistake or conceptual mistake. The guidelines' example is different untrusted external admins being able to steal funds. Different underlying implementations, impacts or fixes may be treated separately. Where an issue has many duplicates, group reports that identify the core issue and show a valid impact. [Source: §4, Root cause groupings and Identifies the core issue](judging-guidelines.md#4-duplication-guidelines).

## Submission and engagement context

The participant advice says to submit issues separately, combine repeated occurrences of one root cause into one issue, and use judgment where occurrences differ. [Source: §5.10, item 3](judging-guidelines.md#510-best-practices). The same-root-cause, vulnerable-code-path and attack-vector requirements for a rewrite apply to versions within a resubmission chain. [Source: §5.5, item 4](judging-guidelines.md#55-rewrite--resubmit).

Judging and deduplication assess the finding's content, not conformity to the [finding report standard](finding-report-standard.md). The comparison requirements are those in [§4](judging-guidelines.md#4-duplication-guidelines).

Engagement statements and prior disclosures are available through [statements.json](statements.json) and the [evidence map](evidence-map.md), with authority described in [§2](judging-guidelines.md#2-order-of-authority) and known status in [§3.3](judging-guidelines.md#33-known). No additional engagement-specific duplication instructions are supplied.
