# Vendored sources

All Solidity dependencies are ordinary files in this project. Building and testing needs no network once the pinned Solidity compiler and Foundry are available.

- `lib/forge-std/src/`: forge-std v1.9.6, commit `3b20d60d14b343ee4f908cb8079495c07f5e8981`. Test-only dependency. Original MIT and Apache-2.0 licenses are alongside the source. [Upstream](https://github.com/foundry-rs/forge-std/tree/3b20d60d14b343ee4f908cb8079495c07f5e8981).
- `src/libraries/FullMath.sol`: Uniswap v3-core v1.0.0, commit `e3589b192d0be27e100cd0daaf6c97204fdb1899`, MIT. Retains the upstream Remco Bloemen attribution. Adapted to Solidity 0.8.26 using explicit unchecked modular arithmetic, memory-safe assembly and a custom error; unused rounding-up helper removed. [Original](https://github.com/Uniswap/v3-core/blob/e3589b192d0be27e100cd0daaf6c97204fdb1899/contracts/libraries/FullMath.sol).
- `src/libraries/TickMath.sol`: same v3-core release, GPL-2.0-or-later. Retains `getSqrtRatioAtTick`; unused inverse function removed. Updated pragma, explicit casts, maximum-uint syntax and custom error. [Original](https://github.com/Uniswap/v3-core/blob/e3589b192d0be27e100cd0daaf6c97204fdb1899/contracts/libraries/TickMath.sol).
- `src/libraries/PoolOracle.sol`: adapts the consult and quote arithmetic from Uniswap v3-periphery's GPL-2.0-or-later [OracleLibrary](https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/OracleLibrary.sol). Adds bounded response copying, explicit ABI validation, accumulator wrap handling under Solidity 0.8 and failure results for invalid observations. No external library linking or deployment.

The vault and its GPL-marked supporting source are GPL-2.0-or-later; `LICENSE` contains GPL v2. Individual file SPDX notices and vendored licenses govern their respective files.
