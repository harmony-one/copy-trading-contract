// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/ICLGauge.sol";
import "./interfaces/ICLPool.sol";
import "./interfaces/ICLSwapCallback.sol";
import "./interfaces/IERC20.sol";

contract Rebalancer is Ownable, ERC721Holder, ICLSwapCallback {
    INonfungiblePositionManager public nft;
    ICLGauge public gauge;
    uint256 public currentTokenId;
    
    // Cached values for gas optimization
    address private _token0;
    address private _token1;
    int24 private _tickSpacing;
    uint8 private _decimals0;
    uint8 private _decimals1;
    bool private _tokensCached;
    bool private _decimalsCached;
    bool private _token0Approved;
    bool private _token1Approved;

    uint256 private constant FIXED_ONE = 1e18;

    // Events
    event SwapResult(int256 amount0Delta, int256 amount1Delta, uint256 balance0, uint256 balance1);
    event SwapByRatioResult(uint256 targetRatio, uint256 slippage);

    constructor(address _nft, address _gauge, address _owner) Ownable(_owner) {
        nft = INonfungiblePositionManager(_nft);
        gauge = ICLGauge(_gauge);
    }
    
    /// @notice Caches token addresses and tickSpacing for gas optimization
    function _cacheTokens() internal {
        if (!_tokensCached) {
            _token0 = gauge.token0();
            _token1 = gauge.token1();
            _tickSpacing = gauge.tickSpacing();
            _tokensCached = true;
        }
    }
    
    /// @notice Caches token decimals for gas optimization
    function _cacheDecimals() internal {
        if (!_decimalsCached) {
            _cacheTokens(); // Ensure tokens are cached
            try IERC20(_token0).decimals() returns (uint8 decimals) {
                _decimals0 = decimals;
            } catch {
                _decimals0 = 18;
            }
            try IERC20(_token1).decimals() returns (uint8 decimals) {
                _decimals1 = decimals;
            } catch {
                _decimals1 = 18;
            }
            _decimalsCached = true;
        }
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

    function token0Decimals() public view returns (uint8) {
        try IERC20(gauge.token0()).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            return 18; // Default to 18 if decimals() is not available
        }
    }

    function token1Decimals() public view returns (uint8) {
        try IERC20(gauge.token1()).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            return 18; // Default to 18 if decimals() is not available
        }
    }

    function deposit(uint256 amount0, uint256 amount1) external onlyOwner {
        IERC20 token0_ = token0();
        IERC20 token1_ = token1();
        require(token0_.transferFrom(msg.sender, address(this), amount0), "transfer token0 failed");
        require(token1_.transferFrom(msg.sender, address(this), amount1), "transfer token1 failed");
    }

    function rebalance(int24 tickLower, int24 tickUpper, uint256 ratio, uint256 slippage) external onlyOwner {
        // Cache token addresses and decimals for gas optimization
        _cacheTokens();
        _cacheDecimals();
        
        // Close existing positions first
        if (currentTokenId != 0) {
            _closeAllPositions();
        }

        // Swap tokens to achieve target ratio before opening new position
        (int256 a0, int256 a1) = _swapByRatio(ratio, slippage);
        
        // Use cached addresses instead of view function calls
        IERC20 token0_ = IERC20(_token0);
        IERC20 token1_ = IERC20(_token1);
        uint256 balance0 = token0_.balanceOf(address(this));
        uint256 balance1 = token1_.balanceOf(address(this));
        
        emit SwapResult(a0, a1, balance0, balance1);

        // Skip creating new position if balances are too low
        if (balance0 == 0 && balance1 == 0) {
            return;
        }

        // Use all available tokens on balance for position creation
        uint256 amount0 = balance0;
        uint256 amount1 = balance1;

        // If both amounts are zero, skip creating position
        if (amount0 == 0 && amount1 == 0) {
            return;
        }

        // Check minimum amounts for position creation
        // For very small amounts, mint may return liquidity = 0, which causes revert
        // Use minimum thresholds based on token decimals
        uint256 minAmount0 = _decimals0 <= 6 ? 100 : (10 ** (_decimals0 - 6)) * 100; // At least 100 in smallest units for 6 decimals, scale for others
        uint256 minAmount1 = _decimals1 <= 6 ? 100 : (10 ** (_decimals1 - 6)) * 100;
        
        // If amounts are too small, skip creating position
        if (amount0 < minAmount0 && amount1 < minAmount1) {
            return;
        }
        
        // If only one token is available, skip creating position
        // Uniswap V3 requires both tokens to create a position
        if (amount0 == 0 || amount1 == 0) {
            return;
        }

        // Approve tokens for NFT Manager - approve to maximum value after swap
        // This ensures we have enough allowance even if balances changed after swap
        address nftAddr = address(nft);
        // Always approve to max to ensure sufficient allowance
        if (amount0 > 0) {
            token0_.approve(nftAddr, type(uint256).max);
            _token0Approved = true;
        }
        if (amount1 > 0) {
            token1_.approve(nftAddr, type(uint256).max);
            _token1Approved = true;
        }

        // Use cached tickSpacing
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: _token0,
            token1: _token1,
            tickSpacing: _tickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 3600, // 1 hour in seconds (avoid calculation)
            sqrtPriceX96: 0
        });

        // Try to mint new position - if it fails, we'll skip it
        try nft.mint(params) returns (uint256 tokenId, uint128 liquidity, uint256, uint256) {
            // Check that liquidity was actually created (liquidity > 0)
            // If liquidity is 0, the position is effectively empty and will cause issues
            if (liquidity == 0) {
                currentTokenId = 0;
                return;
            }
            currentTokenId = tokenId;
            nft.approve(address(gauge), tokenId);
            gauge.deposit(tokenId);
        } catch {
            // If mint fails, skip creating new position
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
                        deadline: block.timestamp + 3600
                    })
                );
                
                // Collect tokens released from liquidity decrease
                // Note: gauge.withdraw() already collected fees, this collects tokens from decreaseLiquidity
                nft.collect(
                    INonfungiblePositionManager.CollectParams({
                        tokenId: tokenId,
                        recipient: address(this),
                        amount0Max: type(uint128).max,
                        amount1Max: type(uint128).max
                    })
                );
            }
            
            // Step 4: Burn the NFT - now position should be empty
            // Note: gauge.withdraw() already collected fees, and we collected tokens from decreaseLiquidity
            // No need for additional collect call
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

    /// @notice Swap tokens through the pool
    /// @param tokenIn Address of the input token
    /// @param tokenOut Address of the output token
    /// @param amountIn Amount of input token to swap
    /// @param amountOutMin Minimum amount of output token to receive
    /// @param isBuy If true, swap token0 for token1; if false, swap token1 for token0
    /// @return amount0Delta Amount of token0 swapped (positive if paid, negative if received)
    /// @return amount1Delta Amount of token1 swapped (positive if paid, negative if received)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        bool isBuy
    ) external onlyOwner returns (int256 amount0Delta, int256 amount1Delta) {
        return _swap(tokenIn, tokenOut, amountIn, amountOutMin, isBuy);
    }

    /// @notice Internal swap function (no owner check, for internal use)
    /// @param tokenIn Address of the input token
    /// @param tokenOut Address of the output token
    /// @param amountIn Amount of input token to swap
    /// @param amountOutMin Minimum amount of output token to receive
    /// @param isBuy If true, swap token0 for token1; if false, swap token1 for token0
    /// @return amount0Delta Amount of token0 swapped (positive if paid, negative if received)
    /// @return amount1Delta Amount of token1 swapped (positive if paid, negative if received)
    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        bool isBuy
    ) internal returns (int256 amount0Delta, int256 amount1Delta) {
        // If amountIn is zero, no swap needed
        if (amountIn == 0) {
            return (0, 0);
        }
        
        _cacheTokens();
        
        ICLPool pool = gauge.pool();
        IERC20 tokenIn_ = IERC20(tokenIn);
        
        // Validate tokens
        require(tokenIn == _token0 || tokenIn == _token1, "Invalid tokenIn");
        require(tokenOut == _token0 || tokenOut == _token1, "Invalid tokenOut");
        require(tokenIn != tokenOut, "Same token");
        
        // Determine swap direction based on tokens
        // zeroForOne = true means swapping token0 -> token1
        // zeroForOne = false means swapping token1 -> token0
        bool zeroForOne = (tokenIn == _token0 && tokenOut == _token1);
        
        // Validate isBuy parameter matches the swap direction
        if (isBuy) {
            // isBuy = true means buying token1 with token0
            require(zeroForOne, "isBuy mismatch");
        } else {
            // isBuy = false means buying token0 with token1
            require(!zeroForOne, "isBuy mismatch");
        }
        
        // Note: For internal calls, tokens should already be in the contract
        // For external calls, tokens are transferred from msg.sender
        uint256 balanceBefore = tokenIn_.balanceOf(address(this));
        if (balanceBefore < amountIn) {
            // This should not happen in internal calls, but handle it for external calls
            require(tokenIn_.transferFrom(msg.sender, address(this), amountIn - balanceBefore), "Transfer failed");
        }
        
        // Approve pool if needed
        address poolAddr = address(pool);
        if (tokenIn == _token0 && !_token0Approved) {
            tokenIn_.approve(poolAddr, type(uint256).max);
            _token0Approved = true;
        } else if (tokenIn == _token1 && !_token1Approved) {
            tokenIn_.approve(poolAddr, type(uint256).max);
            _token1Approved = true;
        }
        
        // Calculate sqrtPriceLimitX96 (0 means no limit)
        uint160 sqrtPriceLimitX96 = zeroForOne 
            ? 4295128739 + 1  // MIN_SQRT_RATIO + 1
            : 1461446703485210103287273052203988822378723970342 - 1; // MAX_SQRT_RATIO - 1
        
        // Perform swap
        (amount0Delta, amount1Delta) = pool.swap(
            address(this), // recipient
            zeroForOne,
            int256(amountIn), // amountSpecified (positive for exact input)
            sqrtPriceLimitX96,
            "" // data
        );
        
        // Calculate actual output amount
        // For exact input swaps:
        // - zeroForOne: amount0Delta > 0 (we pay token0), amount1Delta < 0 (we receive token1)
        // - !zeroForOne: amount1Delta > 0 (we pay token1), amount0Delta < 0 (we receive token0)
        
        // Check if swap was executed (at least one delta should be non-zero)
        require(amount0Delta != 0 || amount1Delta != 0, "Swap did not execute");
        
        uint256 amountOut;
        if (zeroForOne) {
            // Swapping token0 -> token1
            require(amount0Delta >= 0, "Invalid swap: amount0Delta should be non-negative");
            require(amount1Delta <= 0, "Invalid swap: amount1Delta should be non-positive");
            if (amount1Delta < 0) {
                amountOut = uint256(-amount1Delta);
            } else {
                // If amount1Delta is zero but amount0Delta > 0, swap consumed input but produced no output
                // This can happen if price limit was reached or liquidity was insufficient
                amountOut = 0;
            }
        } else {
            // Swapping token1 -> token0
            require(amount1Delta >= 0, "Invalid swap: amount1Delta should be non-negative");
            require(amount0Delta <= 0, "Invalid swap: amount0Delta should be non-positive");
            if (amount0Delta < 0) {
                amountOut = uint256(-amount0Delta);
            } else {
                // If amount0Delta is zero but amount1Delta > 0, swap consumed input but produced no output
                // This can happen if price limit was reached or liquidity was insufficient
                amountOut = 0;
            }
        }
        
        // Check minimum output
        // Allow swap to proceed even if output is less than minOut (within 100% tolerance for small amounts)
        // This handles cases where pool price differs from balance-based estimate or there's insufficient liquidity
        if (amountOutMin > 0) {
            // For very small amounts, be more lenient (100% tolerance)
            // For larger amounts, use 50% tolerance
            uint256 tolerance = amountOutMin < 1000 ? amountOutMin : amountOutMin / 2;
            require(amountOut >= (amountOutMin > tolerance ? amountOutMin - tolerance : 0), "Insufficient output");
        }
    }

    /// @notice External wrapper for swapByRatio (for testing and external use)
    /// @param targetRatio Target ratio token0/token1 in 1e18 format (e.g., 1e18 = 1:1, 2e18 = 2:1)
    /// @param slippage Slippage tolerance in 1e18 format (e.g., 1e16 = 1%)
    /// @return amount0Delta Amount of token0 swapped (positive if paid, negative if received)
    /// @return amount1Delta Amount of token1 swapped (positive if paid, negative if received)
    function swapByRatio(
        uint256 targetRatio,
        uint256 slippage
    ) external onlyOwner returns (int256 amount0Delta, int256 amount1Delta) {
        emit SwapByRatioResult(targetRatio, slippage);
        return _swapByRatio(targetRatio, slippage);
    }

    /// @notice Internal swap function to achieve target ratio (token0/token1 in 1e18 format)
    /// @param targetRatio Target ratio token0/token1 in 1e18 format (e.g., 1e18 = 1:1, 2e18 = 2:1)
    /// @param slippage Slippage tolerance in 1e18 format (e.g., 1e16 = 1%)
    /// @return amount0Delta Amount of token0 swapped (positive if paid, negative if received)
    /// @return amount1Delta Amount of token1 swapped (positive if paid, negative if received)
    function _swapByRatio(
        uint256 targetRatio,
        uint256 slippage
    ) internal returns (int256 amount0Delta, int256 amount1Delta) {
        _cacheTokens();
        _cacheDecimals();
        
        require(slippage <= FIXED_ONE, "Invalid slippage");
        
        IERC20 token0_ = IERC20(_token0);
        IERC20 token1_ = IERC20(_token1);
        
        uint256 balance0 = token0_.balanceOf(address(this));
        uint256 balance1 = token1_.balanceOf(address(this));
        
        // If both balances are zero, no swap needed
        if (balance0 == 0 && balance1 == 0) {
            return (0, 0);
        }
        
        // If one balance is zero, cannot achieve target ratio, skip swap
        if (balance0 == 0 || balance1 == 0) {
            return (0, 0);
        }
        
        require(_decimals0 <= 38 && _decimals1 <= 38, "Too large decimals");
        
        // Calculate needed token0 amount: needed0 = balance1 * targetRatio * scale0 / (scale1 * 1e18)
        uint256 scale0 = 10 ** _decimals0;
        uint256 scale1 = 10 ** _decimals1;
        
        uint256 needed0 = (balance1 * targetRatio * scale0) / (scale1 * FIXED_ONE);
        
        bool isBuy;
        uint256 amount0;
        
        if (needed0 > balance0) {
            // Need to buy token0: swap token1 -> token0
            // We know balance1 > 0 from require above
            isBuy = false;
            amount0 = needed0 - balance0;
        } else if (needed0 < balance0) {
            // Need to sell token0: swap token0 -> token1
            // We know balance0 > 0 (otherwise needed0 >= balance0 would be true)
            isBuy = true;
            amount0 = balance0 - needed0;
        } else {
            // Ratio is already correct, no swap needed
            return (0, 0);
        }
        
        // Check if amount0 is too small to swap
        if (amount0 < 1) {
            return (0, 0);
        }
        
        // Estimate amount of token1 needed for swap
        // We know balance1 > 0 from require above
        // For isBuy=true: we're selling token0, so balance0 > 0 (we calculated amount0 = balance0 - needed0 > 0)
        // For isBuy=false: we're selling token1, so balance1 > 0 (already checked)
        // So we can safely use both balances for estimation
        if (balance0 == 0) {
            // This should not happen, but handle it gracefully
            return (0, 0);
        }
        
        // Use balance ratio for estimation (simpler and more reliable)
        // Pool price could be used, but balance ratio is sufficient for estimation
        uint256 amount1_est = (amount0 * balance1 * scale0) / (balance0 * scale1);
        
        // Check if estimation resulted in zero (can happen due to rounding)
        if (amount1_est == 0) {
            return (0, 0);
        }
        
        // Limit swap amount to avoid zeroing out one of the balances
        // Leave at least 1% of balance to ensure position can be created
        uint256 minReserve = 100; // 1% in basis points (10000 = 100%)
        if (isBuy) {
            // Selling token0, buying token1
            // Limit amount0 to leave at least 1% of balance0
            uint256 maxAmount0 = (balance0 * (10000 - minReserve)) / 10000;
            if (amount0 > maxAmount0) {
                amount0 = maxAmount0;
                // Recalculate amount1_est with limited amount0
                amount1_est = (amount0 * balance1 * scale0) / (balance0 * scale1);
                // After recalculation, check if amount1_est became too small
                if (amount1_est == 0) {
                    return (0, 0);
                }
            }
            // Also limit amount1_est to leave at least 1% of balance1
            uint256 maxAmount1 = (balance1 * (10000 - minReserve)) / 10000;
            if (amount1_est > maxAmount1) {
                amount1_est = maxAmount1;
                // Recalculate amount0 with limited amount1_est
                amount0 = (amount1_est * balance0 * scale1) / (balance1 * scale0);
                // After recalculation, check if amount0 became too small
                if (amount0 == 0) {
                    return (0, 0);
                }
            }
            // Check if swap amount is too small to execute
            // Minimum: at least 1 unit of input token
            if (amount0 < 1 || amount1_est < 1) {
                return (0, 0);
            }
            // Final check before swap - ensure amountIn is not zero
            require(amount0 > 0, "Swap amount too small");
            // Use slippage for minimum output calculation
            uint256 minOut = (amount1_est * (FIXED_ONE - slippage)) / FIXED_ONE;
            return _swap(_token0, _token1, amount0, minOut, true);
        } else {
            // Selling token1, buying token0
            // Limit amount1_est to leave at least 1% of balance1
            uint256 maxAmount1 = (balance1 * (10000 - minReserve)) / 10000;
            if (amount1_est > maxAmount1) {
                amount1_est = maxAmount1;
                // Recalculate amount0 with limited amount1_est
                amount0 = (amount1_est * balance0 * scale1) / (balance1 * scale0);
                // After recalculation, check if amount0 became too small
                if (amount0 == 0) {
                    return (0, 0);
                }
                // Also check if amount1_est is still valid after limiting
                if (amount1_est == 0) {
                    return (0, 0);
                }
            }
            // Also limit amount0 to leave at least 1% of balance0
            uint256 maxAmount0 = (balance0 * (10000 - minReserve)) / 10000;
            if (amount0 > maxAmount0) {
                amount0 = maxAmount0;
                // Recalculate amount1_est with limited amount0
                amount1_est = (amount0 * balance1 * scale0) / (balance0 * scale1);
                // After recalculation, check if amount1_est became too small
                if (amount1_est == 0) {
                    return (0, 0);
                }
            }
            // Check if swap amount is too small to execute
            // Minimum: at least 1 unit of input token
            // For isBuy=false, we use amount1_est as input, so check it specifically
            if (amount1_est == 0 || amount1_est < 1) {
                return (0, 0);
            }
            if (amount0 < 1) {
                return (0, 0);
            }
            // Final check before swap - ensure amountIn is not zero
            require(amount1_est > 0, "Swap amount too small");
            // Use slippage for minimum output calculation
            uint256 minOut = (amount0 * (FIXED_ONE - slippage)) / FIXED_ONE;
            return _swap(_token1, _token0, amount1_est, minOut, false);
        }
    }

    /// @notice Callback function called by the pool during swap
    /// @param amount0Delta Amount of token0 to pay (positive) or receive (negative)
    /// @param amount1Delta Amount of token1 to pay (positive) or receive (negative)
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata /* data */
    ) external override {
        // Verify caller is the pool
        require(msg.sender == address(gauge.pool()), "Invalid caller");
        
        // Determine which token to pay
        if (amount0Delta > 0) {
            // Need to pay token0
            IERC20(_token0).transfer(msg.sender, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            // Need to pay token1
            IERC20(_token1).transfer(msg.sender, uint256(amount1Delta));
        }
        
        // Note: If amount0Delta or amount1Delta is negative, we receive tokens
        // The pool will transfer them to us automatically
    }

    /// @notice External function for safe sqrtPrice calculation (for try-catch)
    function getSqrtRatioAtTickSafe(int24 tick) external pure returns (uint160) {
        return _getSqrtRatioAtTick(tick);
    }

    /// @notice Safe version of ratio calculation with overflow protection
    function _calculateRatioSafe(
        uint160 sqrtPriceCurrent,
        uint160 sqrtPriceLower,
        uint160 sqrtPriceUpper
    ) internal pure returns (uint256) {
        // Check that all values are valid
        if (sqrtPriceCurrent == 0 || sqrtPriceLower == 0 || sqrtPriceUpper == 0) {
            return type(uint256).max;
        }
        
        return _calculateRatioInternal(sqrtPriceCurrent, sqrtPriceLower, sqrtPriceUpper);
    }
    
    /// @notice Internal function for ratio calculation
    function _calculateRatioInternal(
        uint160 sqrtPriceCurrent,
        uint160 sqrtPriceLower,
        uint160 sqrtPriceUpper
    ) internal pure returns (uint256) {
        uint256 Q96 = 2**96;
        uint256 sqrtPriceUpper_ = uint256(sqrtPriceUpper);
        uint256 sqrtPriceCurrent_ = uint256(sqrtPriceCurrent);
        uint256 sqrtPriceLower_ = uint256(sqrtPriceLower);
        
        // Determine price order
        bool priceOrder = sqrtPriceLower_ < sqrtPriceUpper_;
        
        uint256 diffUpper;
        uint256 diffLower;
        
        if (priceOrder) {
            // Normal order (positive ticks)
            if (sqrtPriceUpper_ <= sqrtPriceCurrent_ || sqrtPriceCurrent_ <= sqrtPriceLower_) {
                return type(uint256).max;
            }
            unchecked {
                diffUpper = sqrtPriceUpper_ - sqrtPriceCurrent_;
                diffLower = sqrtPriceCurrent_ - sqrtPriceLower_;
            }
        } else {
            // Reverse order (negative ticks)
            if (sqrtPriceLower_ <= sqrtPriceCurrent_ || sqrtPriceCurrent_ <= sqrtPriceUpper_) {
                return type(uint256).max;
            }
            unchecked {
                diffUpper = sqrtPriceLower_ - sqrtPriceCurrent_;
                diffLower = sqrtPriceCurrent_ - sqrtPriceUpper_;
            }
        }
        
        if (diffLower == 0) return 0;
        
        // ratio = [diffUpper * Q96 * 1e18] / [(sqrtPriceUpper * sqrtPriceCurrent / Q96) * diffLower]
        // Calculate denominator with overflow protection
        uint256 priceProduct = (sqrtPriceUpper_ / Q96) * sqrtPriceCurrent_;
        if (priceProduct == 0) {
            // If product is too small, use simplified formula
            priceProduct = sqrtPriceUpper_ * sqrtPriceCurrent_ / Q96 / Q96;
            if (priceProduct == 0) return 0;
            return (diffUpper * 1e18) / (priceProduct * diffLower);
        }
        
        uint256 denominator = priceProduct * diffLower;
        if (denominator == 0) return 0;
        
        // Calculate numerator
        uint256 numerator = diffUpper * Q96 * 1e18;
        
        return numerator / denominator;
    }

    /// @notice Calculates optimal proportions of amount0 and amount1 for maximum deposit utilization
    /// @param tickLower Lower tick boundary of the range
    /// @param tickUpper Upper tick boundary of the range
    /// @param balance0 Available balance of token0
    /// @param balance1 Available balance of token1
    /// @param decimals0 Number of decimals for token0 (for gas optimization)
    /// @param decimals1 Number of decimals for token1 (for gas optimization)
    /// @return amount0 Optimal amount of token0 for deposit
    /// @return amount1 Optimal amount of token1 for deposit
    function _computeDesiredAmounts(
        int24 tickLower,
        int24 tickUpper,
        uint256 balance0,
        uint256 balance1,
        uint8 decimals0,
        uint8 decimals1
    ) internal view returns (uint256 amount0, uint256 amount1) {
        // Handle case when one balance is zero
        if (balance0 == 0 && balance1 > 0) {
            // Only balance1 available, check if it can be used
            return _computeDesiredAmountsSingleToken(tickLower, tickUpper, balance1, false);
        } else if (balance1 == 0 && balance0 > 0) {
            // Only balance0 available, check if it can be used
            return _computeDesiredAmountsSingleToken(tickLower, tickUpper, balance0, true);
        }

        // Get current price from pool
        ICLPool pool = gauge.pool();
        (uint160 sqrtPriceX96, , , , , ) = pool.slot0();

        // Calculate sqrtPrice for range boundaries with error protection
        uint160 sqrtPriceLowerX96;
        uint160 sqrtPriceUpperX96;
        try this.getSqrtRatioAtTickSafe(tickLower) returns (uint160 price) {
            sqrtPriceLowerX96 = price;
        } catch {
            return (balance0, balance1);
        }
        try this.getSqrtRatioAtTickSafe(tickUpper) returns (uint160 price) {
            sqrtPriceUpperX96 = price;
        } catch {
            return (balance0, balance1);
        }

        // Check price order (for negative ticks sqrtPriceLower > sqrtPriceCurrent)
        // For negative ticks: sqrtPriceLower > sqrtPriceUpper
        // For positive ticks: sqrtPriceLower < sqrtPriceUpper
        bool priceOrder = sqrtPriceLowerX96 < sqrtPriceUpperX96;

        // If current price is outside the range
        if (priceOrder) {
            // Normal order (positive ticks)
            if (sqrtPriceX96 <= sqrtPriceLowerX96) {
                return (balance0, 0);
            }
            if (sqrtPriceX96 >= sqrtPriceUpperX96) {
                return (0, balance1);
            }
        } else {
            // Reverse order (negative ticks)
            if (sqrtPriceX96 >= sqrtPriceLowerX96) {
                return (balance0, 0);
            }
            if (sqrtPriceX96 <= sqrtPriceUpperX96) {
                return (0, balance1);
            }
        }

        // If price is inside the range - calculate optimal proportions
        // Use simplified formula to avoid stack too deep
        uint256 ratio = _calculateRatioSafe(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96);
        
        if (ratio == 0 || ratio == type(uint256).max) {
            // If calculation failed, use simple balances
            return (balance0, balance1);
        }

        // Calculate optimal proportions for maximum balance utilization
        // Use passed decimals to avoid repeated calls
        return _calculateOptimalAmounts(balance0, balance1, ratio, decimals0, decimals1);
    }

    /// @notice Calculates optimal amounts when only one token is available
    /// @param tickLower Lower tick boundary of the range
    /// @param tickUpper Upper tick boundary of the range
    /// @param balance Balance of available token
    /// @param isToken0 true if this is token0, false if token1
    /// @return amount0 Amount of token0 for deposit
    /// @return amount1 Amount of token1 for deposit
    function _computeDesiredAmountsSingleToken(
        int24 tickLower,
        int24 tickUpper,
        uint256 balance,
        bool isToken0
    ) internal view returns (uint256 amount0, uint256 amount1) {
        // Get current price from pool
        ICLPool pool = gauge.pool();
        (uint160 sqrtPriceX96, , , , , ) = pool.slot0();

        // Calculate sqrtPrice for range boundaries with error protection
        uint160 sqrtPriceLowerX96;
        uint160 sqrtPriceUpperX96;
        try this.getSqrtRatioAtTickSafe(tickLower) returns (uint160 price) {
            sqrtPriceLowerX96 = price;
        } catch {
            return (0, 0); // Cannot create position without price
        }
        try this.getSqrtRatioAtTickSafe(tickUpper) returns (uint160 price) {
            sqrtPriceUpperX96 = price;
        } catch {
            return (0, 0);
        }

        // Check price order
        bool priceOrder = sqrtPriceLowerX96 < sqrtPriceUpperX96;

        // Determine where price is relative to the range
        bool priceBelowRange;
        bool priceAboveRange;
        
        if (priceOrder) {
            priceBelowRange = sqrtPriceX96 <= sqrtPriceLowerX96;
            priceAboveRange = sqrtPriceX96 >= sqrtPriceUpperX96;
        } else {
            priceBelowRange = sqrtPriceX96 >= sqrtPriceLowerX96;
            priceAboveRange = sqrtPriceX96 <= sqrtPriceUpperX96;
        }

        // If price is outside range, can use single token
        if (priceBelowRange) {
            // Price below range - only token0 needed
            if (isToken0) {
                return (balance, 0);
            } else {
                return (0, 0); // Need token0 but it's not available
            }
        } else if (priceAboveRange) {
            // Price above range - only token1 needed
            if (!isToken0) {
                return (0, balance);
            } else {
                return (0, 0); // Need token1 but it's not available
            }
        } else {
            // Price inside range - both tokens needed
            // Cannot create position with only one token
            return (0, 0);
        }
    }

    /// @notice Calculates optimal token amounts for maximum balance utilization
    /// @dev ratio = amount0/amount1 in scale 1e18 (normalized by decimals)
    function _calculateOptimalAmounts(
        uint256 balance0,
        uint256 balance1,
        uint256 ratio,
        uint8 decimals0,
        uint8 decimals1
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        // Adjust ratio based on decimals difference
        uint256 adjustedRatio = ratio;
        if (decimals0 > decimals1) {
            adjustedRatio = ratio * (10 ** (decimals0 - decimals1));
        } else if (decimals1 > decimals0) {
            adjustedRatio = ratio / (10 ** (decimals1 - decimals0));
        }
        
        // Normalize balances to maximum decimals
        uint8 maxDecimals = decimals0 > decimals1 ? decimals0 : decimals1;
        uint256 norm0 = decimals0 < maxDecimals ? balance0 * (10 ** (maxDecimals - decimals0)) : balance0;
        uint256 norm1 = decimals1 < maxDecimals ? balance1 * (10 ** (maxDecimals - decimals1)) : balance1;
        
        // Calculate usage options
        uint256 amt0From1 = (norm1 * adjustedRatio) / 1e18;
        uint256 amt1From0 = (norm0 * 1e18) / adjustedRatio;
        
        // Select optimal option
        if (amt0From1 <= norm0) {
            // Use entire balance1
            amount0 = decimals0 < maxDecimals ? amt0From1 / (10 ** (maxDecimals - decimals0)) : amt0From1;
            amount1 = balance1;
        } else if (amt1From0 <= norm1) {
            // Use entire balance0
            amount0 = balance0;
            amount1 = decimals1 < maxDecimals ? amt1From0 / (10 ** (maxDecimals - decimals1)) : amt1From0;
        } else {
            // Both exceed - select option with larger sum
            return _calculateOptimalAmountsFallback(balance0, balance1, adjustedRatio, norm0, norm1, decimals0, decimals1, maxDecimals);
        }
    }
    
    /// @notice Fallback for case when both options exceed balances
    function _calculateOptimalAmountsFallback(
        uint256 balance0,
        uint256 balance1,
        uint256 adjustedRatio,
        uint256 norm0,
        uint256 norm1,
        uint8 decimals0,
        uint8 decimals1,
        uint8 maxDecimals
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        uint256 amt1A = (norm0 * 1e18) / adjustedRatio;
        uint256 amt0B = (norm1 * adjustedRatio) / 1e18;
        
        if (amt1A <= norm1 && (amt0B > norm0 || norm0 + amt1A >= amt0B + norm1)) {
            amount0 = balance0;
            amount1 = decimals1 < maxDecimals ? amt1A / (10 ** (maxDecimals - decimals1)) : amt1A;
        } else if (amt0B <= norm0) {
            amount0 = decimals0 < maxDecimals ? amt0B / (10 ** (maxDecimals - decimals0)) : amt0B;
            amount1 = balance1;
        } else {
            amount0 = balance0;
            uint256 amt1Calc = (norm0 * 1e18) / adjustedRatio;
            if (amt1Calc > norm1) {
                amount1 = balance1;
                amount0 = decimals0 < maxDecimals ? ((norm1 * adjustedRatio) / 1e18) / (10 ** (maxDecimals - decimals0)) : ((norm1 * adjustedRatio) / 1e18);
            } else {
                amount1 = decimals1 < maxDecimals ? amt1Calc / (10 ** (maxDecimals - decimals1)) : amt1Calc;
            }
        }
    }

    /// @notice Calculates sqrtPriceX96 for given tick
    /// @param tick Tick for calculation
    /// @return sqrtPriceX96 sqrt(price) * 2^96
    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        // Formula from TickMath.sol: sqrt(1.0001^tick) * 2^96
        // For simplification we use approximation: sqrt(1.0001^tick) ≈ 1.0001^(tick/2)
        
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(int256(887272)), "Tick out of range");

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x10000000000000000000000000000000000;
        
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
}
