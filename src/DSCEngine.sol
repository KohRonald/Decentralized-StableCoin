// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Ronald Koh
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 *
 * The stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI has no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC system should always be "overcollaterized". At no point should the value of all the collateral be <= the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for mining and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    //////////////
    //  Errors  //
    //////////////
    error DSCEngine__AmountMustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenIsNotAValidCollateral();
    error DSCEngine_TransferFailed();
    error DSCEngine__BreaksHealthFactor();
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine_HealthFactorNotImproved();

    ///////////////////////
    //  STATE VARIABLES  //
    ///////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISON = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% Bonus, 10/100 as per LIQUIDATION_PRECISION
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////
    //  EVENTS  //
    //////////////
    event CollateralDeposited(address indexed user, address indexed tokenCollateral, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address tokenCollateral, uint256 amountCollateral
    );

    /////////////////
    //  MODIFIERS  //
    /////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__AmountMustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedCollateralToken(address token) {
        //remember key value pair, using token as key to get price feed address
        //if address(0) is returned, means token is not mapped to any price feed, thus not allowed
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenIsNotAValidCollateral();
        }
        _;
    }

    /////////////////
    //  FUNCTIONS  //
    /////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        //USD Price Feeds
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////////////////
    //  EXTERNAL FUNCTIONS  //
    //////////////////////////
    /*
        * @notice this function will deposit collateral and mint DSC in one transaction 
        * @param tokenCollateralAddress The address of the token to deposit as collateral
        * @param amountCollateral The amount of collateral to deposit
        * @param amountDscToMint The amount of Decentralized Stable Coin (DSC) to mint
    */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @notice follows CEI Pattern (checks-effects-interactions)
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedCollateralToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        //wraps collateral token as an ERC20, and trasnfer from user to contract
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    /*
    * @notice This function burns DSC and redeems underlying collateral in one transaction
    * @param tokenCollateralAddress The address of the token to redeem as collateral
    * @param amountCollateral The amount of collateral to redeem
    * @param amountDscToBurn The amount of Decentralized Stable Coin (DSC) to burn
    */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /*
    * @notice follows CEI Pattern (checks-effects-interactions)
    * health factor must be over 1 after collateral redemption
    */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
    * @notice follows CEI Pattern (checks-effects-interactions)
    * @param amountDscToMint The amount of Decentralized Stable Coin (DSC) to mint
    * @notice they must have more collateral value than the minimum threshold
    */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        //If minted too much, revert ($150 DSC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) {
        _burnDsc(msg.sender, msg.sender, amountDscToBurn);
        _revertIfHealthFactorIsBroken(msg.sender); //unlikely will be reached
    }

    /*
    * @param collateral The erc20 collateral address to liquidate from user
    * @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
    * @param debtToCover The amount of DSC you want to burn to imporve the users health factor
    * @notice you can partially liquidate a user
    * @notice you will get a liquidation bonus for taking the user funds
    * @notice This function working assumes protocol will be roughly 200% overcollateralized in order for this to work
    * @notice A known bug would be if the protocol were 100% or less collateralized, then we would not be able to incentivize
    * the liquidators. For example, if the price of the colalteal plummeted before anyone could be liquidated.
    * 
    * if someone is almost undercollateralized based on threshhold set, allow them to be liquidated by others
    * liquidate through paying off their debt (burning their DSC) in exchange for their collateral at a discount
    * Eg. $75 ETH backing $50 DSC, under our 200% collateral threshold, allow to liquidate user by paying off/burning
    * the $50 DSC position debt, and receive bonus collateral from the user's account
    *
    * @notice follows CEI Pattern (checks-effects-interactions)
    */
    function liquidate(address tokenCollateralAddress, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //check health factor of user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        //burn DSC "debt" and take their collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(tokenCollateralAddress, debtToCover);

        // 0.05 ETH * 0.1 = 0.005 ETH. Getting 0.055 ETH
        // here calculates bonus collateral to be paid out to liquidator
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        //when liquidating another user, their DSC will be burned, and their collateral worth of that
        // DSC + 10% will be paid to the liquidator
        _redeemCollateral(user, msg.sender, tokenCollateralAddress, totalCollateralToRedeem);

        //burn DSC here
        _burnDsc(user, msg.sender, debtToCover);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine_HealthFactorNotImproved();
        }

        //this revert checks that the liquidator does not break their own health factor in the process
        _revertIfHealthFactorIsBroken(msg.sender);

        //Future improvements:
        //Implement a feature to liquidate in the event the protocol is insolvent and swap extra amounts into a treasury
    }

    function getHealthFactor() external view {}

    ///////////////////////////////////////
    // PRIVATE & INTERNAL VIEW FUNCTIONS //
    ///////////////////////////////////////

    /*
    * @dev Low-level internal function, do not call unless the function calling it is checking for health factor being broken
    */
    function _burnDsc(address onBehalfOf, address dscFrom, uint256 amountDscToBurn) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }

        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        totalCollateralValueInUsd = getAccountCollateralValue(user);

        return (totalDscMinted, totalCollateralValueInUsd);
    }

    /*
    * Returns how close to liquidation a user is
    * If a user goes below 1, then they can get liquidated
    * 1. Get total DSC minted
    * 2. Get total collateral value
    * 
    * Eg. 
    * $1000 ETH / 100 DSC
    * $1000 * 50 = $50000, $50000 / 100 = $500
    * $500 worth of collateral needed to back $250 worth of DSC minted = 2.0 health factor
    * if _health factor < 1, user can be liquidated
    *
    */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        //for precision, the value return here will be in 1e18 format
        //so it can be either 1e18 (1.0) or 2e18 (2.0) or 3e18 (3.0), etc.
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        //1. Check health factor, if they have enough collateral
        //2. Revert if not health factor is not met
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor();
        }
    }

    //////////////////////////////////////
    // PUBLIC & EXTERNAL VIEW FUNCTIONS //
    //////////////////////////////////////
    /*
    * @notice This function will get the priceFeed of the collateral token dynamically, and calculate the total
    * USD amount of the collateral that the user has
    */
    function getTokenAmountFromUsd(address tokenCollateralAdderss, uint256 usdAmountInWei)
        public
        view
        returns (uint256)
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[tokenCollateralAdderss]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        //Eg. price of ETH (token)
        //$/ETH ?
        //$2000 per ETH, we have $1000 worth of ETH, we do $1000/$2000 = 0.5

        //always do precision, usdAmountInWei with 18 decimals, price already has 8 decimals, we times by 1e10 to make it 18 decimal places
        //usdAmountInWei is the USD amount worth of ETH the user has
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISON);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        //loop through each collateral token, get amount user deposited, get price of collateral token, and map it to price, to get USD Value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount); //this is total USD value of all collateral tokens deposited by user
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        //The returned value from Chainlink will be have 8 decimal places, as per docs
        //for precision, we will need to ensure both values have same number of decimal places
        //finally we divide by 1e18 to get final USD value with 18 decimal places
        return ((uint256(price) * ADDITIONAL_FEED_PRECISON) * amount) / PRECISION;
    }
}
