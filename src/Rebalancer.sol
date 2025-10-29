// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/ICLGauge.sol";
import "./interfaces/IERC20.sol";

contract Rebalancer is Ownable {
    INonfungiblePositionManager public nft;
    ICLGauge public gauge;
    uint256 public currentTokenId;

    constructor(address _nft, address _gauge, address _owner) Ownable(_owner) {
        nft = INonfungiblePositionManager(_nft);
        gauge = ICLGauge(_gauge);
    }

    function token0() public view returns (IERC20) {
        return IERC20(gauge.token0());
    }

    function token1() public view returns (IERC20) {
        return IERC20(gauge.token1());
    }

    function tickSpacing() public view returns (int24) {
        return gauge.tickSpacing();
    }

    function deposit(uint256 amount0, uint256 amount1) external onlyOwner {
        IERC20 token0_ = token0();
        IERC20 token1_ = token1();
        require(token0_.transferFrom(msg.sender, address(this), amount0), "transfer token0 failed");
        require(token1_.transferFrom(msg.sender, address(this), amount1), "transfer token1 failed");
    }

    function rebalance(int24 tickLower, int24 tickUpper) external onlyOwner {
        closeAllPositions();

        IERC20 token0_ = token0();
        IERC20 token1_ = token1();
        uint256 amount0 = token0_.balanceOf(address(this));
        uint256 amount1 = token1_.balanceOf(address(this));

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(token0_),
            token1: address(token1_),
            tickSpacing: tickSpacing(),
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 1 hours,
            sqrtPriceX96: 0
        });

        (uint256 tokenId, , , ) = nft.mint(params);
        currentTokenId = tokenId;
        nft.approve(address(gauge), tokenId);
        gauge.deposit(tokenId);
    }

    function closeAllPositions() public onlyOwner {
        if (currentTokenId != 0) {
            gauge.withdraw(currentTokenId);
            nft.collect(INonfungiblePositionManager.CollectParams(currentTokenId, address(this), type(uint128).max, type(uint128).max));
            nft.decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams(currentTokenId, type(uint128).max, 0, 0, block.timestamp + 1 hours));
            nft.burn(currentTokenId);
            currentTokenId = 0;
        }
    }

    function withdrawAll() external onlyOwner {
        IERC20 token0_ = token0();
        IERC20 token1_ = token1();
        require(token0_.transfer(owner(), token0_.balanceOf(address(this))), "withdraw token0 failed");
        require(token1_.transfer(owner(), token1_.balanceOf(address(this))), "withdraw token1 failed");
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }
}
