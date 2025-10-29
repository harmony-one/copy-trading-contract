// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/ICLGauge.sol";
import "./interfaces/IERC20.sol";

contract Rebalancer is Ownable, ERC721Holder {
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
        // Close existing positions first
        if (currentTokenId != 0) {
            _closeAllPositions();
        }

        IERC20 token0_ = token0();
        IERC20 token1_ = token1();
        uint256 amount0 = token0_.balanceOf(address(this));
        uint256 amount1 = token1_.balanceOf(address(this));

        // Skip creating new position if balances are too low
        // This can happen if position was closed but fees were minimal
        if (amount0 == 0 && amount1 == 0) {
            return; // No tokens to create position with
        }

        // Approve tokens for NFT Manager before minting
        token0_.approve(address(nft), amount0);
        token1_.approve(address(nft), amount1);

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

        // Try to mint new position - if it fails, we'll skip it
        try nft.mint(params) returns (uint256 tokenId, uint128, uint256, uint256) {
            currentTokenId = tokenId;
            nft.approve(address(gauge), tokenId);
            gauge.deposit(tokenId);
        } catch {
            // If mint fails (e.g., too little liquidity), skip creating new position
            // This can happen if balances are too low after closing previous position
            currentTokenId = 0;
        }
    }

    function closeAllPositions() public onlyOwner {
        _closeAllPositions();
    }

    function closeAllPositionsExternal() external onlyOwner {
        _closeAllPositions();
    }

    function _closeAllPositions() internal {
        if (currentTokenId != 0) {
            uint256 tokenId = currentTokenId;
            currentTokenId = 0; // Reset before withdraw to prevent reentrancy
            
            // Step 1: Withdraw from gauge - this will:
            // - Collect fees and send them to this contract (msg.sender)
            // - Update staking in pool (decrease staked liquidity)
            // - Return NFT to this contract via safeTransferFrom
            // IMPORTANT: gauge.withdraw() does NOT decrease the position's liquidity itself!
            gauge.withdraw(tokenId);
            
            // Step 2: Get current liquidity from the position
            // After gauge.withdraw(), the NFT is owned by this contract but still has liquidity
            (, , , , , , , uint128 currentLiquidity, , , , ) = nft.positions(tokenId);
            
            // Step 3: If position still has liquidity, decrease it completely
            if (currentLiquidity > 0) {
                // Decrease all remaining liquidity
                nft.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId: tokenId,
                        liquidity: currentLiquidity, // Decrease all liquidity
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline: block.timestamp + 1 hours
                    })
                );
                
                // Collect tokens released from liquidity decrease
                nft.collect(
                    INonfungiblePositionManager.CollectParams({
                        tokenId: tokenId,
                        recipient: address(this),
                        amount0Max: type(uint128).max,
                        amount1Max: type(uint128).max
                    })
                );
            }
            
            // Step 4: Final collect to ensure all fees and tokens are collected
            try nft.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            ) {} catch {}
            
            // Step 5: Burn the NFT - now position should be empty
            // burn() requires position to have zero liquidity and all tokens collected
            nft.burn(tokenId);
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
