// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { FHERC20 } from "fhenix-confidential-contracts/contracts/FHERC20/FHERC20.sol";
import { euint64, InEuint64, FHE } from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @notice Test-only FHERC20 (ERC-7984) token with an open mint, so tests can seed pools and
/// swap without standing up the full shield/wrapper stack. Real package
/// `fhenix-confidential-contracts` (0.3.1) installed cleanly -- this is NOT a hand-rolled mock of
/// the token standard itself, only of the "who can mint" policy.
contract MockFHERC20 is FHERC20 {
    constructor(
        string memory name_,
        string memory symbol_
    ) FHERC20(name_, symbol_, 6, "") {}

    function mint(address to, uint64 amount) external {
        _mint(to, FHE.asEuint64(amount));
    }

    function mintEncrypted(address to, InEuint64 memory amount) external {
        _mint(to, FHE.asEuint64(amount));
    }
}
