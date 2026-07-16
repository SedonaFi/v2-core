// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { FHE, euint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @title ConfidentialUniswapV2ERC20
/// @notice Encrypted-`euint64` LP-share ledger for `ConfidentialUniswapV2Pair`.
/// @dev Deliberately minimal: LP shares are not a transferable token in this milestone (not
/// required by the PRD — see FR-P7/FR-P8), just a per-holder encrypted balance the pair mints
/// on `mint` and burns on `burn`. No sqrt is used anywhere (CoFHE has no encrypted sqrt): the
/// first mint is a declared-unit bootstrap, every later mint is proportional via `FHE.min`.
abstract contract ConfidentialUniswapV2ERC20 {
    euint64 internal _totalLPSupply;
    mapping(address => euint64) internal _lpBalances;

    /// @dev Whether the pool has received its bootstrap (first) mint yet. Plaintext by design:
    /// which mint is "first" is not sensitive (the PRD explicitly allows a plaintext-known seed
    /// for the bootstrap, FR-P7) and CoFHE cannot branch control flow on an encrypted condition.
    bool internal _lpInitialized;

    function confidentialTotalLPSupply() public view virtual returns (euint64) {
        return _totalLPSupply;
    }

    function confidentialLPBalanceOf(address owner) public view virtual returns (euint64) {
        return _lpBalances[owner];
    }

    function _mintLP(address to, euint64 amount) internal {
        _totalLPSupply = FHE.add(_totalLPSupply, amount);
        _lpBalances[to] = FHE.add(_lpBalances[to], amount);

        FHE.allowThis(_totalLPSupply);
        FHE.allowThis(_lpBalances[to]);
        FHE.allow(_lpBalances[to], to);
        FHE.allow(amount, to);
    }

    /// @dev Clamped, never-revert burn: returns the amount actually burned (<= requested,
    /// capped to the holder's balance) so callers can size the underlying token payout on the
    /// same clamp, mirroring the swap's zero-replacement pattern.
    function _burnLP(address from, euint64 amount) internal returns (euint64 burned) {
        euint64 balance = _lpBalances[from];
        burned = FHE.select(FHE.lte(amount, balance), amount, balance);

        _lpBalances[from] = FHE.sub(balance, burned);
        _totalLPSupply = FHE.sub(_totalLPSupply, burned);

        FHE.allowThis(_totalLPSupply);
        FHE.allowThis(_lpBalances[from]);
        FHE.allow(_lpBalances[from], from);
        FHE.allow(burned, from);
    }
}
