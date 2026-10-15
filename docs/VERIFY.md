# Verification handoff: robin.etherscan.io

Verification belongs to the authorized deployer after confirmed addresses are supplied. This job
has not deployed, broadcast, called RPCs or submitted verification. The explorer for the requested
chain 4663 is [robin.etherscan.io](https://robin.etherscan.io).

Use the exact source tree and vendored imports: Solidity 0.8.26, Cancun, via-IR, optimizer enabled
with 1 run, bytecode_hash none, cbor_metadata false. Standard JSON input preserves these settings.
No application has library links. Leave the supplied Foundry configuration unchanged.

| Source identifier | Constructor arguments in declaration order |
|---|---|
| src/PadToken.sol:PadToken | none |
| src/PadGame.sol:PadGame | none |
| src/PvPPad.sol:PvPPad | owner, tokenTemplate, gameTemplate |
| src/PadLiquidity.sol:PadLiquidity | poolManager, pad, imd |
| src/KingOfThePad.sol:KingOfThePad | pad, liquidity, dev |

Deploy all five atomically, with zero value, using the validated launch.json. Owner and dev are
`$owner`, resolving to `0x5b95a971b4583a5f011e9da082acdd679b870d06`.
PoolManager is the inherited `0x8366a39cc670b4001a1121b8f6a443a643e40951`.
IMD is the specified `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` (18 decimals).
There is no pool-id constructor argument. Use the confirmed addresses of this fresh deployment
for references, never addresses from an earlier launch.

At the end of deployment, templates have zero supply and empty name/symbol; pad.launchCount is
zero, liquidity.poolCount is zero and no hook exists. Neither the supplied `nobuy` name nor any
other name creates a launch token. No initialization call follows the constructors.

Opening later is the application's intentional launch action. Mine its salt for the new
PadLiquidity address and hookInitCodeHash; the address mask must be exactly 0x2000 under 0x3fff.
Verify the resulting `src/PadHook.sol:PadHook` with `(poolManager, liquidity)` arguments. Official
EIP-1167 token/game clones use the sealed templates and are identified by PvPPad.tokenOf,
gameOf and isGame. Their initializers run atomically with creation.

The deployer's public-opening review should independently check the actual manager's code,
exttload Lock slot and pool-state layout, the configured IMD's behavior, permissions and transfer
availability, and graduation/settlement on the target chain. These are handoff requirements, not
claims that the offline tests verified live dependencies. Obtain legal review and an independent
audit before public launch. No oracle, backend signer, key, or venue pool is required by the app.

Local handoff checks:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xd6321f3461e845380299a439f8370d678c37b29a7be1fd0dbac3b3e4f390e402 forge test
python3 tools/validate_manifest.py
```

AtomicDeploymentTest includes raw CREATE2 deployment, code deposits, calldata, and intrinsic gas,
then checks the combined budget with later opening. The actual deployment service must still
simulate its complete factory transaction and enforce the 16,777,216 ceiling.
