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

    // Events for error logging
    event RebalanceError(string operation, bytes reason);
    event IncreaseLiquidityError(bytes reason);
    event MintError(bytes reason);
    event CollectError(bytes reason);

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

    function rewardToken() public view returns (IERC20) {
        return IERC20(gauge.rewardToken());
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

        // Skip creating new position only if both tokens are zero
        // Uniswap V3 can create positions with just one token if price is outside tick range:
        // - If price > tickUpper: only token0 is needed
        // - If price < tickLower: only token1 is needed
        // - If price is within range: both tokens are needed (proportional to current price)
        if (amount0 == 0 && amount1 == 0) {
            return; // No tokens to create position with
        }

        // Approve tokens for NFT Manager before minting
        // It's safe to approve zero amounts - ERC20 approve handles this
        if (amount0 > 0) {
            token0_.approve(address(nft), amount0);
        }
        if (amount1 > 0) {
            token1_.approve(address(nft), amount1);
        }

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
        try nft.mint(params) returns (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
            currentTokenId = tokenId;
            
            // Check if there are unused tokens remaining
            // Uniswap V3 mint may use less than desired amounts if price is outside tick range
            // or if proportions don't match the current pool price
            // When one token is zero, only the other will be used (if price allows)
            uint256 amount0Remaining = amount0 > amount0Used ? amount0 - amount0Used : 0;
            uint256 amount1Remaining = amount1 > amount1Used ? amount1 - amount1Used : 0;
            
            // CRITICAL: increaseLiquidity must be called BEFORE depositing to gauge!
            // According to NonfungiblePositionManager reference implementation:
            // - If position is staked (owned by gauge), only gauge can call increaseLiquidity
            // - We must add remaining liquidity while we still own the NFT (before gauge.deposit)
            // - After deposit, the NFT ownership transfers to gauge and we cannot modify it directly
            if ((amount0Remaining > 0 || amount1Remaining > 0) && liquidity > 0) {
                // Approve remaining tokens for increaseLiquidity
                if (amount0Remaining > 0) {
                    token0_.approve(address(nft), amount0Remaining);
                }
                if (amount1Remaining > 0) {
                    token1_.approve(address(nft), amount1Remaining);
                }
                
                // Add remaining liquidity BEFORE depositing to gauge
                // This ensures we can use all available tokens while we own the position
                try nft.increaseLiquidity(
                    INonfungiblePositionManager.IncreaseLiquidityParams({
                        tokenId: tokenId,
                        amount0Desired: amount0Remaining,
                        amount1Desired: amount1Remaining,
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline: block.timestamp + 1 hours
                    })
                ) returns (uint128, uint256, uint256) {
                    // Successfully added remaining liquidity
                    // Now all available tokens are used in the position
                } catch (bytes memory reason) {
                    // If increaseLiquidity fails, remaining tokens will stay in contract
                    // They can be withdrawn later or used in next rebalance
                    // This is especially useful when one token has run out - we can continue
                    // rebalancing with the remaining token
                    emit IncreaseLiquidityError(reason);
                }
            }
            
            // Approve and deposit to gauge AFTER increasing liquidity
            // Once deposited, the gauge owns the NFT and we cannot modify it directly
            // If we need to increase liquidity later, we'd need to withdraw first
            nft.approve(address(gauge), tokenId);
            gauge.deposit(tokenId);
        } catch (bytes memory reason) {
            // If mint fails, it could be due to:
            // 1. Insufficient liquidity in the pool for the tick range
            // 2. Invalid tick range
            // 3. Both tokens are zero (shouldn't reach here due to early return)
            // 4. Price movement makes the position impossible to create
            // 5. Amount is too small (even with one token, minimum liquidity requirements may not be met)
            // In any case, we skip creating new position and keep currentTokenId as 0
            // This allows the contract to continue operating - tokens remain in contract
            // and can be used in next rebalance when more tokens are available
            emit MintError(reason);
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
            ) {} catch (bytes memory reason) {
                emit CollectError(reason);
            }
            
            // Step 5: Burn the NFT - now position should be empty
            // burn() requires position to have zero liquidity and all tokens collected
            try nft.burn(tokenId) {} catch (bytes memory reason) {
                emit RebalanceError("burn", reason);
            }
        }
    }

    function withdrawAll() external onlyOwner {
        IERC20 token0_ = token0();
        IERC20 token1_ = token1();
        require(token0_.transfer(owner(), token0_.balanceOf(address(this))), "withdraw token0 failed");
        require(token1_.transfer(owner(), token1_.balanceOf(address(this))), "withdraw token1 failed");
    }

    /// @notice Withdraw all AERO reward tokens to owner
    /// @dev Gets the reward token address from the gauge contract and transfers all balance to owner
    function withdrawRewards() external onlyOwner {
        IERC20 rewardToken_ = rewardToken();
        uint256 balance = rewardToken_.balanceOf(address(this));
        require(rewardToken_.transfer(owner(), balance), "withdraw rewards failed");
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }
}
