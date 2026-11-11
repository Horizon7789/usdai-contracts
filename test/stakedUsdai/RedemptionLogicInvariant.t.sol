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

    function accounting() external view returns (uint256 pending, uint256 balance) {
        StakedUSDaiStorage.RedemptionState storage state = _getRedemptionStateStorage();
        return (state.pending, state.balance);
    }
}

contract RedemptionLogicInvariantTest is Test {
    uint256 internal constant WAD = 1e18;
    address internal constant ALICE = address(0xA11CE);

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
