// SPDX-License-Identifier: MIT
pragma solidity ^0.7.3;
pragma experimental ABIEncoderV2;

import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vault} from "./Vault.sol";
import {ISTETH, IWSTETH} from "../interfaces/ISTETH.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {ICRV} from "../interfaces/ICRV.sol";
import {
    IStrikeSelection,
    IOptionsPremiumPricer
} from "../interfaces/IRibbon.sol";
import {GnosisAuction} from "./GnosisAuction.sol";
import {
    IOtokenFactory,
    IOtoken,
    IController,
    GammaTypes
} from "../interfaces/GammaInterface.sol";
import {IERC20Detailed} from "../interfaces/IERC20Detailed.sol";
import {SupportsNonCompliantERC20} from "./SupportsNonCompliantERC20.sol";

library VaultLifecycleSTETH {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SupportsNonCompliantERC20 for IERC20;

    struct CloseParams {
        address OTOKEN_FACTORY;
        address USDC;
        address currentOption;
        uint256 delay;
        uint256 lastStrikeOverride;
        uint256 overriddenStrikePrice;
    }

    function commitAndClose(
        address strikeSelection,
        address optionsPremiumPricer,
        uint256 premiumDiscount,
        CloseParams calldata closeParams,
        Vault.VaultParams calldata vaultParams,
        Vault.VaultState calldata vaultState,
        address collateralAsset
    )
        external
        returns (
            address otokenAddress,
            uint256 premium,
            uint256 strikePrice,
            uint256 delta
        )
    {
        uint256 expiry;

        // uninitialized state
        if (closeParams.currentOption == address(0)) {
            expiry = getNextFriday(block.timestamp);
        } else {
            expiry = getNextFriday(
                IOtoken(closeParams.currentOption).expiryTimestamp()
            );
        }

        IStrikeSelection selection = IStrikeSelection(strikeSelection);

        (strikePrice, delta) = closeParams.lastStrikeOverride ==
            vaultState.round
            ? (closeParams.overriddenStrikePrice, selection.delta())
            : selection.getStrikePrice(expiry, false);

        require(strikePrice != 0, "!strikePrice");

        otokenAddress = getOrDeployOtoken(
            closeParams.OTOKEN_FACTORY,
            vaultParams.underlying,
            closeParams.USDC,
            collateralAsset,
            strikePrice,
            expiry
        );

        verifyOtoken(
            otokenAddress,
            vaultParams,
            collateralAsset,
            closeParams.USDC,
            closeParams.delay
        );

        premium = dswmul(
            GnosisAuction.getOTokenPremium(
                otokenAddress,
                optionsPremiumPricer,
                premiumDiscount
            ),
            IWSTETH(collateralAsset).stEthPerToken()
        );

        require(premium > 0, "!premium");
    }

    function verifyOtoken(
        address otokenAddress,
        Vault.VaultParams calldata vaultParams,
        address collateralAsset,
        address USDC,
        uint256 delay
    ) private view {
        require(otokenAddress != address(0), "!otokenAddress");

        IOtoken otoken = IOtoken(otokenAddress);
        require(otoken.isPut() == false, "Type mismatch");
        require(
            otoken.underlyingAsset() == vaultParams.underlying,
            "Wrong underlyingAsset"
        );
        require(
            otoken.collateralAsset() == collateralAsset,
            "Wrong collateralAsset"
        );

        // we just assume all options use USDC as the strike
        require(otoken.strikeAsset() == USDC, "strikeAsset != USDC");

        uint256 readyAt = block.timestamp.add(delay);
        require(otoken.expiryTimestamp() >= readyAt, "Expiry before delay");
    }

    function rollover(
        uint256 currentSupply,
        uint256 currentBalance,
        Vault.VaultParams calldata vaultParams,
        Vault.VaultState calldata vaultState
    )
        external
        pure
        returns (
            uint256 newLockedAmount,
            uint256 queuedWithdrawAmount,
            uint256 newPricePerShare,
            uint256 mintShares
        )
    {
        uint256 pendingAmount = uint256(vaultState.totalPending);
        uint256 roundStartBalance = currentBalance.sub(pendingAmount);

        uint256 singleShare = 10**uint256(vaultParams.decimals);

        newPricePerShare = getPPS(
            currentSupply,
            roundStartBalance,
            singleShare
        );

        // After closing the short, if the options expire in-the-money
        // vault pricePerShare would go down because vault's asset balance decreased.
        // This ensures that the newly-minted shares do not take on the loss.
        uint256 _mintShares =
            pendingAmount.mul(singleShare).div(newPricePerShare);

        uint256 newSupply = currentSupply.add(_mintShares);
        // TODO: We need to use the pps of the round they scheduled the withdrawal
        // not the pps of the new round. https://github.com/ribbon-finance/ribbon-v2/pull/10#discussion_r652174863
        uint256 queuedWithdrawAmount =
            newSupply > 0
                ? uint256(vaultState.queuedWithdrawShares)
                    .mul(currentBalance)
                    .div(newSupply)
                : 0;

        uint256 balanceSansQueued = currentBalance.sub(queuedWithdrawAmount);

        return (
            balanceSansQueued,
            queuedWithdrawAmount,
            newPricePerShare,
            _mintShares
        );
    }

    // https://github.com/opynfinance/GammaProtocol/blob/master/contracts/Otoken.sol#L70
    uint256 private constant OTOKEN_DECIMALS = 10**8;

    function createShort(
        address gammaController,
        address marginPool,
        address oTokenAddress,
        uint256 depositAmount
    ) external returns (uint256) {
        IController controller = IController(gammaController);
        uint256 newVaultID =
            (controller.getAccountVaultCounter(address(this))).add(1);

        IOtoken oToken = IOtoken(oTokenAddress);
        address collateralAsset = oToken.collateralAsset();

        uint256 collateralDecimals =
            uint256(IERC20Detailed(collateralAsset).decimals());
        uint256 mintAmount;

        mintAmount = depositAmount;
        uint256 scaleBy = 10**(collateralDecimals.sub(8)); // oTokens have 8 decimals

        if (mintAmount > scaleBy && collateralDecimals > 8) {
            mintAmount = depositAmount.div(scaleBy); // scale down from 10**18 to 10**8
        }

        // double approve to fix non-compliant ERC20s
        IERC20 collateralToken = IERC20(collateralAsset);
        collateralToken.doubleApprove(marginPool, depositAmount);

        IController.ActionArgs[] memory actions =
            new IController.ActionArgs[](3);

        actions[0] = IController.ActionArgs(
            IController.ActionType.OpenVault,
            address(this), // owner
            address(this), // receiver -  we need this contract to receive so we can swap at the end
            address(0), // asset, otoken
            newVaultID, // vaultId
            0, // amount
            0, //index
            "" //data
        );

        actions[1] = IController.ActionArgs(
            IController.ActionType.DepositCollateral,
            address(this), // owner
            address(this), // address to transfer from
            collateralAsset, // deposited asset
            newVaultID, // vaultId
            depositAmount, // amount
            0, //index
            "" //data
        );

        actions[2] = IController.ActionArgs(
            IController.ActionType.MintShortOption,
            address(this), // owner
            address(this), // address to transfer to
            oTokenAddress, // deposited asset
            newVaultID, // vaultId
            mintAmount, // amount
            0, //index
            "" //data
        );

        controller.operate(actions);

        return mintAmount;
    }

    /**
     * @notice Close the existing short otoken position. Currently this implementation is simple.
     * It closes the most recent vault opened by the contract. This assumes that the contract will
     * only have a single vault open at any given time. Since calling `closeShort` deletes vaults,
     * this assumption should hold.
     */
    function settleShort(address gammaController) external returns (uint256) {
        IController controller = IController(gammaController);

        // gets the currently active vault ID
        uint256 vaultID = controller.getAccountVaultCounter(address(this));

        GammaTypes.Vault memory vault =
            controller.getVault(address(this), vaultID);

        require(vault.shortOtokens.length > 0, "No short");

        IERC20 collateralToken = IERC20(vault.collateralAssets[0]);

        uint256 startCollateralBalance =
            collateralToken.balanceOf(address(this));

        // If it is after expiry, we need to settle the short position using the normal way
        // Delete the vault and withdraw all remaining collateral from the vault
        IController.ActionArgs[] memory actions =
            new IController.ActionArgs[](1);

        actions[0] = IController.ActionArgs(
            IController.ActionType.SettleVault,
            address(this), // owner
            address(this), // address to transfer to
            address(0), // not used
            vaultID, // vaultId
            0, // not used
            0, // not used
            "" // not used
        );

        controller.operate(actions);

        uint256 endCollateralBalance = collateralToken.balanceOf(address(this));

        return endCollateralBalance.sub(startCollateralBalance);
    }

    /**
     * @notice Exercises the ITM option using existing long otoken position. Currently this implementation is simple.
     * It calls the `Redeem` action to claim the payout.
     */
    function settleLong(
        address gammaController,
        address oldOption,
        address asset
    ) external returns (uint256) {
        IController controller = IController(gammaController);

        uint256 oldOptionBalance = IERC20(oldOption).balanceOf(address(this));

        if (controller.getPayout(oldOption, oldOptionBalance) == 0) {
            return 0;
        }

        uint256 startAssetBalance = IERC20(asset).balanceOf(address(this));

        // If it is after expiry, we need to redeem the profits
        IController.ActionArgs[] memory actions =
            new IController.ActionArgs[](1);

        actions[0] = IController.ActionArgs(
            IController.ActionType.Redeem,
            address(0), // not used
            address(this), // address to send profits to
            oldOption, // address of otoken
            0, // not used
            oldOptionBalance, // otoken balance
            0, // not used
            "" // not used
        );

        controller.operate(actions);

        uint256 endAssetBalance = IERC20(asset).balanceOf(address(this));

        return endAssetBalance.sub(startAssetBalance);
    }

    /**
     * @notice Burn the remaining oTokens left over from auction. Currently this implementation is simple.
     * It burns oTokens from the most recent vault opened by the contract. This assumes that the contract will
     * only have a single vault open at any given time.
     */
    function burnOtokens(address gammaController, address currentOption)
        external
        returns (uint256)
    {
        uint256 numOTokensToBurn =
            IERC20(currentOption).balanceOf(address(this));

        if (numOTokensToBurn < 0) {
            return 0;
        }

        IController controller = IController(gammaController);

        // gets the currently active vault ID
        uint256 vaultID = controller.getAccountVaultCounter(address(this));

        GammaTypes.Vault memory vault =
            controller.getVault(address(this), vaultID);

        require(vault.shortOtokens.length > 0, "No short");

        IERC20 collateralToken = IERC20(vault.collateralAssets[0]);

        uint256 startCollateralBalance =
            collateralToken.balanceOf(address(this));

        // Burning all otokens that are left from the gnosis auction,
        // then withdrawing the corresponding collateral amount from the vault
        IController.ActionArgs[] memory actions =
            new IController.ActionArgs[](2);

        actions[0] = IController.ActionArgs(
            IController.ActionType.BurnShortOption,
            address(this), // owner
            address(this), // address to transfer to
            address(vault.shortOtokens[0]), // otoken address
            vaultID, // vaultId
            numOTokensToBurn, // amount
            0, //index
            "" //data
        );

        actions[1] = IController.ActionArgs(
            IController.ActionType.WithdrawCollateral,
            address(this), // owner
            address(this), // address to transfer to
            address(collateralToken), // withdrawn asset
            vaultID, // vaultId
            vault.collateralAmounts[0].mul(numOTokensToBurn).div(
                vault.shortAmounts[0]
            ), // amount
            0, //index
            "" //data
        );

        controller.operate(actions);

        uint256 endCollateralBalance = collateralToken.balanceOf(address(this));

        return endCollateralBalance.sub(startCollateralBalance);
    }

    function getOrDeployOtoken(
        address otokenFactory,
        address underlying,
        address strikeAsset,
        address collateralAsset,
        uint256 strikePrice,
        uint256 expiry
    ) internal returns (address) {
        IOtokenFactory factory = IOtokenFactory(otokenFactory);

        address otokenFromFactory =
            factory.getOtoken(
                underlying,
                strikeAsset,
                collateralAsset,
                strikePrice,
                expiry,
                false
            );

        if (otokenFromFactory != address(0)) {
            return otokenFromFactory;
        }

        address otoken =
            factory.createOtoken(
                underlying,
                strikeAsset,
                collateralAsset,
                strikePrice,
                expiry,
                false
            );
        return otoken;
    }

    function startAuction(GnosisAuction.AuctionDetails calldata auctionDetails)
        external
        returns (uint256)
    {
        return GnosisAuction.startAuction(auctionDetails);
    }

    function placeBid(GnosisAuction.BidDetails calldata bidDetails)
        external
        returns (
            uint256,
            uint256,
            uint64
        )
    {
        return GnosisAuction.placeBid(bidDetails);
    }

    function claimAuctionOtokens(
        Vault.AuctionSellOrder calldata auctionSellOrder,
        address gnosisEasyAuction,
        address counterpartyThetaVault
    ) external {
        GnosisAuction.claimAuctionOtokens(
            auctionSellOrder,
            gnosisEasyAuction,
            counterpartyThetaVault
        );
    }

    function verifyConstructorParams(
        address owner,
        address keeper,
        address feeRecipient,
        uint256 performanceFee,
        string calldata tokenName,
        string calldata tokenSymbol,
        Vault.VaultParams calldata _vaultParams
    ) external pure {
        require(owner != address(0), "!owner");
        require(keeper != address(0), "!keeper");
        require(feeRecipient != address(0), "!feeRecipient");
        require(performanceFee > 0, "!performanceFee");
        require(bytes(tokenName).length > 0, "!tokenName");
        require(bytes(tokenSymbol).length > 0, "!tokenSymbol");

        require(_vaultParams.asset != address(0), "!asset");

        require(_vaultParams.decimals > 0, "!tokenDecimals");
        require(_vaultParams.minimumSupply > 0, "!minimumSupply");
        require(_vaultParams.cap > 0, "!cap");
    }

    /**
     * @notice Withdraws stETH + ETH (if necessary) from vault using vault shares
     * @param collateralToken is the address of the collateral token
     * @param recipient is the recipient
     * @param amount is the withdraw amount in `asset`
     * @return withdrawAmount is the withdraw amount in `collateralToken`
     */
    function withdrawYieldAndBaseToken(
        address collateralToken,
        address recipient,
        uint256 amount
    ) external returns (uint256 withdrawAmount) {
        withdrawAmount = IWSTETH(collateralToken).getWstETHByStETH(amount);

        uint256 yieldTokenBalance =
            withdrawYieldToken(collateralToken, recipient, withdrawAmount);

        // If there is not enough stETH in the vault, it withdraws as much as possible and
        // transfers the rest in `asset`
        if (withdrawAmount > yieldTokenBalance) {
            withdrawBaseToken(
                collateralToken,
                recipient,
                withdrawAmount,
                yieldTokenBalance
            );
        }
    }

    /**
     * @notice Withdraws stETH from vault
     * @param collateralToken is the address of the collateral token
     * @param recipient is the recipient
     * @param withdrawAmount is the withdraw amount in terms of yearn tokens
     */
    function withdrawYieldToken(
        address collateralToken,
        address recipient,
        uint256 withdrawAmount
    ) internal returns (uint256 yieldTokenBalance) {
        IERC20 collateral = IERC20(collateralToken);

        yieldTokenBalance = collateral.balanceOf(address(this));
        uint256 yieldTokensToWithdraw =
            dsmin(yieldTokenBalance, withdrawAmount);
        if (yieldTokensToWithdraw > 0) {
            collateral.safeTransfer(recipient, yieldTokensToWithdraw);
        }
    }

    /**
     * @notice Withdraws `asset` from vault
     * @param collateralToken is the address of the collateral token
     * @param recipient is the recipient
     * @param withdrawAmount is the withdraw amount in terms of yearn tokens
     * @param yieldTokenBalance is the collateral token (stETH) balance of the vault
     */
    function withdrawBaseToken(
        address collateralToken,
        address recipient,
        uint256 withdrawAmount,
        uint256 yieldTokenBalance
    ) internal {
        uint256 underlyingTokensToWithdraw =
            IWSTETH(collateralToken).getStETHByWstETH(
                withdrawAmount.sub(yieldTokenBalance)
            );

        transferAsset(payable(recipient), underlyingTokensToWithdraw);
    }

    /**
     * @notice Unwraps the necessary amount of the yield-bearing yearn token
     *         and transfers amount to vault
     * @param amount is the amount of `asset` to withdraw
     * @param collateralToken is the address of the collateral token
     * @param crvPool is the address of the steth <-> eth pool on curve
     * @param minETHOut is the min eth to recieve
     */
    function unwrapYieldToken(
        uint256 amount,
        address collateralToken,
        address crvPool,
        uint256 minETHOut
    ) external returns (uint256 amountETHOut) {
        uint256 assetBalance = address(this).balance;

        amountETHOut = dsmin(assetBalance, amount);

        uint256 amountToUnwrap =
            IWSTETH(collateralToken).getWstETHByStETH(
                dsmax(assetBalance, amount).sub(assetBalance)
            );

        if (amountToUnwrap > 0) {
            IWSTETH wsteth = IWSTETH(collateralToken);
            // Unrap to stETH
            wsteth.unwrap(amountToUnwrap);

            // approve steth exchange
            IERC20(wsteth.stETH()).doubleApprove(crvPool, amountToUnwrap);

            // CRV SWAP HERE from steth -> eth
            // 0 = ETH, 1 = STETH
            amountETHOut = amountETHOut.add(
                ICRV(crvPool).exchange(1, 0, amountToUnwrap, minETHOut)
            );
        }
    }

    /**
     * @notice Wraps the necessary amount of the base token to the yield-bearing yearn token
     * @param weth is the address of weth
     * @param collateralToken is the address of the collateral token
     */
    function wrapToYieldToken(address weth, address collateralToken) external {
        // Unwrap all weth premiums transferred to contract
        IWETH weth = IWETH(weth);
        uint256 wethBalance = weth.balanceOf(address(this));

        if (wethBalance > 0) {
            weth.withdraw(wethBalance);
        }

        uint256 ethBalance = address(this).balance;

        IWSTETH collateral = IWSTETH(collateralToken);
        ISTETH stethToken = ISTETH(collateral.stETH());

        if (ethBalance > 0) {
            // Send eth to Lido, recieve steth
            stethToken.submit{value: ethBalance}(address(this));
        }

        // Get all steth in contract
        uint256 stethBalance = stethToken.balanceOf(address(this));

        if (stethBalance > 0) {
            // approve wrap
            IERC20(address(stethToken)).doubleApprove(
                collateralToken,
                stethBalance.add(1)
            );
            // Wrap to wstETH - need to add 1 to steth balance as it is innacurate
            collateral.wrap(stethBalance.add(1));
        }
    }

    function getVaultFees(
        Vault.VaultState storage vaultState,
        uint256 currentLockedBalance,
        uint256 performanceFeePercent,
        uint256 managementFeePercent
    )
        external
        view
        returns (
            uint256 performanceFee,
            uint256 managementFee,
            uint256 vaultFee
        )
    {
        uint256 prevLockedAmount = vaultState.lastLockedAmount;
        uint256 totalPending = vaultState.totalPending;

        // Take performance fee and management fee ONLY if difference between
        // last week and this week's vault deposits, taking into account pending
        // deposits and withdrawals, is positive. If it is negative, last week's
        // option expired ITM past breakeven, and the vault took a loss so we
        // do not collect performance fee for last week
        if (currentLockedBalance.sub(totalPending) > prevLockedAmount) {
            performanceFee = currentLockedBalance
                .sub(totalPending)
                .sub(prevLockedAmount)
                .mul(performanceFeePercent)
                .div(100 * 10**6);
            managementFee = currentLockedBalance.mul(managementFeePercent).div(
                100 * 10**6
            );

            vaultFee = performanceFee.add(managementFee);
        }
    }

    /**
     * @notice Helper function to make either an ETH transfer or ERC20 transfer
     * @param recipient is the receiving address
     * @param amount is the transfer amount
     */
    function transferAsset(address payable recipient, uint256 amount) public {
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "!success");
    }

    /**
     * @notice Gets the next options expiry timestamp
     */
    function getNextFriday(uint256 currentExpiry)
        internal
        pure
        returns (uint256)
    {
        uint256 nextWeek = currentExpiry + 86400 * 7;
        uint256 dayOfWeek = ((nextWeek / 86400) + 4) % 7;

        uint256 friday;
        if (dayOfWeek > 5) {
            friday = nextWeek - 86400 * (dayOfWeek - 5);
        } else {
            friday = nextWeek + 86400 * (5 - dayOfWeek);
        }

        uint256 friday8am =
            (friday - (friday % (60 * 60 * 24))) + (8 * 60 * 60);
        return friday8am;
    }

    function getPPS(
        uint256 currentSupply,
        uint256 roundStartBalance,
        uint256 singleShare
    ) internal pure returns (uint256 newPricePerShare) {
        newPricePerShare = currentSupply > 0
            ? singleShare.mul(roundStartBalance).div(currentSupply)
            : singleShare;
    }

    /***
     * DSMath Copy paste
     */

    uint256 constant DSWAD = 10**18;

    function dsadd(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x, "ds-math-add-overflow");
    }

    function dsmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x, "ds-math-mul-overflow");
    }

    //rounds to zero if x*y < WAD / 2
    function dswmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = dsadd(dsmul(x, y), DSWAD / 2) / DSWAD;
    }

    //rounds to zero if x*y < WAD / 2
    function dswdiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = dsadd(dsmul(x, DSWAD), y / 2) / y;
    }

    function dsmin(uint256 x, uint256 y) internal pure returns (uint256 z) {
        return x <= y ? x : y;
    }

    function dsmax(uint256 x, uint256 y) internal pure returns (uint256 z) {
        return x >= y ? x : y;
    }
}