// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }          from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { IPoolManager } from "../contracts/interfaces/IPoolManager.sol";

import { PoolManager }            from "../contracts/PoolManager.sol";
import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import {
    MockERC20Pool,
    MockGlobals,
    MockLoan,
    MockLoanManager,
    MockPoolManagerMigrator,
    MockPool
} from "./mocks/Mocks.sol";

import { PoolManagerHarness } from "./harnesses/PoolManagerHarness.sol";

import { GlobalsBootstrapper } from "./bootstrap/GlobalsBootstrapper.sol";

contract PoolManagerBase is TestUtils, GlobalsBootstrapper {

    address POOL_DELEGATE = address(new Address());

    MockERC20          asset;
    PoolManagerHarness poolManager;
    PoolManagerFactory factory;

    address implementation;
    address initializer;

    function setUp() public virtual {
        asset = new MockERC20("Asset", "AT", 18);

        _deployAndBootstrapGlobals(address(asset), POOL_DELEGATE);

        factory = new PoolManagerFactory(address(globals));

        implementation = address(new PoolManagerHarness());
        initializer    = address(new PoolManagerInitializer());

        vm.startPrank(GOVERNOR);
        factory.registerImplementation(1, implementation, initializer);
        factory.setDefaultVersion(1);
        vm.stopPrank();

        string memory poolName_   = "Pool";
        string memory poolSymbol_ = "POOL1";

        MockGlobals(globals).setValidPoolDeployer(address(this), true);

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(address(globals), POOL_DELEGATE, address(asset), poolName_, poolSymbol_);

        poolManager = PoolManagerHarness(PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(POOL_DELEGATE))));
    }

}

contract ConfigureTests is PoolManagerBase {

    address loanManager       = address(new Address());
    address withdrawalManager = address(new Address());

    uint256 liquidityCap      = 1_000_000e18;
    uint256 managementFeeRate = 0.1e18;

    function test_configure_notDeployer() public {
        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:CO:NOT_DEPLOYER");
        poolManager.configure(loanManager, withdrawalManager, liquidityCap, managementFeeRate);

        poolManager.configure(loanManager, withdrawalManager, liquidityCap, managementFeeRate);
    }

    function test_configure_alreadyConfigured() public {
        poolManager.__setConfigured(true);

        vm.expectRevert("PM:CO:ALREADY_CONFIGURED");
        poolManager.configure(loanManager, withdrawalManager, liquidityCap, managementFeeRate);

        poolManager.__setConfigured(false);
        poolManager.configure(loanManager, withdrawalManager, liquidityCap, managementFeeRate);
    }

    function test_configure_success() public {
        assertTrue(!poolManager.configured());
        assertTrue(!poolManager.isLoanManager(loanManager));

        assertEq(poolManager.withdrawalManager(),         address(0));
        assertEq(poolManager.liquidityCap(),              uint256(0));
        assertEq(poolManager.delegateManagementFeeRate(), uint256(0));

        poolManager.configure(loanManager, withdrawalManager, liquidityCap, managementFeeRate);

        assertTrue(poolManager.configured());
        assertTrue(poolManager.isLoanManager(loanManager));

        assertEq(poolManager.withdrawalManager(),         withdrawalManager);
        assertEq(poolManager.liquidityCap(),              liquidityCap);
        assertEq(poolManager.delegateManagementFeeRate(), managementFeeRate);
        assertEq(poolManager.loanManagerList(0),          loanManager);
    }
}

contract MigrateTests is PoolManagerBase {

    address migrator = address(new MockPoolManagerMigrator());

    function test_migrate_notFactory() external {
        vm.expectRevert("PM:M:NOT_FACTORY");
        poolManager.migrate(migrator, "");
    }

    function test_migrate_internalFailure() external {
        vm.prank(poolManager.factory());
        vm.expectRevert("PM:M:FAILED");
        poolManager.migrate(migrator, "");
    }

    function test_migrate_success() external {
        assertEq(poolManager.poolDelegate(), POOL_DELEGATE);

        vm.prank(poolManager.factory());
        poolManager.migrate(migrator, abi.encode(address(0)));

        assertEq(poolManager.poolDelegate(), address(0));
    }

}

contract SetImplementationTests is PoolManagerBase {

    address newImplementation = address(new PoolManager());

    function test_setImplementation_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setImplementation(newImplementation);
    }

    function test_setImplementation_notFactory() external {
        vm.expectRevert("PM:SI:NOT_FACTORY");
        poolManager.setImplementation(newImplementation);
    }

    function test_setImplementation_success() external {
        assertEq(poolManager.implementation(), implementation);

        vm.prank(poolManager.factory());
        poolManager.setImplementation(newImplementation);

        assertEq(poolManager.implementation(), newImplementation);
    }

}

contract UpgradeTests is PoolManagerBase {

    address newImplementation = address(new PoolManager());

    function setUp() public override {
        super.setUp();

        vm.startPrank(GOVERNOR);
        factory.registerImplementation(2, newImplementation, address(0));
        factory.enableUpgradePath(1, 2, address(0));
        vm.stopPrank();
    }

    function test_upgrade_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.upgrade(2, "");
    }

    function test_upgrade_notPoolDelegate() external {
        vm.expectRevert("PM:U:NOT_PD");
        poolManager.upgrade(2, "");
    }

    function test_upgrade_upgradeFailed() external {
        vm.prank(POOL_DELEGATE);
        vm.expectRevert("MPF:UI:FAILED");
        poolManager.upgrade(2, "1");
    }

    function test_upgrade_success() external {
        vm.prank(POOL_DELEGATE);
        poolManager.upgrade(2, "");
    }

}

