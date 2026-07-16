// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { CofheTest } from "@cofhe/foundry-plugin/contracts/CofheTest.sol";
import { FHE, euint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";

contract SanityTest is CofheTest {
    function setUp() public {
        deployMocks();
    }

    function test_basicAdd() public {
        euint64 a = FHE.asEuint64(2);
        euint64 b = FHE.asEuint64(3);
        euint64 c = FHE.add(a, b);
        expectPlaintext(c, uint64(5));
    }
}
