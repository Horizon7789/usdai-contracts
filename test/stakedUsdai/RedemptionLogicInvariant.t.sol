// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {StakedUSDaiStorage} from "src/StakedUSDaiStorage.sol";
import {RedemptionLogic} from "src/RedemptionLogic.sol";
import {IStakedUSDai} from "src/interfaces/IStakedUSDai.sol";

/// @dev Minimal storage-compatible harness for exercising the production library.
contract RedemptionLogicHarness is StakedUSDaiStorage {
    using EnumerableSet for EnumerableSet.UintSet;

    constructor() StakedUSDaiStorage(address(0), address(0), uint64(block.timestamp), address(0)) {}

    function request(uint256 shares, address controller) external returns (uint256) {
        return RedemptionLogic._requestRedeem(
            _getRedemptionStateStorage(), _genesisTimestamp, shares, controller
        );
    }

    function process(uint256 shares, uint256 sharePrice) external returns (uint256 amount) {
        (amount,) = RedemptionLogic._processRedemptions(
            _getRedemptionStateStorage(), shares, sharePrice
        );
        _getRedemptionStateStorage().balance += amount;
    }

    function withdraw(uint256 amount, address controller) external returns (uint256) {
        return RedemptionLogic._withdraw(_getRedemptionStateStorage(), amount, controller);
    }

    function redeem(uint256 shares, address controller) external returns (uint256) {
        return RedemptionLogic._redeem(_getRedemptionStateStorage(), shares, controller);
    }

    function redemption(uint256 id) external view returns (IStakedUSDai.Redemption memory) {
        return _getRedemptionStateStorage().redemptions[id];
    }

    function ids(address controller) external view returns (uint256[] memory) {
        return _getRedemptionStateStorage().redemptionIds[controller].values();
    }

    function available(address controller) external view returns (uint256 amount, uint256 shares) {
        uint256[] memory activeIds = _getRedemptionStateStorage().redemptionIds[controller].values();
        for (uint256 i; i < activeIds.length; ++i) {
            IStakedUSDai.Redemption storage item = _getRedemptionStateStorage().redemptions[activeIds[i]];
            amount += item.withdrawableAmount;
            shares += item.redeemableShares;
        }
    }

    function queueInfo() external view returns (uint256 index, uint256 head, uint256 tail) {
        StakedUSDaiStorage.RedemptionState storage state = _getRedemptionStateStorage();
        return (state.index, state.head, state.tail);
    }

    function accounting() external view returns (uint256 pending, uint256 balance) {
        StakedUSDaiStorage.RedemptionState storage state = _getRedemptionStateStorage();
        return (state.pending, state.balance);
    }
}

