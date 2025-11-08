// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/ICLGauge.sol";
import "./interfaces/ICLPool.sol";
import "./interfaces/ICLSwapCallback.sol";
import "./interfaces/IERC20.sol";


/// @notice FullMath from Uniswap V3 (mulDiv implementation)
library FullMath {
    /// @dev Calculates floor(a*b/denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            // Compute the product mod 2^256 and mod 2^256 - 1, then use
            // the Chinese Remainder Theorem to reconstruct the 512 bit result.
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division
            if (prod1 == 0) {
                require(denominator > 0);
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }

            require(denominator > prod1);

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0]
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
            }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator.
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
            }

            // Divide [prod1 prod0] by twos
            assembly {
                prod0 := div(prod0, twos)
            }
            assembly {
                // Shift in bits from prod1 into prod0. For this we need to compute
                // prod1 * (2^256 / twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; // inverse mod 2^8
            inv *= 2 - denominator * inv; // inverse mod 2^16
            inv *= 2 - denominator * inv; // inverse mod 2^32
            inv *= 2 - denominator * inv; // inverse mod 2^64
            inv *= 2 - denominator * inv; // inverse mod 2^128
            inv *= 2 - denominator * inv; // inverse mod 2^256

            // Because the division is now exact we can multiply by the modular inverse of denominator.
            result = prod0 * inv;
            return result;
        }
    }
}


contract Rebalancer is Ownable, ERC721Holder, ICLSwapCallback {
    using FullMath for uint256;
    
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
        uint256 private constant Q96 = 2**96;
    uint256 private constant Q192 = 2**192;

    // Struct for swap parameters
    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOutMin;
        bool isBuy;
        bool shouldSwap; // false if no swap is needed
    }

    // Events
    event SwapResult(int256 amount0Delta, int256 amount1Delta, uint256 balance0, uint256 balance1);
    event SwapByRatioResult(uint256 targetRatio, uint256 slippage);
    event SwapParamsCalculated(
        bool shouldSwap,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        bool isBuy,
        uint256 balance0,
        uint256 balance1,
        uint256 currentRatio,
        uint256 targetRatio
    );

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

    /// @notice Calculate swap parameters to achieve target ratio using current contract balances (view function)
    /// @param targetRatio Target ratio token0/token1 in 1e18 format (e.g., 1e18 = 1:1, 2e18 = 2:1)
    /// @param slippage Slippage tolerance in 1e18 format (e.g., 1e16 = 1%)
    /// @return params Swap parameters struct
    function calculateSwapByRatioParamsView(
        uint256 targetRatio,
        uint256 slippage
    ) public view returns (SwapParams memory params) {
        // Use existing view functions to get token addresses
        IERC20 token0_ = token0();
        IERC20 token1_ = token1();
        
        address token0Addr = address(token0_);
        address token1Addr = address(token1_);
        
        uint256 balance0 = token0_.balanceOf(address(this));
        uint256 balance1 = token1_.balanceOf(address(this));
        
        // Get decimals using existing view functions
        uint8 decimals0 = token0Decimals();
        uint8 decimals1 = token1Decimals();
        
        // Get current price from pool for accurate calculation
        (uint160 sqrtPriceX96, , , , , ) = gauge.pool().slot0();
        
        return calculateSwapByRatioParamsWithPrice(
            targetRatio,
            slippage,
            balance0,
            balance1,
            decimals0,
            decimals1,
            token0Addr,
            token1Addr,
            sqrtPriceX96
        );
    }