contract AcceptPendingPoolDelegate_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());
    address SET_ADDRESS       = address(new Address());

    function setUp() public override {
        super.setUp();
        vm.prank(POOL_DELEGATE);
        poolManager.setPendingPoolDelegate(SET_ADDRESS);
    }

    function test_acceptPendingPoolDelegate_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(SET_ADDRESS);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.acceptPendingPoolDelegate();
    }

    function test_acceptPendingPoolDelegate_notPendingPoolDelegate() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:APA:NOT_PENDING_PD");
        poolManager.acceptPendingPoolDelegate();
    }

    function test_acceptPendingPoolDelegate_success() external {
        assertEq(poolManager.pendingPoolDelegate(), SET_ADDRESS);
        assertEq(poolManager.poolDelegate(),        POOL_DELEGATE);

        vm.prank(SET_ADDRESS);
        poolManager.acceptPendingPoolDelegate();

        assertEq(poolManager.pendingPoolDelegate(), address(0));
        assertEq(poolManager.poolDelegate(),        SET_ADDRESS);
    }

}

contract SetPendingPoolDelegate_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());
    address SET_ADDRESS       = address(new Address());

    function test_setPendingPoolDelegate_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setPendingPoolDelegate(SET_ADDRESS);
    }

    function test_setPendingPoolDelegate_notPoolDelegate() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SPA:NOT_PD");
        poolManager.setPendingPoolDelegate(SET_ADDRESS);
    }

    function test_setPendingPoolDelegate_success() external {
        assertEq(poolManager.pendingPoolDelegate(), address(0));

        vm.prank(POOL_DELEGATE);
        poolManager.setPendingPoolDelegate(SET_ADDRESS);

        assertEq(poolManager.pendingPoolDelegate(), SET_ADDRESS);
    }

}

contract SetActive_SetterTests is PoolManagerBase {

    function test_setActive_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(address(globals));
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setActive(true);
    }

    function test_setActive_notGovernor() external {
        assertTrue(!poolManager.active());

        vm.expectRevert("PM:SA:NOT_GLOBALS");
        poolManager.setActive(true);
    }

    function test_setActive_success() external {
        assertTrue(!poolManager.active());

        vm.prank(address(globals));
        poolManager.setActive(true);

        assertTrue(poolManager.active());

        vm.prank(address(globals));
        poolManager.setActive(false);

        assertTrue(!poolManager.active());
    }
}

contract SetAllowedLender_SetterTests is PoolManagerBase {

    function test_setAllowedLender_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(address(globals));
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setAllowedLender(address(this), true);
    }

    function test_setAllowedLender_notPoolDelegate() external {
        assertTrue(!poolManager.active());

        vm.expectRevert("PM:SAL:NOT_PD");
        poolManager.setAllowedLender(address(this), true);
    }

    function test_setAllowedLender_success() external {
        assertTrue(!poolManager.isValidLender(address(this)));

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(address(this), true);

        assertTrue(poolManager.isValidLender(address(this)));

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(address(this), false);

        assertTrue(!poolManager.isValidLender(address(this)));
    }
}

contract SetLiquidityCap_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());

    function test_setLiquidityCap_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setLiquidityCap(1000);
    }

    function test_setLiquidityCap_notPoolDelegate() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SLC:NOT_PD");
        poolManager.setLiquidityCap(1000);
    }

    function test_setLiquidityCap_success() external {
        assertEq(poolManager.liquidityCap(), 0);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(1000);

        assertEq(poolManager.liquidityCap(), 1000);
    }

}

contract SetDelegateManagementFeeRate_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());

    uint256 newManagementFeeRate = uint256(0.1e18);

    function test_setDelegateManagementFeeRate_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setDelegateManagementFeeRate(newManagementFeeRate);
    }

    function test_setDelegateManagementFeeRate_notPoolDelegate() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SDMFR:NOT_PD");
        poolManager.setDelegateManagementFeeRate(newManagementFeeRate);
    }

    function test_setDelegateManagementFeeRate_oob() external {
        MockGlobals(globals).setPlatformManagementFeeRate(address(poolManager), 0.9e18);

        vm.startPrank(POOL_DELEGATE);
        vm.expectRevert("PM:SDMFR:OOB");
        poolManager.setDelegateManagementFeeRate(newManagementFeeRate + 1);

        poolManager.setDelegateManagementFeeRate(newManagementFeeRate);
    }

    function test_setDelegateManagementFeeRate_success() external {
        assertEq(poolManager.delegateManagementFeeRate(), uint256(0));

        vm.prank(POOL_DELEGATE);
        poolManager.setDelegateManagementFeeRate(newManagementFeeRate);

        assertEq(poolManager.delegateManagementFeeRate(), newManagementFeeRate);
    }

}

contract SetOpenToPublic_SetterTests is PoolManagerBase {

    function test_setOpenToPublic_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setOpenToPublic();
    }

    function test_setOpenToPublic_notPoolDelegate() external {
        assertTrue(!poolManager.active());

        vm.expectRevert("PM:SOTP:NOT_PD");
        poolManager.setOpenToPublic();
    }

    function test_setOpenToPublic_success() external {
        assertTrue(!poolManager.openToPublic());

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        assertTrue(poolManager.openToPublic());
    }
}

