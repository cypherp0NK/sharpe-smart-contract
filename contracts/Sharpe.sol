// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.0;
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolImmutables.sol";
import "@uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolState.sol";
import "@uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolDerivedState.sol";
import "@uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolActions.sol";
import "@uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolOwnerActions.sol";
import "@uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolEvents.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IUniswapV2Router02.sol";

contract Sharpe is IVault,IUniswapV3MintCallback,IUniswapV3SwapCallback,ERC20,ReentrancyGuard{

    using SafeERC20 for IERC20;
    event Deposit(address indexed sender,address indexed to,uint256 shares,uint256 amount0,uint256 amount1);
    event Withdraw(address indexed sender,address indexed to,uint256 shares,uint256 amount0,uint256 amount1);
    event CollectFees(uint256 feesToVault0,uint256 feesToVault1,uint256 feesToProtocol0,uint256 feesToProtocol1);
    event Snapshot(int24 tick, uint256 totalAmount0, uint256 totalAmount1, uint256 totalSupply);
    event MintCallBack(uint256 amount0, uint256 amount1, bytes data);
    event SwapCallBack(int256 amount0Delta, int256 amount1Delta, bytes data);
    event DeviationChange(int24 maxTwapDeviation);
    event DurationChange(uint32 twapDuration);
    event ProtocolFeesCollected(address indexed to, uint256 fees0Taken, uint256 fees1Taken, uint256 fees0Left, uint256 fees1Left);
    event Sweep(address indexed to, address foreignToken, uint256 amount);
    event SetSharpeKeeper(address indexed sharpeKeeper);
    event ChangeProtocolFee(uint256 protocolFee);
    event ChangeMaxSupply(uint256 maxTotalSupply);
    event EmergencyBurn(int24 tickLower,int24 tickUpper,uint128 liquidity);
    event PendingGovernance(address indexed governance);
    event GovernanceAccepted(address indexed newGovernance);

    IUniswapV3Pool public immutable pool;
    int24 public immutable tickSpacing;
    int24 public baseLower;
    int24 public baseUpper;
    int24 public limitLower;
    int24 public limitUpper;
    int24 public maxTwapDeviation;
    uint32 public twapDuration;
    uint256 public protocolFee;
    uint256 public maxTotalSupply;    
    uint256 public accruedProtocolFees0;
    uint256 public accruedProtocolFees1;
    address public immutable token0;
    address public immutable token1;
    address public immutable router;
    address public SharpeKeeper;
    address public governance;
    address public pendingGovernance;
    /**
     * This vault is mainly for stablecoin pairs
     * dev After deploying, strategy needs to be set by offchain devs
     * param _pool Underlying Uniswap V3 pool
     * param _router Underlying Uniswap V2 router
     * param _protocolFee Protocol fee expressed as multiple of 1e-6
     * param _maxTotalSupply Cap on total supply
     */
    constructor(
        address _pool,
        address _router,
        int24 _maxTwapDeviation,
        uint32 _twapDuration,
        uint256 _protocolFee,
        uint256 _maxTotalSupply
    ) ERC20("Sharpe", "SHRP") {
        require(_protocolFee < 1e6, "protocolFee");
        require(_maxTwapDeviation > 0, "maxTwapDeviation");
        require(_twapDuration > 0, "twapDuration");
        pool = IUniswapV3Pool(_pool);
        router = _router;
        token0 = IUniswapV3Pool(_pool).token0();
        token1 = IUniswapV3Pool(_pool).token1();
        tickSpacing = IUniswapV3Pool(_pool).tickSpacing();
        maxTwapDeviation = _maxTwapDeviation;
        twapDuration = _twapDuration;
        protocolFee = _protocolFee;
        maxTotalSupply = _maxTotalSupply;
        governance = msg.sender;
    }
    /**
     * @notice Deposits tokens in proportion to the vault's current holdings.
     * @dev These tokens sit in the vault and are not used for liquidity on Uniswap until the next rebalance.
     * Also note it's not necessary to check if user manipulated price to deposit cheaper, as the value of range
     * orders can only be manipulated higher.
     * In a scenario where user has only one of each tokens the vault performs
     * a swap on their behalf at point of deposit.
     * @param amount0Desired Max amount of token0 to deposit
     * @param amount1Desired Max amount of token1 to deposit
     * @param amount0Min Revert if resulting `amount0` is less than this
     * @param amount1Min Revert if resulting `amount1` is less than this
     * @param to Recipient of shares
     * @return shares Number of shares minted
     * @return amount0 Amount of token0 deposited
     * @return amount1 Amount of token1 deposited
     */
    function deposit(uint256 amount0Desired,uint256 amount1Desired,uint256 amount0Min,uint256 amount1Min, address to)
        external override nonReentrant
        returns (uint256 shares,uint256 amount0,uint256 amount1)
    {
        require(amount0Desired > 0 || amount1Desired > 0, "amount0Desired or amount1Desired");
        require(to != address(0) && to != address(this), "to");
        // Poke positions so vault's current holdings are up-to-date
        _poke(baseLower, baseUpper);
        _poke(limitLower, limitUpper);
        // Calculate amounts proportional to vault's holdings
        (shares, amount0, amount1) = _calcSharesAndAmounts(amount0Desired, amount1Desired);
        
        //Perform swap from amount0 to amount1 or from amount1 to amount0 if one of amount0Desired or amount1Desired equals zero
        if (shares == 0){ 
            require((amount0 > 0 && amount1 == 0) || (amount1 > 0 && amount0 == 0), "amount0 or amount1");
            uint256 totalSupply = totalSupply();
            (uint256 total0, uint256 total1) = getTotalAmounts();
            uint256 actualAmount0;
            uint256 actualAmount1;
            // Single Asset Deposit
            // The goal here is for the vault to hold both tokens at the end even if the recipient provided just one token

            if (amount0 > 0 && amount1 == 0){
                //1. View amounts of total0 the vault would have if it were to swap all of total1 
                //to get the vault's total holdings in the amounts of total0 alone.
                uint256 total0InTotal1 = _checkAmounts(total1, token1, token0);
                uint256 total = total0 + total0InTotal1;

                //2. Pull in single token from recipient and perform a swap with a portion of it
                IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
                (shares, amount0, amount1, actualAmount0, actualAmount1,) = _zappAndCalc(amount0, amount0Min, amount1Min, token0, token1, total, total0, total1, totalSupply);
                
                //3. Send any dust back to recipient after the swap and calculation for shares and amounts has happened.
                if (actualAmount0 - amount0 > 0) IERC20(token0).safeTransfer(to, actualAmount0 - amount0);
                if (actualAmount1 - amount1 > 0) IERC20(token1).safeTransfer(to, actualAmount1 - amount1);
                
                // 4. Mint shares to recipient
                _mint(to, shares);
                emit Deposit(msg.sender, to, shares, amount0, amount1);
            }
            else {
                uint256 total1InTotal0 = _checkAmounts(total0, token0, token1);
                uint256 total = total1 + total1InTotal0;
                IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
                (shares, amount1, amount0, actualAmount1, actualAmount0,) = _zappAndCalc(amount1, amount1Min, amount0Min, token1, token0, total, total1, total0, totalSupply);
                if (actualAmount1 - amount1 > 0) IERC20(token1).safeTransfer(to, actualAmount1 - amount1);
                if (actualAmount0 - amount0 > 0) IERC20(token0).safeTransfer(to, actualAmount0 - amount0);
                _mint(to, shares);
                emit Deposit(msg.sender, to, shares, amount0, amount1);
            }
        }

        //Pull in amount0 and amount1 from recipient as long as both tokens are provided
        else { 
            require(amount0 >= amount0Min, "amount0Min");
            require(amount1 >= amount1Min, "amount1Min");
            require(shares > 0, "shares");
            // Pull in tokens from sender
            if (amount0 > 0) IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
            if (amount1 > 0) IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
            // Mint shares to recipient
            _mint(to, shares);
            emit Deposit(msg.sender, to, shares, amount0, amount1);
            require(totalSupply() <= maxTotalSupply, "maxTotalSupply");
            }
    }
    /// @dev Performs a swap.
    function _zappTokens(uint256 amount, address tokenA, address tokenB) internal returns(uint256 swappedAmount){
            IERC20(tokenA).safeApprove(router, amount);
            address[] memory path = new address[](2);
            path[0] = tokenA;
            path[1] = tokenB;
            uint[] memory receivedToken = IUniswapV2Router02(router).swapExactTokensForTokens(amount,0,path,address(this), block.timestamp);
            swappedAmount = receivedToken[1];
    }
    /// @dev Calculates the amounts of tokens to store after a swap such that they're in the same proportion as total amounts.
    function _zappAndCalc( uint256 amount,
                    uint256 amountAMin,
                    uint256 amountBMin,
                    address tokenA,
                    address tokenB,
                    uint256 total,
                    uint256 totalA,
                    uint256 totalB,
                    uint256 totalSupply)
                    internal returns(uint256 swappedShares, uint256 storedAmountA, uint256 storedAmountB, uint256 amountAToStore, uint256 amountBToStore, uint256 difference){
                
                //1. Subtract from amount in proportion to vault's total holding
                (amountAToStore, difference) = _calcAmountsToSwap(amount, totalA, total);
                //2. Keep AmountAToStore and Send difference for swap
                amountBToStore = _zappTokens(difference, tokenA, tokenB);

                //3. calculate shares and amounts
                uint256 cross = Math.min(amountAToStore * totalB, amountBToStore * totalA);
                require(cross > 0, "swappedCross");
                storedAmountA = (cross - 1) / totalB + 1;
                storedAmountB = (cross - 1) / totalA + 1;
                swappedShares = (cross * totalSupply) / totalA / totalB;
                require(storedAmountA >= amountAMin, "amountAMin");
                require(storedAmountB >= amountBMin, "amountBMin");
                require(swappedShares > 0, "swappedShares");
                require(totalSupply + swappedShares <= maxTotalSupply, "maxTotalSupply");
    }
    /// @dev Calculates the the amount of token to store and the amount to send for swap.
    function _calcAmountsToSwap (uint256 amount, uint256 totalA, uint256 total) internal pure returns (uint256 amountAToStore, uint256 difference){
        amountAToStore = (amount * totalA) / total;
        difference = amount - amountAToStore;
    }
    /// @dev Checks amount of totalA in the value of tokenB or the amount of totalB in the value of tokenA.
    function _checkAmounts(uint256 total, address tokenA, address tokenB) internal view returns (uint256 amountsOut){
        address[] memory path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;
        uint[] memory receivedAmounts = IUniswapV2Router02(router).getAmountsOut(total, path);
        amountsOut = receivedAmounts[1];
    }
    /// @dev Do zero-burns to poke a position on Uniswap so earned fees are
    /// updated. Should be called if total amounts needs to include up-to-date fees.
    function _poke(int24 tickLower, int24 tickUpper) internal {
        (uint128 liquidity, , , , ) = _position(tickLower, tickUpper);
        if (liquidity > 0) {
            pool.burn(tickLower, tickUpper, 0);
        }
    }
    /// @dev Calculates the largest possible `amount0` and `amount1` such that
    /// they're in the same proportion as total amounts, but not greater than
    /// `amount0Desired` and `amount1Desired` respectively.
    function _calcSharesAndAmounts(uint256 amount0Desired, uint256 amount1Desired) internal view
        returns (uint256 shares,uint256 amount0,uint256 amount1)
    {
        uint256 totalSupply = totalSupply();
        (uint256 total0, uint256 total1) = getTotalAmounts();

        // If total supply > 0, vault can't be empty
        assert(totalSupply == 0 || total0 > 0 && total1 > 0);
        if (totalSupply == 0) {
            // For first deposit, just use the amounts desired
            require(amount0Desired > 0 && amount1Desired > 0, "amount0Desired and amount1Desired");
            amount0 = amount0Desired;
            amount1 = amount1Desired;
            shares = Math.max(amount0, amount1);
        }
        else {
            //calculate the amount0 and amount1 to take in from recipient so they are in the same ratio to what the vault currently holds
            uint256 cross = Math.min(amount0Desired * total1, amount1Desired * total0);
            
            //If cross is zero it means only one token is being supplied by recipient, will deposit() perform 
            //a swap for the second token and calculate the shares and amounts.
            if (cross == 0){
                amount0 = amount0Desired;
                amount1 = amount1Desired;
                shares = 0;
            }
            //When recipient already provides both tokens for deposit the shares are calculated and deposit() skips performing a swap
            else { 
                // Round up amounts
                amount0 = (cross - 1) / total1 + 1;
                amount1 = (cross - 1) / total0 + 1;
                shares = (cross * totalSupply) / total0 / total1;
            }
        }
    }
    /**
     * @notice Withdraws tokens in proportion to the vault's holdings.
     * @param shares Shares burned by sender
     * @param amount0Min Revert if resulting `amount0` is smaller than this
     * @param amount1Min Revert if resulting `amount1` is smaller than this
     * @param to Recipient of tokens
     * @param kind Checks if recipient wants to receive position amounts in both tokens or single token
     * @return amount0 Amount of token0 sent to recipient
     * @return amount1 Amount of token1 sent to recipient
     */
    function withdraw(uint256 shares,uint256 amount0Min,uint256 amount1Min,address to, SwapKind kind
) external override nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(shares > 0, "shares");
        require(to != address(0) && to != address(this), "to");
        uint256 totalSupply = totalSupply();

        // Burn recipient's shares
        _burn(msg.sender, shares);

        //Fetches all of recipient's lp tokens
        (amount0, amount1) = _getTokensFromPosition(shares, totalSupply);
        
        // Push tokens to recipient
        if (kind == SwapKind.ToAmount0){
            //Swaps token1 so user receives all assets in token0 only
            uint256 receivedAmount0 = _zappTokens(amount1, token1, token0);
            amount0 = amount0 + receivedAmount0;
            require(amount0 >= amount0Min, "amount0Min");
            if (amount0 > 0) IERC20(token0).safeTransfer(to, amount0);
            emit Withdraw(msg.sender, to, shares, amount0, 0);
        }
        else if (kind == SwapKind.ToAmount1){
            //Swaps token0 so user receives all assets in token1 only
            uint256 receivedAmount1 = _zappTokens(amount0, token0, token1);
            amount1 = amount1 + receivedAmount1;
            require(amount1 >= amount1Min, "amount1Min");
            if (amount1 > 0) IERC20(token1).safeTransfer(to, amount1);
            emit Withdraw(msg.sender, to, shares, 0, amount1);
        }
        else{
            //Sends both tokens to the recipient
            require(amount0 >= amount0Min, "amount0Min");
            require(amount1 >= amount1Min, "amount1Min");
            if (amount0 > 0) IERC20(token0).safeTransfer(to, amount0);
            if (amount1 > 0) IERC20(token1).safeTransfer(to, amount1);
            emit Withdraw(msg.sender, to, shares, amount0, amount1);
        }
    }
    
    /// @dev Withdraws recipient's proportion of liquidity and adds all unused amounts.
    function _getTokensFromPosition(uint256 shares, uint256 totalSupply) internal returns(uint256 amount0, uint256 amount1){
        // Calculate token amounts proportional to unused balances
        uint256 unusedAmount0 = (getBalance0() * shares) / totalSupply;
        uint256 unusedAmount1 = (getBalance1() * shares) / totalSupply;
        // Withdraw proportion of liquidity from Uniswap pool
        (uint256 baseAmount0, uint256 baseAmount1) =
            _burnLiquidityShare(baseLower, baseUpper, shares, totalSupply);
        (uint256 limitAmount0, uint256 limitAmount1) =
            _burnLiquidityShare(limitLower, limitUpper, shares, totalSupply);
        // Sum up total amounts owed to recipient
        amount0 = unusedAmount0 + baseAmount0 + limitAmount0;
        amount1 = unusedAmount1 + baseAmount1 + limitAmount1;
    }
    /// @dev Withdraws share of liquidity in a range from Uniswap pool.
    function _burnLiquidityShare(int24 tickLower,int24 tickUpper,uint256 shares,uint256 totalSupply
    ) internal returns (uint256 amount0, uint256 amount1) {
        (uint128 totalLiquidity, , , , ) = _position(tickLower, tickUpper);
        uint256 liquidity = (uint256(totalLiquidity) * shares) / totalSupply;
        if (liquidity > 0) {
            (uint256 burned0, uint256 burned1, uint256 fees0, uint256 fees1) = _burnAndCollect(tickLower, tickUpper, _toUint128(liquidity));
            // Add share of fees
            amount0 = burned0 + ((fees0 * shares) / totalSupply);
            amount1 = burned1 + ((fees1 * shares) / totalSupply);
        }
    }
    /**
     * @notice Updates vault's positions. Can only be called by the strategy/sharpeKeeper.
     * @dev Two orders are placed - a base order and a limit order. The base
     * order is placed first with as much liquidity as possible. This order
     * should use up all of one token, leaving only the other one. This excess
     * amount is then placed as a single-sided bid or ask order.
     */
    function rebalance(int256 swapAmount,uint160 sqrtPriceLimitX96,int24 _baseLower,int24 _baseUpper,
        int24 _bidLower,int24 _bidUpper,int24 _askLower,int24 _askUpper
    ) external nonReentrant{
        require(msg.sender == SharpeKeeper, "SharpeKeeper");
        _checkRange(_baseLower, _baseUpper);
        _checkRange(_bidLower, _bidUpper);
        _checkRange(_askLower, _askUpper);
        int24 tick = _getTick();
        require(_bidUpper <= tick, "bidUpper");
        require(_askLower > tick, "askLower"); // inequality is strict as tick is rounded down
        // Withdraw all current liquidity from Uniswap pool
        {
            (uint128 baseLiquidity, , , , ) = _position(baseLower, baseUpper);
            (uint128 limitLiquidity, , , , ) = _position(limitLower, limitUpper);
            _burnAndCollect(baseLower, baseUpper, baseLiquidity);
            _burnAndCollect(limitLower, limitUpper, limitLiquidity);
        }
        // Emit snapshot to record balances and supply
        uint256 balance0 = getBalance0();
        uint256 balance1 = getBalance1();
        emit Snapshot(tick, balance0, balance1, totalSupply());
        if (swapAmount != 0) {
            pool.swap(
                address(this),swapAmount > 0,swapAmount > 0 ? swapAmount : -swapAmount,sqrtPriceLimitX96,"");
            balance0 = getBalance0();
            balance1 = getBalance1();
        }
        // Place base order on Uniswap
        uint128 liquidity = _liquidityForAmounts(_baseLower, _baseUpper, balance0, balance1);
        _mintLiquidity(_baseLower, _baseUpper, liquidity);
        (baseLower, baseUpper) = (_baseLower, _baseUpper);
        balance0 = getBalance0();
        balance1 = getBalance1();
        // Place bid or ask order on Uniswap depending on which token is left
        uint128 bidLiquidity = _liquidityForAmounts(_bidLower, _bidUpper, balance0, balance1);
        uint128 askLiquidity = _liquidityForAmounts(_askLower, _askUpper, balance0, balance1);
        if (bidLiquidity > askLiquidity) {
            _mintLiquidity(_bidLower, _bidUpper, bidLiquidity);
            (limitLower, limitUpper) = (_bidLower, _bidUpper);
        } else {
            _mintLiquidity(_askLower, _askUpper, askLiquidity);
            (limitLower, limitUpper) = (_askLower, _askUpper);
        }
    }
    /// @dev Fetches tick and ensures tick value is relatively close to the value of
    /// time-weighted average price.
    function _getTick() internal view returns (int24){
        (, int24 tick, , , , , ) = pool.slot0();
        uint32 _twapDuration = twapDuration;
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = _twapDuration;
        secondsAgo[1] = 0;
        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgo);
        int24 twap = int24((tickCumulatives[1] - tickCumulatives[0]) / _twapDuration);
        int24 deviation = tick > twap ? tick - twap : twap - tick;
        assert(deviation <= maxTwapDeviation);
        return tick;
    }

    function _checkRange(int24 tickLower, int24 tickUpper) internal view {
        int24 _tickSpacing = tickSpacing;
        require(tickLower < tickUpper, "tickLower < tickUpper");
        require(tickLower >= TickMath.MIN_TICK, "tickLower too low");
        require(tickUpper <= TickMath.MAX_TICK, "tickUpper too high");
        require(tickLower % _tickSpacing == 0, "tickLower % tickSpacing");
        require(tickUpper % _tickSpacing == 0, "tickUpper % tickSpacing");
    }
    /// @dev Withdraws liquidity from a range and collects all fees in the
    /// process.
    function _burnAndCollect(int24 tickLower,int24 tickUpper,uint128 liquidity)
        internal
        returns (uint256 burned0,uint256 burned1,uint256 feesToVault0,uint256 feesToVault1)
    {
        if (liquidity > 0) {
            (burned0, burned1) = pool.burn(tickLower, tickUpper, liquidity);
        }
        // Collect all owed tokens including earned fees
        (uint256 collect0, uint256 collect1) = pool.collect(address(this),tickLower,tickUpper,type(uint128).max,type(uint128).max);
        feesToVault0 = collect0 - burned0;
        feesToVault1 = collect1 - burned1;
        uint256 feesToProtocol0;
        uint256 feesToProtocol1;
        // Update accrued protocol fees
        uint256 _protocolFee = protocolFee;
        if (_protocolFee > 0) {
            feesToProtocol0 = (feesToVault0 * _protocolFee) / 1e6;
            feesToProtocol1 = (feesToVault1 * _protocolFee) / 1e6;
            feesToVault0 = feesToVault0 - feesToProtocol0;
            feesToVault1 = feesToVault1 - feesToProtocol1;
            accruedProtocolFees0 = accruedProtocolFees0 + feesToProtocol0;
            accruedProtocolFees1 = accruedProtocolFees1 + feesToProtocol1;
        }
        emit CollectFees(feesToVault0, feesToVault1, feesToProtocol0, feesToProtocol1);
    }
    /// @dev Deposits liquidity in a range on the Uniswap pool.
    function _mintLiquidity(int24 tickLower,int24 tickUpper,uint128 liquidity) internal {
        if (liquidity > 0) {
            pool.mint(address(this), tickLower, tickUpper, liquidity, "");
        }
    }
    /**
     * @notice Calculates the vault's total holdings of token0 and token1 - in
     * other words, how much of each token the vault would hold if it withdrew
     * all its liquidity from Uniswap.
     */
    function getTotalAmounts() public view override returns (uint256 total0, uint256 total1) {
        (uint256 baseAmount0, uint256 baseAmount1) = getPositionAmounts(baseLower, baseUpper);
        (uint256 limitAmount0, uint256 limitAmount1) = getPositionAmounts(limitLower, limitUpper);
        total0 = getBalance0() + baseAmount0 + limitAmount0;
        total1 = getBalance1() + baseAmount1 + limitAmount1;
    }
    /**
     * @notice Amounts of token0 and token1 held in vault's position. Includes
     * owed fees but excludes the proportion of fees that will be paid to the
     * protocol. Doesn't include fees accrued since last poke.
     */
    function getPositionAmounts(int24 tickLower, int24 tickUpper) public view returns (uint256 amount0, uint256 amount1) {
        (uint128 liquidity, , , uint128 tokensOwed0, uint128 tokensOwed1) = _position(tickLower, tickUpper);
        (amount0, amount1) = _amountsForLiquidity(tickLower, tickUpper, liquidity);
        // Subtract protocol fees
        uint256 oneMinusFee = uint256(1e6) - protocolFee;
        amount0 = amount0 + ((uint256(tokensOwed0) * oneMinusFee) / 1e6);
        amount1 = amount1 + ((uint256(tokensOwed1) * oneMinusFee) / 1e6);
    }
    /**
     * @notice Balance of token0 in vault not used in any position.
     */
    function getBalance0() public view returns (uint256) {
        return IERC20(token0).balanceOf(address(this)) - accruedProtocolFees0;
    }
    /**
     * @notice Balance of token1 in vault not used in any position.
     */
    function getBalance1() public view returns (uint256) {
        return IERC20(token1).balanceOf(address(this)) - accruedProtocolFees1;
    }
    /// @dev Wrapper around `IUniswapV3Pool.positions()`.
    function _position(int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128,uint256,uint256,uint128,uint128)
    {
        bytes32 positionKey = PositionKey.compute(address(this), tickLower, tickUpper);
        return pool.positions(positionKey);
    }
    /// @dev Wrapper around `LiquidityAmounts.getAmountsForLiquidity()`.
    function _amountsForLiquidity(int24 tickLower,int24 tickUpper,uint128 liquidity
    ) internal view returns (uint256, uint256) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
            LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidity
            );
    }
    /// @dev Wrapper around `LiquidityAmounts.getLiquidityForAmounts()`.
    function _liquidityForAmounts(int24 tickLower,int24 tickUpper,uint256 amount0,uint256 amount1
    ) internal view returns (uint128) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
            LiquidityAmounts.getLiquidityForAmounts(sqrtRatioX96,TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),amount0,amount1);
    }
    /// @dev Casts uint256 to uint128 with overflow check.
    function _toUint128(uint256 x) internal pure returns (uint128) {
        assert(x <= type(uint128).max);
        return uint128(x);
    }
    /// @dev Callback for Uniswap V3 pool.
    function uniswapV3MintCallback(uint256 amount0,uint256 amount1,bytes calldata data) external override {
        require(msg.sender == address(pool), "liquidity pool");
        if (amount0 > 0) IERC20(token0).safeTransfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(token1).safeTransfer(msg.sender, amount1);
        emit MintCallBack(amount0, amount1, data);
    }
    /// @dev Callback for Uniswap V3 pool.
    function uniswapV3SwapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata data) external override {
        require(msg.sender == address(pool), "liquidity pool");
        if (amount0Delta > 0) IERC20(token0).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(token1).safeTransfer(msg.sender, uint256(amount1Delta));
        emit SwapCallBack(amount0Delta, amount1Delta, data);
    }
    /**
     * @notice Change maximum price deviation of twap compared to tick.
     */
    function setMaxTwapDeviation(int24 _maxTwapDeviation) external onlyGovernance {
        require(_maxTwapDeviation > 0, "maxTwapDeviation");
        maxTwapDeviation = _maxTwapDeviation;
        emit DeviationChange(maxTwapDeviation);
    }
    /**
     * @notice Change the duration for Time Weighted Average Price.
     */
    function setTwapDuration(uint32 _twapDuration) external onlyGovernance {
        require(_twapDuration > 0, "twapDuration");
        twapDuration = _twapDuration;
        emit DurationChange(twapDuration);
    }

    /**
     * @notice Used to collect accumulated protocol fees.
     */
    function collectProtocol(uint256 amount0,uint256 amount1,address to) external onlyGovernance {
        accruedProtocolFees0 = accruedProtocolFees0 - amount0;
        accruedProtocolFees1 = accruedProtocolFees1 - amount1;
        if (amount0 > 0) IERC20(token0).safeTransfer(to, amount0);
        if (amount1 > 0) IERC20(token1).safeTransfer(to, amount1);
        emit ProtocolFeesCollected(to, amount0, amount1, accruedProtocolFees0, accruedProtocolFees1);
    }
    /**
     * @notice Removes tokens accidentally sent to this vault.
     */
    function sweep(address token,uint256 amount,address to) external onlyGovernance {
        require(token != token0 && token != token1, "token");
        IERC20(token).safeTransfer(to, amount);
        emit Sweep(to, token, amount);
    }
    /**
     * @notice set SharpeKeeper Used to set the strategy contract that determines the position ranges and calls rebalance().
     * Must be called after this vault is deployed.
     */
    function setSharpeKeeper(address _SharpeKeeper) external onlyGovernance {
        SharpeKeeper = _SharpeKeeper;
        emit SetSharpeKeeper(SharpeKeeper);
    }
    /**
     * @notice Used to change the protocol fee charged on pool fees earned from
     * Uniswap, expressed as multiple of 1e-6.
     */
    function setProtocolFee(uint256 _protocolFee) external onlyGovernance {
        require(_protocolFee < 1e6, "protocolFee");
        protocolFee = _protocolFee;
        emit ChangeProtocolFee(protocolFee);
    }
    /**
     * @notice Used to change deposit cap for a guarded launch or to ensure vault doesn't 
     * grow too large relative to the pool. Cap is on total supply rather than amounts 
     * of token0 and token1 as those amounts fluctuate naturally over time.
     */
    function setMaxTotalSupply(uint256 _maxTotalSupply) external onlyGovernance {
        maxTotalSupply = _maxTotalSupply;
        emit ChangeMaxSupply(maxTotalSupply);
    }
    /**
     * @notice Removes liquidity in case of emergency.
     */
    function emergencyBurn(int24 tickLower,int24 tickUpper,uint128 liquidity) external onlyGovernance {
        pool.burn(tickLower, tickUpper, liquidity);
        pool.collect(address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max);
        emit EmergencyBurn(tickLower, tickUpper, liquidity);
    }
    /**
     * @notice Governance address is not updated until the new governance
     * address has called `acceptGovernance()` to accept this responsibility.
     */
    function setGovernance(address _governance) external onlyGovernance {
        pendingGovernance = _governance;
        emit PendingGovernance(pendingGovernance);
    }
    /**
     * @notice `setGovernance()` should be called by the existing governance address prior to calling this function.
     */
    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "pendingGovernance");
        governance = msg.sender;
        emit GovernanceAccepted(governance);
    }
    modifier onlyGovernance {
        require(msg.sender == governance, "governance");
        _;
    }
}
