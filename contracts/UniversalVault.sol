// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.7.5;
pragma abicoder v2;

import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/Initializable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/EnumerableSet.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {ERC1271} from "./Access/ERC1271.sol";
import {OwnableERC721} from "./Access/OwnableERC721.sol";

interface IRageQuit {
    function rageQuit() external;
}

interface IUniversalVault {
    event Locked(address delegate, address token, uint256 amount);
    event Unlocked(address delegate, address token, uint256 amount);

    function initialize() external;

    function owner() external view returns (address ownerAddress);

    function lock(
        address token,
        uint256 amount,
        bytes calldata permission
    ) external;

    function unlock(
        address token,
        uint256 amount,
        bytes calldata permission
    ) external;

    function rageQuit(address delegate, address token)
        external
        returns (bool notified, string memory error);
}

/// @title UniversalVault
/// @notice Vault for isolated storage of staking tokens
/// @dev Warning: not compatible with rebasing tokens
/// @dev Security contact: dev-support@ampleforth.org
contract UniversalVault is IUniversalVault, ERC1271, OwnableERC721, Initializable {
    using SafeMath for uint256;
    using Address for address;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /* storage */

    struct LockData {
        address delegate;
        address token;
        uint256 balance;
    }

    uint256 private _nonce;
    mapping(bytes32 => LockData) private _locks;
    EnumerableSet.Bytes32Set private _lockSet;

    /* events */
    event RageQuit(address delegate, address token, bool notified, string reason);

    /* initialization function */

    function initialize() external override initializer {
        OwnableERC721._setNFT(msg.sender);
    }

    /* ether receive */

    receive() external payable {}

    /* internal overrides */

    function _getOwner() internal view override(ERC1271) returns (address ownerAddress) {
        return OwnableERC721.owner();
    }

    /* pure functions */

    function calculateLockID(address delegate, address token) public pure returns (bytes32 lockID) {
        return keccak256(abi.encodePacked(delegate, token));
    }

    function calculatePermissionHash(
        string memory method,
        address vault,
        address delegate,
        address token,
        uint256 amount,
        uint256 nonce
    ) public pure returns (bytes32 hash) {
        return keccak256(abi.encodePacked(method, vault, delegate, token, amount, nonce));
    }

    /* private functions */

    function trimSelector(bytes memory data) private pure returns (bytes4 selector) {
        // manually unpack first 4 bytes
        // see: https://docs.soliditylang.org/en/v0.7.6/types.html#array-slices
        return data[0] | (bytes4(data[1]) >> 8) | (bytes4(data[2]) >> 16) | (bytes4(data[3]) >> 24);
    }

    /* getter functions */

    function getNonce() external view returns (uint256 nonce) {
        return _nonce;
    }

    function owner()
        public
        view
        override(IUniversalVault, OwnableERC721)
        returns (address ownerAddress)
    {
        return OwnableERC721.owner();
    }

    function getLockSetCount() external view returns (uint256 count) {
        return _lockSet.length();
    }

    function getLockAt(uint256 index) external view returns (LockData memory lockData) {
        return _locks[_lockSet.at(index)];
    }

    function getBalanceDelegated(address token, address delegate)
        external
        view
        returns (uint256 balance)
    {
        return _locks[calculateLockID(delegate, token)].balance;
    }

    function getBalanceLocked(address token) external view returns (uint256 balance) {
        for (uint256 index; index < _lockSet.length(); index++) {
            LockData storage _lockData = _locks[_lockSet.at(index)];
            if (_lockData.token == token && _lockData.balance > balance)
                balance = _lockData.balance;
        }
        return balance;
    }

    function checkBalances() public view returns (bool validity) {
        // iterate over all token locks and validate sufficient balance
        for (uint256 index; index < _lockSet.length(); index++) {
            // fetch storage lock reference
            LockData storage _lockData = _locks[_lockSet.at(index)];
            // if insufficient balance and not shutdown, return false
            if (IERC20(_lockData.token).balanceOf(address(this)) < _lockData.balance) return false;
        }
        // if sufficient balance or shutdown, return true
        return true;
    }

    /* user functions */

    /// @notice Perform an external call from the vault
    /// access control: only owner
    /// state machine: anytime
    /// state scope: none
    /// token transfer: transfer out amount limited by largest lock for given token
    /// @param to Destination address of transaction.
    /// @param value Ether value of transaction
    /// @param data Data payload of transaction
    function externalCall(
        address to,
        uint256 value,
        bytes calldata data
    ) external payable onlyOwner returns (bytes memory returnData) {
        // blacklist ERC20 approval
        if (data.length > 0) {
            require(data.length >= 4, "UniversalVault: calldata too short");
            require(
                trimSelector(data) != IERC20.approve.selector,
                "UniversalVault: cannot make ERC20 approval"
            );
            // perform external call
            returnData = to.functionCallWithValue(data, value);
        } else {
            // perform external call
            Address.sendValue(payable(to), value);
        }
        // verify sufficient token balance remaining
        require(checkBalances(), "UniversalVault: insufficient balance locked");
        // explicit return
        return returnData;
    }

    // EOA -> delegate:Deposit() -> vault:Lock()
    function lock(
        address token,
        uint256 amount,
        bytes calldata permission
    )
        external
        override
        onlyValidSignature(
            calculatePermissionHash("lock", address(this), msg.sender, token, amount, _nonce),
            permission
        )
    {
        // get lock id
        bytes32 lockID = calculateLockID(msg.sender, token);

        // add lock to storage
        if (_lockSet.contains(lockID)) {
            // if lock already exists, increase amount
            _locks[lockID].balance = _locks[lockID].balance.add(amount);
        } else {
            // if does not exist, create new lock
            // add lock to set
            assert(_lockSet.add(lockID));
            // add lock data to storage
            _locks[lockID] = LockData(msg.sender, token, amount);
        }

        // validate sufficient balance
        require(
            IERC20(token).balanceOf(address(this)) >= _locks[lockID].balance,
            "UniversalVault: insufficient balance"
        );

        // increase nonce
        _nonce += 1;

        // emit event
        emit Locked(msg.sender, token, amount);
    }

    // EOA -> delegate:Withdraw() -> vault:Unlock()
    function unlock(
        address token,
        uint256 amount,
        bytes calldata permission
    )
        external
        override
        onlyValidSignature(
            calculatePermissionHash("unlock", address(this), msg.sender, token, amount, _nonce),
            permission
        )
    {
        // get lock id
        bytes32 lockID = calculateLockID(msg.sender, token);

        // validate existing lock
        require(_lockSet.contains(lockID), "UniversalVault: missing lock");

        // update lock data
        if (_locks[lockID].balance > amount) {
            // substract amount from lock balance
            _locks[lockID].balance = _locks[lockID].balance.sub(amount);
        } else {
            // delete lock data
            delete _locks[lockID];
            assert(_lockSet.remove(lockID));
        }

        // increase nonce
        _nonce += 1;

        // emit event
        emit Unlocked(msg.sender, token, amount);
    }

    function rageQuit(address delegate, address token)
        external
        override
        onlyOwner
        returns (bool notified, string memory error)
    {
        // get lock id
        bytes32 lockID = calculateLockID(delegate, token);

        // validate existing lock
        require(_lockSet.contains(lockID), "UniversalVault: missing lock");

        // attempt to notify delegate
        if (delegate.isContract()) {
            try IRageQuit(delegate).rageQuit() {
                notified = true;
            } catch Error(string memory res) {
                notified = false;
                error = res;
            } catch (bytes memory) {
                notified = false;
            }
        }

        // update lock storage
        assert(_lockSet.remove(lockID));
        delete _locks[lockID];

        // emit event
        emit RageQuit(delegate, token, notified, error);
    }
}
