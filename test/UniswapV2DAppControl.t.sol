// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";

// Import necessary contracts and interfaces
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "openzeppelin-contracts/contracts/access/Ownable.sol";

// Import Atlas-specific types and libraries
import { UserOperation } from "@atlas/types/UserOperation.sol";
import { SolverOperation } from "@atlas/types/SolverOperation.sol";
import { DAppConfig } from "@atlas/types/ConfigTypes.sol";
import { DAppOperation } from "@atlas/types/DAppOperation.sol";
import { CallVerification } from "@atlas/libraries/CallVerification.sol";
import { SolverBase } from "@atlas/solver/SolverBase.sol";
import { BaseTest } from "@atlas-test/base/BaseTest.t.sol";
import { AccountingMath } from "@atlas/libraries/AccountingMath.sol";

// Import the contract under test and related interfaces
import { UniswapV2DAppControl } from "src/UniswapV2DAppControl.sol";
import { IUniswapV2Router01, IUniswapV2Router02 } from "src/interfaces/IUniswapV2Router.sol";

// Import helper contracts for testing
import { TxBuilder } from "@atlas/helpers/TxBuilder.sol";

/// @title UniswapV2DAppControlTest
/// @notice Test contract for UniswapV2DAppControl integration with Atlas Protocol
contract UniswapV2DAppControlTest is BaseTest {
    // Address of Uniswap V2 Router on Ethereum mainnet
    address V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    // Contract instances
    UniswapV2DAppControl v2DAppControlControl;
    TxBuilder txBuilder;
    Sig sig;

    // Test solver contract
    BasicV2Solver basicV2Solver;

    /// @notice Set up the test environment
    function setUp() public override {
        // Call the setup function from the parent contract
        super.setUp();

        // Deploy UniswapV2DAppControl contract
        vm.startPrank(governanceEOA);
        v2DAppControlControl = new UniswapV2DAppControl(address(atlas), WETH_ADDRESS, V2_ROUTER);
        atlasVerification.initializeGovernance(address(v2DAppControlControl));
        vm.stopPrank();

        // Initialize TxBuilder for creating test transactions
        txBuilder = new TxBuilder({
            _control: address(v2DAppControlControl),
            _atlas: address(atlas),
            _verification: address(atlasVerification)
        });
    }

    /// @notice Test swapping WETH for DAI using UniswapV2 through Atlas Protocol
    function test_UniswapV2DAppControl_swapWETHForDAI() public {
        // Initialize operation structures
        UserOperation memory userOp;
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        DAppOperation memory dAppOp;

        // USER SETUP

        vm.startPrank(userEOA);
        // Create an execution environment for the user
        address executionEnvironment = atlas.createExecutionEnvironment(userEOA, address(v2DAppControlControl));
        console.log("Execution Environment:", executionEnvironment);
        console.log("userEOA", userEOA);
        vm.stopPrank();
        vm.label(address(executionEnvironment), "EXECUTION ENV");

        // Define the swap path (WETH -> DAI)
        address[] memory path = new address[](2);
        path[0] = WETH_ADDRESS;
        path[1] = DAI_ADDRESS;

        // Encode the swap function call
        bytes memory userOpData = abi.encodeCall(
            IUniswapV2Router01.swapExactTokensForTokens,
            (
                1e18, // amountIn (1 WETH)
                0, // amountOutMin (accept any amount of DAI)
                path,
                userEOA, // recipient
                block.timestamp + 999 // deadline
            )
        );

        // Build the UserOperation
        userOp = txBuilder.buildUserOperation({
            from: userEOA,
            to: address(v2DAppControlControl),
            maxFeePerGas: tx.gasprice + 1,
            value: 0,
            deadline: block.number + 555,
            data: userOpData
        });

        // Set the DApp address and session key
        userOp.dapp = V2_ROUTER;
        userOp.sessionKey = governanceEOA;

        // Sign the UserOperation
        (sig.v, sig.r, sig.s) = vm.sign(userPK, atlasVerification.getUserOperationPayload(userOp));
        userOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Fund the user with ETH and WETH
        vm.startPrank(userEOA);
        deal(userEOA, 1e18);
        deal(WETH_ADDRESS, userEOA, 1e18);
        console.log("WETH.balanceOf(userEOA)", WETH.balanceOf(userEOA));
        WETH.approve(address(atlas), 1e18);
        vm.stopPrank();

        // SOLVER SETUP

        vm.startPrank(solverOneEOA);
        // Deploy and fund the solver contract
        basicV2Solver = new BasicV2Solver(WETH_ADDRESS, address(atlas));
        deal(WETH_ADDRESS, address(basicV2Solver), 1e17);
        atlas.deposit{ value: 1e18 }();
        atlas.bond(1e18);
        vm.stopPrank();

        // Build the SolverOperation
        bytes memory solverOpData = abi.encodeWithSelector(BasicV2Solver.backrun.selector);
        solverOps[0] = txBuilder.buildSolverOperation({
            userOp: userOp,
            solverOpData: solverOpData,
            solver: solverOneEOA,
            solverContract: address(basicV2Solver),
            bidAmount: 1e17, // 0.1 ETH
            value: 0
        });

        // Sign the SolverOperation
        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // DAPP SETUP
        dAppOp = txBuilder.buildDAppOperation(governanceEOA, userOp, solverOps);

        // Bond AtlETH for the DApp governance to pay gas if needed
        deal(governanceEOA, 2e18);
        vm.startPrank(governanceEOA);
        atlas.deposit{ value: 1e18 }();
        atlas.bond(1e18);
        vm.stopPrank();

        // EXECUTE THE METACALL
        console.log("\nBEFORE METACALL");
        console.log("User WETH balance", WETH.balanceOf(userEOA));
        console.log("User DAI balance", DAI.balanceOf(userEOA));

        vm.prank(governanceEOA);
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp });

        console.log("\nAFTER METACALL");
        console.log("User WETH balance", WETH.balanceOf(userEOA));
        console.log("User DAI balance", DAI.balanceOf(userEOA));

        // Add assertions here to verify the swap was successful
        assertLt(WETH.balanceOf(userEOA), 1e18, "WETH balance should have decreased");
        assertGt(DAI.balanceOf(userEOA), 0, "DAI balance should have increased");
    }
}

/// @title BasicV2Solver
/// @notice A basic solver contract for testing purposes
contract BasicV2Solver is SolverBase {
    constructor(address weth, address atlas) SolverBase(weth, atlas, msg.sender) { }

    /// @notice Simulates a backrun operation (empty in this case)
    function backrun() public onlySelf {
        // Backrun logic would go here
    }

    /// @notice Ensures the function is called through atlasSolverCall
    modifier onlySelf() {
        require(msg.sender == address(this), "Not called via atlasSolverCall");
        _;
    }

    // Allow the contract to receive ETH
    fallback() external payable { }
    receive() external payable { }
}
