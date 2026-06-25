// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {MellowClaimerAdapter} from "../adapters/mellow/MellowClaimerAdapter.sol";
import {IMellowClaimer} from "../integrations/mellow/IMellowClaimer.sol";
import {IMellowMultiVault} from "../integrations/mellow/IMellowMultiVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

// Mocking the external Mellow Asset (e.g., WETH)
contract MockAsset {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
}

// Mocking the external Mellow Claimer contract
contract MockMellowClaimer is IMellowClaimer {
    MockAsset public asset;
    uint256 public claimableAmount;

    constructor(MockAsset _asset) { asset = _asset; }
    function setClaimableAmount(uint256 amount) external { claimableAmount = amount; }

    function multiAcceptAndClaim(
        address multiVault,
        uint256[] calldata subvaultIndices,
        uint256[][] calldata indices,
        address recipient,
        uint256 maxAssets
    ) external returns (uint256 assets) {
        uint256 toClaim = claimableAmount;
        if (toClaim > maxAssets) toClaim = maxAssets;
        asset.mint(recipient, toClaim);
        return toClaim;
    }
}

// Harness: Wrapping the ACTUAL MellowClaimerAdapter to bypass CreditManager checks
// This proves the vulnerability exists in the real adapter code.
contract MellowClaimerAdapterHarness is MellowClaimerAdapter {
    address private _creditAccount;
    MockAsset private _asset;
    MockMellowClaimer private _claimer;

    constructor(
        address creditManager,
        address claimer,
        address creditAccount,
        MockAsset asset,
        MockMellowClaimer mellowClaimer
    ) MellowClaimerAdapter(creditManager, claimer) {
        _creditAccount = creditAccount;
        _asset = asset;
        _claimer = mellowClaimer;
    }

    // Override internal functions to route to our mocks
    function _creditAccount() internal view override returns (address) {
        return _creditAccount;
    }

    function _execute(bytes memory callData) internal override returns (bytes memory) {
        (, uint256[] memory subvaultIndices, uint256[][] memory indices, address recipient, uint256 maxAssets) = 
            abi.decode(callData, (address, uint256[], uint256[][], address, uint256));
        
        uint256 claimed = _claimer.multiAcceptAndClaim(address(0), subvaultIndices, indices, recipient, maxAssets);
        return abi.encode(claimed);
    }
}

contract MellowClaimerDoSTest is Test {
    MockAsset public asset;
    MockMellowClaimer public claimer;
    MellowClaimerAdapterHarness public adapter;
    
    address creditAccount = address(this);

    function setUp() public {
        asset = new MockAsset();
        claimer = new MockMellowClaimer(asset);
        
        // Deploy the Harness wrapping the REAL MellowClaimerAdapter
        adapter = new MellowClaimerAdapterHarness(
            address(1), // Mock CreditManager
            address(claimer),
            creditAccount,
            asset,
            claimer
        );
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
        vm.expectRevert(MellowClaimerAdapter.InsufficientClaimedException.selector);
        
        // Call the real adapter function via the harness
        uint256[] memory subvaultIndices = new uint256[](0);
        uint256[][] memory indices = new uint256[][](0);
        adapter.multiAcceptAndClaim(address(0), subvaultIndices, indices, address(0), maxAssetsRequestedByGearbox);

        // 4. AFTER EXPLOIT VERIFICATION
        // Verify that user funds are completely stuck (balance remains 0 despite 10e18 being claimable)
        assertEq(asset.balanceOf(creditAccount), 0, "User funds are stuck! DoS Confirmed.");
    }
}