contract ClaimTests is PoolManagerBase {

    address BORROWER = address(new Address());
    address LP       = address(new Address());

    address loan;

    MockERC20Pool   pool;
    MockLoanManager loanManager;

    function setUp() public override {
        super.setUp();

        pool = new MockERC20Pool(address(poolManager), address(asset), "Pool", "Pool");
        loanManager = new MockLoanManager(poolManager.pool(), TREASURY, POOL_DELEGATE);

        // Replace the pool in the poolManager
        address currentPool_ = poolManager.pool();
        vm.etch(currentPool_, address(pool).code);

        pool = MockERC20Pool(currentPool_);

        // Configure globals
        MockGlobals(globals).setValidBorrower(BORROWER, true);

        // Mint ERC20 to pool
        asset.mint(address(poolManager.pool()), 1_000_000e18);

        // Get past zero supply check
        pool.mint(LP, 1);

        loan = address(new MockLoan(address(asset), address(asset)));
        MockLoan(loan).__setBorrower(BORROWER);
        MockGlobals(globals).setValidBorrower(BORROWER, true);

        vm.startPrank(POOL_DELEGATE);
        poolManager.addLoanManager(address(loanManager));
        poolManager.fund(1_000_000e18, loan, address(loanManager));
        vm.stopPrank();

        // Setup expected fees.
        loanManager.__setDelegateManagementFee(6e18);
        loanManager.__setPlatformManagementFee(4e18);
        loanManager.__setPoolAmount(0);

        MockLoan(loan).__setClaimableFunds(10e18);
    }

    function test_claim_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.claim(loan);
    }

    function test_claim_failWithZeroSupply() external {
        pool.burn(LP, 1);

        vm.expectRevert("PM:C:ZERO_SUPPLY");
        poolManager.claim(loan);
    }

    function test_claim_failWithZeroLoanManager() external {
        address newLoan = address(new Address());

        vm.expectRevert("PM:C:NO_LOAN_MANAGER");
        poolManager.claim(newLoan);
    }

    function test_claim_success_insufficientCover() external {
        MockGlobals(globals).setMinCoverAmount(address(pool), 1_000e18);

        assertEq(asset.balanceOf(POOL_DELEGATE), 0);
        assertEq(asset.balanceOf(TREASURY),      0);
        assertEq(asset.balanceOf(address(pool)), 0);

        // Add 1 less than the required min cover to earn Pool Delegate fees.
        asset.mint(poolManager.poolDelegateCover(), 1_000e18 - 1);

        poolManager.claim(loan);

        assertEq(asset.balanceOf(POOL_DELEGATE), 0);    // Insufficient cover, Pool Delegate forfeits their fees.
        assertEq(asset.balanceOf(TREASURY),      4e18); // 100% of 10e18 managementFeePortion
        assertEq(asset.balanceOf(address(pool)), 6e18); // Pool receives fees instead. Including this check in other claim_success tests to demonstrate that it should only change when there's insufficient cover.
    }

    function test_claim_success_sufficientCover() external {
        MockGlobals(globals).setMinCoverAmount(address(pool), 1_000e18);

        assertEq(asset.balanceOf(POOL_DELEGATE), 0);
        assertEq(asset.balanceOf(TREASURY),      0);
        assertEq(asset.balanceOf(address(pool)), 0);

        // Add exact amount of cover required to earn Pool Delegate fees.
        asset.mint(poolManager.poolDelegateCover(), 1_000e18);

        poolManager.claim(loan);

        assertEq(asset.balanceOf(POOL_DELEGATE), 6e18); // 60% of 10e18 managementFeePortion
        assertEq(asset.balanceOf(TREASURY),      4e18); // 40% of 10e18 managementFeePortion
        assertEq(asset.balanceOf(address(pool)), 0);
    }

    function test_claim_success_noCoverRequired() external {
        assertEq(asset.balanceOf(POOL_DELEGATE), 0);
        assertEq(asset.balanceOf(TREASURY),      0);
        assertEq(asset.balanceOf(address(pool)), 0);

        poolManager.claim(loan);

        assertEq(asset.balanceOf(POOL_DELEGATE), 6e18); // 60% of 10e18 managementFeePortion
        assertEq(asset.balanceOf(TREASURY),      4e18); // 40% of 10e18 managementFeePortion
        assertEq(asset.balanceOf(address(pool)), 0);
    }

}

