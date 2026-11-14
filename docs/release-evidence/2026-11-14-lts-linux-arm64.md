# Direct Linux arm64 ClickHouse 26.8.28.14 qualification

The unchanged delivered SDK implementation from source cohort
`f4bc4e6d32decfaaf1a19e1033a22f3e28fc167c` passes all thirteen direct native
groups against the exact official Linux arm64 OCI artifact. This adds fixture
matrix/CI metadata and no runtime version or SDK implementation change.

The official registry resolves tag 26.8.28.14 to index
`sha256:63e02621435cde1146ab0fde66057091ee75b312d12917c0109a6a0c99bc7ce1`
and Linux arm64 manifest
`sha256:597add6eeadf0b3c562b58c9a63d9712b9a0cde4e49b68e64a697dbf2b363b25`.
The source tag `v26.8.28.14-lts` remains at commit
`3694fe07040369cef78c937311cbaac5f0555484`.

Working-tree Cabal, seven extracted sibling source distributions, and installed
Nix suite/driver/example variants each pass transport, completion, ledger,
exclusive, runner, repair, boundaries, survivors, adoption, consumer, CLI,
example and remediation: 39 required groups total, zero failures/skips. Each
fixture verifies the exact OCI manifest/platform and observed server version,
uses its own Apple Container resources and stops only its own saved handles.
The extracted-source Haskell binaries are the previously qualified f4bc4e6
archives, with an explicit data-directory overlay adding this one matrix entry;
their fixture script and Haskell implementation are unchanged. The Nix variant
uses the same additive matrix entry. This is direct Atomic qualification; this
image has no replicated, Linux-client, managed-cloud or remote-CI claim.

Private evidence roots are `.dev/candidates/lts-linux-arm64-gve0ns8e/`,
`.dev/candidates/lts-linux-source-bkcjmpm0/` and the Nix root named in
`.dev/ep53-lts-linux-nix.log`. Logs are `.dev/ep53-lts-linux-native-2.log`,
`.dev/ep53-lts-linux-source.log` and `.dev/ep53-lts-linux-nix.log`.
The first working-tree invocation refused before native execution because only
the index reference had been pulled; pulling the required exact platform
manifest resolved that preflight. That failed invocation is not a passing run.

The independent application/platform ceremony belongs to
`mori://shinzui/kansoku/plans/53-prove-shared-server-maintenance-across-deployment-platforms`.
It uses Darwin clients against reviewed Nagare Linux data services; its result
is not inferred from these SDK groups.
