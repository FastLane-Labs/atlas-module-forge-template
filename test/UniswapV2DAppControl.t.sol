// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { UserOperation } from "@atlas/types/UserOperation.sol";
import { SolverOperation } from "@atlas/types/SolverOperation.sol";
import { DAppConfig } from "@atlas/types/ConfigTypes.sol";
import { DAppOperation } from "@atlas/types/DAppOperation.sol";
import { CallVerification } from "@atlas/libraries/CallVerification.sol";
import { SolverBase } from "@atlas/solver/SolverBase.sol";
import { BaseTest } from "@atlas-test/base/BaseTest.t.sol";
import { AccountingMath } from "@atlas/libraries/AccountingMath.sol";

import { UniswapV2DAppControl } from "src/UniswapV2DAppControl.sol";
import { IUniswapV2Router01, IUniswapV2Router02 } from "src/interfaces/IUniswapV2Router.sol";

contract UniswapV2DAppControlTest is BaseTest {
    struct SwapTokenInfo {
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        uint256 outputMin;
    }

    struct BeforeAndAfterVars {
        uint256 userInputTokenBalance;
        uint256 userOutputTokenBalance;
        uint256 solverRewardTokenBalance;
        uint256 burnAddressRewardTokenBalance;
        uint256 atlasGasSurcharge;
    }

    // Base addresses
    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant BURN = address(0xdead);
    address constant ETH_ADDRESS = address(0); // Renamed to avoid confusion
    address constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    IERC20 constant USDC = IERC20(USDC_ADDRESS);
    address REWARD_TOKEN;

    uint256 constant ERR_MARGIN = 0.18e18; // 18% error margin
    uint256 constant BUNDLER_GAS_ETH = 1e16;

    UniswapV2DAppControl uniswapV2DAppControl;
    address executionEnvironment;

    SwapTokenInfo swapInfo;
    BeforeAndAfterVars beforeVars;

    event TokensRewarded(address indexed user, address indexed token, uint256 amount);

    function setUp() public virtual override {
        // Fork Mainnet
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        __createAndLabelAccounts();
        __deployAtlasContracts();
        __fundSolversAndDepositAtlETH();

        REWARD_TOKEN = address(DAI); // Using DAI as the reward token for this example

        vm.startPrank(governanceEOA);
        uniswapV2DAppControl = new UniswapV2DAppControl(address(atlas), REWARD_TOKEN, UNISWAP_V2_ROUTER);
        atlasVerification.initializeGovernance(address(uniswapV2DAppControl));
        vm.stopPrank();

        vm.prank(userEOA);
        executionEnvironment = atlas.createExecutionEnvironment(userEOA, address(uniswapV2DAppControl));

        vm.label(address(WETH), "WETH");
        vm.label(USDC_ADDRESS, "USDC");
        vm.label(address(DAI), "DAI");
        vm.label(REWARD_TOKEN, "REWARD_TOKEN");
    }

    function testSwapExactTokensForTokens() public {
        // Arrange
        uint256 inputAmount = 1000 * 1e18; // Example input amount
        uint256 outputMin = 900 * 1e18; // Minimum acceptable output amount

        // Prepare swap information
        swapInfo = SwapTokenInfo({
            inputToken: address(DAI),
            inputAmount: inputAmount,
            outputToken: USDC_ADDRESS,
            outputMin: outputMin
        });

        // Encode the swap data as per UniswapV2Router02 interface
        address[] memory path = new address[](2);
        path[0] = swapInfo.inputToken;
        path[1] = swapInfo.outputToken;

        bytes memory swapData = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactTokensForTokens.selector,
            swapInfo.inputAmount,
            swapInfo.outputMin,
            path,
            userEOA,
            block.timestamp + 1 hours
        );

        // Create UserOperation
        UserOperation memory userOp = _createUserOp(swapData);

        // Create SolverOperation
        SolverOperation memory solverOp = _createSolverOp(userOp, 0);

        // Initialize solverOps array
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        // Record initial balances
        beforeVars.userInputTokenBalance = DAI.balanceOf(userEOA);
        beforeVars.userOutputTokenBalance = USDC.balanceOf(userEOA);
        beforeVars.solverRewardTokenBalance = IERC20(REWARD_TOKEN).balanceOf(solverOneEOA);
        beforeVars.burnAddressRewardTokenBalance = IERC20(REWARD_TOKEN).balanceOf(BURN);
        beforeVars.atlasGasSurcharge = AccountingMath.getAtlasSurcharge(1e18); // Calculate surcharge for 1 ETH

        // Act
        _executeAndVerifySwap(userOp, solverOps);

        // Assert
        // Check token balances
        assertEq(DAI.balanceOf(userEOA), beforeVars.userInputTokenBalance - inputAmount, "User DAI balance mismatch");
        assertEq(
            USDC.balanceOf(userEOA),
            beforeVars.userOutputTokenBalance + swapInfo.outputMin,
            "User USDC balance mismatch"
        );

        // Check reward distribution
        assertEq(
            IERC20(REWARD_TOKEN).balanceOf(userEOA),
            beforeVars.userOutputTokenBalance + swapInfo.outputMin,
            "User reward token balance mismatch"
        );

        // Additional assertions can be added based on the contract's logic
    }

    function testSwapETHForExactTokens() public {
        // Arrange
        uint256 ethAmount = 1 ether; // Example ETH amount sent
        uint256 outputAmount = 1000 * 1e18; // Exact output amount desired

        // Prepare swap information
        swapInfo = SwapTokenInfo({
            inputToken: ETH_ADDRESS,
            inputAmount: ethAmount,
            outputToken: USDC_ADDRESS,
            outputMin: outputAmount
        });

        // Encode the swap data as per UniswapV2Router02 interface
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = swapInfo.outputToken;

        bytes memory swapData = abi.encodeWithSelector(
            IUniswapV2Router01.swapETHForExactTokens.selector,
            swapInfo.outputMin,
            path,
            userEOA,
            block.timestamp + 1 hours
        );

        // Create UserOperation with ETH value
        UserOperation memory userOp = _createUserOp(swapData);
        userOp.value = ethAmount; // Set the ETH value sent

        // Create SolverOperation
        SolverOperation memory solverOp = _createSolverOp(userOp, 0);

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        // Record initial balances
        beforeVars.userInputTokenBalance = _balanceOf(ETH_ADDRESS, userEOA);
        beforeVars.userOutputTokenBalance = USDC.balanceOf(userEOA);
        beforeVars.solverRewardTokenBalance = IERC20(REWARD_TOKEN).balanceOf(solverOneEOA);
        beforeVars.burnAddressRewardTokenBalance = IERC20(REWARD_TOKEN).balanceOf(BURN);
        beforeVars.atlasGasSurcharge = AccountingMath.getAtlasSurcharge(1e18); // Calculate surcharge for 1 ETH

        // Act
        _executeAndVerifySwap(userOp, solverOps);

        // Assert
        // Check ETH balance
        assertEq(
            _balanceOf(ETH_ADDRESS, userEOA), beforeVars.userInputTokenBalance - ethAmount, "User ETH balance mismatch"
        );

        // Check token balances
        assertEq(
            USDC.balanceOf(userEOA), beforeVars.userOutputTokenBalance + outputAmount, "User USDC balance mismatch"
        );

        // Check reward distribution
        assertEq(
            IERC20(REWARD_TOKEN).balanceOf(userEOA),
            beforeVars.userOutputTokenBalance + outputAmount,
            "User reward token balance mismatch"
        );

        // Additional assertions can be added based on the contract's logic
    }

    function _createUserOp(bytes memory swapData) internal view returns (UserOperation memory) {
        return UserOperation({
            from: userEOA,
            to: address(atlas),
            value: 0,
            gas: 1_000_000,
            maxFeePerGas: tx.gasprice,
            nonce: 1,
            deadline: block.timestamp + 1 hours,
            dapp: UNISWAP_V2_ROUTER,
            control: address(uniswapV2DAppControl),
            callConfig: uniswapV2DAppControl.CALL_CONFIG(),
            sessionKey: address(0),
            data: swapData,
            signature: new bytes(0)
        });
    }

    function _createSolverOp(
        UserOperation memory userOp,
        uint256 bidAmount
    )
        internal
        returns (SolverOperation memory)
    {
        address solverContract = address(new MockSolver(address(WETH), address(atlas)));
        SolverOperation memory solverOp = SolverOperation({
            from: solverOneEOA,
            to: address(atlas),
            value: 0,
            gas: 500_000,
            maxFeePerGas: userOp.maxFeePerGas,
            deadline: userOp.deadline,
            solver: solverContract,
            control: address(uniswapV2DAppControl),
            userOpHash: atlasVerification.getUserOperationHash(userOp),
            bidToken: uniswapV2DAppControl.getBidFormat(userOp),
            bidAmount: bidAmount,
            data: abi.encodeCall(MockSolver.solve, ()),
            signature: new bytes(0)
        });

        // Sign the solver operation
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(r, s, v);

        return solverOp;
    }

    function _executeAndVerifySwap(UserOperation memory userOp, SolverOperation[] memory solverOps) internal {
        // Expect the TokensRewarded event to be emitted
        vm.expectEmit(true, true, false, true);
        emit TokensRewarded(userOp.from, REWARD_TOKEN, solverOps[0].bidAmount);

        // Execute the user operation via Atlas
        DAppConfig memory dAppConfig = DAppConfig({
            to: userOp.to,
            callConfig: userOp.callConfig,
            bidToken: solverOps[0].bidToken,
            solverGasLimit: 500_000 // Add a reasonable gas limit for solvers
         });

        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);

        atlas.execute(
            dAppConfig,
            userOp,
            solverOps,
            executionEnvironment,
            address(0), // bundler
            userOpHash,
            false // isSimulation
        );
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        if (token == ETH_ADDRESS) {
            return account.balance;
        } else {
            return IERC20(token).balanceOf(account);
        }
    }
}

contract MockSolver is SolverBase {
    constructor(address weth, address atlas) SolverBase(weth, atlas, msg.sender) { }

    function solve() public {
        // Mock implementation
    }

    fallback() external payable { }
    receive() external payable { }
}
