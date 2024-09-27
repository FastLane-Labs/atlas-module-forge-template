// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

// Import Forge Standard Test library for testing utilities
import "forge-std/Test.sol";

// Import OpenZeppelin contracts and interfaces for ERC20 tokens and access control
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "openzeppelin-contracts/contracts/access/Ownable.sol";

// Import Atlas Protocol-specific types and libraries
import { UserOperation } from "@atlas/types/UserOperation.sol";
import { SolverOperation } from "@atlas/types/SolverOperation.sol";
import { DAppConfig } from "@atlas/types/ConfigTypes.sol";
import { DAppOperation } from "@atlas/types/DAppOperation.sol";
import { CallVerification } from "@atlas/libraries/CallVerification.sol";
import { SolverBase } from "@atlas/solver/SolverBase.sol";
import { BaseTest } from "@atlas-test/base/BaseTest.t.sol";
import { AccountingMath } from "@atlas/libraries/AccountingMath.sol";

// Import the contract under test and related Uniswap V2 router interfaces
import { UniswapV2DAppControl } from "../src/UniswapV2DAppControl.sol";
import { IUniswapV2Router01, IUniswapV2Router02 } from "../src/interfaces/IUniswapV2Router.sol";

// Import helper contracts for building transactions during testing
import { TxBuilder } from "@atlas/helpers/TxBuilder.sol";

