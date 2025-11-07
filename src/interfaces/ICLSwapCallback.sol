// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ICLSwapCallback {
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}