contract FundTests is PoolManagerBase {

    address BORROWER = address(new Address());
    address LP       = address(new Address());

    MockLoan        loan;
    MockLoanManager loanManager;
    MockERC20Pool   pool;

    uint256 principalRequested = 1_000_000e18;
    uint256 collateralRequired = 0;

    function setUp() public override {
        super.setUp();

        MockGlobals(globals).setValidBorrower(BORROWER, true);

        loan        = new MockLoan(address(asset), address(asset));
        pool        = new MockERC20Pool(address(poolManager), address(asset), "Pool", "Pool");
        loanManager = new MockLoanManager(poolManager.pool(), TREASURY, POOL_DELEGATE);

        loan.__setPrincipal(principalRequested);
        loan.__setCollateral(collateralRequired);
        loan.__setBorrower(BORROWER);

        // Replace the pool in the poolManager
        address currentPool_ = poolManager.pool();
        vm.etch(currentPool_, address(pool).code);

        pool = MockERC20Pool(currentPool_);

        // Mint ERC20 to pool
        asset.mint(address(poolManager.pool()), 1_000_000e18);

        // Get past zero supply check
        pool.mint(LP, 1);

        vm.prank(POOL_DELEGATE);
        poolManager.addLoanManager(address(loanManager));
    }

    function test_fund_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.fund(principalRequested, address(loan), address(loanManager));
    }

    function test_fund_notPoolDelegate() external {
        vm.expectRevert("PM:F:NOT_PD");
        poolManager.fund(principalRequested, address(loan), address(loanManager));
    }

    function test_fund_invalidBorrower() external {

        MockGlobals(globals).setValidBorrower(BORROWER, false);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:F:INVALID_BORROWER");
        poolManager.fund(principalRequested, address(loan), address(loanManager));
    }

    function test_fund_zeroSupply() external {
        pool.burn(LP, 1);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:F:ZERO_SUPPLY");
        poolManager.fund(principalRequested, address(loan), address(loanManager));

    }

    function test_fund_transferFail() external {
        asset.burn(address(poolManager.pool()), 1_000_000e18);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("P:F:TRANSFER_FAIL");
        poolManager.fund(principalRequested, address(loan), address(loanManager));
    }

    function test_fund_invalidLoanManager() external {

        // Remove the loanManager from the poolManager (added on setUp)
        vm.prank(POOL_DELEGATE);
        poolManager.removeLoanManager(address(loanManager));

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:F:INVALID_LOAN_MANAGER");
        poolManager.fund(principalRequested, address(loan), address(loanManager));
    }

    function test_fund_insufficientCover() external {
        MockGlobals(globals).setMinCoverAmount(address(pool), 1_000e18);

        // Add 1 less than the required min cover to be able to fund new loans.
        asset.mint(poolManager.poolDelegateCover(), 1_000e18 - 1);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:F:INSUFFICIENT_COVER");
        poolManager.fund(principalRequested, address(loan), address(loanManager));

        asset.mint(poolManager.poolDelegateCover(), 1);

        vm.prank(POOL_DELEGATE);
        poolManager.fund(principalRequested, address(loan), address(loanManager));
    }

    function test_fund_success_sufficientCover() external {
        MockGlobals(globals).setMinCoverAmount(address(pool), 1_000e18);

        asset.mint(poolManager.poolDelegateCover(), 1_000e18);

        assertEq(poolManager.loanManagers(address(loan)), address(0));

        vm.prank(POOL_DELEGATE);
        poolManager.fund(principalRequested, address(loan), address(loanManager));

        assertEq(poolManager.loanManagers(address(loan)), address(loanManager));
    }

    function test_fund_success() external {
        assertEq(poolManager.loanManagers(address(loan)), address(0));

        vm.prank(POOL_DELEGATE);
        poolManager.fund(principalRequested, address(loan), address(loanManager));

        assertEq(poolManager.loanManagers(address(loan)), address(loanManager));
    }

}

contract TriggerCollateralLiquidation is PoolManagerBase {

    address BORROWER   = address(new Address());
    address LP         = address(new Address());
    address AUCTIONEER = address(new Address());

    address loan;
    address poolDelegateCover;

    MockERC20Pool   pool;
    MockLoanManager loanManager;

    function setUp() public override {
        super.setUp();

        pool        = new MockERC20Pool(address(poolManager), address(asset), "Pool", "Pool");
        loanManager = new MockLoanManager(address(pool), TREASURY, POOL_DELEGATE);

        // Replace the pool in the poolManager
        address currentPool_ = poolManager.pool();
        vm.etch(currentPool_, address(pool).code);

        poolDelegateCover = poolManager.poolDelegateCover();

        pool = MockERC20Pool(currentPool_);

        // Mint ERC20 to pool
        asset.mint(address(poolManager.pool()), 1_000_000e18);

        // Get past zero supply check
        pool.mint(LP, 1);

        loan = address(new MockLoan(address(asset), address(asset)));
        MockLoan(loan).__setBorrower(BORROWER);
        MockGlobals(globals).setValidBorrower(BORROWER, true);

        vm.startPrank(POOL_DELEGATE);
        poolManager.addLoanManager(address(loanManager));
        poolManager.fund(1_000_000e18, loan, address(loanManager));
        vm.stopPrank();
    }

    function test_triggerCollateralLiquidation_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.triggerCollateralLiquidation(loan);
    }

    function test_triggerCollateralLiquidation_notPoolDelegate() external {
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(pool), poolManager.HUNDRED_PERCENT());

        loanManager.__setTriggerCollateralLiquidationReturn(2_000e18);

        vm.expectRevert("PM:TCL:NOT_PD");
        poolManager.triggerCollateralLiquidation(loan);

        vm.prank(POOL_DELEGATE);
        poolManager.triggerCollateralLiquidation(loan);
    }

}

