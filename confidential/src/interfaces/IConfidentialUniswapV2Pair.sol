// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { euint64, InEuint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";

interface IConfidentialUniswapV2Pair {
    event ConfidentialMint(address indexed sender, address indexed to);
    event ConfidentialBurn(address indexed sender, address indexed to);
    event ConfidentialSwap(address indexed sender, address indexed to, bool zeroForOne);
    event Sync();

    function factory() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function initialize(address _token0, address _token1) external;

    function mint(InEuint64 calldata amount0Desired, InEuint64 calldata amount1Desired, address to) external returns (euint64 liquidity);

    function burn(InEuint64 calldata liquidityIn, address to) external returns (euint64 amount0, euint64 amount1);

    function swap(InEuint64 calldata amountIn, bool zeroForOne, InEuint64 calldata minAmountOut, address to) external returns (euint64 amountOut);

    function confidentialReserve0() external view returns (euint64);

    function confidentialReserve1() external view returns (euint64);

    function confidentialLPBalanceOf(address owner) external view returns (euint64);

    function confidentialTotalLPSupply() external view returns (euint64);
}
