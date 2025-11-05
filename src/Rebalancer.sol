// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/ICLGauge.sol";
import "./interfaces/ICLPool.sol";
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

    function rebalance(int24 tickLower, int24 tickUpper) external onlyOwner {
        // Close existing positions first
        if (currentTokenId != 0) {
            _closeAllPositions();
        }

        IERC20 token0_ = token0();
        IERC20 token1_ = token1();
        uint256 balance0 = token0_.balanceOf(address(this));
        uint256 balance1 = token1_.balanceOf(address(this));

        // Skip creating new position if balances are too low
        // This can happen if position was closed but fees were minimal
        if (balance0 == 0 && balance1 == 0) {
            return; // No tokens to create position with
        }

        // Compute optimal amounts using advanced calculation
        // This handles cases where one balance is zero and price is outside range
        (uint256 amount0, uint256 amount1) = _computeDesiredAmounts(
            tickLower,
            tickUpper,
            balance0,
            balance1
        );

        // If computed amounts are both zero, skip creating position
        // This can happen if price is inside range but one balance is zero
        if (amount0 == 0 && amount1 == 0) {
            return;
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

    /// @notice Внешняя функция для безопасного вычисления sqrtPrice (для try-catch)
    function getSqrtRatioAtTickSafe(int24 tick) external pure returns (uint160) {
        return _getSqrtRatioAtTick(tick);
    }

    /// @notice Безопасная версия вычисления соотношения с защитой от переполнения
    function _calculateRatioSafe(
        uint160 sqrtPriceCurrent,
        uint160 sqrtPriceLower,
        uint160 sqrtPriceUpper
    ) internal pure returns (uint256) {
        // Проверяем, что все значения валидны
        if (sqrtPriceCurrent == 0 || sqrtPriceLower == 0 || sqrtPriceUpper == 0) {
            return type(uint256).max;
        }
        
        return _calculateRatioInternal(sqrtPriceCurrent, sqrtPriceLower, sqrtPriceUpper);
    }
    
    /// @notice Внутренняя функция вычисления соотношения
    function _calculateRatioInternal(
        uint160 sqrtPriceCurrent,
        uint160 sqrtPriceLower,
        uint160 sqrtPriceUpper
    ) internal pure returns (uint256) {
        uint256 Q96 = 2**96;
        uint256 sqrtPriceUpper_ = uint256(sqrtPriceUpper);
        uint256 sqrtPriceCurrent_ = uint256(sqrtPriceCurrent);
        uint256 sqrtPriceLower_ = uint256(sqrtPriceLower);
        
        // Определяем порядок цен
        bool priceOrder = sqrtPriceLower_ < sqrtPriceUpper_;
        
        uint256 diffUpper;
        uint256 diffLower;
        
        if (priceOrder) {
            // Нормальный порядок (положительные тики)
            if (sqrtPriceUpper_ <= sqrtPriceCurrent_ || sqrtPriceCurrent_ <= sqrtPriceLower_) {
                return type(uint256).max;
            }
            unchecked {
                diffUpper = sqrtPriceUpper_ - sqrtPriceCurrent_;
                diffLower = sqrtPriceCurrent_ - sqrtPriceLower_;
            }
        } else {
            // Обратный порядок (отрицательные тики)
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
        // Вычисляем denominator с учетом возможного переполнения
        uint256 priceProduct = (sqrtPriceUpper_ / Q96) * sqrtPriceCurrent_;
        if (priceProduct == 0) {
            // Если произведение слишком мало, используем упрощенную формулу
            priceProduct = sqrtPriceUpper_ * sqrtPriceCurrent_ / Q96 / Q96;
            if (priceProduct == 0) return 0;
            return (diffUpper * 1e18) / (priceProduct * diffLower);
        }
        
        uint256 denominator = priceProduct * diffLower;
        if (denominator == 0) return 0;
        
        // Вычисляем numerator
        uint256 numerator = diffUpper * Q96 * 1e18;
        
        return numerator / denominator;
    }

    /// @notice Вычисляет оптимальные пропорции amount0 и amount1 для максимального использования депозита
    /// @param tickLower Нижняя граница тика диапазона
    /// @param tickUpper Верхняя граница тика диапазона
    /// @param balance0 Доступный баланс token0
    /// @param balance1 Доступный баланс token1
    /// @return amount0 Оптимальное количество token0 для депозита
    /// @return amount1 Оптимальное количество token1 для депозита
    function _computeDesiredAmounts(
        int24 tickLower,
        int24 tickUpper,
        uint256 balance0,
        uint256 balance1
    ) internal view returns (uint256 amount0, uint256 amount1) {
        // Обработка случая, когда один из балансов равен 0
        if (balance0 == 0 && balance1 > 0) {
            // Есть только balance1, нужно проверить, можно ли использовать его
            return _computeDesiredAmountsSingleToken(tickLower, tickUpper, balance1, false);
        } else if (balance1 == 0 && balance0 > 0) {
            // Есть только balance0, нужно проверить, можно ли использовать его
            return _computeDesiredAmountsSingleToken(tickLower, tickUpper, balance0, true);
        }

        // Получаем текущую цену из пула
        ICLPool pool = gauge.pool();
        (uint160 sqrtPriceX96, , , , , ) = pool.slot0();

        // Вычисляем sqrtPrice для границ диапазона с защитой от ошибок
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

        // Проверяем порядок цен (для отрицательных тиков sqrtPriceLower > sqrtPriceCurrent)
        // Для отрицательных тиков: sqrtPriceLower > sqrtPriceUpper
        // Для положительных тиков: sqrtPriceLower < sqrtPriceUpper
        bool priceOrder = sqrtPriceLowerX96 < sqrtPriceUpperX96;

        // Если текущая цена вне диапазона
        if (priceOrder) {
            // Нормальный порядок (положительные тики)
            if (sqrtPriceX96 <= sqrtPriceLowerX96) {
                return (balance0, 0);
            }
            if (sqrtPriceX96 >= sqrtPriceUpperX96) {
                return (0, balance1);
            }
        } else {
            // Обратный порядок (отрицательные тики)
            if (sqrtPriceX96 >= sqrtPriceLowerX96) {
                return (balance0, 0);
            }
            if (sqrtPriceX96 <= sqrtPriceUpperX96) {
                return (0, balance1);
            }
        }

        // Если цена внутри диапазона - вычисляем оптимальные пропорции
        // Используем упрощенную формулу для избежания stack too deep
        uint256 ratio = _calculateRatioSafe(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96);
        
        if (ratio == 0 || ratio == type(uint256).max) {
            // Если вычисление не удалось, используем простые балансы
            return (balance0, balance1);
        }

        // Получаем decimals для корректного расчета
        uint8 decimals0 = token0Decimals();
        uint8 decimals1 = token1Decimals();

        // Вычисляем оптимальные пропорции для максимального использования балансов
        return _calculateOptimalAmounts(balance0, balance1, ratio, decimals0, decimals1);
    }

    /// @notice Вычисляет оптимальные количества когда доступен только один токен
    /// @param tickLower Нижняя граница тика диапазона
    /// @param tickUpper Верхняя граница тика диапазона
    /// @param balance Баланс доступного токена
    /// @param isToken0 true если это token0, false если token1
    /// @return amount0 Количество token0 для депозита
    /// @return amount1 Количество token1 для депозита
    function _computeDesiredAmountsSingleToken(
        int24 tickLower,
        int24 tickUpper,
        uint256 balance,
        bool isToken0
    ) internal view returns (uint256 amount0, uint256 amount1) {
        // Получаем текущую цену из пула
        ICLPool pool = gauge.pool();
        (uint160 sqrtPriceX96, , , , , ) = pool.slot0();

        // Вычисляем sqrtPrice для границ диапазона с защитой от ошибок
        uint160 sqrtPriceLowerX96;
        uint160 sqrtPriceUpperX96;
        try this.getSqrtRatioAtTickSafe(tickLower) returns (uint160 price) {
            sqrtPriceLowerX96 = price;
        } catch {
            return (0, 0); // Не можем создать позицию без цены
        }
        try this.getSqrtRatioAtTickSafe(tickUpper) returns (uint160 price) {
            sqrtPriceUpperX96 = price;
        } catch {
            return (0, 0);
        }

        // Проверяем порядок цен
        bool priceOrder = sqrtPriceLowerX96 < sqrtPriceUpperX96;

        // Определяем, где находится цена относительно диапазона
        bool priceBelowRange;
        bool priceAboveRange;
        
        if (priceOrder) {
            priceBelowRange = sqrtPriceX96 <= sqrtPriceLowerX96;
            priceAboveRange = sqrtPriceX96 >= sqrtPriceUpperX96;
        } else {
            priceBelowRange = sqrtPriceX96 >= sqrtPriceLowerX96;
            priceAboveRange = sqrtPriceX96 <= sqrtPriceUpperX96;
        }

        // Если цена вне диапазона, можно использовать один токен
        if (priceBelowRange) {
            // Цена ниже диапазона - нужен только token0
            if (isToken0) {
                return (balance, 0);
            } else {
                return (0, 0); // Нужен token0, но его нет
            }
        } else if (priceAboveRange) {
            // Цена выше диапазона - нужен только token1
            if (!isToken0) {
                return (0, balance);
            } else {
                return (0, 0); // Нужен token1, но его нет
            }
        } else {
            // Цена внутри диапазона - нужны оба токена
            // Не можем создать позицию только с одним токеном
            return (0, 0);
        }
    }

    /// @notice Вычисляет оптимальные количества токенов для максимального использования балансов
    /// @dev ratio = amount0/amount1 в масштабе 1e18 (нормализовано по decimals)
    function _calculateOptimalAmounts(
        uint256 balance0,
        uint256 balance1,
        uint256 ratio,
        uint8 decimals0,
        uint8 decimals1
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        // Корректируем ratio с учетом разницы decimals
        uint256 adjustedRatio = ratio;
        if (decimals0 > decimals1) {
            adjustedRatio = ratio * (10 ** (decimals0 - decimals1));
        } else if (decimals1 > decimals0) {
            adjustedRatio = ratio / (10 ** (decimals1 - decimals0));
        }
        
        // Нормализуем балансы к максимальному decimals
        uint8 maxDecimals = decimals0 > decimals1 ? decimals0 : decimals1;
        uint256 norm0 = decimals0 < maxDecimals ? balance0 * (10 ** (maxDecimals - decimals0)) : balance0;
        uint256 norm1 = decimals1 < maxDecimals ? balance1 * (10 ** (maxDecimals - decimals1)) : balance1;
        
        // Вычисляем варианты использования
        uint256 amt0From1 = (norm1 * adjustedRatio) / 1e18;
        uint256 amt1From0 = (norm0 * 1e18) / adjustedRatio;
        
        // Выбираем оптимальный вариант
        if (amt0From1 <= norm0) {
            // Используем весь balance1
            amount0 = decimals0 < maxDecimals ? amt0From1 / (10 ** (maxDecimals - decimals0)) : amt0From1;
            amount1 = balance1;
        } else if (amt1From0 <= norm1) {
            // Используем весь balance0
            amount0 = balance0;
            amount1 = decimals1 < maxDecimals ? amt1From0 / (10 ** (maxDecimals - decimals1)) : amt1From0;
        } else {
            // Оба превышают - выбираем вариант с большей суммой
            return _calculateOptimalAmountsFallback(balance0, balance1, adjustedRatio, norm0, norm1, decimals0, decimals1, maxDecimals);
        }
    }
    
    /// @notice Fallback для случая когда оба варианта превышают балансы
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

    /// @notice Вычисляет sqrtPriceX96 для заданного тика
    /// @param tick Тик для вычисления
    /// @return sqrtPriceX96 sqrt(price) * 2^96
    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        // Формула из TickMath.sol: sqrt(1.0001^tick) * 2^96
        // Для упрощения используем приближение: sqrt(1.0001^tick) ≈ 1.0001^(tick/2)
        
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