/// @notice Calculate swap parameters to achieve target ratio using pool price (pure)
    /// @dev sqrtPriceX96 is UniswapV3 sqrt price (Q96) with price = token1/token0 = (sqrtPriceX96^2)/2^192
    function calculateSwapByRatioParamsWithPrice(
        uint256 targetRatio,       // token0/token1 in 1e18
        uint256 slippage,          // in 1e18
        uint256 balance0,
        uint256 balance1,
        uint8 decimals0,
        uint8 decimals1,
        address token0Address,
        address token1Address,
        uint160 sqrtPriceX96
    ) public pure returns (SwapParams memory params) {
        params.shouldSwap = false;

        // Basic guards
        if (targetRatio == 0 || slippage > FIXED_ONE) return params;
        if (balance0 == 0 && balance1 == 0) return params;
        if (balance0 == 0 || balance1 == 0) return params;
        if (decimals0 > 38 || decimals1 > 38) return params;
        if (sqrtPriceX96 == 0) return params;

        uint256 scale0 = 10 ** uint256(decimals0);
        uint256 scale1 = 10 ** uint256(decimals1);

        // currentRatio = (balance0 * scale1 * FIXED_ONE) / (balance1 * scale0)
        uint256 currentNumer = FullMath.mulDiv(balance0, scale1, 1); // balance0*scale1
        uint256 currentDenom = FullMath.mulDiv(balance1, scale0, 1); // balance1*scale0
        if (currentDenom == 0) return params;
        uint256 currentRatio = FullMath.mulDiv(currentNumer, FIXED_ONE, currentDenom);

        // if already close enough, no swap
        // use small epsilon to avoid exact equality issues
        uint256 eps = FIXED_ONE / 1_000_000; // 1e-6 relative tolerance
        if (currentRatio >= targetRatio - eps && currentRatio <= targetRatio + eps) {
            return params;
        }

        // Compute price0Per1 in FIXED_ONE scale:
        // uniswap price P = token1/token0 = (sqrtP^2)/Q192
        // price0Per1 = 1/P = Q192 / (sqrtP^2)
        uint256 sqrtP = uint256(sqrtPriceX96);
        uint256 denom = sqrtP * sqrtP; // <= 2^192 fits into uint256
        if (denom == 0) return params;
        uint256 price0Per1 = FullMath.mulDiv(Q192, FIXED_ONE, denom); // token0 per token1 in FIXED_ONE

        // reserve guard (leave some percent)
        uint256 minReserveBps = 100; // 1%
        uint256 maxSpendToken1 = FullMath.mulDiv(balance1, (10000 - minReserveBps), 10000);
        uint256 maxSpendToken0 = FullMath.mulDiv(balance0, (10000 - minReserveBps), 10000);

        bool needBuyToken0 = currentRatio < targetRatio; // true => spend token1 to get token0

        // prepare common denominator term = price0Per1 * scale1 + targetRatio * scale0
        // compute price0Per1*scale1 and targetRatio*scale0 safely
        uint256 termA = FullMath.mulDiv(price0Per1, scale1, 1);      // price0Per1 * S1
        uint256 termB = FullMath.mulDiv(targetRatio, scale0, 1);     // targetRatio * S0
        uint256 denomTerm = termA + termB; // always > 0

        // Depending on direction compute numerator and delta1 (token1 delta)
        uint256 delta1; // amount of token1 (positive) — interpretation depends on direction
        uint256 delta0; // derived amount of token0

        if (needBuyToken0) {
            // formula: delta1 = (targetRatio*balance1*S0 - balance0*S1*FIXED_ONE) / (price0Per1*S1 + targetRatio*S0)
            // compute left = targetRatio * balance1 * S0
            uint256 left = FullMath.mulDiv(targetRatio, balance1, 1); // targetRatio * balance1
            left = FullMath.mulDiv(left, scale0, 1);                 // * S0

            // compute right = balance0 * S1 * FIXED_ONE
            uint256 right = FullMath.mulDiv(balance0, scale1, 1);    // balance0 * S1
            right = FullMath.mulDiv(right, FIXED_ONE, 1);           // * FIXED_ONE

            if (left <= right) {
                // target already unreachable in this direction (or very close) — no swap
                // but we can attempt best-effort: spend maxSpendToken1
                if (maxSpendToken1 == 0) return params;
                delta1 = maxSpendToken1;
                // delta0 = delta1 * price0Per1 / FIXED_ONE
                delta0 = FullMath.mulDiv(delta1, price0Per1, FIXED_ONE);
            } else {
                uint256 numer = left - right;
                if (denomTerm == 0) return params; // safety
                delta1 = FullMath.mulDiv(numer, 1, denomTerm);
                if (delta1 == 0) {
                    // tiny required amount (rounded to 0) => no swap
                    return params;
                }
                // cap by available
                if (delta1 > maxSpendToken1) {
                    // can't reach target; do best-effort (spend max)
                    delta1 = maxSpendToken1;
                }
                // compute delta0
                delta0 = FullMath.mulDiv(delta1, price0Per1, FIXED_ONE);
            }

            // final checks
            if (delta1 == 0 || delta0 == 0) return params;

            // fill params: we spend token1 to buy token0
            params.shouldSwap = true;
            params.tokenIn = token1Address;
            params.tokenOut = token0Address;
            params.amountIn = delta1; // token1 units
            params.isBuy = false;      // buying token0 (selling token1), so isBuy = false
            // amountOutMin = delta0 * (1 - slippage)
            params.amountOutMin = FullMath.mulDiv(delta0, (FIXED_ONE - slippage), FIXED_ONE);
            if (params.amountOutMin == 0 && delta0 > 0) params.amountOutMin = 1;

            return params;

        } else {
            // need to SELL token0 to BUY token1
            // formula: delta1 = (balance0*S1*FIXED_ONE - targetRatio*balance1*S0) / (price0Per1*S1 + targetRatio*S0)
            uint256 left = FullMath.mulDiv(balance0, scale1, 1);    // balance0 * S1
            left = FullMath.mulDiv(left, FIXED_ONE, 1);            // * FIXED_ONE

            uint256 right = FullMath.mulDiv(targetRatio, balance1, 1); // targetRatio * balance1
            right = FullMath.mulDiv(right, scale0, 1);                 // * S0

            if (left <= right) {
                // cannot move ratio down by selling token0 (or already close)
                if (maxSpendToken0 == 0) return params;
                // Best-effort: sell maxToken0Spend -> compute resulting delta1 = amountOut1
                delta0 = maxSpendToken0;
                // delta1 = delta0 * (sqrtP^2) / Q192  -> but we have price0Per1 = Q192/denom => invert
                // easier: delta1 = delta0 * (1/price0Per1)
                // 1/price0Per1 (in FIXED_ONE) = denom / Q192 * FIXED_ONE? To avoid invert, we compute:
                // delta1 = delta0 * (Q192 / denom)^(-1) => delta1 = FullMath.mulDiv(delta0, denom, Q192);
                // but denom may be big: FullMath handles it.
                delta1 = FullMath.mulDiv(delta0, denom, Q192);
            } else {
                uint256 numer = left - right;
                if (denomTerm == 0) return params;
                // note: here delta1 is token1 gained when selling token0 by amount delta0 where delta0 = ?
                // Derived formula gives delta1 in token1 units (positive).
                delta1 = FullMath.mulDiv(numer, 1, denomTerm);

                if (delta1 == 0) return params;

                // now delta0 = delta1 * price0Per1 / FIXED_ONE
                delta0 = FullMath.mulDiv(delta1, price0Per1, FIXED_ONE);

                // cap by available sale (maxSpendToken0)
                if (delta0 > maxSpendToken0) {
                    // cap delta0 and recompute delta1 from delta0 via pool price (use exact inverse)
                    delta0 = maxSpendToken0;
                    // delta1 = delta0 * denom / Q192  (because token1 per token0 = denom/Q192)
                    delta1 = FullMath.mulDiv(delta0, denom, Q192);
                }
            }

            if (delta0 == 0 || delta1 == 0) return params;

            // fill params: we spend token0 to get token1
            params.shouldSwap = true;
            params.tokenIn = token0Address;
            params.tokenOut = token1Address;
            params.amountIn = delta0; // token0 units (we sell)
            params.isBuy = true;      // buying token1 (selling token0), so isBuy = true
            params.amountOutMin = FullMath.mulDiv(delta1, (FIXED_ONE - slippage), FIXED_ONE);
            if (params.amountOutMin == 0 && delta1 > 0) params.amountOutMin = 1;

            return params;
        }
    }


    /// @notice Calculate swap parameters to achieve target ratio using pool price (view function)
    /// @param targetRatio Target ratio token0/token1 in 1e18 format (e.g., 1e18 = 1:1, 2e18 = 2:1)
    /// @param slippage Slippage tolerance in 1e18 format (e.g., 1e16 = 1%)
    /// @param balance0 Current balance of token0
    /// @param balance1 Current balance of token1
    /// @param decimals0 Decimals of token0
    /// @param decimals1 Decimals of token1
    /// @param token0Address Address of token0
    /// @param token1Address Address of token1
    /// @param sqrtPriceX96 Current sqrt price from pool (Q96 format)
    /// @return params Swap parameters struct
    function calculateSwapByRatioParamsWithPriceL(
        uint256 targetRatio,
        uint256 slippage,
        uint256 balance0,
        uint256 balance1,
        uint8 decimals0,
        uint8 decimals1,
        address token0Address,
        address token1Address,
        uint160 sqrtPriceX96
    ) public pure returns (SwapParams memory params) {
        // Initialize with no swap
        params.shouldSwap = false;
        
        // Validate slippage
        if (slippage > FIXED_ONE) {
            return params;
        }
        
        // If both balances are zero, no swap needed
        if (balance0 == 0 && balance1 == 0) {
            return params;
        }
        
        // If one balance is zero, cannot achieve target ratio, skip swap
        if (balance0 == 0 || balance1 == 0) {
            return params;
        }
        
        if (decimals0 > 38 || decimals1 > 38) {
            return params;
        }
        
        // Require price to be available - no fallback to balance ratio
        require(sqrtPriceX96 != 0, "Price not available");
        
        uint256 scale0 = 10 ** decimals0;
        uint256 scale1 = 10 ** decimals1;
        
        // Calculate price from sqrtPriceX96
        // price = (sqrtPriceX96 / 2^96)^2
        // priceX96 = (sqrtPriceX96^2) / 2^96 (price in Q96 format)
        uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) / (2**96);
        
        // Calculate target balances after swap
        // After swap: (balance0_new * scale1 * 1e18) / (balance1_new * scale0) = targetRatio
        // Where balance0_new = balance0 + amount0_out, balance1_new = balance1 - amount1_in
        
        // For swap token1 -> token0 (buying token0):
        // amount0_out = amount1_in * price * (scale0 / scale1)
        // amount0_out = amount1_in * priceX96 * scale0 / (2^96 * scale1)
        
        // Target equation:
        // (balance0 + amount0_out) * scale1 * 1e18 / ((balance1 - amount1_in) * scale0) = targetRatio
        // (balance0 + amount1_in * priceX96 * scale0 / (2^96 * scale1)) * scale1 * 1e18 / ((balance1 - amount1_in) * scale0) = targetRatio
        
        // Solving for amount1_in:
        // (balance0 * scale1 * 1e18 + amount1_in * priceX96 * scale0 * 1e18 / 2^96) / ((balance1 - amount1_in) * scale0) = targetRatio
        // balance0 * scale1 * 1e18 + amount1_in * priceX96 * scale0 * 1e18 / 2^96 = targetRatio * (balance1 - amount1_in) * scale0
        // balance0 * scale1 * 1e18 + amount1_in * priceX96 * scale0 * 1e18 / 2^96 = targetRatio * balance1 * scale0 - targetRatio * amount1_in * scale0
        // amount1_in * (priceX96 * scale0 * 1e18 / 2^96 + targetRatio * scale0) = targetRatio * balance1 * scale0 - balance0 * scale1 * 1e18
        // amount1_in = (targetRatio * balance1 * scale0 - balance0 * scale1 * 1e18) / (priceX96 * scale0 * 1e18 / 2^96 + targetRatio * scale0)
        
        // For swap token0 -> token1 (selling token0):
        // amount1_out = amount0_in * (2^96 * scale1) / (priceX96 * scale0)
        // (balance0 - amount0_in) * scale1 * 1e18 / ((balance1 + amount1_out) * scale0) = targetRatio
        // Similar calculation but in reverse
        
        // Calculate current ratio
        // Check for division by zero
        if (balance1 == 0) {
            return params;
        }
        uint256 currentRatio = (balance0 * scale1 * FIXED_ONE) / (balance1 * scale0);
        
        bool isBuy;
        uint256 amountIn;
        uint256 amountOut;
        
        if (currentRatio < targetRatio) {
            // Need to increase ratio: buy token0 (sell token1)
            isBuy = false;
            
            // Calculate amount1_in needed to achieve target ratio
            // Using the formula derived above
            // amount1_in = (targetRatio * balance1 * scale0 - balance0 * scale1 * 1e18) / (priceX96 * scale0 * 1e18 / 2^96 + targetRatio * scale0)
            
            // Check if we can achieve target ratio
            // We need: targetRatio * balance1 * scale0 > balance0 * scale1 * FIXED_ONE
            // If not, we're already at or above target ratio
            uint256 targetValue = targetRatio * balance1 * scale0;
            uint256 currentValue = balance0 * scale1 * FIXED_ONE;
            if (targetValue <= currentValue) {
                // Already at or above target ratio
                return params;
            }
            
            uint256 numerator = targetValue - currentValue;
            
            // Calculate denominator: priceX96 * scale0 * 1e18 / 2^96 + targetRatio * scale0
            // = scale0 * (priceX96 * 1e18 / 2^96 + targetRatio)
            // To avoid precision loss, multiply numerator by 2^96 first
            // amountIn = (numerator * 2^96) / (priceX96 * scale0 * 1e18 + targetRatio * scale0 * 2^96)
            uint256 priceTerm = priceX96 * scale0 * FIXED_ONE;
            uint256 targetTerm = targetRatio * scale0 * (2**96);
            
            // Check for overflow
            if (targetTerm > type(uint256).max - priceTerm) {
                return params;
            }
            
            uint256 denominator = priceTerm + targetTerm;
            
            if (denominator == 0) {
                return params;
            }
            
            // If numerator is zero, we're already at target ratio
            if (numerator == 0) {
                return params;
            }
            
            // Check if numerator * 2^96 would overflow
            if (numerator > type(uint256).max / (2**96)) {
                return params;
            }
            
            // Calculate amountIn with higher precision
            // amountIn = (numerator * 2^96) / denominator
            uint256 numeratorScaled = numerator * (2**96);
            amountIn = numeratorScaled / denominator;
            
            // If amountIn is zero due to rounding, we need to ensure we have at least minimum amount
            // But first, check if the calculation itself is valid (numeratorScaled should be >= denominator for non-zero result)
            if (amountIn == 0) {
                // If numeratorScaled < denominator, the result would be zero
                // In this case, we need to use a minimum amount that would give at least 1 unit of output
                // amountOut = (amountIn * priceX96 * scale0) / (2**96 * scale1) >= 1
                // So: amountIn >= (2**96 * scale1) / (priceX96 * scale0)
                if (priceX96 == 0 || scale0 == 0) {
                    return params;
                }
                uint256 minAmountInForOutput = (2**96 * scale1) / (priceX96 * scale0);
                if (minAmountInForOutput == 0) {
                    minAmountInForOutput = 1;
                }
                // We can't use more than balance1, and we should use at least the minimum
                if (minAmountInForOutput > 0 && minAmountInForOutput <= balance1) {
                    amountIn = minAmountInForOutput;
                } else {
                    // If we can't get even 1 unit of output, cannot proceed
                    return params;
                }
            }
            
            // Calculate expected amount0_out using pool price
            amountOut = (amountIn * priceX96 * scale0) / (2**96 * scale1);
            
            // If amountOut is still zero, we cannot proceed
            if (amountOut == 0) {
                return params;
            }
            
        } else if (currentRatio > targetRatio) {
            // Need to decrease ratio: sell token0 (buy token1)
            isBuy = true;
            
            // Calculate amount0_in needed to achieve target ratio
            // After swap: balance0_new = balance0 - amount0_in, balance1_new = balance1 + amount1_out
            // amount1_out = amount0_in * (2^96 * scale1) / (priceX96 * scale0)
            // Target: (balance0 - amount0_in) * scale1 * 1e18 / ((balance1 + amount1_out) * scale0) = targetRatio
            // (balance0 - amount0_in) * scale1 * 1e18 / ((balance1 + amount0_in * 2^96 * scale1 / (priceX96 * scale0)) * scale0) = targetRatio
            // (balance0 - amount0_in) * scale1 * 1e18 = targetRatio * (balance1 * scale0 + amount0_in * 2^96 * scale1 / priceX96)
            // balance0 * scale1 * 1e18 - amount0_in * scale1 * 1e18 = targetRatio * balance1 * scale0 + targetRatio * amount0_in * 2^96 * scale1 / priceX96
            // balance0 * scale1 * 1e18 - targetRatio * balance1 * scale0 = amount0_in * (scale1 * 1e18 + targetRatio * 2^96 * scale1 / priceX96)
            // amount0_in = (balance0 * scale1 * 1e18 - targetRatio * balance1 * scale0) / (scale1 * 1e18 + targetRatio * 2^96 * scale1 / priceX96)
            
            // Check if we can achieve target ratio
            // We need: balance0 * scale1 * FIXED_ONE > targetRatio * balance1 * scale0
            // If not, we're already at or below target ratio
            uint256 currentValue = balance0 * scale1 * FIXED_ONE;
            uint256 targetValue = targetRatio * balance1 * scale0;
            if (currentValue <= targetValue) {
                // Already at or below target ratio
                return params;
            }
            
            uint256 numerator = currentValue - targetValue;
            
            // denominator = scale1 * 1e18 + targetRatio * 2^96 * scale1 / priceX96
            // = scale1 * (1e18 + targetRatio * 2^96 / priceX96)
            // To avoid overflow when multiplying by priceX96, we use a different approach:
            // Calculate denominator_term = targetRatio * 2^96 * scale1 / priceX96
            // But to avoid precision loss, we multiply numerator by priceX96 first:
            // amountIn = (numerator * priceX96) / (scale1 * (1e18 * priceX96 + targetRatio * 2^96))
            
            // denominator = scale1 * 1e18 + targetRatio * 2^96 * scale1 / priceX96
            // To avoid precision loss from division, we rearrange:
            // amountIn = numerator / (scale1 * (1e18 + targetRatio * 2^96 / priceX96))
            // Multiply numerator and denominator by priceX96 to avoid division in denominator:
            // amountIn = (numerator * priceX96) / (scale1 * (1e18 * priceX96 + targetRatio * 2^96))
            
            // Check for potential overflow in multiplication
            uint256 priceTerm = FIXED_ONE * priceX96;
            uint256 targetTerm = targetRatio * 2**96;
            
            // Check if priceTerm + targetTerm would overflow
            if (targetTerm > type(uint256).max - priceTerm) {
                // Cannot calculate due to overflow - return no swap
                return params;
            }
            
            uint256 denominator = scale1 * (priceTerm + targetTerm);
            
            if (denominator == 0) {
                return params;
            }
            
            // If numerator is zero, we're already at target ratio
            if (numerator == 0) {
                return params;
            }
            
            // Check if numerator * priceX96 would overflow
            if (numerator > type(uint256).max / priceX96) {
                // Cannot calculate due to overflow - return no swap
                return params;
            }
            
            // Calculate amountIn with higher precision
            amountIn = (numerator * priceX96) / denominator;
            
            // If amountIn is zero due to rounding, use a minimum percentage of balance0
            // This ensures we always perform a swap when ratio needs adjustment
            if (amountIn == 0 && balance0 > 0) {
                // Use at least 1% of balance0 for swap
                amountIn = balance0 / 100;
                if (amountIn == 0) {
                    amountIn = 1; // At least 1 unit
                }
                // Ensure we don't exceed balance
                if (amountIn > balance0) {
                    amountIn = balance0;
                }
            }
            
            // Calculate expected amount1_out using pool price
            if (priceX96 == 0) {
                return params;
            }
            amountOut = (amountIn * 2**96 * scale1) / (priceX96 * scale0);
            
            // If amountOut is zero, ensure we have at least minimum amountIn and amountOut
            if (amountOut == 0) {
                // If amountIn is also zero, use 1% of balance0
                if (amountIn == 0 && balance0 > 0) {
                    amountIn = balance0 / 100;
                    if (amountIn == 0) {
                        amountIn = 1;
                    }
                    amountOut = (amountIn * 2**96 * scale1) / (priceX96 * scale0);
                }
                // If amountOut is still zero, set it to 1
                if (amountOut == 0 && amountIn > 0) {
                    amountOut = 1;
                }
                // If we still don't have valid amounts, cannot proceed
                if (amountIn == 0 || amountOut == 0) {
                    return params;
                }
            }
        } else {
            // Ratio is already correct
            return params;
        }
        
        // Check if amounts are valid
        // If amountIn is zero, try to use a minimum percentage of balance
        // This is a fallback to ensure swap happens even if calculation gives zero
        if (amountIn == 0) {
            // Use at least 1% of the appropriate balance for swap
            if (isBuy && balance0 > 0) {
                // Selling token0, buying token1
                amountIn = balance0 / 100; // 1% of balance0
                if (amountIn == 0) {
                    amountIn = 1; // At least 1 unit
                }
                // Recalculate amountOut with new amountIn
                amountOut = (amountIn * 2**96 * scale1) / (priceX96 * scale0);
                if (amountOut == 0) {
                    amountOut = 1; // At least 1 unit of output
                }
            } else if (!isBuy && balance1 > 0) {
                // Selling token1, buying token0
                amountIn = balance1 / 100; // 1% of balance1
                if (amountIn == 0) {
                    amountIn = 1; // At least 1 unit
                }
                // Recalculate amountOut with new amountIn
                amountOut = (amountIn * priceX96 * scale0) / (2**96 * scale1);
                if (amountOut == 0) {
                    amountOut = 1; // At least 1 unit of output
                }
            } else {
                return params;
            }
        }
        
        // Final check: if amountOut is still zero, set it to 1 if amountIn > 0
        if (amountOut == 0 && amountIn > 0) {
            amountOut = 1;
        }
        
        // If we still don't have valid amounts, cannot proceed
        if (amountIn == 0 || amountOut == 0) {
            return params;
        }
        
        // Limit swap amount to avoid zeroing out balances
        uint256 minReserve = 100; // 1% in basis points
        
        if (isBuy) {
            // Selling token0, buying token1
            uint256 maxAmount0 = (balance0 * (10000 - minReserve)) / 10000;
            if (amountIn > maxAmount0) {
                amountIn = maxAmount0;
                amountOut = (amountIn * 2**96 * scale1) / (priceX96 * scale0);
                // If amountOut becomes zero after limiting, try to use minimum
                if (amountOut == 0 && amountIn > 0) {
                    // Use minimum amountOut = 1
                    amountOut = 1;
                    // Recalculate amountIn to match
                    amountIn = (amountOut * priceX96 * scale0) / (2**96 * scale1);
                    if (amountIn == 0 || amountIn > maxAmount0) {
                        return params;
                    }
                }
            }
            
            uint256 maxAmount1 = (balance1 * (10000 - minReserve)) / 10000;
            if (amountOut > maxAmount1) {
                amountOut = maxAmount1;
                amountIn = (amountOut * priceX96 * scale0) / (2**96 * scale1);
                // If amountIn becomes zero after limiting, we cannot proceed
                if (amountIn == 0) {
                    return params;
                }
            }
            
            // Ensure minimum amounts
            if (amountIn < 1) {
                return params;
            }
            if (amountOut < 1) {
                return params;
            }
            
            params.shouldSwap = true;
            params.tokenIn = token0Address;
            params.tokenOut = token1Address;
            params.amountIn = amountIn;
            params.isBuy = true;
            params.amountOutMin = (amountOut * (FIXED_ONE - slippage)) / FIXED_ONE;
        } else {
            // Selling token1, buying token0
            uint256 maxAmount1 = (balance1 * (10000 - minReserve)) / 10000;
            if (amountIn > maxAmount1) {
                amountIn = maxAmount1;
                amountOut = (amountIn * priceX96 * scale0) / (2**96 * scale1);
                // If amountOut becomes zero after limiting, we cannot proceed
                if (amountOut == 0) {
                    return params;
                }
            }
            
            // Ensure minimum amounts
            if (amountIn < 1) {
                return params;
            }
            if (amountOut < 1) {
                return params;
            }
            
            params.shouldSwap = true;
            params.tokenIn = token1Address;
            params.tokenOut = token0Address;
            params.amountIn = amountIn;
            params.isBuy = false;
            
            // For small swaps, be more conservative
            if (amountIn < 100) {
                params.amountOutMin = 0;
            } else {
                uint256 effectiveSlippage = slippage * 3;
                if (effectiveSlippage > FIXED_ONE / 2) {
                    effectiveSlippage = FIXED_ONE / 2;
                }
                params.amountOutMin = (amountOut * (FIXED_ONE - effectiveSlippage)) / FIXED_ONE;
                if (params.amountOutMin == 0 && amountIn >= 100) {
                    params.amountOutMin = 1;
                }
            }
        }
        
        return params;
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
        
        IERC20 token0_ = IERC20(_token0);
        IERC20 token1_ = IERC20(_token1);
        
        uint256 balance0 = token0_.balanceOf(address(this));
        uint256 balance1 = token1_.balanceOf(address(this));
        
        // Get current price from pool for accurate calculation
        (uint160 sqrtPriceX96, , , , , ) = gauge.pool().slot0();
        // Check if we have balances
        if (balance0 == 0 || balance1 == 0) {
            return (0, 0);
        }
        
        SwapParams memory params = calculateSwapByRatioParamsWithPrice(
            targetRatio,
            slippage,
            balance0,
            balance1,
            _decimals0,
            _decimals1,
            _token0,
            _token1,
            sqrtPriceX96
        );
        
        // Calculate current ratio for logging
        uint256 scale0 = 10 ** _decimals0;
        uint256 scale1 = 10 ** _decimals1;
        uint256 currentRatio = 0;
        if (balance1 > 0) {
            currentRatio = (balance0 * scale1 * FIXED_ONE) / (balance1 * scale0);
        }
        
        // Emit event for debugging
        emit SwapParamsCalculated(
            params.shouldSwap,
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            params.amountOutMin,
            params.isBuy,
            balance0,
            balance1,
            currentRatio,
            targetRatio
        );
        
        // If no swap is needed, return zero
        if (!params.shouldSwap) {
            // Log why swap is not needed
            // This will help diagnose the issue
            return (0, 0);
        }
        
        // Validate swap parameters before executing
        require(params.amountIn > 0, "Invalid swap: amountIn is zero");
        require(params.tokenIn != address(0) && params.tokenOut != address(0), "Invalid swap: token addresses are zero");
        
        // Execute swap with calculated parameters
        return _swap(params.tokenIn, params.tokenOut, params.amountIn, params.amountOutMin, params.isBuy);
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