/// @title UniswapV2DAppControlTest
/// @notice This contract contains test cases for verifying the integration of UniswapV2DAppControl with the Atlas
/// Protocol.
/// It leverages the Forge testing framework and mocks interactions with Uniswap V2 Router and Atlas Protocol.
contract UniswapV2DAppControlTest is BaseTest {
    // Address of the Uniswap V2 Router deployed on the Ethereum mainnet.
    // This is used to interact with Uniswap V2 for swapping tokens.
    address V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    // Instance of the UniswapV2DAppControl contract being tested.
    UniswapV2DAppControl v2DAppControlControl;

    // Instance of TxBuilder used to construct UserOperation and SolverOperation objects for testing.
    TxBuilder txBuilder;

    // Structure to hold signature components.
    Sig sig;

    // Instance of a test solver contract that simulates solver behavior in Atlas Protocol.
    BasicV2Solver basicV2Solver;

    /// @notice Sets up the testing environment before each test case is run.
    /// This includes deploying necessary contracts, initializing Atlas Protocol components,
    /// and preparing helper utilities like TxBuilder.
    function setUp() public override {
        // Invoke the setup function from the BaseTest parent contract to initialize common test configurations.
        super.setUp();

        // Deploy the UniswapV2DAppControl contract with required constructor parameters.
        // The governanceEOA (Externally Owned Account) is used as the deployer.
        vm.startPrank(governanceEOA);
        v2DAppControlControl = new UniswapV2DAppControl(address(atlas), WETH_ADDRESS, V2_ROUTER);

        // Register the deployed DAppControl contract with the Atlas Protocol for governance and verification.
        atlasVerification.initializeGovernance(address(v2DAppControlControl));
        vm.stopPrank();

        // Initialize the TxBuilder with references to the DAppControl contract, Atlas Protocol instance,
        // and the verification module to facilitate building transaction operations in tests.
        txBuilder = new TxBuilder({
            _control: address(v2DAppControlControl),
            _atlas: address(atlas),
            _verification: address(atlasVerification)
        });
    }

    /// @notice Tests the functionality of swapping WETH for DAI using UniswapV2 via the Atlas Protocol.
    /// This test simulates a user initiating a swap, a solver participating in the operation,
    /// and verifies that the token balances are updated correctly post-execution.
    function test_UniswapV2DAppControl_swapWETHForDAI() public {
        // Initialize structures to hold user and solver operations as well as DApp operation details.
        UserOperation memory userOp;
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        DAppOperation memory dAppOp;

        // ===========================
        // USER SETUP
        // ===========================

        // Simulate user actions by starting a prank from the user's EOA.
        vm.startPrank(userEOA);

        // Create an execution environment within Atlas for the user.
        // This environment is responsible for handling gas payments during metacall executions.
        // In an actual scenario, this would be created during a metacall, but here it's manually set up for testing.
        address executionEnvironment = atlas.createExecutionEnvironment(userEOA, address(v2DAppControlControl));
        console.log("Execution Environment:", executionEnvironment);
        vm.stopPrank();

        // Label the execution environment address for easier identification during testing.
        vm.label(address(executionEnvironment), "EXECUTION ENV");

        // Define the token swap path for Uniswap V2: from WETH to DAI.
        address[] memory path = new address[](2);
        path[0] = WETH_ADDRESS; // Starting token: Wrapped ETH
        path[1] = DAI_ADDRESS; // Target token: DAI

        // Encode the data for the swapExactTokensForTokens function call on Uniswap V2 Router.
        // Parameters:
        // - amountIn: 1 WETH (represented in wei as 1e18)
        // - amountOutMin: 0 (accept any amount of DAI, for testing purposes)
        // - path: Defined above (WETH -> DAI)
        // - to: userEOA (recipient of the DAI)
        // - deadline: Current block timestamp plus 999 seconds to allow the transaction to be mined.
        bytes memory userOpData = abi.encodeCall(
            IUniswapV2Router01.swapExactTokensForTokens,
            (
                1e18, // amountIn: 1 WETH
                0, // amountOutMin: accept any amount of DAI
                path, // swap path
                userEOA, // recipient of DAI
                block.timestamp + 999 // deadline
            )
        );

        // Build the UserOperation using TxBuilder, which includes all necessary transaction details.
        // Parameters:
        // - from: userEOA (the initiator of the operation)
        // - to: address of UniswapV2DAppControl contract
        // - maxFeePerGas: current gas price plus 1 wei (for flexibility)
        // - value: 0 (no ETH is sent with the operation)
        // - deadline: block number plus 555 to set a block-based deadline
        // - data: encoded function call data for the swap
        userOp = txBuilder.buildUserOperation({
            from: userEOA,
            to: address(v2DAppControlControl),
            maxFeePerGas: tx.gasprice + 1,
            value: 0,
            deadline: block.number + 555,
            data: userOpData
        });

        // Assign the DApp address (Uniswap V2 Router) and the session key (governanceEOA) to the UserOperation.
        // The session key may be used for additional authorization or verification within the Atlas Protocol.
        userOp.dapp = V2_ROUTER;
        userOp.sessionKey = governanceEOA;

        // Sign the UserOperation using the user's private key.
        // The signature ensures the authenticity and integrity of the operation.
        (sig.v, sig.r, sig.s) = vm.sign(userPK, atlasVerification.getUserOperationPayload(userOp));
        userOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Fund the user account with WETH to perform the swap.
        // The user does not need to spend ETH directly as the transaction gas is sponsored by the bundler.
        vm.startPrank(userEOA);
        deal(WETH_ADDRESS, userEOA, 1e18); // Assign 1 WETH to userEOA
        console.log("WETH.balanceOf(userEOA)", WETH.balanceOf(userEOA));

        // Approve the Atlas Protocol to spend the user's WETH for the swap operation.
        WETH.approve(address(atlas), 1e18);
        vm.stopPrank();

        // ===========================
        // SOLVER SETUP
        // ===========================

        // Simulate solver actions by starting a prank from the solver's EOA.
        vm.startPrank(solverOneEOA);

        // Deploy the BasicV2Solver contract, which will handle solver-specific operations such as backrunning.
        // It is initialized with the WETH address and the Atlas Protocol address.
        basicV2Solver = new BasicV2Solver(WETH_ADDRESS, address(atlas));

        // Fund the solver contract with WETH to cover the bid amount required for participating in the backrun.
        deal(WETH_ADDRESS, address(basicV2Solver), 1e17); // 0.1 WETH

        // Solvers need to deposit atlETH to pay for gas costs associated with metacall executions.
        // Deposit and bond atlETH within the Atlas Protocol to ensure the solver can cover these costs.
        atlas.deposit{ value: 1e18 }(); // Deposit 1 ETH worth of atlETH
        atlas.bond(1e18); // Bond 1 ETH worth of atlETH
        vm.stopPrank();

        // ===========================
        // SOLVER OPERATION BUILDING
        // ===========================

        // Encode the function selector for the backrun operation in the BasicV2Solver contract.
        bytes memory solverOpData = abi.encodeWithSelector(BasicV2Solver.backrun.selector);

        // Build the SolverOperation using TxBuilder, linking it to the UserOperation.
        // Parameters:
        // - userOp: The UserOperation created earlier
        // - solverOpData: Encoded data for the solver's backrun function
        // - solver: solverOneEOA (the EOA address of the solver)
        // - solverContract: Address of the deployed BasicV2Solver contract
        // - bidAmount: 0.1 WETH (1e17 wei) as the bid for the backrun opportunity
        // - value: 0 (no ETH is sent with the solver operation)
        solverOps[0] = txBuilder.buildSolverOperation({
            userOp: userOp,
            solverOpData: solverOpData,
            solver: solverOneEOA,
            solverContract: address(basicV2Solver),
            bidAmount: 1e17, // 0.1 ETH equivalent in WETH
            value: 0
        });

        // Sign the SolverOperation using the solver's private key to authenticate the operation.
        // This signature ensures that the solver has authorized participation in the operation.
        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // ===========================
        // DAPP SETUP
        // ===========================

        // Build the DAppOperation, which aggregates the UserOperation and SolverOperations.
        // The DAppOperation is responsible for coordinating the interactions between the user and solvers.
        // Parameter:
        // - governanceEOA: The governance address initiating the DApp operation
        // - userOp: The UserOperation detailing the user's intent to swap tokens
        // - solverOps: Array of SolverOperations that are participating in the auction operation (here 1)
        dAppOp = txBuilder.buildDAppOperation(governanceEOA, userOp, solverOps);

        // Fund the governanceEOA with ETH to cover any potential gas costs that might be required during the operation.
        deal(governanceEOA, 2e18); // Assign 2 ETH to governanceEOA

        // Simulate governance actions by starting a prank from the governanceEOA.
        vm.startPrank(governanceEOA);

        // Deposit and bond atlETH for the governance account to ensure it can cover gas fees if necessary.
        atlas.deposit{ value: 1e18 }(); // Deposit 1 ETH worth of atlETH
        atlas.bond(1e18); // Bond 1 ETH worth of atlETH
        vm.stopPrank();

        // ===========================
        // METACALL EXECUTION
        // ===========================

        // Log the user's WETH and DAI balances before executing the metacall to monitor changes post-operation.
        console.log("\nBEFORE METACALL");
        console.log("User WETH balance", WETH.balanceOf(userEOA));
        console.log("User DAI balance", DAI.balanceOf(userEOA));

        // Simulate a call to the metacall function from the governanceEOA.
        // The metacall serves as the entry point for executing Atlas transactions, coordinating user and solver
        // operations.
        // Any ETH sent with the metacall is treated as a potential subsidy for the winning solver.
        vm.prank(governanceEOA);
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp });

        // Log the user's WETH and DAI balances after executing the metacall to verify the swap outcome.
        console.log("\nAFTER METACALL");
        console.log("User WETH balance", WETH.balanceOf(userEOA));
        console.log("User DAI balance", DAI.balanceOf(userEOA));

        // ===========================
        // ASSERTIONS
        // ===========================

        // Verify that the user's WETH balance has decreased by at least the swap amount.
        // This ensures that the WETH was successfully spent in the swap operation.
        assertLt(WETH.balanceOf(userEOA), 1e18, "WETH balance should have decreased");

        // Verify that the user's DAI balance has increased, indicating a successful swap from WETH to DAI.
        assertGt(DAI.balanceOf(userEOA), 0, "DAI balance should have increased");
    }
}

