# Phase 1 Submission: Platform Architecture and Sprint 0

**Candidate submission template**
**Sprint 0: 14-27 July 2026**
**Phase:** Architecture and Onboarding

---

## Section 1: Business Problem (Context)

*Describe in your own words what business problem NorthPeak is trying to solve and why a data platform is the answer.*

[YOUR ANSWER HERE - minimum 200 words]

---

## Section 2: Architecture Decision (Implementation)

*Explain the medallion architecture you are proposing and why you chose it.*

Reference: See `/architecture/ADR/ADR-001-medallion-architecture.md` which you must complete and commit before submitting this section.

[YOUR ANSWER HERE]

---

## Section 3: Technical Justification (Technical Decision)

*Why did you choose these specific tools? Cover at least 3 tool choices.*

Example structure:
- Why PySpark over plain Python for the pipeline?
- Why DuckDB as the local warehouse?
- Why dbt Core for transformations?
- Why Great Expectations for data quality?

[YOUR ANSWER HERE]

---

## Section 4: Alternative Considered

*What other architecture would have worked? Why did you not choose it?*

[YOUR ANSWER HERE]

---

## Section 5: User Stories (Azure DevOps format)

*Write 3 user stories in the standard format for the work you are about to do.*

**User Story 1:**
As a [role], I want [feature], so that [benefit].
Acceptance criteria:
- Given [context], when [action], then [outcome]

[COMPLETE USER STORIES HERE]

---

## Section 6: Production Consideration

*How would this architecture differ in a real enterprise deployment on Azure/Databricks?*

Reference: See `/architecture/cloud-mapping/local-to-azure-databricks.md`

[YOUR ANSWER HERE]

---

## Evidence Required

- [ ] ADR-001 committed to `/architecture/ADR/`
- [ ] Cloud mapping doc reviewed and annotated
- [ ] 3 user stories written above
- [ ] GitHub repository URL: https://github.com/alain-Sortnext/northpeak-data-platform
