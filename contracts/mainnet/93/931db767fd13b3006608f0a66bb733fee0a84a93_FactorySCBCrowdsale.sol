// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "./SCCrowdsale/SCBonusableCrowdsale.sol";
import "./SCCrowdsale/SCBonusableDatesChangeableCrowdsale.sol";
import "../IController.sol";

contract FactorySCBCrowdsale is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IController public immutable CONTROLLER;

    mapping (address => uint256[2]) public price;

    event NewContract(address contractAddress, uint8 contractType);

    modifier canSetPrice {
        require(CONTROLLER.canSetPrice(msg.sender), "Cannot set price");
        _;
    }

    constructor(IController _controller) {
        CONTROLLER = _controller;
    }

    function setPrice(address _token, uint256[2] calldata _price) external canSetPrice {
        price[_token] = _price;
    }

    function deploySoftCappableBonusableCrowdsale(
        address[2] calldata tokenToPayAndOwner,
        address _token, uint256 _tokenDecimals,
        uint256 _duration,
        uint256 _soft_cap,
        address[] calldata _tokens, uint256[] calldata _rates,
        uint256[2] calldata _limits,
        uint256[2] calldata _bonus
    ) external nonReentrant {
        uint256 _price = price[tokenToPayAndOwner[0]][0];
        require(_price > 0, "Wrong payment method");
        IERC20(tokenToPayAndOwner[0]).safeTransferFrom(msg.sender, CONTROLLER.feeReceiver(), _price);
        require(_tokens.length == _rates.length, "Invalid parameters");
        SoftCappableBonusableCrowdsale crowdsale = new SoftCappableBonusableCrowdsale(_token, _tokenDecimals, _duration, _soft_cap);
        crowdsale.setLimits(_limits[0], _limits[1]);
        crowdsale.setBonus(_bonus[0], _bonus[1]);
        for (uint256 i; i < _tokens.length; i++) {
            crowdsale.addPaymentMethod(_tokens[i], _rates[i]);
        }
        crowdsale.transferOwnership(tokenToPayAndOwner[1]);
        emit NewContract(address(crowdsale), 0);
    }

    function deploySoftCappableBonusableDatesChangeableCrowdsale(
        address[2] calldata tokenToPayAndOwner,
        address _token, uint256 _tokenDecimals,
        uint256 _duration,
        uint256 _soft_cap,
        address[] calldata _tokens, uint256[] calldata _rates,
        uint256[2] calldata _limits,
        uint256[2] calldata _bonus
    ) external nonReentrant {
        uint256 _price = price[tokenToPayAndOwner[0]][1];
        require(_price > 0, "Wrong payment method");
        IERC20(tokenToPayAndOwner[0]).safeTransferFrom(msg.sender, CONTROLLER.feeReceiver(), _price);
        require(_tokens.length == _rates.length, "Invalid parameters");
        SoftCappableBonusableDatesChangeableCrowdsale crowdsale = new SoftCappableBonusableDatesChangeableCrowdsale(_token, _tokenDecimals, _duration, _soft_cap);
        crowdsale.setLimits(_limits[0], _limits[1]);
        crowdsale.setBonus(_bonus[0], _bonus[1]);
        for (uint256 i; i < _tokens.length; i++) {
            crowdsale.addPaymentMethod(_tokens[i], _rates[i]);
        }
        crowdsale.transferOwnership(tokenToPayAndOwner[1]);
        emit NewContract(address(crowdsale), 1);
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "../Bonusable.sol";
import "../DatesChangeable.sol";

contract SoftCappableBonusableDatesChangeableCrowdsale is BonusableCrowdsale, DatesChangeableCrowdsale {
    using SafeERC20 for IERC20;

    uint256 public SOFT_CAP;

    address[] public paymentMethods;
    uint256[] public ratePerFullToken;
    mapping (address => uint256[]) public amounts;
    uint256[] private refundable;
    mapping (address => uint256) private _paymentMethodExists;

    constructor(address _token, uint256 _tokenDecimals, uint256 _duration, uint256 _soft_cap) CrowdsaleBase(_token, _tokenDecimals, _duration) {
        SOFT_CAP = _soft_cap;
    }

    function start() external onlyOwner {
        require(endTime == 0, "Already started");
        endTime = block.timestamp + DURATION;
        refundable.push(0);
    }

    function addPaymentMethod(address token, uint256 rate) external onlyOwner {
        require(token != address(tokenToSell), "Cannot add sellable token as payment method");
        uint256 ID = _paymentMethodExists[token];
        if (ID == 0) {
            require(paymentMethods.length < 3, "Cannot add more than three payment methods");
            paymentMethods.push(token);
            ratePerFullToken.push(rate);
            _paymentMethodExists[token] = paymentMethods.length;
            refundable.push(0);
        }
        else {
            ratePerFullToken[ID - 1] = rate;
        }
    }

    function buy(address tokenToPay, uint256 amountToPay) external afterStartAndBeforeEnd nonReentrant {
        uint256 ID = _paymentMethodExists[tokenToPay];
        require(ID != 0, "Invalid payment method");
        uint256 _rate = ratePerFullToken[ID - 1];
        require(_rate > 0, "Invalid payment method");

        IERC20(tokenToPay).safeTransferFrom(_msgSender(), address(this), amountToPay);
        uint256 toGet = _calculate(amountToPay, _rate);

        _beforeSending(toGet);
        require(toGet <= (tokenToSell.balanceOf(address(this)) - refundable[0]), "Cannot buy this much");
        totalSold += toGet;

        if (totalSold < SOFT_CAP) {
            while (amounts[_msgSender()].length <= ID) {
                amounts[_msgSender()].push(0);
            }
            amounts[_msgSender()][0] += toGet;
            refundable[0] += toGet;
            amounts[_msgSender()][ID] += amountToPay;
            refundable[ID] += amountToPay;
        }
        else {
            if (amounts[_msgSender()].length > 0) {
                toGet += amounts[_msgSender()][0];
                for (uint256 i; i < amounts[_msgSender()].length; i++) {
                    refundable[i] -= amounts[_msgSender()][i];
                }
                delete amounts[_msgSender()];
            }
            tokenToSell.safeTransfer(_msgSender(), toGet);
        }
    }

    function redeem() external nonReentrant {
        tokenToSell.safeTransfer(_msgSender(), amounts[_msgSender()][0]);
        for (uint256 i; i < amounts[_msgSender()].length; i++) {
            refundable[i] -= amounts[_msgSender()][i];
        }
        delete amounts[_msgSender()];
    }

    function refund() external nonReentrant {
        require(block.timestamp > endTime, "Not ended yet");
        require(totalSold < SOFT_CAP, "Soft cap is reached");
        for (uint256 i; i < amounts[_msgSender()].length; i++) {
            uint256 toRefund = amounts[_msgSender()][i];
            if (toRefund > 0) {
                if (i != 0) {
                    address token = paymentMethods[i - 1];
                    IERC20(token).safeTransfer(_msgSender(), toRefund);
                }
                else {
                    totalSold -= toRefund;
                    bought[_msgSender()] -= toRefund;
                }
                refundable[i] -= toRefund;
            }
        }
        delete amounts[_msgSender()];
    }

    function getToken(address token) external onlyOwner nonReentrant {
        if (token == address(tokenToSell)) {
            require(block.timestamp > endTime, "Not ended yet");
            tokenToSell.safeTransfer(_msgSender(), tokenToSell.balanceOf(address(this)) - refundable[0]);
        }
        else {
            uint256 toGet = IERC20(token).balanceOf(address(this));
            uint256 ID = _paymentMethodExists[token];
            if (ID != 0 && totalSold < SOFT_CAP) {
                toGet -= refundable[ID];
            }
            if (toGet > 0) {
                IERC20(token).safeTransfer(_msgSender(), toGet);
            }
        }
    }

    function _calculate(uint256 amountToPay, uint256 _rate) internal virtual override(CrowdsaleBase, BonusableCrowdsale) returns(uint256) {
        return BonusableCrowdsale._calculate(amountToPay, _rate);
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "../Bonusable.sol";

contract SoftCappableBonusableCrowdsale is BonusableCrowdsale {
    using SafeERC20 for IERC20;

    uint256 public SOFT_CAP;

    address[] public paymentMethods;
    uint256[] public ratePerFullToken;
    mapping (address => uint256[]) public amounts;
    uint256[] private refundable;
    mapping (address => uint256) private _paymentMethodExists;

    constructor(address _token, uint256 _tokenDecimals, uint256 _duration, uint256 _soft_cap) CrowdsaleBase(_token, _tokenDecimals, _duration) {
        SOFT_CAP = _soft_cap;
    }

    function start() external onlyOwner {
        require(endTime == 0, "Already started");
        endTime = block.timestamp + DURATION;
        refundable.push(0);
    }

    function addPaymentMethod(address token, uint256 rate) external onlyOwner {
        require(token != address(tokenToSell), "Cannot add sellable token as payment method");
        uint256 ID = _paymentMethodExists[token];
        if (ID == 0) {
            require(paymentMethods.length < 3, "Cannot add more than three payment methods");
            paymentMethods.push(token);
            ratePerFullToken.push(rate);
            _paymentMethodExists[token] = paymentMethods.length;
            refundable.push(0);
        }
        else {
            ratePerFullToken[ID - 1] = rate;
        }
    }

    function buy(address tokenToPay, uint256 amountToPay) external afterStartAndBeforeEnd nonReentrant {
        uint256 ID = _paymentMethodExists[tokenToPay];
        require(ID != 0, "Invalid payment method");
        uint256 _rate = ratePerFullToken[ID - 1];
        require(_rate > 0, "Invalid payment method");

        IERC20(tokenToPay).safeTransferFrom(_msgSender(), address(this), amountToPay);
        uint256 toGet = _calculate(amountToPay, _rate);

        _beforeSending(toGet);
        require(toGet <= (tokenToSell.balanceOf(address(this)) - refundable[0]), "Cannot buy this much");
        totalSold += toGet;

        if (totalSold < SOFT_CAP) {
            while (amounts[_msgSender()].length <= ID) {
                amounts[_msgSender()].push(0);
            }
            amounts[_msgSender()][0] += toGet;
            refundable[0] += toGet;
            amounts[_msgSender()][ID] += amountToPay;
            refundable[ID] += amountToPay;
        }
        else {
            if (amounts[_msgSender()].length > 0) {
                toGet += amounts[_msgSender()][0];
                for (uint256 i; i < amounts[_msgSender()].length; i++) {
                    refundable[i] -= amounts[_msgSender()][i];
                }
                delete amounts[_msgSender()];
            }
            tokenToSell.safeTransfer(_msgSender(), toGet);
        }
    }

    function redeem() external nonReentrant {
        tokenToSell.safeTransfer(_msgSender(), amounts[_msgSender()][0]);
        for (uint256 i; i < amounts[_msgSender()].length; i++) {
            refundable[i] -= amounts[_msgSender()][i];
        }
        delete amounts[_msgSender()];
    }

    function refund() external nonReentrant {
        require(block.timestamp > endTime, "Not ended yet");
        require(totalSold < SOFT_CAP, "Soft cap is reached");
        for (uint256 i; i < amounts[_msgSender()].length; i++) {
            uint256 toRefund = amounts[_msgSender()][i];
            if (toRefund > 0) {
                if (i != 0) {
                    address token = paymentMethods[i - 1];
                    IERC20(token).safeTransfer(_msgSender(), toRefund);
                }
                else {
                    totalSold -= toRefund;
                    bought[_msgSender()] -= toRefund;
                }
                refundable[i] -= toRefund;
            }
        }
        delete amounts[_msgSender()];
    }

    function getToken(address token) external onlyOwner nonReentrant {
        if (token == address(tokenToSell)) {
            require(block.timestamp > endTime, "Not ended yet");
            tokenToSell.safeTransfer(_msgSender(), tokenToSell.balanceOf(address(this)) - refundable[0]);
        }
        else {
            uint256 toGet = IERC20(token).balanceOf(address(this));
            uint256 ID = _paymentMethodExists[token];
            if (ID != 0 && totalSold < SOFT_CAP) {
                toGet -= refundable[ID];
            }
            if (toGet > 0) {
                IERC20(token).safeTransfer(_msgSender(), toGet);
            }
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "./CrowdsaleBase.sol";

abstract contract DatesChangeableCrowdsale is CrowdsaleBase {

    function endCrowdsale() external onlyOwner afterStartAndBeforeEnd {
        endTime = block.timestamp;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract CrowdsaleBase is Ownable, ReentrancyGuard {

    IERC20 public tokenToSell;
    uint256 public tokenDecimals;
    uint256 public DURATION;

    uint256 public totalSold;
    uint256 public endTime;

    uint256 public lowerLimit;
    uint256 public upperLimit;

    mapping(address => uint256) public bought;

    modifier afterStartAndBeforeEnd() {
        require(endTime > block.timestamp, "Already ended or not started");
        _;
    }

    constructor(address _token, uint256 _tokenDecimals, uint256 _duration) {
        tokenToSell = IERC20(_token);
        tokenDecimals = _tokenDecimals;
        DURATION = _duration;
    }

    function setLimits(uint256 _lowerLimit, uint256 _upperLimit) external onlyOwner {
        lowerLimit = _lowerLimit;
        upperLimit = _upperLimit;
    }

    function _calculate(uint256 amountToPay, uint256 _rate) internal virtual returns(uint256) {
        return ((amountToPay * (10 ** tokenDecimals)) / _rate);
    }

    function _beforeSending(uint256 _toGet) internal virtual {
        require(_toGet >= lowerLimit, "Cannot receive less than lower limit");
        bought[_msgSender()] += _toGet;
        require(upperLimit == 0 || bought[_msgSender()] <= upperLimit, "Cannot receive more than upper limit");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "./CrowdsaleBase.sol";

abstract contract BonusableCrowdsale is CrowdsaleBase {
    uint256 public bonusBreakpoint;
    uint256 public bonusPercentage;

    function setBonus(uint256 _bonusBreakpoint, uint256 _bonusPercentage) external onlyOwner {
        bonusBreakpoint = _bonusBreakpoint;
        bonusPercentage = _bonusPercentage;
    }

    function _calculate(uint256 amountToPay, uint256 _rate) internal virtual override returns(uint256) {
        uint256 initAmount = super._calculate(amountToPay, _rate);
        if (initAmount >= bonusBreakpoint) {
            uint256 finalAmount = initAmount + ((initAmount * bonusPercentage) / 1000);
            if (finalAmount <= tokenToSell.balanceOf(address(this))) {
                return finalAmount;
            }
        }
        return initAmount;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface IController {

    function feeReceiver() external view returns(address);

    function canSetPrice(address) external view returns(bool);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}


// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCall(target, data, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        require(isContract(target), "Address: call to non-contract");

        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        require(isContract(target), "Address: static call to non-contract");

        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionDelegateCall(target, data, "Address: low-level delegate call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(isContract(target), "Address: delegate call to non-contract");

        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Tool to verifies that a low level call was successful, and revert if it wasn't, either by bubbling the
     * revert reason using the provided one.
     *
     * _Available since v4.3._
     */
    function verifyCallResult(
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal pure returns (bytes memory) {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly

                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}


// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../IERC20.sol";
import "../../../utils/Address.sol";

/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    using Address for address;

    function safeTransfer(
        IERC20 token,
        address to,
        uint256 value
    ) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 value
    ) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    function safeApprove(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        require(
            (value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    function safeIncreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        uint256 newAllowance = token.allowance(address(this), spender) + value;
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    function safeDecreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        unchecked {
            uint256 oldAllowance = token.allowance(address(this), spender);
            require(oldAllowance >= value, "SafeERC20: decreased allowance below zero");
            uint256 newAllowance = oldAllowance - value;
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address.functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        if (returndata.length > 0) {
            // Return data is optional
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}


// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);
}


// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and make it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }
}


// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../utils/Context.sol";

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        _setOwner(_msgSender());
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _setOwner(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _setOwner(newOwner);
    }

    function _setOwner(address newOwner) private {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}