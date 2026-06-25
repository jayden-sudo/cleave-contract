// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Series} from "../src/Series.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {PythLazerOracle} from "../src/oracle/PythLazerOracle.sol";

/// Tests for the Lazer adapter using a REAL Pyth-signed Lazer update fixture (the same one Pyth
/// ships in lazer/contracts/evm/test/PythLazer.t.sol). The signature is verified on-chain, so
/// these exercise the genuine trust-minimization path, not a mock.
contract PythLazerOracleTest is Test {
    // Real signer of the fixture below (Pyth's test key); recovers via ECDSA from the update.
    address constant SIGNER = 0xb8d50f0bAE75BF6E03c104903d7C3aFc4a6596Da;
    uint32 constant FEED_ID = 6; // the feed encoded in the fixture
    uint256 constant PUBLISH = 1_738_270_008; // payload timestamp 1738270008001000us -> seconds
    uint256 constant PRICE_1E18 = 1e18; // price 100000000 * 10^(18-8)

    uint256 constant MAX_STALENESS = 1 days;
    uint64 constant PIN_TOLERANCE = 1 hours;

    // Real signed EVM Lazer update: magic|r|s|v|len|payload (feed 6: price 1e8, expo -8).
    bytes constant FIXTURE =
        hex"2a22999a9ee4e2a3df5affd0ad8c7c46c96d3b5ef197dd653bedd8f44a4b6b69b767fbc66341e80b80acb09ead98c60d169b9a99657ebada101f447378f227bffbc69d3d01003493c7d37500062cf28659c1e801010000000605000000000005f5e10002000000000000000001000000000000000003000104fff8";

    PythLazerOracle oracle;
    address alice = address(0xA11CE);

    receive() external payable {}

    function setUp() public {
        oracle = new PythLazerOracle(SIGNER, FEED_ID, MAX_STALENESS, PIN_TOLERANCE);
        vm.warp(PUBLISH + 60); // a bit after the fixture's publish time
    }

    // --- live price (push + read) ---

    function test_update_then_price() public {
        oracle.update(FIXTURE);
        assertEq(oracle.lastPrice(), PRICE_1E18, "scales price*10^(18+expo)");
        assertEq(oracle.lastPublishTime(), PUBLISH, "publish time in seconds");
        assertEq(oracle.price(), PRICE_1E18, "fresh price reads back");
    }

    function test_price_reverts_before_any_update() public {
        vm.expectRevert(PythLazerOracle.NoPrice.selector);
        oracle.price();
    }

    function test_price_reverts_when_stale() public {
        oracle.update(FIXTURE);
        vm.warp(PUBLISH + MAX_STALENESS + 1);
        vm.expectRevert(PythLazerOracle.StalePrice.selector);
        oracle.price();
    }

    function test_price_accepts_future_dated_publish() public {
        // Mainnet-fork case: chain clock lags the (real-time) publish time -> not stale.
        vm.warp(PUBLISH - 5 hours);
        oracle.update(FIXTURE);
        assertEq(oracle.price(), PRICE_1E18, "publish ahead of block.timestamp is accepted");
    }

    function test_update_ignores_older_publish() public {
        oracle.update(FIXTURE);
        // a second identical update has the same publish time -> not newer -> state unchanged
        oracle.update(FIXTURE);
        assertEq(oracle.lastPublishTime(), PUBLISH);
    }

    // --- signature / feed guards (the trust-minimization core) ---

    function test_update_reverts_untrusted_signer() public {
        PythLazerOracle wrong = new PythLazerOracle(address(0xBEEF), FEED_ID, MAX_STALENESS, PIN_TOLERANCE);
        vm.expectRevert(PythLazerOracle.UntrustedSigner.selector);
        wrong.update(FIXTURE);
    }

    function test_update_reverts_on_tampered_payload() public {
        bytes memory bad = FIXTURE;
        bad[80] = bytes1(uint8(bad[80]) ^ 0xFF); // flip a byte inside the signed payload
        vm.expectRevert(); // recovered signer changes -> UntrustedSigner (or InvalidSignature)
        oracle.update(bad);
    }

    function test_update_reverts_wrong_feed() public {
        PythLazerOracle other = new PythLazerOracle(SIGNER, 7, MAX_STALENESS, PIN_TOLERANCE);
        vm.expectRevert(PythLazerOracle.FeedNotFound.selector);
        other.update(FIXTURE);
    }

    function test_update_reverts_bad_magic() public {
        bytes memory bad = FIXTURE;
        bad[0] = 0x00; // corrupt the EVM envelope magic
        vm.expectRevert(PythLazerOracle.InvalidMagic.selector);
        oracle.update(bad);
    }

    // --- settlement: pin / priceAt ---

    function test_pin_then_priceAt() public {
        uint256 maturity = PUBLISH; // publish == maturity is in-window
        uint256 px = oracle.pin(maturity, FIXTURE);
        assertEq(px, PRICE_1E18);
        assertEq(oracle.priceAt(maturity), PRICE_1E18);
    }

    function test_priceAt_reverts_before_pin() public {
        vm.expectRevert(PythLazerOracle.NotPinned.selector);
        oracle.priceAt(PUBLISH);
    }

    function test_pin_double_reverts() public {
        oracle.pin(PUBLISH, FIXTURE);
        vm.expectRevert(PythLazerOracle.AlreadyPinned.selector);
        oracle.pin(PUBLISH, FIXTURE);
    }

    function test_pin_reverts_future_maturity() public {
        vm.expectRevert(PythLazerOracle.FutureTimestamp.selector);
        oracle.pin(block.timestamp + 1, FIXTURE);
    }

    function test_pin_reverts_publish_before_maturity() public {
        // maturity after the publish time -> publishSec < endTimestamp -> out of window
        uint256 maturity = PUBLISH + 30;
        vm.expectRevert(PythLazerOracle.OutOfWindow.selector);
        oracle.pin(maturity, FIXTURE);
    }

    function test_pin_reverts_publish_after_window() public {
        // maturity far before publish, beyond pinTolerance -> publishSec > endTimestamp + tol
        uint256 maturity = PUBLISH - PIN_TOLERANCE - 10;
        vm.expectRevert(PythLazerOracle.OutOfWindow.selector);
        oracle.pin(maturity, FIXTURE);
    }

    // --- integration: a Lazer-priced Series settles via pin() then settle() then redeem() ---

    function test_integration_split_pin_settle_redeem() public {
        uint256 maturity = PUBLISH;
        vm.warp(PUBLISH - 100); // create before maturity
        Series series = new Series(
            "HK.2513 (fixture)", 0.8e18, maturity, IPriceOracle(address(oracle)), address(0), "P", "P", "N", "N"
        );

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        series.split{value: 10 ether}();

        vm.warp(PUBLISH + 100); // past maturity
        vm.expectRevert(PythLazerOracle.NotPinned.selector);
        series.settle();

        oracle.pin(maturity, FIXTURE);
        series.settle();
        assertTrue(series.settled(), "settles once the Lazer price is pinned");
        // price 1e18, strike 0.8e18 -> f = min(1, 0.8/1) = 0.8
        assertEq(series.f(), 0.8e18, "split fraction from the verified price");

        uint256 before = alice.balance;
        vm.startPrank(alice);
        series.redeem(series.P().balanceOf(alice), series.N().balanceOf(alice));
        vm.stopPrank();
        assertApproxEqAbs(alice.balance - before, 10 ether, 2, "P+N redeems ~ deposit");
    }
}
