// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../contracts/OrangePriceOracle.sol";

/**
 * @dev Mock Chainlink aggregator for testing
 */
contract MockAggregator is AggregatorV3Interface {
    int256 private _price;
    uint256 private _updatedAt;
    uint8 private _decimals;
    string private _description;
    bool private _shouldRevert;

    constructor(int256 price_, uint8 decimals_, string memory description_) {
        _price = price_;
        _updatedAt = block.timestamp;
        _decimals = decimals_;
        _description = description_;
    }

    function setPrice(int256 price_) external {
        _price = price_;
        _updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function setShouldRevert(bool shouldRevert_) external {
        _shouldRevert = shouldRevert_;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external pure override returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        revert("Not implemented");
    }

    function latestRoundData() external view override returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        if (_shouldRevert) revert("Feed error");
        return (1, _price, _updatedAt, _updatedAt, 1);
    }
}


contract OrangePriceOracleTest is Test {

    OrangePriceOracle public oracle;
    MockAggregator public primaryMock;
    MockAggregator public fallbackMock;

    address public owner = address(this);
    address public user = address(0x1);

    int256 constant INITIAL_PRICE = 2000e8; // $2000 with 8 decimals
    int256 constant FALLBACK_PRICE = 2010e8; // Slightly different price
    uint256 constant HEARTBEAT = 3600; // 1 hour
    uint256 constant DEVIATION_BPS = 500; // 5%


    function setUp() public {
        primaryMock = new MockAggregator(INITIAL_PRICE, 8, "ETH / USD");
        fallbackMock = new MockAggregator(FALLBACK_PRICE, 8, "ETH / USD Fallback");

        oracle = new OrangePriceOracle(
            address(primaryMock),
            address(fallbackMock),
            HEARTBEAT,
            DEVIATION_BPS
        );
    }


    function test_Constructor_SetsParameters() public view {
        assertEq(address(oracle.primaryFeed()), address(primaryMock));
        assertEq(address(oracle.fallbackFeed()), address(fallbackMock));
        assertEq(oracle.heartbeatSeconds(), HEARTBEAT);
        assertEq(oracle.maxDeviationBps(), DEVIATION_BPS);
    }

    function test_Constructor_RevertsOnZeroPrimaryFeed() public {
        vm.expectRevert(OrangePriceOracle.ZeroAddress.selector);
        new OrangePriceOracle(address(0), address(fallbackMock), HEARTBEAT, DEVIATION_BPS);
    }

    function test_Constructor_AllowsZeroFallbackFeed() public {
        OrangePriceOracle oracleNoFallback = new OrangePriceOracle(
            address(primaryMock),
            address(0),
            HEARTBEAT,
            DEVIATION_BPS
        );
        assertEq(address(oracleNoFallback.fallbackFeed()), address(0));
    }

    function test_Constructor_RevertsOnInvalidHeartbeat() public {
        vm.expectRevert(OrangePriceOracle.InvalidHeartbeat.selector);
        new OrangePriceOracle(address(primaryMock), address(0), 30, DEVIATION_BPS); // Too low

        vm.expectRevert(OrangePriceOracle.InvalidHeartbeat.selector);
        new OrangePriceOracle(address(primaryMock), address(0), 100000, DEVIATION_BPS); // Too high
    }

    function test_Constructor_RevertsOnInvalidThreshold() public {
        vm.expectRevert(OrangePriceOracle.InvalidThreshold.selector);
        new OrangePriceOracle(address(primaryMock), address(0), HEARTBEAT, 6000); // > 50%
    }


    function test_GetLatestPrice_ReturnsPrimaryPrice() public view {
        (int256 price, uint256 updatedAt, bool usedFallback) = oracle.getLatestPrice();
        
        assertEq(price, INITIAL_PRICE);
        assertGt(updatedAt, 0);
        assertFalse(usedFallback);
    }

    function test_GetLatestPrice_UsesFallbackOnStalePrice() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        fallbackMock.setPrice(FALLBACK_PRICE); // This updates timestamp to current

        (int256 price,, bool usedFallback) = oracle.getLatestPrice();
        
        assertEq(price, FALLBACK_PRICE);
        assertTrue(usedFallback);
    }

    function test_GetLatestPrice_UsesFallbackOnInvalidPrice() public {
        primaryMock.setPrice(0);

        (int256 price,, bool usedFallback) = oracle.getLatestPrice();
        
        assertEq(price, FALLBACK_PRICE);
        assertTrue(usedFallback);
    }

    function test_GetLatestPrice_UsesFallbackOnNegativePrice() public {
        primaryMock.setPrice(-100);

        (int256 price,, bool usedFallback) = oracle.getLatestPrice();
        
        assertEq(price, FALLBACK_PRICE);
        assertTrue(usedFallback);
    }

    function test_GetLatestPrice_UsesFallbackOnRevert() public {
        primaryMock.setShouldRevert(true);

        (int256 price,, bool usedFallback) = oracle.getLatestPrice();
        
        assertEq(price, FALLBACK_PRICE);
        assertTrue(usedFallback);
    }

    function test_GetLatestPrice_RevertsWhenBothFeedsFail() public {
        primaryMock.setPrice(0);
        fallbackMock.setPrice(0);

        vm.expectRevert(OrangePriceOracle.NoValidPrice.selector);
        oracle.getLatestPrice();
    }

    function test_GetLatestPrice_RevertsWhenNoFallbackAndPrimaryFails() public {
        OrangePriceOracle oracleNoFallback = new OrangePriceOracle(
            address(primaryMock),
            address(0),
            HEARTBEAT,
            DEVIATION_BPS
        );
        
        primaryMock.setPrice(0);

        vm.expectRevert(OrangePriceOracle.NoValidPrice.selector);
        oracleNoFallback.getLatestPrice();
    }


    function test_GetLatestPriceStrict_ReturnsPrice() public view {
        int256 price = oracle.getLatestPriceStrict();
        assertEq(price, INITIAL_PRICE);
    }

    function test_GetLatestPriceStrict_RevertsOnStalePrice() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);

        vm.expectRevert(OrangePriceOracle.StalePrice.selector);
        oracle.getLatestPriceStrict();
    }

    function test_GetLatestPriceStrict_RevertsOnInvalidPrice() public {
        primaryMock.setPrice(0);

        vm.expectRevert(OrangePriceOracle.InvalidPrice.selector);
        oracle.getLatestPriceStrict();
    }


    function test_GetPricesFromBothFeeds_ReturnsBothPrices() public view {
        (
            int256 primaryPrice,
            int256 fallbackPrice,
            bool primaryValid,
            bool fallbackValid
        ) = oracle.getPricesFromBothFeeds();

        assertEq(primaryPrice, INITIAL_PRICE);
        assertEq(fallbackPrice, FALLBACK_PRICE);
        assertTrue(primaryValid);
        assertTrue(fallbackValid);
    }

    function test_GetPricesFromBothFeeds_HandlesInvalidPrimary() public {
        primaryMock.setPrice(0);

        (
            int256 primaryPrice,
            int256 fallbackPrice,
            bool primaryValid,
            bool fallbackValid
        ) = oracle.getPricesFromBothFeeds();

        assertEq(primaryPrice, 0);
        assertEq(fallbackPrice, FALLBACK_PRICE);
        assertFalse(primaryValid);
        assertTrue(fallbackValid);
    }


    function test_CheckPriceDeviation_WithinThreshold() public view {
        (bool withinThreshold, uint256 deviationBps) = oracle.checkPriceDeviation();
        
        assertTrue(withinThreshold);
        assertLt(deviationBps, DEVIATION_BPS);
    }

    function test_CheckPriceDeviation_ExceedsThreshold() public {
        fallbackMock.setPrice(2500e8); // 25% higher

        (bool withinThreshold, uint256 deviationBps) = oracle.checkPriceDeviation();
        
        assertFalse(withinThreshold);
        assertGt(deviationBps, DEVIATION_BPS);
    }

    function test_CheckPriceDeviation_NoFallback() public {
        OrangePriceOracle oracleNoFallback = new OrangePriceOracle(
            address(primaryMock),
            address(0),
            HEARTBEAT,
            DEVIATION_BPS
        );

        (bool withinThreshold, uint256 deviationBps) = oracleNoFallback.checkPriceDeviation();
        
        assertTrue(withinThreshold);
        assertEq(deviationBps, 0);
    }


    function test_SetPrimaryFeed_UpdatesFeed() public {
        MockAggregator newPrimary = new MockAggregator(3000e8, 8, "New Primary");
        
        oracle.setPrimaryFeed(address(newPrimary));
        
        assertEq(address(oracle.primaryFeed()), address(newPrimary));
    }

    function test_SetPrimaryFeed_EmitsEvent() public {
        MockAggregator newPrimary = new MockAggregator(3000e8, 8, "New Primary");
        
        vm.expectEmit(true, true, false, false);
        emit OrangePriceOracle.PrimaryFeedUpdated(address(primaryMock), address(newPrimary));
        
        oracle.setPrimaryFeed(address(newPrimary));
    }

    function test_SetPrimaryFeed_RevertsOnZeroAddress() public {
        vm.expectRevert(OrangePriceOracle.ZeroAddress.selector);
        oracle.setPrimaryFeed(address(0));
    }

    function test_SetPrimaryFeed_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        oracle.setPrimaryFeed(address(fallbackMock));
    }


    function test_SetFallbackFeed_UpdatesFeed() public {
        MockAggregator newFallback = new MockAggregator(3000e8, 8, "New Fallback");
        
        oracle.setFallbackFeed(address(newFallback));
        
        assertEq(address(oracle.fallbackFeed()), address(newFallback));
    }

    function test_SetFallbackFeed_AllowsZeroToDisable() public {
        oracle.setFallbackFeed(address(0));
        assertEq(address(oracle.fallbackFeed()), address(0));
    }

    function test_SetFallbackFeed_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        oracle.setFallbackFeed(address(primaryMock));
    }


    function test_SetHeartbeat_UpdatesHeartbeat() public {
        uint256 newHeartbeat = 7200;
        
        oracle.setHeartbeat(newHeartbeat);
        
        assertEq(oracle.heartbeatSeconds(), newHeartbeat);
    }

    function test_SetHeartbeat_EmitsEvent() public {
        uint256 newHeartbeat = 7200;
        
        vm.expectEmit(false, false, false, true);
        emit OrangePriceOracle.HeartbeatUpdated(HEARTBEAT, newHeartbeat);
        
        oracle.setHeartbeat(newHeartbeat);
    }

    function test_SetHeartbeat_RevertsOnInvalidValue() public {
        vm.expectRevert(OrangePriceOracle.InvalidHeartbeat.selector);
        oracle.setHeartbeat(30);
    }

    function test_SetHeartbeat_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        oracle.setHeartbeat(7200);
    }


    function test_SetDeviationThreshold_UpdatesThreshold() public {
        uint256 newThreshold = 1000;
        
        oracle.setDeviationThreshold(newThreshold);
        
        assertEq(oracle.maxDeviationBps(), newThreshold);
    }

    function test_SetDeviationThreshold_RevertsOnTooHigh() public {
        vm.expectRevert(OrangePriceOracle.InvalidThreshold.selector);
        oracle.setDeviationThreshold(6000);
    }

    function test_SetDeviationThreshold_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        oracle.setDeviationThreshold(1000);
    }


    function test_Decimals_ReturnsCorrectValue() public view {
        assertEq(oracle.decimals(), 8);
    }

    function test_Description_ReturnsCorrectValue() public view {
        assertEq(oracle.description(), "ETH / USD");
    }

    function test_IsPrimaryStale_ReturnsFalseWhenFresh() public view {
        assertFalse(oracle.isPrimaryStale());
    }

    function test_IsPrimaryStale_ReturnsTrueWhenStale() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        assertTrue(oracle.isPrimaryStale());
    }

    function test_IsFallbackStale_ReturnsFalseWhenFresh() public view {
        assertFalse(oracle.isFallbackStale());
    }

    function test_IsFallbackStale_ReturnsTrueWhenNoFallback() public {
        OrangePriceOracle oracleNoFallback = new OrangePriceOracle(
            address(primaryMock),
            address(0),
            HEARTBEAT,
            DEVIATION_BPS
        );
        assertTrue(oracleNoFallback.isFallbackStale());
    }


    function test_Integration_PriceUpdateCycle() public {
        (int256 price1,,) = oracle.getLatestPrice();
        assertEq(price1, INITIAL_PRICE);

        primaryMock.setPrice(2100e8);
        (int256 price2,,) = oracle.getLatestPrice();
        assertEq(price2, 2100e8);

        vm.warp(block.timestamp + HEARTBEAT + 1);
        fallbackMock.setPrice(FALLBACK_PRICE); // Refresh fallback timestamp
        (int256 price3,, bool usedFallback) = oracle.getLatestPrice();
        assertEq(price3, FALLBACK_PRICE);
        assertTrue(usedFallback);
    }

    function test_Integration_FullFailover() public {
        (int256 price1,, bool fb1) = oracle.getLatestPrice();
        assertEq(price1, INITIAL_PRICE);
        assertFalse(fb1);

        primaryMock.setShouldRevert(true);
        (int256 price2,, bool fb2) = oracle.getLatestPrice();
        assertEq(price2, FALLBACK_PRICE);
        assertTrue(fb2);

        fallbackMock.setPrice(0);
        vm.expectRevert(OrangePriceOracle.NoValidPrice.selector);
        oracle.getLatestPrice();
    }
}
