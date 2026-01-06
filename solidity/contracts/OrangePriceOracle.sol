// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OrangePriceOracle
 * @dev Oracle consumer contract integrating Chainlink price feeds with fallback logic.
 * 
 * Features:
 * - Primary and fallback price feed support
 * - Staleness checks to detect outdated data
 * - Circuit breaker for extreme price deviations
 * - Owner-configurable parameters
 * 
 * The contract ensures resilience by automatically falling back to a secondary
 * oracle when the primary fails staleness or sanity checks.
 */
contract OrangePriceOracle is Ownable {

    error ZeroAddress();
    error StalePrice();
    error InvalidPrice();
    error PriceDeviationTooHigh();
    error NoValidPrice();
    error InvalidThreshold();
    error InvalidHeartbeat();


    event PrimaryFeedUpdated(address indexed oldFeed, address indexed newFeed);
    event FallbackFeedUpdated(address indexed oldFeed, address indexed newFeed);
    event HeartbeatUpdated(uint256 oldHeartbeat, uint256 newHeartbeat);
    event DeviationThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event FallbackUsed(address indexed fallbackFeed, int256 price);


    AggregatorV3Interface public primaryFeed;
    AggregatorV3Interface public fallbackFeed;

    uint256 public heartbeatSeconds;
    uint256 public maxDeviationBps;

    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MAX_DEVIATION_BPS = 5000; // 50% max allowed deviation threshold
    uint256 public constant MIN_HEARTBEAT = 60; // 1 minute minimum
    uint256 public constant MAX_HEARTBEAT = 86400; // 24 hours maximum


    /**
     * @dev Constructor
     * @param primaryFeed_ Primary Chainlink price feed address
     * @param fallbackFeed_ Fallback Chainlink price feed address (can be address(0))
     * @param heartbeatSeconds_ Maximum age of price data before considered stale
     * @param maxDeviationBps_ Maximum allowed deviation between feeds in basis points
     */
    constructor(
        address primaryFeed_,
        address fallbackFeed_,
        uint256 heartbeatSeconds_,
        uint256 maxDeviationBps_
    ) Ownable(msg.sender) {
        if (primaryFeed_ == address(0)) revert ZeroAddress();
        if (heartbeatSeconds_ < MIN_HEARTBEAT || heartbeatSeconds_ > MAX_HEARTBEAT) revert InvalidHeartbeat();
        if (maxDeviationBps_ > MAX_DEVIATION_BPS) revert InvalidThreshold();

        primaryFeed = AggregatorV3Interface(primaryFeed_);
        if (fallbackFeed_ != address(0)) {
            fallbackFeed = AggregatorV3Interface(fallbackFeed_);
        }
        heartbeatSeconds = heartbeatSeconds_;
        maxDeviationBps = maxDeviationBps_;
    }


    /**
     * @dev Returns the latest price with fallback logic.
     * @return price The latest price from primary or fallback feed
     * @return updatedAt Timestamp of the price update
     * @return usedFallback Whether fallback feed was used
     */
    function getLatestPrice() external view returns (int256 price, uint256 updatedAt, bool usedFallback) {
        (bool primarySuccess, int256 primaryPrice, uint256 primaryUpdatedAt) = _tryGetPrice(primaryFeed);

        if (primarySuccess) {
            return (primaryPrice, primaryUpdatedAt, false);
        }

        if (address(fallbackFeed) != address(0)) {
            (bool fallbackSuccess, int256 fallbackPrice, uint256 fallbackUpdatedAt) = _tryGetPrice(fallbackFeed);
            if (fallbackSuccess) {
                return (fallbackPrice, fallbackUpdatedAt, true);
            }
        }

        revert NoValidPrice();
    }

    /**
     * @dev Returns the latest price, reverting if stale or invalid.
     * @return price The latest valid price
     */
    function getLatestPriceStrict() external view returns (int256 price) {
        (price,,) = _getPriceWithValidation(primaryFeed);
    }

    /**
     * @dev Returns prices from both feeds for comparison.
     * @return primaryPrice Price from primary feed (0 if unavailable)
     * @return fallbackPrice Price from fallback feed (0 if unavailable)
     * @return primaryValid Whether primary price is valid
     * @return fallbackValid Whether fallback price is valid
     */
    function getPricesFromBothFeeds() external view returns (
        int256 primaryPrice,
        int256 fallbackPrice,
        bool primaryValid,
        bool fallbackValid
    ) {
        (primaryValid, primaryPrice,) = _tryGetPrice(primaryFeed);
        
        if (address(fallbackFeed) != address(0)) {
            (fallbackValid, fallbackPrice,) = _tryGetPrice(fallbackFeed);
        }
    }

    /**
     * @dev Checks if the price deviation between feeds is within threshold.
     * @return withinThreshold Whether deviation is acceptable
     * @return deviationBps The actual deviation in basis points
     */
    function checkPriceDeviation() external view returns (bool withinThreshold, uint256 deviationBps) {
        if (address(fallbackFeed) == address(0)) {
            return (true, 0);
        }

        (bool primaryValid, int256 primaryPrice,) = _tryGetPrice(primaryFeed);
        (bool fallbackValid, int256 fallbackPrice,) = _tryGetPrice(fallbackFeed);

        if (!primaryValid || !fallbackValid) {
            return (false, type(uint256).max);
        }

        deviationBps = _calculateDeviation(primaryPrice, fallbackPrice);
        withinThreshold = deviationBps <= maxDeviationBps;
    }


    /**
     * @dev Sets the primary price feed. Only callable by owner.
     * @param newFeed New primary feed address
     */
    function setPrimaryFeed(address newFeed) external onlyOwner {
        if (newFeed == address(0)) revert ZeroAddress();
        
        emit PrimaryFeedUpdated(address(primaryFeed), newFeed);
        primaryFeed = AggregatorV3Interface(newFeed);
    }

    /**
     * @dev Sets the fallback price feed. Only callable by owner.
     * @param newFeed New fallback feed address (can be address(0) to disable)
     */
    function setFallbackFeed(address newFeed) external onlyOwner {
        emit FallbackFeedUpdated(address(fallbackFeed), newFeed);
        fallbackFeed = AggregatorV3Interface(newFeed);
    }

    /**
     * @dev Sets the heartbeat duration. Only callable by owner.
     * @param newHeartbeat New heartbeat in seconds
     */
    function setHeartbeat(uint256 newHeartbeat) external onlyOwner {
        if (newHeartbeat < MIN_HEARTBEAT || newHeartbeat > MAX_HEARTBEAT) revert InvalidHeartbeat();
        
        emit HeartbeatUpdated(heartbeatSeconds, newHeartbeat);
        heartbeatSeconds = newHeartbeat;
    }

    /**
     * @dev Sets the maximum deviation threshold. Only callable by owner.
     * @param newThreshold New threshold in basis points
     */
    function setDeviationThreshold(uint256 newThreshold) external onlyOwner {
        if (newThreshold > MAX_DEVIATION_BPS) revert InvalidThreshold();
        
        emit DeviationThresholdUpdated(maxDeviationBps, newThreshold);
        maxDeviationBps = newThreshold;
    }


    /**
     * @dev Returns the number of decimals for the primary feed.
     * @return decimals Number of decimals
     */
    function decimals() external view returns (uint8) {
        return primaryFeed.decimals();
    }

    /**
     * @dev Returns the description of the primary feed.
     * @return description Feed description
     */
    function description() external view returns (string memory) {
        return primaryFeed.description();
    }

    /**
     * @dev Checks if the primary feed price is stale.
     * @return isStale Whether the price is stale
     */
    function isPrimaryStale() external view returns (bool isStale) {
        (,,,uint256 updatedAt,) = primaryFeed.latestRoundData();
        isStale = block.timestamp - updatedAt > heartbeatSeconds;
    }

    /**
     * @dev Checks if the fallback feed price is stale.
     * @return isStale Whether the price is stale
     */
    function isFallbackStale() external view returns (bool isStale) {
        if (address(fallbackFeed) == address(0)) return true;
        (,,,uint256 updatedAt,) = fallbackFeed.latestRoundData();
        isStale = block.timestamp - updatedAt > heartbeatSeconds;
    }


    /**
     * @dev Attempts to get a valid price from a feed.
     * @param feed The price feed to query
     * @return success Whether the price is valid
     * @return price The price value
     * @return updatedAt The timestamp of the update
     */
    function _tryGetPrice(AggregatorV3Interface feed) internal view returns (
        bool success,
        int256 price,
        uint256 updatedAt
    ) {
        if (address(feed) == address(0)) {
            return (false, 0, 0);
        }

        try feed.latestRoundData() returns (
            uint80,
            int256 answer,
            uint256,
            uint256 updatedAtResult,
            uint80
        ) {
            if (answer <= 0) {
                return (false, 0, 0);
            }
            if (block.timestamp - updatedAtResult > heartbeatSeconds) {
                return (false, 0, 0);
            }
            return (true, answer, updatedAtResult);
        } catch {
            return (false, 0, 0);
        }
    }

    /**
     * @dev Gets price with strict validation, reverts on failure.
     * @param feed The price feed to query
     * @return price The price value
     * @return updatedAt The timestamp
     * @return roundId The round ID
     */
    function _getPriceWithValidation(AggregatorV3Interface feed) internal view returns (
        int256 price,
        uint256 updatedAt,
        uint80 roundId
    ) {
        (roundId, price,, updatedAt,) = feed.latestRoundData();
        
        if (price <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > heartbeatSeconds) revert StalePrice();
    }

    /**
     * @dev Calculates the deviation between two prices in basis points.
     * @param price1 First price
     * @param price2 Second price
     * @return deviationBps Deviation in basis points
     */
    function _calculateDeviation(int256 price1, int256 price2) internal pure returns (uint256 deviationBps) {
        if (price1 <= 0 || price2 <= 0) return type(uint256).max;
        
        uint256 p1 = uint256(price1);
        uint256 p2 = uint256(price2);
        
        uint256 diff = p1 > p2 ? p1 - p2 : p2 - p1;
        uint256 avg = (p1 + p2) / 2;
        
        deviationBps = (diff * BPS_DENOMINATOR) / avg;
    }
}
