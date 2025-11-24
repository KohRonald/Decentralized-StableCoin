// SPDX-License-Identifier: MIT
// narrows down how we call our function to test

pragma solidity ^0.8.30;

import {Test, console2} from "lib/forge-std/src/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(weth)));
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return; //if no address has desposited via our tracked array, we return
        }

        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(sender);

        int256 maxDscToMint = (int256(collateralValueInUsd / 2)) - int256(totalDscMinted);

        if (maxDscToMint < 0) {
            return; //if negative dsc to mint then we return
        }
        amount = bound(amount, 0, uint256(maxDscToMint));
        console2.log("amount DSC to mint:", amount);

        if (amount == 0) {
            return; //if fuzz test choose to mint zero then we return
        }

        vm.startPrank(sender);
        dscEngine.mintDsc(amount); //should only mint if dsc amount is less than collateral
        vm.stopPrank();

        timesMintIsCalled++;
    }

    //redeem collateral <-- call when have collateral

    function depositCollateral(uint256 amountCollateral, uint256 collateralSeed) public {
        //we do this to ensure that we are only depositing tokens that we expect to test
        //because if other non-allowed tokens is deposited, it will always revert
        //and that is a waste of function calls during our fuzz test
        //we want to maximize the test of deposit collateral with allowed token addresses
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE); //sets the range of how much collateral the fuzz can use to test

        //need to approve the protocol to deposit the collateral
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dscEngine), amountCollateral);

        dscEngine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender); //might double push if same addresses is used twice
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed((collateralSeed));
        uint256 maxCollateralToRedeem = dscEngine.getCollateralBalanceOfUser(msg.sender, address(collateral));

        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem); //params are (collateral variable, min collateral to redeem, max collateral to redeem)
        if (amountCollateral == 0) {
            return; //dont call redeemCollateral if amountCollateral is zero because there is nothing to redeem, in doing so test will fail
        }
        vm.startPrank(msg.sender);
        dscEngine.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function updateCollateralPrice(uint96 newPrice) public {
        int256 newPriceInt = int256(uint256(newPrice)); //convert as updateAnswer() takes int256
        ethUsdPriceFeed.updateAnswer(newPriceInt);
    }

    // Helper functions
    // Function to random choose between 2 allowed collateral types
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }

    function callSummary() external view {
        console2.log("Weth total deposited", weth.balanceOf(address(dscEngine)));
        console2.log("Wbtc total deposited", wbtc.balanceOf(address(dscEngine)));
        console2.log("Total supply of DSC", dsc.totalSupply());
    }
}
