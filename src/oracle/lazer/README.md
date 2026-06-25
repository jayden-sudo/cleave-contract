# Vendored Pyth Lazer parsing libraries

`PythLazerLib.sol` and `PythLazerStructs.sol` are vendored **verbatim** from
`pyth-network/pyth-crosschain` (`lazer/contracts/evm/src/`, `main`). They are pure parsing
helpers for a Pyth Lazer payload that has *already* had its signature verified.

We deliberately do **not** vendor `PythLazer.sol` (the upgradeable on-chain verifier). Cleave's
`../PythLazerOracle.sol` re-implements the (small, immutable) signature-verification step inline
against an immutable trusted signer — matching Cleave's no-admin / no-proxy ethos — and uses these
two files only for the binary payload parsing.

Upstream pragma is `^0.8.13`; the repo compiles them at the pinned `0.8.26`.

**Only deliberate modification:** the `public` function visibilities in `PythLazerLib.sol` were
changed to `internal` (mechanical, visibility-only — logic byte-identical) so the library inlines
into `PythLazerOracle` and the oracle deploys as a single self-contained immutable contract with no
external library to link or trust. To update, re-copy from upstream and re-apply
`perl -i -pe 's/\bpublic\b/internal/g'` to `PythLazerLib.sol`.
