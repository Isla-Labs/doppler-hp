// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BeforeSwapDelta, toBeforeSwapDelta } from "@v4-core/types/BeforeSwapDelta.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { DynamicFee } from "src/libs/DynamicFee.sol";
import { TreasuryManager } from "src/TreasuryManager.sol";

/// @notice Context for multi-hop swap coordination
struct MultiHopContext {
    bool isMultiHop;
    bool isUsdc;
}

/// @title Dynamic Fee Library for Doppler
/// @notice Handles dynamic fee processing for Doppler hooks
library DopplerDynamicFeeLib {
    
    /// @notice Process dynamic fees for buy transactions (before swap)
    /// @param treasuryManager The treasury manager instance
    /// @param poolManager The pool manager instance
    /// @param sender The address executing the swap
    /// @param key The pool key
    /// @param swapParams The swap parameters
    /// @return delta The dynamic fee delta
    function processDynamicFeesBeforeSwap(
        TreasuryManager treasuryManager,
        IPoolManager poolManager,
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams
    ) external returns (BeforeSwapDelta) {
        if (!swapParams.zeroForOne) return toBeforeSwapDelta(0, 0); // Not a buy
        
        uint256 ethPriceUsd = DynamicFee.fetchEthPriceWithFallback();
        uint256 inputAmount = uint256(swapParams.amountSpecified < 0 ? -swapParams.amountSpecified : swapParams.amountSpecified);
        uint256 dynamicFeeBps = DynamicFee.calculateDynamicFee(inputAmount, ethPriceUsd);
        
        if (dynamicFeeBps == 0) return toBeforeSwapDelta(0, 0);
        
        uint256 totalFeeAmount = (inputAmount * dynamicFeeBps) / 10000;
        treasuryManager.distributeFees(poolManager, key.currency0, totalFeeAmount, sender, true);
        return toBeforeSwapDelta(int128(int256(totalFeeAmount)), 0);
    }

    /// @notice Process dynamic fees for sell transactions (after swap)
    /// @param treasuryManager The treasury manager instance
    /// @param poolManager The pool manager instance
    /// @param sender The address executing the swap
    /// @param key The pool key
    /// @param swapParams The swap parameters
    /// @param delta The balance delta
    /// @param hookData The hook data
    /// @param insufficientProceeds Whether insufficient proceeds state is active
    /// @return dynamicFeeDelta The dynamic fee delta
    function processDynamicFeesAfterSwap(
        TreasuryManager treasuryManager,
        IPoolManager poolManager,
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData,
        bool insufficientProceeds
    ) external returns (int128) {
        if (swapParams.zeroForOne || insufficientProceeds) return 0; // Not a sell or insufficient proceeds
        
        MultiHopContext memory context = _decodeHookData(hookData);
        if (context.isMultiHop && !context.isUsdc) return 0; // Skip PlayerToken → PlayerToken multi-hops
        
        uint256 ethPriceUsd = DynamicFee.fetchEthPriceWithFallback();
        uint256 outputAmount = delta.amount0() < 0 
            ? uint256(uint128(-delta.amount0())) 
            : uint256(uint128(delta.amount0()));
        uint256 dynamicFeeBps = DynamicFee.calculateDynamicFee(outputAmount, ethPriceUsd);
        
        if (dynamicFeeBps == 0) return 0;
        
        uint256 totalFeeAmount = (outputAmount * dynamicFeeBps) / 10000;
        treasuryManager.distributeFees(poolManager, key.currency0, totalFeeAmount, sender, false);
        return int128(int256(totalFeeAmount));
    }

    /// @notice Decode hookData into MultiHopContext
    /// @param hookData Encoded multi-hop context data
    /// @return context Decoded multi-hop context
    function _decodeHookData(bytes calldata hookData) private pure returns (MultiHopContext memory context) {
        if (hookData.length == 0) {
            return MultiHopContext(false, false); // Single hop default
        }
        return abi.decode(hookData, (MultiHopContext));
    }
}