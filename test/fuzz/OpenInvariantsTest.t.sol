// // SPDX-License-Identifier: MIT

// pragma solidity ^0.8.30;

// import {Test, console2} from "lib/forge-std/src/Test.sol";
// import {StdInvariant} from "lib/forge-std/src/StdInvariant.sol";
// import {DeployDSC} from "script/DeployDSC.s.sol";
// import {DSCEngine} from "src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "script/HelperConfig.s.sol";
// import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

// import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// contract OpenInvariantsTest is StdInvariant, Test {
//     DeployDSC deployer;
//     DSCEngine dscEngine;
//     DecentralizedStableCoin dsc;
//     HelperConfig helperConfig;
//     address weth;
//     address wbtc;

//     function setUp() external {
//         deployer = new DeployDSC();
//         (dsc, dscEngine, helperConfig) = deployer.run();
//         (,, weth, wbtc,) = helperConfig.activeNetworkConfig();
//         targetContract(address(dscEngine)); //Tells foundry to run stateful fuzz testing on our function in which ever order it wants on the DSCEngine contract
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         //get total value of all collateral in protocol
//         //compare it to all the debt which is the minted DSC
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));

//         console2.log("totalWethDeposited: ", totalWethDeposited);
//         console2.log("totalWbtcDeposited: ", totalWbtcDeposited);
//         console2.log("totalSupply: ", totalSupply);

//         uint256 wethValue = dscEngine.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValue = dscEngine.getUsdValue(wbtc, totalWbtcDeposited);

//         assert(wethValue + wbtcValue >= totalSupply);
//     }
// }

// //Hold properties of system

// //What are our invarients? The properties

// //1. Total supply of DSC should never be less than the total value of collateral
// //2. Getter view functions should never revert