contract RedemptionLogicInvariantTest is Test {
    uint256 internal constant WAD = 1e18;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);

    RedemptionLogicHarness internal harness;

    function setUp() public {
        harness = new RedemptionLogicHarness();
    }

    function testFuzz_PartialWithdrawThenRedeemPreservesAccounting(uint96 rawWithdrawAmount) public {
        uint256 shares = 12 * WAD;
        uint256 sharePrice = 1.25e18;
        uint256 totalAmount = shares * sharePrice / WAD;
        uint256 withdrawAmount = bound(uint256(rawWithdrawAmount), 1, totalAmount - 1);

        harness.request(shares, ALICE);
        vm.warp(block.timestamp + 30 days + 1);

        assertEq(harness.process(shares, sharePrice), totalAmount);

        uint256 sharesConsumedByWithdraw = harness.withdraw(withdrawAmount, ALICE);
        _assertAccounting(ALICE, 0, totalAmount - withdrawAmount);

        uint256 remainingShares = shares - sharesConsumedByWithdraw;
        uint256 redeemedAmount = harness.redeem(remainingShares, ALICE);
        assertEq(redeemedAmount, totalAmount - withdrawAmount);

        _assertAccounting(ALICE, 0, 0);
    }

    function test_PartialWithdrawAndRedeemAcrossMultipleRequests() public {
        uint256 firstShares = 5 * WAD;
        uint256 secondShares = 7 * WAD;
        uint256 sharePrice = 1.2e18;
        uint256 totalShares = firstShares + secondShares;
        uint256 totalAmount = totalShares * sharePrice / WAD;

        harness.request(firstShares, ALICE);
        harness.request(secondShares, ALICE);
        vm.warp(block.timestamp + 30 days + 1);

        assertEq(harness.process(totalShares, sharePrice), totalAmount);

        uint256 firstWithdrawal = 3 * WAD;
        uint256 sharesConsumedByWithdraw = harness.withdraw(firstWithdrawal, ALICE);
        _assertAccounting(ALICE, 0, totalAmount - firstWithdrawal);

        uint256 sharesToRedeem = 2 * WAD;
        uint256 redeemedAmount = harness.redeem(sharesToRedeem, ALICE);
        assertGt(redeemedAmount, 0);
        _assertAccounting(ALICE, 0, totalAmount - firstWithdrawal - redeemedAmount);

        uint256[] memory activeIds = harness.ids(ALICE);
        uint256 remainingShares;
        for (uint256 i; i < activeIds.length; ++i) {
            IStakedUSDai.Redemption memory item = harness.redemption(activeIds[i]);
            remainingShares += item.pendingShares + item.redeemableShares;
        }
        assertEq(remainingShares, totalShares - sharesConsumedByWithdraw - sharesToRedeem);
    }

    function testFuzz_StatefulMultiControllerAccounting(bytes32 seed) public {
        address[3] memory users = [ALICE, BOB, CAROL];
        uint256 totalRequested;

        // Six independent requests across three controllers.
        for (uint256 i; i < 6; ++i) {
            uint256 shares = bound(_random(seed, i), 1e18, 20e18);
            harness.request(shares, users[i % users.length]);
            totalRequested += shares;
        }
        _assertGlobalAccounting();
        vm.warp(block.timestamp + 30 days + 1);

        // Service the queue in fuzz-selected chunks at varying share prices.
        uint256 remaining = totalRequested;
        uint256 step;
        while (remaining > 0) {
            uint256 minChunk = remaining > 1e18 ? 1e18 : 1;
            uint256 chunk = bound(_random(seed, 10 + step), minChunk, remaining);
            uint256 price = bound(_random(seed, 100 + step), 5e17, 15e17);
            harness.process(chunk, price);
            remaining -= chunk;
            _assertGlobalAccounting();
            ++step;
        }

        // Mix partial withdrawals and partial redemptions per controller.
        for (uint256 i; i < users.length; ++i) {
            address controller = users[i];
            (uint256 amount, uint256 shares) = harness.available(controller);
            if (amount > 0) {
                uint256 withdrawal = bound(_random(seed, 200 + i), 0, amount);
                if (withdrawal > 0) harness.withdraw(withdrawal, controller);
            }

            (, uint256 sharesAfterWithdrawal) = harness.available(controller);
            if (sharesAfterWithdrawal > 0) {
                uint256 redeemShares = bound(_random(seed, 300 + i), 0, sharesAfterWithdrawal);
                if (redeemShares > 0) harness.redeem(redeemShares, controller);
            }
            _assertGlobalAccounting();

            // Consume any residual claim via either full withdrawal or full redemption.
            (uint256 residualAmount, uint256 residualShares) = harness.available(controller);
            if (residualAmount > 0 && residualShares > 0) {
                if ((_random(seed, 400 + i) & 1) == 0) {
                    harness.withdraw(residualAmount, controller);
                } else {
                    harness.redeem(residualShares, controller);
                }
            }
            _assertGlobalAccounting();
        }

        (uint256 pending, uint256 balance) = harness.accounting();
        assertEq(pending, 0, "all requests should be serviced");
        assertEq(balance, 0, "all claims should be consumed");
    }

    function _random(bytes32 seed, uint256 nonce) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, nonce)));
    }

    function _assertGlobalAccounting() internal view {
        (uint256 globalPending, uint256 globalBalance) = harness.accounting();
        address[3] memory users = [ALICE, BOB, CAROL];
        uint256 sumPending;
        uint256 sumBalance;

        for (uint256 i; i < users.length; ++i) {
            uint256[] memory activeIds = harness.ids(users[i]);
            for (uint256 j; j < activeIds.length; ++j) {
                IStakedUSDai.Redemption memory item = harness.redemption(activeIds[j]);
                sumPending += item.pendingShares;
                sumBalance += item.withdrawableAmount;
            }
        }
        assertEq(sumPending, globalPending, "sum of controller pending shares mismatch");
        assertEq(sumBalance, globalBalance, "sum of controller claims mismatch");

        (uint256 index, uint256 head, uint256 tail) = harness.queueInfo();
        assertEq(tail, index, "tail should be latest redemption ID");
        assertEq(head == 0, globalPending == 0, "head and pending state mismatch");

        uint256 cursor = head;
        uint256 previous;
        uint256 visited;
        bool first = true;
        while (cursor != 0) {
            IStakedUSDai.Redemption memory item = harness.redemption(cursor);
            assertGt(item.pendingShares, 0, "queue contains a serviced request");
            if (!first) assertEq(item.prev, previous, "queue previous pointer mismatch");
            first = false;
            previous = cursor;
            cursor = item.next;
            ++visited;
            assertLe(visited, index, "queue traversal exceeded request count");
        }
    }

    function _assertAccounting(address controller, uint256 expectedPending, uint256 expectedBalance) internal view {
        (uint256 pending, uint256 balance) = harness.accounting();
        assertEq(pending, expectedPending, "global pending mismatch");
        assertEq(balance, expectedBalance, "global redemption balance mismatch");

        uint256[] memory activeIds = harness.ids(controller);
        uint256 outstandingAmount;
        uint256 outstandingPending;
        for (uint256 i; i < activeIds.length; ++i) {
            IStakedUSDai.Redemption memory item = harness.redemption(activeIds[i]);
            outstandingAmount += item.withdrawableAmount;
            outstandingPending += item.pendingShares;
        }
        assertEq(outstandingAmount, balance, "active redemption amounts do not sum to balance");
        assertEq(outstandingPending, pending, "active pending shares do not sum to global pending");
    }
}
