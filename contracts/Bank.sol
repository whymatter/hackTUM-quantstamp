//SPDX-License-Identifier: Unlicense
pragma solidity 0.7.0;

import "./interfaces/IBank.sol";
import "./interfaces/IPriceOracle.sol";
import "./interfaces/IERC20.sol";
import "./libraries/Math.sol";
import "hardhat/console.sol";

contract Bank is IBank {
    address ETH = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    address HAK;
    address PriceOracle;

    mapping(address => Account) ethAccounts;
    mapping(address => Account) hakAccounts;
    mapping(address => BorrowAccount) borrowAccounts;

    constructor(address _priceOracle, address _hakToken) {
        PriceOracle = _priceOracle;
        HAK = _hakToken;
    }

    function checkTokenType(address token) private view {
        require(token == ETH || token == HAK, "token not supported");
    }

    // Get account or create if doesn't exist
    function getAccountMemory(address token, address account)
        private
        view
        returns (Account memory)
    {
        if (token == ETH) {
            return ethAccounts[account];
        } else {
            return hakAccounts[account];
        }
    }

    function getAccountStorage(address token, address account)
        private
        view
        returns (Account storage)
    {
        if (token == ETH) {
            return ethAccounts[account];
        } else {
            return hakAccounts[account];
        }
    }

    // Calculate the interest accrued on the account since the last stored calculation
    function calcNewInterest(address token, address account)
        private
        view
        returns (uint256)
    {
        Account memory user_account = getAccountMemory(token, account);
        if (user_account.lastInterestBlock == 0) {
            return 0;
        } else {
            uint256 num_blocks = DSMath.sub(
                block.number,
                user_account.lastInterestBlock
            );
            return (user_account.deposit * 3 * num_blocks) / 10000;
        }
    }

    // Updates interest calculated for an account.
    // Updates the account in storage, updating all relevant fields.
    function updateInterest(address token, address account) private {
        uint256 interest = calcNewInterest(token, account);
        Account storage user_account = getAccountStorage(token, account);
        user_account.interest += interest;
        user_account.lastInterestBlock = block.number;
    }

    function calcNewInterestOwed(address account)
        private
        view
        returns (uint256)
    {
        BorrowAccount memory user_account = borrowAccounts[account];
        if (user_account.lastInterestBlock == 0) {
            return 0;
        } else {
            uint256 num_blocks = DSMath.sub(
                block.number,
                user_account.lastInterestBlock
            );
            return (user_account.amountBorrowed * 5 * num_blocks) / 10000;
        }
    }

    function updateInterestOwed(address account) private {
        uint256 interest = calcNewInterestOwed(account);
        BorrowAccount storage user_account = borrowAccounts[account];
        user_account.interestOwed += interest;
        user_account.lastInterestBlock = block.number;
    }

    /**
     * The purpose of this function is to allow end-users to deposit a given
     * token amount into their bank account.
     * @param token - the address of the token to deposit. If this address is
     *                set to 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE then
     *                the token to deposit is ETH.
     * @param amount - the amount of the given token to deposit.
     * @return - true if the deposit was successful, otherwise revert.
     */
    function deposit(address token, uint256 amount)
        external
        payable
        override
        returns (bool)
    {
        checkTokenType(token);
        // If currency is ETH, take the `value` attached to the message rather than `amount`
        // -> Ether is automatically transferred via `payable` keyword
        //   -> TODO investigate as potential vulnerability
        if (token == ETH) {
            amount = msg.value;
        }
        require(amount > 0);
        if (token == HAK) {
            // Check that the sender has enough HAK to cover the deposit
            require(IERC20(token).balanceOf(msg.sender) >= amount);
            // Transfer the sender's HAK to this account
            // TODO: understand why/how we get permission to make the transfer
            IERC20(token).transferFrom(msg.sender, address(this), amount);
        }

        Account storage account = getAccountStorage(token, msg.sender);
        updateInterest(token, msg.sender);
        account.deposit += amount;
        emit Deposit(msg.sender, token, amount);
        return true;
    }

    /**
     * The purpose of this function is to allow end-users to withdraw a given
     * token amount from their bank account. Upon withdrawal, the user must
     * automatically receive a 3% interest rate per 100 blocks on their deposit.
     * @param token - the address of the token to withdraw. If this address is
     *                set to 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE then
     *                the token to withdraw is ETH.
     * @param amount - the amount of the given token to withdraw. If this param
     *                 is set to 0, then the maximum amount available in the
     *                 caller's account should be withdrawn.
     * @return - the amount that was withdrawn plus interest upon success,
     *           otherwise revert.
     */
    function withdraw(address token, uint256 amount)
        external
        override
        returns (uint256)
    {
        // TODO: is this the correct logic?
        //  -> assume we can withdraw only from the deposit, and send the whole interest back
        checkTokenType(token);
        Account storage user_account = getAccountStorage(token, msg.sender);
        require(user_account.deposit > 0, "no balance");
        require(amount <= user_account.deposit, "amount exceeds balance");

        updateInterest(token, msg.sender);
        if (amount == 0) {
            amount = user_account.deposit;
        }
        user_account.deposit -= amount;
        uint256 total_return = amount + user_account.interest;
        user_account.interest = 0;

        if (token == HAK) {
            require(IERC20(token).balanceOf(address(this)) >= total_return);
            IERC20(token).transfer(msg.sender, total_return);
        } else {
            require(
                address(this).balance >= total_return,
                "bank has not enough ETH balance"
            );
            bool sent = msg.sender.send(total_return);
            require(sent, "failed to send ETH");
        }
        emit Withdraw(msg.sender, token, total_return);
        return total_return;
    }

    // Note: does not update interest!
    // Basically: (deposits[account] + accruedInterest[account]) * 10000 / (borrowed[account] + owedInterest[account])
    function calcCollateralRatio(
        Account memory hakAccount,
        BorrowAccount memory borrowAccount
    ) private view returns (uint256) {
        console.log(
            "Hak deposit = %s, ETH borrowed = %s",
            hakAccount.deposit,
            borrowAccount.amountBorrowed
        );

        require(hakAccount.deposit > 0, "no collateral deposited");

        // Check for infinite collateral
        if (hakAccount.deposit > 0 && borrowAccount.amountBorrowed == 0) {
            return type(uint256).max;
        }

        // Calculate deposit and interest accrued to user in ETH
        uint256 hak_price = IPriceOracle(PriceOracle).getVirtualPrice(HAK);
        console.log("Hak price is %s", hak_price);
        uint256 hak_deposit_as_eth = hakAccount.deposit * hak_price;
        uint256 hak_interest_as_eth = hakAccount.interest * hak_price;

        return
            ((hak_deposit_as_eth + hak_interest_as_eth) * 10000) /
            (borrowAccount.amountBorrowed + borrowAccount.interestOwed) /
            10**18;
    }

    /**
     * The purpose of this function is to allow users to borrow funds by using their
     * deposited funds as collateral. The minimum ratio of deposited funds over
     * borrowed funds must not be less than 150%.
     * @param token - the address of the token to borrow. This address must be
     *                set to 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE, otherwise
     *                the transaction must revert.
     * @param amount - the amount to borrow. If this amount is set to zero (0),
     *                 then the amount borrowed should be the maximum allowed,
     *                 while respecting the collateral ratio of 150%.
     * @return - the current collateral ratio.
     */
    function borrow(address token, uint256 amount)
        external
        override
        returns (uint256)
    {
        require(token == ETH, "can only borrow ETH");
        console.log("Request to borrow %s ETH", amount);

        updateInterest(ETH, msg.sender);
        updateInterest(HAK, msg.sender);
        updateInterestOwed(msg.sender);

        Account memory hak_account = getAccountMemory(HAK, msg.sender);
        BorrowAccount memory borrow_account = borrowAccounts[msg.sender];

        if (amount == 0) {
            amount =
                ((hak_account.deposit + hak_account.interest) * 10000) /
                15000;
            amount =
                amount -
                borrow_account.amountBorrowed -
                borrow_account.interestOwed;
        }

        // Calculate hypothetical collateral ratio if the money were borrowed
        borrow_account.amountBorrowed += amount;
        uint256 new_collateral = calcCollateralRatio(
            hak_account,
            borrow_account
        );
        console.log("new collateral is %d", new_collateral);
        require(
            new_collateral >= 15000,
            "borrow would exceed collateral ratio"
        );

        // Make sure we can cover the loan
        require(address(this).balance >= amount);

        // At this point, we know we can make the loan
        BorrowAccount storage stored_borrow_account = borrowAccounts[
            msg.sender
        ];
        stored_borrow_account.amountBorrowed += amount;
        stored_borrow_account.lastInterestBlock = block.number;

        bool sent = msg.sender.send(amount);
        require(sent, "failed to send ETH");
        emit Borrow(msg.sender, ETH, amount, new_collateral);
        return new_collateral;
    }

    /**
     * The purpose of this function is to allow users to repay their loans.
     * Loans can be repaid partially or entirely. When replaying a loan, an
     * interest payment is also required. The interest on a loan is equal to
     * 5% of the amount lent per 100 blocks. If the loan is repaid earlier,
     * or later then the interest should be proportional to the number of
     * blocks that the amount was borrowed for.
     * @param token - the address of the token to repay. If this address is
     *                set to 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE then
     *                the token is ETH.
     * @param amount - the amount to repay including the interest.
     * @return - the amount still left to pay for this loan, excluding interest.
     */
    function repay(address token, uint256 amount)
        external
        payable
        override
        returns (uint256)
    {
        require(token == ETH, "token not supported");
        require(msg.value >= amount, "msg.value < amount to repay");
        amount = msg.value;

        BorrowAccount storage borrow_account = borrowAccounts[msg.sender];
        require(borrow_account.amountBorrowed > 0, "nothing to repay");

        updateInterestOwed(msg.sender);
        // First, pay off the interest
        if (amount <= borrow_account.interestOwed) {
            // Case: amount sent <= interest
            borrow_account.interestOwed -= amount;
            emit Repay(
                msg.sender,
                token,
                borrow_account.amountBorrowed + borrow_account.interestOwed
            );
            return borrow_account.amountBorrowed;
        } else {
            // Case amount sent > interest and can pay off principal
            uint256 interest_paid = borrow_account.interestOwed;
            borrow_account.interestOwed = 0;
            // Now deduct from amountBorrowed
            uint256 paid_remaining = amount - interest_paid;
            borrow_account.amountBorrowed -= paid_remaining;
            emit Repay(msg.sender, token, borrow_account.amountBorrowed);
            return borrow_account.amountBorrowed;
        }
    }

    /**
     * The purpose of this function is to allow so called keepers to collect bad
     * debt, that is in case the collateral ratio goes below 150% for any loan.
     * @param token - the address of the token used as collateral for the loan.
     * @param account - the account that took out the loan that is now undercollateralized.
     * @return - true if the liquidation was successful, otherwise revert.
     */
    function liquidate(address token, address account)
        external
        payable
        override
        returns (bool)
    {}

    /**
     * The purpose of this function is to return the collateral ratio for any account.
     * The collateral ratio is computed as the value deposited divided by the value
     * borrowed. However, if no value is borrowed then the function should return
     * uint256 MAX_INT = type(uint256).max
     * @param token - the address of the deposited token used a collateral for the loan.
     * @param account - the account that took out the loan.
     * @return - the value of the collateral ratio with 2 percentage decimals, e.g. 1% = 100.
     *           If the account has no deposits for the given token then return zero (0).
     *           If the account has deposited token, but has not borrowed anything then
     *           return MAX_INT.
     */
    function getCollateralRatio(address token, address account)
        public
        view
        override
        returns (uint256)
    {
        checkTokenType(token);
        if (token == HAK) {
            Account memory hak_account = getAccountMemory(HAK, account);
            BorrowAccount memory borrow_account = borrowAccounts[account];

            // TODO: double-check
            hak_account.interest += calcNewInterest(HAK, account);
            borrow_account.interestOwed += calcNewInterestOwed(account);

            uint256 collateral = calcCollateralRatio(
                hak_account,
                borrow_account
            );
            console.log("Calculated collateral = %s", collateral);
            return collateral;
        }
        // TODO: WHAT TO RETURN FOR ETH?
        return 0;
    }

    /**
     * The purpose of this function is to return the balance that the caller
     * has in their own account for the given token (including interest).
     * @param token - the address of the token for which the balance is computed.
     * @return - the value of the caller's balance with interest, excluding debts.
     */
    function getBalance(address token) public view override returns (uint256) {
        Account memory user_account = getAccountMemory(token, msg.sender);
        return
            user_account.deposit +
            user_account.interest +
            calcNewInterest(token, msg.sender);
    }
}