/// @title BasicV2Solver
/// @notice A minimal solver contract designed for testing purposes within the Atlas Protocol.
/// It inherits from SolverBase and includes a placeholder backrun function to simulate solver behavior.
contract BasicV2Solver is SolverBase {
    /// @notice Constructor initializes the solver with necessary parameters.
    /// @param weth The address of the WETH token contract.
    /// @param atlas The address of the deployed Atlas Protocol contract.
    constructor(address weth, address atlas) SolverBase(weth, atlas, msg.sender) { }

    /// @notice Simulates a backrun operation.
    /// This function is intended to be called by the Atlas Protocol during metacall execution.
    /// The actual backrun logic would be implemented here in a real-world scenario.
    function backrun() public onlySelf {
        // Placeholder for backrun logic.
        // In a complete implementation, this would contain the steps to perform a backrun.
    }

    /// @notice Modifier to ensure that certain functions are only callable by the contract itself.
    /// This prevents unauthorized external calls and ensures that functions like backrun are invoked correctly.
    modifier onlySelf() {
        require(msg.sender == address(this), "Not called via atlasSolverCall");
        _;
    }

    /// @notice Fallback function to allow the contract to receive ETH without any data.
    /// This is essential for handling ETH transfers that might be part of solver operations.
    fallback() external payable { }

    /// @notice Receive function to allow the contract to receive ETH when sent directly.
    /// This ensures compatibility with standard ETH transfer methods.
    receive() external payable { }
}