contract FinishCollateralLiquidation is PoolManagerBase {

    address BORROWER = address(new Address());
    address LP       = address(new Address());
    address LOAN     = address(new Address());

    address loan;
    address poolDelegateCover;

    MockERC20Pool   pool;
    MockLoanManager loanManager;

    function setUp() public override {
        super.setUp();

        pool         = new MockERC20Pool(address(poolManager), address(asset), "Pool", "Pool");
        loanManager = new MockLoanManager(address(pool), TREASURY, POOL_DELEGATE);

        // Replace the pool in the poolManager
        address currentPool_ = poolManager.pool();
        vm.etch(currentPool_, address(pool).code);

        poolDelegateCover = poolManager.poolDelegateCover();

        pool = MockERC20Pool(currentPool_);

        _bootstrapGlobals(address(asset), POOL_DELEGATE);

        // Mint ERC20 to pool
        asset.mint(address(poolManager.pool()), 1_000_000e18);

        // Get past zero supply check
        pool.mint(LP, 1);

        loan = address(new MockLoan(address(asset), address(asset)));
        MockLoan(loan).__setBorrower(BORROWER);
        MockGlobals(globals).setValidBorrower(BORROWER, true);

        vm.startPrank(POOL_DELEGATE);
        poolManager.addLoanManager(address(loanManager));
        poolManager.fund(1_000_000e18, loan, address(loanManager));
        vm.stopPrank();
    }

    function test_finishCollateralLiquidation_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.finishCollateralLiquidation(loan);
    }

    function test_finishCollateralLiquidation_notPoolDelegate() external {
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(pool), poolManager.HUNDRED_PERCENT());

        loanManager.__setTriggerCollateralLiquidationReturn(2_000e18);

        vm.prank(POOL_DELEGATE);
        poolManager.triggerCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(), 2_000e18);

        loanManager.__setFinishCollateralLiquidationReturn(1_000e18);

        vm.expectRevert("PM:FCL:NOT_PD");
        poolManager.finishCollateralLiquidation(loan);

        vm.prank(POOL_DELEGATE);
        poolManager.finishCollateralLiquidation(loan);
    }

    function test_finishCollateralLiquidation_success_noCover() external {
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(pool), poolManager.HUNDRED_PERCENT());

        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 0);
        assertEq(poolManager.unrealizedLosses(),                0);

        loanManager.__setTriggerCollateralLiquidationReturn(2_000e18);
        vm.prank(POOL_DELEGATE);
        poolManager.triggerCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(), 2_000e18);

        loanManager.__setFinishCollateralLiquidationReturn(1_000e18);

        vm.prank(POOL_DELEGATE);
        poolManager.finishCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(),                0);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 0);
    }

    function test_finishCollateralLiquidation_success_noRemainingLossAfterCollateralLiquidation() external {
        MockGlobals(globals).setMinCoverAmount(address(pool), 1_000e18);
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(pool), poolManager.HUNDRED_PERCENT());
        asset.mint(poolManager.poolDelegateCover(), 1_000e18);

        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 1_000e18);
        assertEq(poolManager.unrealizedLosses(),                0);

        loanManager.__setTriggerCollateralLiquidationReturn(2_000e18);
        vm.prank(POOL_DELEGATE);
        poolManager.triggerCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(), 2_000e18);

        loanManager.__setFinishCollateralLiquidationReturn(0);

        vm.prank(POOL_DELEGATE);
        poolManager.finishCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(),                0);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 1_000e18);
    }

    function test_finishCollateralLiquidation_success_coverLeftOver() external {
        MockGlobals(globals).setMinCoverAmount(address(pool), 2_000e18);
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(pool), poolManager.HUNDRED_PERCENT());
        asset.mint(poolManager.poolDelegateCover(), 2_000e18);

        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 2_000e18);
        assertEq(poolManager.unrealizedLosses(),                0);

        loanManager.__setTriggerCollateralLiquidationReturn(3_000e18);
        vm.prank(POOL_DELEGATE);
        poolManager.triggerCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(), 3_000e18);

        loanManager.__setFinishCollateralLiquidationReturn(1_000e18);

        vm.prank(POOL_DELEGATE);
        poolManager.finishCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(),                0);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 1_000e18);
    }

    function test_finishCollateralLiquidation_success_noCoverLeftOver() external {
        MockGlobals(globals).setMinCoverAmount(address(pool), 1_000e18);
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(pool), poolManager.HUNDRED_PERCENT());
        asset.mint(poolManager.poolDelegateCover(), 1_000e18);

        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 1_000e18);
        assertEq(poolManager.unrealizedLosses(),                0);

        loanManager.__setTriggerCollateralLiquidationReturn(2_000e18);
        vm.prank(POOL_DELEGATE);
        poolManager.triggerCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(), 2_000e18);

        loanManager.__setFinishCollateralLiquidationReturn(1_000e18);

        vm.prank(POOL_DELEGATE);
        poolManager.finishCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(),                0);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 0);
    }

    function test_finishCollateralLiquidation_success_fullCoverLiquidation_preexistingLoss() external {
        MockGlobals(globals).setMinCoverAmount(address(pool), 1_000e18);
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(pool), poolManager.HUNDRED_PERCENT());
        asset.mint(poolManager.poolDelegateCover(), 1_000e18);

        // There could be unrealizedLosses from a previous ongoing loan default.
        poolManager.__setUnrealizedLosses(2_000e18);

        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 1_000e18);
        assertEq(poolManager.unrealizedLosses(),                2_000e18);

        loanManager.__setTriggerCollateralLiquidationReturn(3_000e18);
        vm.prank(POOL_DELEGATE);
        poolManager.triggerCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(), 5_000e18);

        loanManager.__setFinishCollateralLiquidationReturn(1_000e18);

        vm.prank(POOL_DELEGATE);
        poolManager.finishCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(),                2_000e18);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 0);
    }

    function test_finishCollateralLiquidation_success_exceedMaxCoverLiquidationPercentAmount() external {
        MockGlobals(globals).setMinCoverAmount(address(pool), 1_000e18);
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(pool), 0.5e18);
        asset.mint(poolManager.poolDelegateCover(), 1_000e18);

        assertEq(poolManager.unrealizedLosses(), 0);

        loanManager.__setTriggerCollateralLiquidationReturn(3_000e18);
        vm.prank(POOL_DELEGATE);
        poolManager.triggerCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(), 3_000e18);

        loanManager.__setFinishCollateralLiquidationReturn(1_000e18);

        vm.prank(POOL_DELEGATE);
        poolManager.finishCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(),                0);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 500e18);
    }

}

