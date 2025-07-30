// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { SD59x18, exp, sd } from "@prb/math/src/SD59x18.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title Dynamic Fee Library
/// @author Isla Labs  
library DynamicFee {
    // ==========================================
    // CONSTANTS
    // ==========================================

    /// @notice Chainlink ETH-USD price feed on Base
    address internal constant CHAINLINK_ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    
    /// @notice Oracle validation constants
    uint256 internal constant MAX_STALENESS = 3600; // 1 hour
    uint256 internal constant FALLBACK_ETH_PRICE_USD = 2500000000; // $2,500 (6 decimals) to maintain swap functionality

    /// @notice Dynamic fee constants
    uint256 internal constant FEE_MIN_BPS = 100;
    uint256 internal constant SCALE_PARAMETER = 1000;
    uint256 internal constant ALPHA_TIER_1 = 100;
    uint256 internal constant ALPHA_TIER_2 = 120;
    uint256 internal constant ALPHA_TIER_3 = 50;
    uint256 internal constant ALPHA_TIER_4 = 100;
    uint256 internal constant FEE_START_TIER_1 = 500;
    uint256 internal constant FEE_START_TIER_2 = 481;
    uint256 internal constant FEE_START_TIER_3 = 322;
    uint256 internal constant FEE_START_TIER_4 = 123;
    uint256 internal constant TIER_1_THRESHOLD_USD = 500;
    uint256 internal constant TIER_2_THRESHOLD_USD = 5000;
    uint256 internal constant TIER_3_THRESHOLD_USD = 50000;

    // @notice Unused constant
    address internal constant ZERO_ADDRESS = 0x0000000000000000000000000000000000000000;

    // ==========================================
    // ERRORS & EVENTS
    // ==========================================

    error EthPriceFetchFailed();
    error ChainlinkPriceStale();
    error ChainlinkPriceInvalid();

    event EthPriceCalculated(uint256 ethPriceUsd, uint256 timestamp, string method);
    event ChainlinkPriceUsed(uint256 ethPriceUsd, uint256 timestamp);
    event FallbackUsed(uint256 emergencyPrice, string reason);

    // ==========================================
    // MAIN FUNCTIONS
    // ==========================================

    /// @notice Fetch ETH price for swaps (uses fallback if needed)
    /// @dev For swaps (failed price fetch doesn't interfere with execution)
    /// @return ethPriceUsd ETH price in USD (6 decimal precision)
    function fetchEthPriceWithFallback() external view returns (uint256 ethPriceUsd) {
        // Chainlink ETH-USD on Base
        try AggregatorV3Interface(CHAINLINK_ETH_USD_FEED).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            // Check if price is stale or invalid
            if (block.timestamp - updatedAt <= MAX_STALENESS && answer > 0) {
                uint256 oraclePrice = uint256(answer) / 100; // Convert 8→6 decimals
                return oraclePrice;
            }
        } catch {}
        
        // Return fallback price to keep swaps functional
        return FALLBACK_ETH_PRICE_USD;
    }

    /// @notice View ETH price for analytics (fails if stale/invalid)
    /// @dev For analytics (accurate data or honest failure)
    /// @return ethPriceUsd ETH price in USD (6 decimal precision)
    function viewEthPrice() external view returns (uint256 ethPriceUsd) {
        // Chainlink ETH-USD on Base
        try AggregatorV3Interface(CHAINLINK_ETH_USD_FEED).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            // Check staleness
            if (block.timestamp - updatedAt > MAX_STALENESS) {
                revert ChainlinkPriceStale();
            }
            // Check validity
            if (answer <= 0) {
                revert ChainlinkPriceInvalid();
            }
            
            return uint256(answer) / 100; // Convert 8→6 decimals
        } catch (bytes memory reason) {
            // Re-throw custom errors
            if (reason.length > 0) {
                assembly {
                    revert(add(32, reason), mload(reason))
                }
            }
            // For other failures, throw generic error
            revert EthPriceFetchFailed();
        }
    }

    /// @notice Fetch ETH price with events (for contracts that need logging)
    /// @dev Uses fallback like fetchEthPriceWithFallback but emits events
    /// @return ethPriceUsd ETH price in USD (6 decimal precision)
    function fetchEthPriceWithEvents() external returns (uint256 ethPriceUsd) {
        // Chainlink ETH-USD on Base
        try AggregatorV3Interface(CHAINLINK_ETH_USD_FEED).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            // Check if price is stale or invalid
            if (block.timestamp - updatedAt <= MAX_STALENESS && answer > 0) {
                uint256 oraclePrice = uint256(answer) / 100; // Convert 8→6 decimals
                
                emit ChainlinkPriceUsed(oraclePrice, block.timestamp);
                emit EthPriceCalculated(oraclePrice, block.timestamp, "Chainlink_primary");
                return oraclePrice;
            } else {
                emit FallbackUsed(FALLBACK_ETH_PRICE_USD, block.timestamp - updatedAt > MAX_STALENESS ? "Chainlink_stale" : "Chainlink_invalid");
            }
        } catch {
            emit FallbackUsed(FALLBACK_ETH_PRICE_USD, "Chainlink_failed");
        }
        
        // Return fallback price
        emit EthPriceCalculated(FALLBACK_ETH_PRICE_USD, block.timestamp, "Fallback_price");
        return FALLBACK_ETH_PRICE_USD;
    }

    /// @notice Calculate dynamic fee using USD-based exponential decay
    /// @param volumeEth Volume in ETH (wei)
    /// @param ethPriceUsd ETH price in USD (6 decimals)
    /// @return feeBps Fee in basis points
    function calculateDynamicFee(uint256 volumeEth, uint256 ethPriceUsd) external pure returns (uint256 feeBps) {
        uint256 volumeUsd = (volumeEth * ethPriceUsd) / (1 ether * 1e6);
        
        (uint256 alpha, uint256 vStartUsd, uint256 feeStart) = getTierParameters(volumeUsd);
        
        uint256 volumeDiff = volumeUsd > vStartUsd ? volumeUsd - vStartUsd : 0;
        uint256 exponent = (alpha * volumeDiff) / SCALE_PARAMETER;
        
        uint256 expValue = calculateExponentialDecayPRB(exponent);
        
        uint256 feeRange = feeStart - FEE_MIN_BPS;
        uint256 dynamicComponent = (feeRange * expValue) / 1 ether;
        
        uint256 result = FEE_MIN_BPS + dynamicComponent;
        
        return result < FEE_MIN_BPS ? FEE_MIN_BPS : result;
    }

    /// @notice Get tier parameters based on USD volume
    function getTierParameters(uint256 volumeUsd) public pure returns (uint256 alpha, uint256 vStartUsd, uint256 feeStart) {
        if (volumeUsd <= TIER_1_THRESHOLD_USD) {
            return (ALPHA_TIER_1, 0, FEE_START_TIER_1);
        } else if (volumeUsd <= TIER_2_THRESHOLD_USD) {
            return (ALPHA_TIER_2, TIER_1_THRESHOLD_USD, FEE_START_TIER_2);
        } else if (volumeUsd <= TIER_3_THRESHOLD_USD) {
            return (ALPHA_TIER_3, TIER_2_THRESHOLD_USD, FEE_START_TIER_3);
        } else {
            return (ALPHA_TIER_4, TIER_3_THRESHOLD_USD, FEE_START_TIER_4);
        }
    }

    /// @notice Calculate e^(-x) using PRBMath
    function calculateExponentialDecayPRB(uint256 x) public pure returns (uint256) {
        if (x == 0) return 1 ether;
        if (x >= 10000) return 0;
        
        SD59x18 negativeX = sd(-int256(x)) / sd(1000);
        SD59x18 result = exp(negativeX);
        
        return uint256(result.unwrap());
    }
}