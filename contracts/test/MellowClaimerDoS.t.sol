// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

// Mocking Asset Token
contract MockAsset {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
}

// Mocking Mellow Claimer
contract MockMellowClaimer {
    MockAsset public asset;
    uint256 public claimableAmount;

    constructor(MockAsset _asset) { asset = _asset; }
    function setClaimableAmount(uint256 amount) external { claimableAmount = amount; }

    // Simulasi multiAcceptAndClaim: Hanya transfer yang claimable, bukan yang pending
    function multiAcceptAndClaim(address recipient, uint256 maxAssets) external returns (uint256) {
        uint256 toClaim = claimableAmount;
        if (toClaim > maxAssets) toClaim = maxAssets;
        asset.mint(recipient, toClaim);
        return toClaim;
    }
}

// Test Contract untuk membuktikan bug di MellowClaimerAdapter
contract MellowClaimerDoSTest is Test {
    uint256 constant MAX_ASSETS_BUFFER = 100; // Konstanta dari adapter asli
    error InsufficientClaimedException();

    MockAsset public asset;
    MockMellowClaimer public claimer;
    
    address creditAccount = address(this);

    function setUp() public {
        asset = new MockAsset();
        claimer = new MockMellowClaimer(asset);
    }

    // Reproduksi exact logic dari MellowClaimerAdapter._claim()
    function _claimLogic(uint256 maxAssets) internal {
        uint256 assetBalanceBefore = asset.balanceOf(creditAccount);
        
        // External call ke Mellow (hanya klaim yang mature)
        claimer.multiAcceptAndClaim(creditAccount, maxAssets);

        // === VULNERABLE CODE BLOCK ===
        if (maxAssets < MAX_ASSETS_BUFFER) return;
        maxAssets -= MAX_ASSETS_BUFFER;

        uint256 assetBalanceAfter = asset.balanceOf(creditAccount);
        if (assetBalanceAfter - assetBalanceBefore < maxAssets) {
            revert InsufficientClaimedException();
        }
        // =============================
    }

    function test_PoC_EndToEnd_MellowClaimerDoS() public {
        // 1. BEFORE EXPLOIT: Setup state Mellow Vault
        // User memiliki 1000e18 pending (unbonding) dan 10e18 claimable (mature)
        uint256 pendingAssets = 1000e18;
        uint256 claimableAssets = 10e18;
        claimer.setClaimableAmount(claimableAssets);

        // 2. SIMULASI GEARBOX CREDIT FACADE
        // User memanggil withdrawCollateral(phantomToken, type(uint256).max)
        // CreditFacade mengubah type(uint256).max menjadi balanceOf(phantomToken) - 1
        uint256 phantomBalance = pendingAssets + claimableAssets;
        uint256 maxAssetsRequestedByGearbox = phantomBalance - 1;

        // 3. EXECUTION & IMPACT
        // Kita expect transaksinya REVERT karena maxAssets jauh lebih besar dari assets yang diterima
        vm.expectRevert(InsufficientClaimedException.selector);
        _claimLogic(maxAssetsRequestedByGearbox);

        // 4. AFTER EXPLOIT VERIFICATION
        // Cek apakah dana user benar-benar terkunci (balance tetap 0)
        assertEq(asset.balanceOf(creditAccount), 0, "User funds are stuck! DoS Confirmed.");
    }
}
