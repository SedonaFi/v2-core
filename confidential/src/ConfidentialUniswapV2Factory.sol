// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { IConfidentialUniswapV2Factory } from "./interfaces/IConfidentialUniswapV2Factory.sol";
import { ConfidentialUniswapV2Pair } from "./ConfidentialUniswapV2Pair.sol";
import { IConfidentialUniswapV2Pair } from "./interfaces/IConfidentialUniswapV2Pair.sol";

/// @title ConfidentialUniswapV2Factory
/// @notice CREATE2 registry for `ConfidentialUniswapV2Pair`s, one canonical pair per sorted
/// (token0 < token1) pair -- mirrors vanilla `UniswapV2Factory`'s deterministic-address pattern
/// exactly (same salt scheme, argument-free pair constructor) so pair addresses stay computable
/// off-chain without querying the factory.
contract ConfidentialUniswapV2Factory is IConfidentialUniswapV2Factory {
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    /// @notice Address the pool grants `FHE.allow` on its reserves to after every write, so an
    /// off-chain backend can `decryptForView` exact reserves and serve quotes (PRD FR-C6a).
    address public backendQuoteAddress;

    address public admin;

    constructor(address _backendQuoteAddress) {
        admin = msg.sender;
        backendQuoteAddress = _backendQuoteAddress;
    }

    function setBackendQuoteAddress(address _backendQuoteAddress) external {
        require(msg.sender == admin, "CUniV2: FORBIDDEN");
        backendQuoteAddress = _backendQuoteAddress;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "CUniV2: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "CUniV2: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "CUniV2: PAIR_EXISTS");

        bytes memory bytecode = type(ConfidentialUniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        require(pair != address(0), "CUniV2: CREATE2_FAILED");

        IConfidentialUniswapV2Pair(pair).initialize(token0, token1);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }
}
