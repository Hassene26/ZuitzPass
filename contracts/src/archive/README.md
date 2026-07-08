# `src/archive/` — Path B (ERC-7812 membership gate), archived

These contracts implement the **original Path B** design: a generic ZK membership gate
(`ZuitzerlandVerifier`) that authenticated users by proving membership in an ERC-7812
Evidence Registry via a Noir-exported Solidity verifier (`NoirVerifierWrapper`), with
per-provider root-recency adapters (`BaseProviderAdapter` → `RarimoAdapter`,
`ZkPassportAdapter`) and the `IZuitzerland` interfaces.

**Why they are archived (STATUS.md verdict #1):** the Ethereum ERC-7812 singleton
(`0x781246…7812`) is deployed but empty — zero registrars, no users — so a gate against it
authenticates nobody. Path B is **cut from the shipping product** in favour of consuming
providers' own live verifiers (see `ARCHITECTURE_UPDATED.md`). The code here is **correct,
not wrong** (the SMT fixture Checks 1 & 2 passed against a real dl-solarity tree); it is kept
in-tree as reference and becomes relevant only if a live ERC-7812 registrar ever appears — at
which point it resurfaces as the Phase-3 claims-SMT + per-app-nullifier path
(`ARCHITECTURE_UPDATED.md` §4). Until then: no maintenance, excluded from the product deploy.

Nothing outside `src/archive/` and `test/archive/` imports these files. The active product is
`ClaimsRegistry` + `StatementRegistry` + the issuer gates (`ZuitzPassExecutor`, `WorldIDGate`).
The dormant Phase-3 circuit lives at `../../membership_proof/` (untouched).
