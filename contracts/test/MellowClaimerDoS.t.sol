// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

// --- MOCKS ---

// Mocking the underlying asset (e.g., WETH)
contract MockAsset {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
}

// Mocking the external Mellow Claimer contract
contract MockMellowClaimer {
    MockAsset public asset;
    uint256 public claimableAmount;

    constructor(MockAsset _asset) { asset = _asset; }
    function setClaimableAmount(uint256 amount) external { claimableAmount = amount; }

    // Simulates multiAcceptAndClaim: only transfers mature (claimable) assets, not pending ones
    function multiAcceptAndClaim(address recipient, uint256 maxAssets) external returns (uint256) {
        uint256 toClaim = claimableAmount;
        if (toClaim > maxAssets) toClaim = maxAssets;
        asset.mint(recipient, toClaim);
        return toClaim;
    }
}

// --- VULNERABLE LOGIC HARNESS ---
// This contract contains the exact vulnerable logic from MellowClaimerAdapter._claim
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
        
        // External call to Mellow (only claims mature assets)
        claimer.multiAcceptAndClaim(creditAccount, maxAssets);

        // === VULNERABLE CODE BLOCK (Copied from MellowClaimerAdapter.sol) ===
        if (maxAssets < MAX_ASSETS_BUFFER) return;
        maxAssets -= MAX_ASSETS_BUFFER;

        uint256 assetBalanceAfter = asset.balanceOf(creditAccount);
        if (assetBalanceAfter - assetBalanceBefore < maxAssets) {
            revert InsufficientClaimedException();
        }
        // ====================================================================
    }
}

// --- TEST CONTRACT ---
contract MellowClaimerDoSTest is Test {
    MockAsset public asset;
    MockMellowClaimer public claimer;
    VulnerableMellowAdapter public adapter;
    
    address creditAccount = address(this);

    function setUp() public {
        asset = new MockAsset();
        claimer = new MockMellowClaimer(asset);
        adapter = new VulnerableMellowAdapter();
    }

    function test_PoC_EndToEnd_MellowClaimerDoS() public {
        // 1. BEFORE EXPLOIT: Setup Mellow Vault state
        // User has 1000e18 pending (unbonding) and 10e18 claimable (mature)
        uint256 pendingAssets = 1000e18;
        uint256 claimableAssets = 10e18;
        claimer.setClaimableAmount(claimableAssets);

        // Verify initial balance is 0
        assertEq(asset.balanceOf(creditAccount), 0, "Initial balance should be 0");

        // 2. SIMULATE GEARBOX CREDIT FACADE BEHAVIOR
        // User calls withdrawCollateral(phantomToken, type(uint256).max)
        // CreditFacade converts type(uint256).max to balanceOf(phantomToken) - 1
        uint256 phantomBalance = pendingAssets + claimableAssets;
        uint256 maxAssetsRequestedByGearbox = phantomBalance - 1;

        // 3. EXECUTION & IMPACT
        // We expect the transaction to REVERT because maxAssets is vastly larger than the assets received
        vm.expectRevert(VulnerableMellowAdapter.InsufficientClaimedException.selector);
        adapter.claimLogic(asset, claimer, creditAccount, maxAssetsRequestedByGearbox);

        // 4. AFTER EXPLOIT VERIFICATION
        // Verify that user funds are completely stuck (balance remains 0 despite 10e18 being claimable)
        assertEq(asset.balanceOf(creditAccount), 0, "User funds are stuck! DoS Confirmed.");
    }
}
