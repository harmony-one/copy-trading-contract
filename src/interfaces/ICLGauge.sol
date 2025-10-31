// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ICLGauge {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
    function rewardToken() external view returns (address);
    function deposit(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
}

