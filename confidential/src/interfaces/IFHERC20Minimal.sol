// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { euint64, InEuint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @notice Minimal ERC-7984 / FHERC20 surface the confidential pool depends on.
/// @dev Matches `fhenix-confidential-contracts`' `FHERC20`/`IFHERC20` (confidentialTransfer,
/// confidentialTransferFrom, setOperator, confidentialBalanceOf). Depending on the interface
/// (not the concrete FHERC20 base) keeps the pool decoupled from whichever wrapper package
/// backs a given token.
interface IFHERC20Minimal {
    function confidentialTransfer(address to, euint64 amount) external returns (euint64 transferred);

    function confidentialTransferFrom(address from, address to, euint64 amount) external returns (euint64 transferred);

    function confidentialTransferFrom(
        address from,
        address to,
        InEuint64 memory amount
    ) external returns (euint64 transferred);

    function confidentialBalanceOf(address account) external view returns (euint64);

    function setOperator(address operator, uint48 until) external;

    function isOperator(address holder, address spender) external view returns (bool);
}
