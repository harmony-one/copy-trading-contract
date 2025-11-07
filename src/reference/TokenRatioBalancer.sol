// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

contract TokenRatioBalancer {
    uint256 private constant FIXED_ONE = 1e18;

    /// @notice Рассчитывает, сколько и какого токена нужно добавить/убрать,
    /// чтобы привести ratio к заданному targetRatio.
    /// Сделан internal, чтобы buildSwapParams вызывал его напрямую (газ-эффективно).
    /// targetRatio — в формате 1e18 (A/B).
    function _getRebalanceAmount(
        uint256 balanceA,
        address tokenA,
        uint256 balanceB,
        address tokenB,
        uint256 targetRatio
    ) internal view returns (bool isBuy, uint256 amountA) {
        require(balanceB > 0, "balanceB cannot be zero");

        uint8 decimalsA = IERC20Decimals(tokenA).decimals();
        uint8 decimalsB = IERC20Decimals(tokenB).decimals();
        require(decimalsA <= 38 && decimalsB <= 38, "too large decimals");

        // neededA = balanceB * targetRatio * scaleA / (scaleB * 1e18)
        uint256 scaleA = 10 ** decimalsA;
        uint256 scaleB = 10 ** decimalsB;

        // compute numerator = balanceB * targetRatio
        // then multiply by scaleA and divide by (scaleB * FIXED_ONE)
        // do checks to avoid trivial overflows (basic)
        uint256 numerator = balanceB * targetRatio;
        // safe denominator
        uint256 denominator = scaleB * FIXED_ONE;
        require(denominator > 0, "denominator zero");

        uint256 neededA = (numerator * scaleA) / denominator;

        if (neededA > balanceA) {
            isBuy = true;
            amountA = neededA - balanceA;
        } else {
            isBuy = false;
            amountA = balanceA - neededA;
        }
    }

    /// @notice Публичный wrapper, обратимый интерфейс (сохраняем имя getRebalanceAmount для совместимости).
    function getRebalanceAmount(
        uint256 balanceA,
        address tokenA,
        uint256 balanceB,
        address tokenB,
        uint256 targetRatio
    ) external view returns (bool isBuy, uint256 amount) {
        return _getRebalanceAmount(balanceA, tokenA, balanceB, tokenB, targetRatio);
    }

    /// @notice Построить параметры для swap'а, используя внутренний расчёт
    /// @param balanceA текущий баланс A (raw)
    /// @param tokenA адрес A
    /// @param balanceB текущий баланс B (raw)
    /// @param tokenB адрес B
    /// @param targetRatio желаемое A/B в 1e18
    /// @param slippage допустимый слиппедж в 1e18 (напр. 1e16 = 1%)
    /// @return tokenIn адрес токена, который нужно отдать
    /// @return tokenOut адрес токена, который получим
    /// @return amountIn количество tokenIn (raw)
    /// @return amountOutMin минимально допустимое количество tokenOut (raw)
    /// @return isBuy направление (true — нужно купить A (отдаем B), false — продать A)
    function buildSwapParams(
        uint256 balanceA,
        address tokenA,
        uint256 balanceB,
        address tokenB,
        uint256 targetRatio,
        uint256 slippage
    )
        external
        view
        returns (
            address tokenIn,
            address tokenOut,
            uint256 amountIn,
            uint256 amountOutMin,
            bool isBuy
        )
    {
        require(slippage <= FIXED_ONE, "invalid slippage");

        uint256 amountA;
        (isBuy, amountA) = _getRebalanceAmount(balanceA, tokenA, balanceB, tokenB, targetRatio);

        if (amountA == 0) {
            return (address(0), address(0), 0, 0, isBuy);
        }

        {
            uint8 decimalsA = IERC20Decimals(tokenA).decimals();
            uint8 decimalsB = IERC20Decimals(tokenB).decimals();
            require(decimalsA <= 38 && decimalsB <= 38, "too large decimals");
            require(balanceA > 0 && balanceB > 0, "balances must be > 0");

            uint256 scaleA = 10 ** decimalsA;
            uint256 scaleB = 10 ** decimalsB;
            uint256 amountB_est = ((amountA * balanceB) * scaleA) / (balanceA * scaleB);

            if (isBuy) {
                tokenIn = tokenB;
                tokenOut = tokenA;
                amountIn = amountB_est;
                amountOutMin = (amountA * (FIXED_ONE - slippage)) / FIXED_ONE;
            } else {
                tokenIn = tokenA;
                tokenOut = tokenB;
                amountIn = amountA;
                amountOutMin = (amountB_est * (FIXED_ONE - slippage)) / FIXED_ONE;
            }
        }
    }
}