contract RedeemTests is PoolManagerBase {

    address WITHDRAWAL_MANAGER = address(new Address());

    function setUp() public override {
        super.setUp();

        vm.prank(POOL_DELEGATE);
        poolManager.setWithdrawalManager(WITHDRAWAL_MANAGER);
    }

    function test_redeem_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(WITHDRAWAL_MANAGER);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.redeem(0, address(0), address(0));
    }

    function test_redeem_notWithdrawalManager() external {
        vm.expectRevert("PM:R:NOT_WM");
        poolManager.redeem(0, address(0), address(0));
    }

    function test_redeem_success() external {
        vm.etch(poolManager.pool(), address(new MockPool()).code);
        vm.prank(WITHDRAWAL_MANAGER);
        poolManager.redeem(0, address(0), address(0));
    }

}

contract AddLoanManager_SetterTests is PoolManagerBase {

    address LOAN_MANAGER      = address(new Address());
    address NOT_POOL_DELEGATE = address(new Address());

    function test_addLoanManager_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.addLoanManager(LOAN_MANAGER);
    }

    function test_addLoanManager_notPD() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:ALM:NOT_PD");
        poolManager.addLoanManager(LOAN_MANAGER);
    }

    function test_addLoanManager_duplicateLM() external {
        vm.startPrank(POOL_DELEGATE);

        poolManager.addLoanManager(LOAN_MANAGER);

        vm.expectRevert("PM:ALM:DUP_LM");
        poolManager.addLoanManager(LOAN_MANAGER);
    }

    function test_addLoanManager() external {
        assertTrue(!poolManager.isLoanManager(LOAN_MANAGER));

        assertEq(poolManager.__getLoanManagerListLength(), 0);
        assertEq(poolManager.__getLoanManagerListValue(0), address(0));

        vm.prank(POOL_DELEGATE);
        poolManager.addLoanManager(LOAN_MANAGER);

        assertTrue(poolManager.isLoanManager(LOAN_MANAGER));

        assertEq(poolManager.__getLoanManagerListLength(), 1);
        assertEq(poolManager.__getLoanManagerListValue(0), LOAN_MANAGER);
    }

}

contract RemoveLoanManager_SetterTests is PoolManagerBase {

    address LOAN_MANAGER_1    = address(new Address());
    address LOAN_MANAGER_2    = address(new Address());
    address LOAN_MANAGER_3    = address(new Address());
    address NOT_POOL_DELEGATE = address(new Address());

    function setUp() public override {
        super.setUp();

        vm.startPrank(POOL_DELEGATE);
        poolManager.addLoanManager(LOAN_MANAGER_1);
        poolManager.addLoanManager(LOAN_MANAGER_2);
        poolManager.addLoanManager(LOAN_MANAGER_3);
        vm.stopPrank();
    }

    function test_addLoanManager_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.removeLoanManager(LOAN_MANAGER_1);
    }

    function test_removeLoanManager_notPD() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:RLM:NOT_PD");
        poolManager.removeLoanManager(LOAN_MANAGER_1);
    }

    function test_removeLoanManager_firstItem() external {
        assertTrue(poolManager.isLoanManager(LOAN_MANAGER_1));
        assertTrue(poolManager.isLoanManager(LOAN_MANAGER_2));
        assertTrue(poolManager.isLoanManager(LOAN_MANAGER_3));

        assertEq(poolManager.__getLoanManagerListLength(), 3);
        assertEq(poolManager.__getLoanManagerListValue(0), LOAN_MANAGER_1);
        assertEq(poolManager.__getLoanManagerListValue(1), LOAN_MANAGER_2);
        assertEq(poolManager.__getLoanManagerListValue(2), LOAN_MANAGER_3);

        vm.prank(POOL_DELEGATE);
        poolManager.removeLoanManager(LOAN_MANAGER_1);

        assertTrue(!poolManager.isLoanManager(LOAN_MANAGER_1));
        assertTrue( poolManager.isLoanManager(LOAN_MANAGER_2));
        assertTrue( poolManager.isLoanManager(LOAN_MANAGER_3));

        assertEq(poolManager.__getLoanManagerListLength(), 2);
        assertEq(poolManager.__getLoanManagerListValue(0), LOAN_MANAGER_3);
        assertEq(poolManager.__getLoanManagerListValue(1), LOAN_MANAGER_2);
        assertEq(poolManager.__getLoanManagerListValue(2), address(0));
    }

    function test_removeLoanManager_secondItem() external {
        assertTrue(poolManager.isLoanManager(LOAN_MANAGER_1));
        assertTrue(poolManager.isLoanManager(LOAN_MANAGER_2));
        assertTrue(poolManager.isLoanManager(LOAN_MANAGER_3));

        assertEq(poolManager.__getLoanManagerListLength(), 3);
        assertEq(poolManager.__getLoanManagerListValue(0), LOAN_MANAGER_1);
        assertEq(poolManager.__getLoanManagerListValue(1), LOAN_MANAGER_2);
        assertEq(poolManager.__getLoanManagerListValue(2), LOAN_MANAGER_3);

        vm.prank(POOL_DELEGATE);
        poolManager.removeLoanManager(LOAN_MANAGER_2);

        assertTrue( poolManager.isLoanManager(LOAN_MANAGER_1));
        assertTrue(!poolManager.isLoanManager(LOAN_MANAGER_2));
        assertTrue( poolManager.isLoanManager(LOAN_MANAGER_3));

        assertEq(poolManager.__getLoanManagerListLength(), 2);
        assertEq(poolManager.__getLoanManagerListValue(0), LOAN_MANAGER_1);
        assertEq(poolManager.__getLoanManagerListValue(1), LOAN_MANAGER_3);
        assertEq(poolManager.__getLoanManagerListValue(2), address(0));
    }

    function test_removeLoanManager_thirdItem() external {
        assertTrue(poolManager.isLoanManager(LOAN_MANAGER_1));
        assertTrue(poolManager.isLoanManager(LOAN_MANAGER_2));
        assertTrue(poolManager.isLoanManager(LOAN_MANAGER_3));

        assertEq(poolManager.__getLoanManagerListLength(), 3);
        assertEq(poolManager.__getLoanManagerListValue(0), LOAN_MANAGER_1);
        assertEq(poolManager.__getLoanManagerListValue(1), LOAN_MANAGER_2);
        assertEq(poolManager.__getLoanManagerListValue(2), LOAN_MANAGER_3);

        vm.prank(POOL_DELEGATE);
        poolManager.removeLoanManager(LOAN_MANAGER_3);

        assertTrue( poolManager.isLoanManager(LOAN_MANAGER_1));
        assertTrue( poolManager.isLoanManager(LOAN_MANAGER_2));
        assertTrue(!poolManager.isLoanManager(LOAN_MANAGER_3));

        assertEq(poolManager.__getLoanManagerListLength(), 2);
        assertEq(poolManager.__getLoanManagerListValue(0), LOAN_MANAGER_1);
        assertEq(poolManager.__getLoanManagerListValue(1), LOAN_MANAGER_2);
        assertEq(poolManager.__getLoanManagerListValue(2), address(0));
    }

}

