# `test/archive/` — tests for the archived Path B contracts

Unit tests and mocks for the archived `src/archive/**` Path-B stack
(`ZuitzerlandVerifier`, `NoirVerifierWrapper`, provider adapters). They still compile and pass;
they are segregated here because Path B is cut from the shipping product — see
`../../src/archive/README.md` and STATUS.md verdict #1 for the rationale.

`script/archive/Deploy.s.sol` is the matching (archived) deploy script for this stack.
