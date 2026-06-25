// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

// --- MOCKS ---

contract MockAsset {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
}

contract MockMellowClaimer {
    MockAsset public asset;
    uint256 public claimableAmount;

    constructor(MockAsset _asset) { asset = _asset; }
    function setClaimableAmount(uint256 amount) external { claimableAmount = amount; }

    function multiAcceptAndClaim(address recipient, uint256 maxAssets) external returns (uint256) {
        uint256 toClaim = claimableAmount;
        if (toClaim > maxAssets) toClaim = maxAssets;
        asset.mint(recipient, toClaim);
        return toClaim;
    }
}

// --- VULNERABLE LOGIC HARNESS ---
contract VulnerableMellowAdapter {
    uint256 public constant MAX_ASSETS_BUFFER = 100;
    error InsufficientClaimedException();

    function claimLogic(
        MockAsset asset,
        MockMellowClaimer claimer,
        address creditAccount,
        uint256 maxAssets
    ) external {
        uint256 assetBalanceBefore = asset.balanceOf(creditAccount);
        
        claimer.multiAcceptAndClaim(creditAccount, maxAssets);

        if (maxAssets < MAX_ASSETS_BUFFER) return;
        maxAssets -= MAX_ASSETS_BUFFER;

        uint256 assetBalanceAfter = asset.balanceOf(creditAccount);
        if (assetBalanceAfter - assetBalanceBefore < maxAssets) {
            revert InsufficientClaimedException();
        }
    }
}

// --- MOCKING GEARBOX CREDIT FACADE ---
// Simulates how CreditFacade converts type(uint256).max and executes the multicall
contract MockCreditFacade {
    VulnerableMellowAdapter public adapter;
    MockAsset public asset;
    MockMellowClaimer public claimer;

    constructor(VulnerableMellowAdapter _adapter, MockAsset _asset, MockMellowClaimer _claimer) {
        adapter = _adapter;
        asset = _asset;
        claimer = _claimer;
    }

    // Simulates withdrawCollateral & liquidateCreditAccount which calls the adapter inside a multicall
    function executeWithdrawOrLiquidate(address creditAccount, uint256 amount) external {
        if (amount == type(uint256).max) {
            // Gearbox CreditFacadeV3 logic for type(uint256).max
            uint256 phantomBalance = 1010e18; // 1000 pending + 10 claimable
            amount = phantomBalance - 1;
        }
        
        // Calls the adapter (which will revert)
        uint256[] memory subvaultIndices = new uint256[](0);
        uint256[][] memory indices = new uint256[][](0);
        adapter.claimLogic(asset, claimer, creditAccount, amount);
    }
}

// --- TEST CONTRACT ---
contract MellowClaimerDoSTest is Test {
    MockAsset public asset;
    MockMellowClaimer public claimer;
    VulnerableMellowAdapter public adapter;
    MockCreditFacade public facade;
    
    address user = address(0xA1);
    address liquidator = address(0xB2);

    function setUp() public {
        asset = new MockAsset();
        claimer = new MockMellowClaimer(asset);
        adapter = new VulnerableMellowAdapter();
        facade = new MockCreditFacade(adapter, asset, claimer);

        // Setup state: 10e18 mature, 1000e18 pending
        claimer.setClaimableAmount(10e18);
    }

    function test_PoC_UserWithdrawStuck() public {
        // 1. BEFORE: User balance is 0
        assertEq(asset.balanceOf(user), 0, "User initial balance should be 0");

        // 2. EXECUTION: User tries to withdraw using type(uint256).max
        vm.prank(user);
        vm.expectRevert(VulnerableMellowAdapter.InsufficientClaimedException.selector);
        facade.executeWithdrawOrLiquidate(user, type(uint256).max);

        // 3. AFTER IMPACT 1: User funds are stuck (cannot be withdrawn)
        assertEq(asset.balanceOf(user), 0, "IMPACT 1: User funds are stuck! User DoS Confirmed.");
    }

    function test_PoC_LiquidationDoS() public {
        // 1. BEFORE: Liquidator balance is 0
        assertEq(asset.balanceOf(liquidator), 0, "Liquidator initial balance should be 0");

        // 2. EXECUTION: Liquidator tries to liquidate the account (also using type(uint256).max in its internal multicall)
        vm.prank(liquidator);
        vm.expectRevert(VulnerableMellowAdapter.InsufficientClaimedException.selector);
        facade.executeWithdrawOrLiquidate(liquidator, type(uint256).max);

        // 3. AFTER IMPACT 2: Liquidation fails, liquidator gets nothing, account cannot be liquidated
        assertEq(asset.balanceOf(liquidator), 0, "IMPACT 2: Liquidation failed! Liquidation DoS Confirmed.");
    }
}