contract SetWithdrawalManager_SetterTests is PoolManagerBase {

    address WITHDRAWAL_MANAGER = address(new Address());
    address NOT_POOL_DELEGATE  = address(new Address());

    function test_setWithdrawalManager_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setWithdrawalManager(WITHDRAWAL_MANAGER);
    }

    function test_setWithdrawalManager_notPD() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SWM:NOT_PD");
        poolManager.setWithdrawalManager(WITHDRAWAL_MANAGER);
    }

    function test_setWithdrawalManager() external {
        assertEq(poolManager.withdrawalManager(), address(0));

        vm.prank(POOL_DELEGATE);
        poolManager.setWithdrawalManager(WITHDRAWAL_MANAGER);

        assertEq(poolManager.withdrawalManager(), WITHDRAWAL_MANAGER);
    }

}

contract CanCallTests is PoolManagerBase {

    function test_canCall_deposit_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:deposit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:D:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_deposit_lenderNotAllowed() external {
        bytes32 functionId_ = bytes32("P:deposit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:D:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(receiver_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_deposit_liquidityCapExceeded() external {
        bytes32 functionId_ = bytes32("P:deposit");
        address receiver_   = address(this);

        vm.startPrank(POOL_DELEGATE);
        poolManager.setOpenToPublic();
        poolManager.setLiquidityCap(1_000e6);
        vm.stopPrank();

        bytes memory params = abi.encode(1_000e6 + 1, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:D:DEPOSIT_GT_LIQ_CAP");
    }

    function test_canCall_depositWithPermit_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:depositWithPermit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:DWP:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_depositWithPermit_lenderNotAllowed() external {
        bytes32 functionId_ = bytes32("P:depositWithPermit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:DWP:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(receiver_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_depositWithPermit_liquidityCapExceeded() external {
        bytes32 functionId_ = bytes32("P:depositWithPermit");
        address receiver_   = address(this);

        vm.startPrank(POOL_DELEGATE);
        poolManager.setOpenToPublic();
        poolManager.setLiquidityCap(1_000e6);
        vm.stopPrank();

        bytes memory params = abi.encode(1_000e6 + 1, receiver_, uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:DWP:DEPOSIT_GT_LIQ_CAP");
    }

    function test_canCall_mint_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:mint");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:M:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_mint_lenderNotAllowed() external {
        bytes32 functionId_ = bytes32("P:mint");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:M:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(receiver_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_mint_liquidityCapExceeded() external {
        bytes32 functionId_ = bytes32("P:mint");
        address receiver_   = address(this);

        vm.startPrank(POOL_DELEGATE);
        poolManager.setOpenToPublic();
        poolManager.setLiquidityCap(1_000e6);
        vm.stopPrank();

        bytes memory params = abi.encode(1_000e6 + 1, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:M:DEPOSIT_GT_LIQ_CAP");
    }

    function test_canCall_mintWithPermit_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:mintWithPermit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:MWP:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_mintWithPermit_lenderNotAllowed() external {
        bytes32 functionId_ = bytes32("P:mintWithPermit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:MWP:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(receiver_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_mintWithPermit_liquidityCapExceeded() external {
        bytes32 functionId_ = bytes32("P:mintWithPermit");
        address receiver_   = address(this);

        vm.startPrank(POOL_DELEGATE);
        poolManager.setOpenToPublic();
        poolManager.setLiquidityCap(1_000e6);
        vm.stopPrank();

        bytes memory params = abi.encode(1_000e6 + 1, receiver_, uint256(0), uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:MWP:DEPOSIT_GT_LIQ_CAP");
    }

    function test_canCall_transfer_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:transfer");
        address recipient_  = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:T:RECIPIENT_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_transfer_recipientNotAllowed() external {
        bytes32 functionId_ = bytes32("P:transfer");
        address recipient_  = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:T:RECIPIENT_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(recipient_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_transferFrom_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:transferFrom");
        address recipient_  = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(address(1), recipient_, uint256(1_000e6));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:TF:RECIPIENT_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_transferFrom_recipientNotAllowed() external {
        bytes32 functionId_ = bytes32("P:transferFrom");
        address recipient_  = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(address(1), recipient_, uint256(1_000e6));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:TF:RECIPIENT_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(recipient_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_protocolPaused() external {
        address caller     = address(new Address());
        bytes32 functionId = bytes32("Fake Function");

        bytes memory data = new bytes(0);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId, caller, data);

        // Call can be performed
        assertTrue(canCall_);

        // Set protocol paused
        MockGlobals(globals).setProtocolPause(true);

        // Call cannot be performed
        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId, caller, data);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PROTOCOL_PAUSED");

        // Set protocol paused to false
        MockGlobals(globals).setProtocolPause(false);

        // Call can be performed again
        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId, caller, data);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

}

contract DepositCoverTests is PoolManagerBase {

    function setUp() public override {
        super.setUp();

        asset.mint(POOL_DELEGATE, 1_000e18);
    }

    function test_depositCover_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.depositCover(1_000e18);
    }

    function test_depositCover_insufficientApproval() external {
        vm.startPrank(POOL_DELEGATE);
        asset.approve(address(poolManager), 1_000e18 - 1);

        vm.expectRevert("PM:DC:TRANSFER_FAIL");
        poolManager.depositCover(1_000e18);

        asset.approve(address(poolManager), 1_000e18);
        poolManager.depositCover(1_000e18);
    }

    function test_depositCover_success() external {
        assertEq(asset.balanceOf(POOL_DELEGATE),                       1_000e18);
        assertEq(asset.balanceOf(poolManager.poolDelegateCover()),     0);
        assertEq(asset.allowance(POOL_DELEGATE, address(poolManager)), 0);

        vm.startPrank(POOL_DELEGATE);

        asset.approve(address(poolManager), 1_000e18);

        assertEq(asset.allowance(POOL_DELEGATE, address(poolManager)), 1_000e18);

        poolManager.depositCover(1_000e18);
        assertEq(asset.balanceOf(POOL_DELEGATE),                       0);
        assertEq(asset.balanceOf(poolManager.poolDelegateCover()),     1_000e18);
        assertEq(asset.allowance(POOL_DELEGATE, address(poolManager)), 0);
    }

}

contract WithdrawCoverTests is PoolManagerBase {

    address pool;

    function setUp() public override {
        super.setUp();

        pool = poolManager.pool();
    }

    function test_withdrawCover_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.withdrawCover(1_000e18, POOL_DELEGATE);
    }

    function test_withdrawCover_notPoolDelegate() external {
        MockGlobals(globals).setMinCoverAmount(pool, 1_000e18);

        asset.mint(poolManager.poolDelegateCover(), 2_000e18);

        vm.expectRevert("PM:WC:NOT_PD");
        poolManager.withdrawCover(1_000e18, POOL_DELEGATE);

        vm.prank(POOL_DELEGATE);
        poolManager.withdrawCover(1_000e18, POOL_DELEGATE);
    }

    function test_withdrawCover_tryWithdrawBelowRequired() external {
        MockGlobals(globals).setMinCoverAmount(pool, 1_000e18);

        asset.mint(poolManager.poolDelegateCover(), 2_000e18);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:WC:BELOW_MIN");
        poolManager.withdrawCover(1_000e18 + 1, POOL_DELEGATE);

        vm.prank(POOL_DELEGATE);
        poolManager.withdrawCover(1_000e18, POOL_DELEGATE);
    }

    function test_withdrawCover_noRequirement() external {
        asset.mint(poolManager.poolDelegateCover(), 1_000e18);

        // Withdraw all cover, for example in the scenario that a pool closes.
        vm.prank(POOL_DELEGATE);
        poolManager.withdrawCover(1_000e18, POOL_DELEGATE);
    }

    function test_withdrawCover_withdrawMoreThanBalance() external {
        asset.mint(poolManager.poolDelegateCover(), 1_000e18);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:WC:BELOW_MIN");
        poolManager.withdrawCover(1_000e18 + 1, POOL_DELEGATE);
    }

    function test_withdrawCover_success() external {
        MockGlobals(globals).setMinCoverAmount(pool, 1_000e18);

        asset.mint(poolManager.poolDelegateCover(), 2_000e18);

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 2_000e18);
        assertEq(asset.balanceOf(POOL_DELEGATE),                   0);

        vm.prank(POOL_DELEGATE);
        poolManager.withdrawCover(1_000e18, POOL_DELEGATE);

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 1_000e18);
        assertEq(asset.balanceOf(POOL_DELEGATE),                   1_000e18);
    }

    function test_withdrawCover_success_zeroRecipient() external {
        MockGlobals(globals).setMinCoverAmount(pool, 1_000e18);

        asset.mint(poolManager.poolDelegateCover(), 2_000e18);

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 2_000e18);
        assertEq(asset.balanceOf(POOL_DELEGATE),                   0);

        vm.prank(POOL_DELEGATE);
        poolManager.withdrawCover(1_000e18, address(0));

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 1_000e18);
        assertEq(asset.balanceOf(POOL_DELEGATE),                   1_000e18);
    }

}
