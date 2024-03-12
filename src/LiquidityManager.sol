// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "./core/Initializable.sol";
import "./core/libraries/SafeERC20.sol";
import "./extensions/EnumerableSet.sol";
import "./extensions/ReentrancyGuard.sol";

import "./core/interfaces/uniswap/IUniswapV2Router02.sol";
import "./core/interfaces/uniswap/IUniswapV2Factory.sol";
import "./core/interfaces/uniswap/IUniswapV2Pair.sol";
import "./core/interfaces/IERC20.sol";

/**
 * @title Liquidity Manager
 * @notice Optimized Liquidity Manager & Locker by Metacrypt
 * @author Metacrypt (https://www.metacrypt.org/)
 * @dev Copyright (c) Metacrypt - All Rights Reserved
 * @dev * * * * *
 * @dev Liquidity Manager is free to use on every chain it is deployed on, by anyone
 * @dev and at any time. This is an open project for the community to safely launch
 * @dev their projects without worrying about liquidity.
 * @dev * * * * *
 * @dev Unauthorized copies are prohibited.
 */
contract LiquidityManager is ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    /*
     ** Events
     */
    event LiquidityAdded(address indexed token, uint256 amountA, uint256 amountB, uint256 lpTokens);
    event TokensLocked(
        uint256 indexed lockId,
        address indexed token,
        address indexed owner,
        uint256 amount,
        uint256 duration
    );
    event TokensUnlocked(uint256 indexed lockId, address indexed token, address indexed owner, uint256 amount);

    /*
     ** Structs
     */
    struct TokenLock {
        uint256 startTime; // Start time of the lock
        uint256 duration; // Duration of the lock
        uint256 amount; // Amount of tokens currently locked
        uint256 lockID; // Lock ID nonce per token
        address owner; // Owner of the lock, also the withdrawer
        bool claimed; // Whether the lock has been claimed
    }

    struct UserInfo {
        EnumerableSet.AddressSet lockedTokens; // All tokens locked by the user
        mapping(address token => uint256[] lockIDs) locksForToken; // Map token address to lock id for that token
    }

    /*
     ** Errors
     */
    error LiquidityManager__LockAlreadyClaimed();
    error LiquidityManager__NotOwner();
    error LiquidityManager__LockNotUnlockedYet();

    /*
     ** Storage
     */
    mapping(address token => TokenLock[] locks) public tokenLocks; // Map token to associated locks
    mapping(address user => UserInfo userInfo) private users; // User tables

    /*
     ** External Functions
     */
    function addLiquidity(
        address _router, // Router Address
        address _token, // Token Address
        uint256 _amount, // Token Amount
        address _lpReceiver // LP Receiver Address
    ) external payable nonReentrant {
        IUniswapV2Router02 router = IUniswapV2Router02(_router);
        IUniswapV2Factory factory = IUniswapV2Factory(router.factory());
        address weth = router.WETH();
        IERC20 token = IERC20(_token);

        _amount = _amount == type(uint256).max ? token.balanceOf(msg.sender) : _amount;

        SafeERC20.safeTransferFrom(token, msg.sender, address(this), _amount);

        IUniswapV2Pair pair = IUniswapV2Pair(factory.getPair(_token, weth));
        if (address(pair) == address(0)) {
            pair = IUniswapV2Pair(factory.createPair(_token, weth));
        }

        SafeERC20.safeApprove(token, address(router), type(uint256).max);
        (uint256 amountA, uint256 amountB, uint256 lpTokens) = router.addLiquidityETH{ value: msg.value }(
            _token,
            _amount,
            0,
            0,
            address(this),
            block.timestamp + 1
        );

        emit LiquidityAdded(_token, amountA, amountB, lpTokens);

        SafeERC20.safeTransfer(IERC20(address(pair)), _lpReceiver, pair.balanceOf(address(this)));
    }

    function lockToken(address _token, uint256 _amount, uint256 _duration, address _lockOwner) external nonReentrant {
        IERC20 lockedToken = IERC20(_token);
        _amount = _amount == type(uint256).max ? lockedToken.balanceOf(msg.sender) : _amount;

        SafeERC20.safeTransferFrom(lockedToken, msg.sender, address(this), _amount);

        TokenLock memory newLock;
        newLock.startTime = block.timestamp;
        newLock.duration = _duration;
        newLock.amount = _amount;
        newLock.lockID = tokenLocks[_token].length;
        newLock.owner = _lockOwner;
        // newLock.claimed = false; // set by default!

        tokenLocks[_token].push(newLock);

        UserInfo storage user = users[_lockOwner];
        user.lockedTokens.add(_token);
        user.locksForToken[_token].push(newLock.lockID);

        emit TokensLocked(newLock.lockID, _token, _lockOwner, _amount, _duration);
    }

    function unlockToken(address _token, uint256 _lockID) external nonReentrant {
        IERC20 lockedToken = IERC20(_token);
        TokenLock storage userLock = tokenLocks[_token][_lockID];

        if (userLock.claimed) {
            revert LiquidityManager__LockAlreadyClaimed();
        }
        if (userLock.owner != msg.sender) {
            revert LiquidityManager__NotOwner();
        }
        if (userLock.startTime + userLock.duration > block.timestamp) {
            revert LiquidityManager__LockNotUnlockedYet();
        }

        userLock.claimed = true;
        emit TokensUnlocked(_lockID, _token, msg.sender, userLock.amount);

        SafeERC20.safeTransfer(lockedToken, msg.sender, userLock.amount);
    }

    /*
     ** Helpers
     */
    function getLockStatus(
        address _token,
        uint256 _lockId
    ) external view returns (bool canBeUnlocked, bool hasBeenClaimed) {
        TokenLock storage specificLock = tokenLocks[_token][_lockId];

        canBeUnlocked = specificLock.startTime + specificLock.duration <= block.timestamp;
        hasBeenClaimed = specificLock.claimed;
    }

    function getUserLockedTokens(address _user) external view returns (address[] memory lockedTokens) {
        UserInfo storage user = users[_user];
        lockedTokens = new address[](user.lockedTokens.length());

        for (uint256 i = 0; i < user.lockedTokens.length(); i++) {
            lockedTokens[i] = user.lockedTokens.at(i);
        }
    }

    function getUserLocksForToken(address _user, address _token) external view returns (uint256[] memory lockIDs) {
        UserInfo storage user = users[_user];

        lockIDs = user.locksForToken[_token];
    }
}
