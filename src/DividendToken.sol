// SPDX-License-Identifier: MIT
// Factory: CreateMyToken
pragma solidity 0.8.24;

import "./core/ERC20.sol";
import "./core/Ownable.sol";
import "./core/libraries/Clones.sol";

import "./core/interfaces/uniswap/IUniswapV2Router02.sol";
import "./core/interfaces/uniswap/IUniswapV2Factory.sol";

import "./extensions/DividendTracker.sol";

uint256 constant DENOMINATOR = 100_00;
uint256 constant gasForProcessing = 500_000;

contract DividendToken is ERC20, Ownable {
    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;

    address public immutable trackerImplementation;

    DividendTracker public dividendTracker;
    address public rewardToken;

    uint256 public swapTokensAtAmount;

    mapping(address => bool) public _isBlacklisted;

    uint256 public tokenRewardsFee;
    uint256 public liquidityFee;
    uint256 public marketingFee;

    address private _marketingWalletAddress;
    address private _liquidityWalletAddress;

    // exlcude from fees and max transaction amount
    mapping(address => bool) private _isExcludedFromFees;

    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping(address => bool) public automatedMarketMakerPairs;

    // Emphemerals START
    bool private swapping;
    // Emphemerals END

    event ExcludeFromFees(address indexed account, bool isExcluded);

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    event LiquidityWalletUpdated(address indexed newLiquidityWallet, address indexed oldLiquidityWallet);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiqudity);
    event SendDividends(uint256 tokensSwapped, uint256 amount);
    event ProcessedDividendTracker(
        uint256 iterations,
        uint256 claims,
        uint256 lastProcessedIndex,
        bool indexed automatic,
        uint256 gas,
        address indexed processor
    );

    constructor() {
        _disableInitializers();

        trackerImplementation = address(new DividendTracker());
    }

    function initialize(
        address owner_,
        address _mintTarget,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 initialSupply_,
        address router_,
        address rewardToken_,
        uint256 tokenRewardsFee_,
        address liquidityWallet_,
        address marketingWallet_,
        uint256 liquidityFee_,
        uint256 marketingFee_,
        uint256 minimumTokenBalanceForDividendsPct_,
        address[] calldata _prep
    ) external initializer {
        _transferOwnership(owner_);

        ERC20.init(name_, symbol_, decimals_, initialSupply_);

        tokenRewardsFee = tokenRewardsFee_;
        liquidityFee = liquidityFee_;
        marketingFee = marketingFee_;

        require(tokenRewardsFee + liquidityFee + marketingFee <= 100, "Invalid Fee");

        swapTokensAtAmount = (initialSupply_) / (DENOMINATOR * 100); // 0.0001%

        rewardToken = rewardToken_;
        dividendTracker = DividendTracker(payable(Clones.clone(trackerImplementation)));
        dividendTracker.initialize(rewardToken, (initialSupply_ * minimumTokenBalanceForDividendsPct_) / DENOMINATOR);

        uniswapV2Router = IUniswapV2Router02(router_);
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(address(this), uniswapV2Router.WETH());

        _setAutomatedMarketMakerPair(uniswapV2Pair, true);

        _marketingWalletAddress = marketingWallet_;
        _liquidityWalletAddress = liquidityWallet_;

        // exclude from receiving dividends
        dividendTracker.excludeFromDividends(address(dividendTracker));
        dividendTracker.excludeFromDividends(address(this));
        dividendTracker.excludeFromDividends(owner_);
        dividendTracker.excludeFromDividends(_mintTarget);
        dividendTracker.excludeFromDividends(address(0xdead));
        dividendTracker.excludeFromDividends(address(0));
        dividendTracker.excludeFromDividends(address(uniswapV2Router));
        dividendTracker.excludeFromDividends(address(uniswapV2Pair));

        // exclude from paying fees or having max transaction amount
        _isExcludedFromFees[owner_] = true;
        _isExcludedFromFees[_mintTarget] = true;
        _isExcludedFromFees[_marketingWalletAddress] = true;
        _isExcludedFromFees[_liquidityWalletAddress] = true;
        _isExcludedFromFees[address(this)] = true;

        for (uint256 i = 0; i < _prep.length; ++i) {
            _isExcludedFromFees[_prep[i]] = true;
            dividendTracker.excludeFromDividends(_prep[i]);
        }

        _mint(_mintTarget, initialSupply_);
    }

    receive() external payable {}

    function setSwapTokensAtAmount(uint256 amount) external onlyOwner {
        require(amount != swapTokensAtAmount, "MT: Already set");
        swapTokensAtAmount = amount;
    }

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        _isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees(account, excluded);
    }

    function setMarketingWallet(address payable wallet) external onlyOwner {
        _marketingWalletAddress = wallet;
    }

    function setRewardsFee(uint256 value) external onlyOwner {
        tokenRewardsFee = value;
    }

    function setLiquidityFee(uint256 value) external onlyOwner {
        liquidityFee = value;
    }

    function setMarketingFee(uint256 value) external onlyOwner {
        marketingFee = value;
    }

    function setAutomatedMarketMakerPair(address pair, bool value) public onlyOwner {
        require(
            pair != uniswapV2Pair,
            "BABYTOKEN: The PancakeSwap pair cannot be removed from automatedMarketMakerPairs"
        );

        _setAutomatedMarketMakerPair(pair, value);
    }

    function blacklistAddress(address account, bool value) external onlyOwner {
        _isBlacklisted[account] = value;
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        require(
            automatedMarketMakerPairs[pair] != value,
            "BABYTOKEN: Automated market maker pair is already set to that value"
        );
        automatedMarketMakerPairs[pair] = value;

        if (value) {
            dividendTracker.excludeFromDividends(pair);
        }

        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function updateClaimWait(uint256 claimWait) external onlyOwner {
        dividendTracker.updateClaimWait(claimWait);
    }

    function isExcludedFromFees(address account) public view returns (bool) {
        return _isExcludedFromFees[account];
    }

    function withdrawableDividendOf(address account) public view returns (uint256) {
        return dividendTracker.withdrawableDividendOf(account);
    }

    function excludeFromDividends(address account) external onlyOwner {
        dividendTracker.excludeFromDividends(account);
    }

    function processDividendTracker(uint256 gas) external {
        (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) = dividendTracker.process(gas);

        emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, false, gas, tx.origin);
    }

    function claim() external {
        dividendTracker.processAccount(payable(msg.sender), false);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(!_isBlacklisted[from] && !_isBlacklisted[to], "Blacklisted address");

        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        uint256 contractTokenBalance = balanceOf(address(this));
        bool canSwap = contractTokenBalance >= swapTokensAtAmount;
        uint256 totalFees = tokenRewardsFee + liquidityFee + marketingFee;

        if (canSwap && !swapping && !automatedMarketMakerPairs[from] && from != owner() && to != owner()) {
            swapping = true;

            uint256 marketingTokens = (contractTokenBalance * marketingFee) / totalFees;
            swapAndSendToFee(marketingTokens);

            uint256 swapTokens = (contractTokenBalance * liquidityFee) / totalFees;
            swapAndLiquify(swapTokens);

            uint256 sellTokens = balanceOf(address(this));
            swapAndSendDividends(sellTokens);

            swapping = false;
        }

        bool takeFee = !swapping;

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if (_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }

        if (takeFee) {
            uint256 fees = (amount * totalFees) / 100;
            super._transfer(from, address(this), fees);

            amount = amount - fees;
        }

        super._transfer(from, to, amount);

        try dividendTracker.setBalance(payable(from), balanceOf(from)) {} catch {}
        try dividendTracker.setBalance(payable(to), balanceOf(to)) {} catch {}

        if (!swapping) {
            uint256 gas = gasForProcessing;

            try dividendTracker.process(gas) returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
                emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, true, gas, tx.origin);
            } catch {}
        }
    }

    function swapAndSendToFee(uint256 tokens) private {
        uint256 initialBalance = IERC20(rewardToken).balanceOf(address(this));

        swapTokensForRewardToken(tokens);
        uint256 newBalance = IERC20(rewardToken).balanceOf(address(this)) - initialBalance;
        IERC20(rewardToken).transfer(_marketingWalletAddress, newBalance);
    }

    function swapAndLiquify(uint256 tokens) private {
        // split the contract balance into halves
        uint256 half = tokens / 2;
        uint256 otherHalf = tokens - (half);

        // capture the contract's current ETH balance.
        // this is so that we can capture exactly the amount of ETH that the
        // swap creates, and not make the liquidity event include any ETH that
        // has been manually sent to the contract
        uint256 initialBalance = address(this).balance;

        // swap tokens for ETH
        swapTokensForNative(half); // <- this breaks the ETH -> TOKEN swap when swap+liquify is triggered

        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance - initialBalance;

        // add liquidity to uniswap
        addLiquidity(otherHalf, newBalance);

        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function swapTokensForNative(uint256 tokenAmount) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function swapTokensForRewardToken(uint256 tokenAmount) private {
        address[] memory path;

        if (rewardToken == uniswapV2Router.WETH()) {
            path = new address[](2);

            path[0] = address(this);
            path[1] = rewardToken;
        } else {
            path = new address[](3);

            path[0] = address(this);
            path[1] = uniswapV2Router.WETH();
            path[2] = rewardToken;
        }

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // add the liquidity
        uniswapV2Router.addLiquidityETH{ value: ethAmount }(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            _liquidityWalletAddress,
            block.timestamp + 30
        );
    }

    function swapAndSendDividends(uint256 tokens) private {
        swapTokensForRewardToken(tokens);

        uint256 dividends = IERC20(rewardToken).balanceOf(address(this));
        bool success = IERC20(rewardToken).transfer(address(dividendTracker), dividends);

        if (success) {
            dividendTracker.distributeDividends(dividends);
            emit SendDividends(tokens, dividends);
        }
    }
}

// Create your own token at https://www.createmytoken.com/
