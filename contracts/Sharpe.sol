// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
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
    using SafeMath for uint256;
    event Deposit(address indexed sender,address indexed to,uint256 shares,uint256 amount0,uint256 amount1);
    event Withdraw(address indexed sender,address indexed to,uint256 shares,uint256 amount0,uint256 amount1);
    event CollectFees(uint256 feesToVault0,uint256 feesToVault1,uint256 feesToProtocol0,uint256 feesToProtocol1);
    event Snapshot(int24 tick, uint256 totalAmount0, uint256 totalAmount1, uint256 totalSupply);
    IUniswapV3Pool public immutable pool;
    IUniswapV2Router02 public immutable router;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    int24 public immutable tickSpacing;
    uint256 public protocolFee;
    uint256 public maxTotalSupply;
    address public SharpeKeeper;
    address public governance;
    address public pendingGovernance;
    address public immutable token0Address;
    address public immutable token1Address;
    address public immutable routerAddress;
    int24 public baseLower;
    int24 public baseUpper;
    int24 public limitLower;
    int24 public limitUpper;
    uint256 public accruedProtocolFees0;
    uint256 public accruedProtocolFees1;
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
        uint256 _protocolFee,
        uint256 _maxTotalSupply
    ) ERC20("Sharpe", "SHRP") {
        pool = IUniswapV3Pool(_pool);
        router = IUniswapV2Router02(_router);
        token0 = IERC20(IUniswapV3Pool(_pool).token0());
        token1 = IERC20(IUniswapV3Pool(_pool).token1());
        token0Address = IUniswapV3Pool(_pool).token0();
        token1Address = IUniswapV3Pool(_pool).token1();
        routerAddress = _router;
        tickSpacing = IUniswapV3Pool(_pool).tickSpacing();
        protocolFee = _protocolFee;
        maxTotalSupply = _maxTotalSupply;
        governance = msg.sender;
        require(_protocolFee < 1e6, "protocolFee");
    }
    /**
     * @notice Deposits tokens in proportion to the vault's current holdings.
     * @dev These tokens sit in the vault and are not used for liquidity on Uniswap until the next rebalance.
     * Also note it's not necessary to check if user manipulated price to deposit cheaper, as the value of range
     * orders can only by manipulated higher.
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
            // Single Asset Deposit
            // The goal here is for the vault to hold both tokens at the end even if the user provided just one token

            if (amount0 > 0 && amount1 == 0){
                //1. View amounts of total0 the vault would have if it were to swap all of total1 
                //to get the vault's total holdings in the amounts of total0 alone.
                address[] memory path0 = new address[](2);
                path0[0] = token1Address;
                path0[1] = token0Address;
                uint[] memory total1ToTotal0 = router.getAmountsOut(total1, path0);

                //2. Subtract from amount0 in proportion to vault's total holding and send difference for swap.
                uint256 amount0ToStore = amount0.mul(total0).div(total0.add(total1ToTotal0[1]));
                uint256 difference = amount0.sub(amount0ToStore); 
                token0.safeTransferFrom(msg.sender, address(this), amount0); //pulls in single token from recipient
                token0.approve(routerAddress, difference); //approves router to perform the swap
                address[] memory path1 = new address[](2);
                path1[0] = token0Address;
                path1[1] = token1Address;
                uint[] memory amount1ToStore = router.swapExactTokensForTokens(difference,0,path1,address(this), block.timestamp); //swaps the difference
                
                //3. calculate shares according to amount0 stored and amount1 just received
                uint256 cross = Math.min(amount0ToStore.mul(total1), amount1ToStore[1].mul(total0));
                amount0 = cross.sub(1).div(total1).add(1);
                amount1 = cross.sub(1).div(total0).add(1);
                shares = cross.mul(totalSupply).div(total0).div(total1);
                require(amount0 >= amount0Min, "amount0Min");
                require(amount1 >= amount1Min, "amount1Min");
                require(shares > 0, "swappedShares");
                
                // 4. Send back all dust after getting the actual amount0 and amount1 for vault to store proportional to its holdings
                if (amount0ToStore.sub(amount0) > 0) token0.safeTransfer(to, amount0ToStore.sub(amount0));
                if (amount1ToStore[1].sub(amount1) > 0) token1.safeTransfer(to, amount1ToStore[1].sub(amount1));
                
                // 5. Mint shares to recipient
                _mint(to, shares);
                emit Deposit(msg.sender, to, shares, amount0, amount1);
                require(totalSupply.add(shares) <= maxTotalSupply, "maxTotalSupply");
            }
            else {
                //opposite of the first logic
                address[] memory path0 = new address[](2);
                path0[0] = token0Address;
                path0[1] = token1Address;
                uint[] memory total0ToTotal1 = router.getAmountsOut(total0, path0);
                uint256 amount1ToStore = amount1.mul(total1).div(total1.add(total0ToTotal1[1]));
                uint256 difference = amount1.sub(amount1ToStore);
                token1.safeTransferFrom(msg.sender, address(this), amount1);
                token1.approve(routerAddress, difference);
                address[] memory path1 = new address[](2);
                path1[0] = token1Address;
                path1[1] = token0Address;
                uint[] memory amount0ToStore = router.swapExactTokensForTokens(difference,0,path1,address(this), block.timestamp);                uint256 cross = Math.min(amount0ToStore[1].mul(total1), amount1ToStore.mul(total0));
                amount0 = cross.sub(1).div(total1).add(1);
                amount1 = cross.sub(1).div(total0).add(1);
                shares = cross.mul(totalSupply).div(total0).div(total1);
                require(amount0 >= amount0Min, "amount0Min");
                require(amount1 >= amount1Min, "amount1Min");
                require(shares > 0, "swappedShares");
                if (amount0ToStore[1].sub(amount0) > 0) token0.safeTransfer(to, amount0ToStore[1].sub(amount0));
                if (amount1ToStore.sub(amount1) > 0) token1.safeTransfer(to, amount1ToStore.sub(amount1));
                _mint(to, shares);
                emit Deposit(msg.sender, to, shares, amount0, amount1);
                require(totalSupply.add(shares) <= maxTotalSupply, "maxTotalSupply");
            }
        }

        //Pull in amount0 and amount1 from recipient as long as both are provided
        else { 
            require(amount0 >= amount0Min, "amount0Min");
            require(amount1 >= amount1Min, "amount1Min");
            require(shares > 0, "shares");
            // Pull in tokens from sender
            if (amount0 > 0) token0.safeTransferFrom(msg.sender, address(this), amount0);
            if (amount1 > 0) token1.safeTransferFrom(msg.sender, address(this), amount1);
            // Mint shares to recipient
            _mint(to, shares);
            emit Deposit(msg.sender, to, shares, amount0, amount1);
            require(totalSupply() <= maxTotalSupply, "maxTotalSupply");
            }
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
        assert(totalSupply == 0 || total0 > 0 || total1 > 0);
        if (totalSupply == 0) {
            // For first deposit, just use the amounts desired
            amount0 = amount0Desired;
            amount1 = amount1Desired;
            shares = Math.max(amount0, amount1);
        } else if (total0 == 0) {
            amount1 = amount1Desired;
            shares = amount1.mul(totalSupply).div(total1);
        } else if (total1 == 0) {
            amount0 = amount0Desired;
            shares = amount0.mul(totalSupply).div(total0);
        } else {
            //calculate the amount0 and amount1 to take in from recipient so they are in the same ratio to what the vault currently holds
            require(amount0Desired > 0 || amount1Desired > 0, "atleast one token is needed");
            uint256 cross = Math.min(amount0Desired.mul(total1), amount1Desired.mul(total0));
            
            //Tell contract to perform a swap from deposit() with the single token amount given by setting shares to zero
            if (cross == 0){ 
                amount0 = amount0Desired;
                amount1 = amount1Desired;
                shares = 0;
            }
            //When recipient already provides both tokens for deposit the shares are calculated and deposit() skips performing a swap
            else { 
                require(cross > 0, "cross");
                // Round up amounts
                amount0 = cross.sub(1).div(total1).add(1);
                amount1 = cross.sub(1).div(total0).add(1);
                shares = cross.mul(totalSupply).div(total0).div(total1);
            }
        }
    }
    /**
     * @notice Withdraws tokens in proportion to the vault's holdings.
     * @param shares Shares burned by sender
     * @param amount0Min Revert if resulting `amount0` is smaller than this
     * @param amount1Min Revert if resulting `amount1` is smaller than this
     * @param to Recipient of tokens
     * @return amount0 Amount of token0 sent to recipient
     * @return amount1 Amount of token1 sent to recipient
     */
    function withdraw(uint256 shares,uint256 amount0Min,uint256 amount1Min,address to, bool swapToAmount0, bool swapToAmount1
) external override nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(shares > 0, "shares");
        require(to != address(0) && to != address(this), "to");
        uint256 totalSupply = totalSupply();

        // Burn recipient's shares
        _burn(msg.sender, shares);

        //Fetches all of recipient's lp tokens
        (amount0, amount1) = _getTokensFromPosition(shares, totalSupply);
        
        // Push tokens to recipient
        if (swapToAmount0){
            //Swaps token1 so user receives all assets in token0 only
            uint256 receivedAmount0 = _zappTokens(amount1, true);
            amount0 = amount0.add(receivedAmount0);
            require(amount0 >= amount0Min, "amount0Min");
            if (amount0 > 0) token0.safeTransfer(to, amount0);
            emit Withdraw(msg.sender, to, shares, amount0, 0);
        }
        else if (swapToAmount1){
            //Swaps token0 so user receives all assets in token1 only
            uint256 receivedAmount1 = _zappTokens(amount0, false);
            amount1 = amount1.add(receivedAmount1);
            require(amount1 >= amount1Min, "amount1Min");
            if (amount1 > 0) token1.safeTransfer(to, amount1);
            emit Withdraw(msg.sender, to, shares, 0, amount1);
        }
        else{
            //Sends both tokens to the recipient
            require(amount0 >= amount0Min, "amount0Min");
            require(amount1 >= amount1Min, "amount1Min");
            if (amount0 > 0) token0.safeTransfer(to, amount0);
            if (amount1 > 0) token1.safeTransfer(to, amount1);
            emit Withdraw(msg.sender, to, shares, amount0, amount1);
        }
        
    }
    /// @dev Performs a swap if recipient wants a single token output at withdrawal.
    function _zappTokens(uint256 amount, bool output) internal returns(uint256 swappedAmount){
        if (output){
            token1.approve(routerAddress, amount);
            address[] memory path = new address[](2);
            path[0] = token1Address;
            path[1] = token0Address;
            uint[] memory receivedToken = router.swapExactTokensForTokens(amount,0,path,address(this), block.timestamp);
            swappedAmount = receivedToken[1];
        }
        else{
            token0.approve(routerAddress, amount);
            address [] memory path = new address[](2);
            path[0] = token0Address;
            path[1] = token1Address;
            uint[] memory receivedToken = router.swapExactTokensForTokens(amount, 0, path, address(this), block.timestamp);
            swappedAmount = receivedToken[1];
        }
    }
    /// @dev Withdraws recipient's proportion of liquidity and adds all unused amounts.
    function _getTokensFromPosition(uint256 shares, uint256 totalSupply) internal returns(uint256 amount0, uint256 amount1){
        // Calculate token amounts proportional to unused balances
        uint256 unusedAmount0 = getBalance0().mul(shares).div(totalSupply);
        uint256 unusedAmount1 = getBalance1().mul(shares).div(totalSupply);
        // Withdraw proportion of liquidity from Uniswap pool
        (uint256 baseAmount0, uint256 baseAmount1) =
            _burnLiquidityShare(baseLower, baseUpper, shares, totalSupply);
        (uint256 limitAmount0, uint256 limitAmount1) =
            _burnLiquidityShare(limitLower, limitUpper, shares, totalSupply);
        // Sum up total amounts owed to recipient
        amount0 = unusedAmount0.add(baseAmount0).add(limitAmount0);
        amount1 = unusedAmount1.add(baseAmount1).add(limitAmount1);
    }
    /// @dev Withdraws share of liquidity in a range from Uniswap pool.
    function _burnLiquidityShare(int24 tickLower,int24 tickUpper,uint256 shares,uint256 totalSupply
    ) internal returns (uint256 amount0, uint256 amount1) {
        (uint128 totalLiquidity, , , , ) = _position(tickLower, tickUpper);
        uint256 liquidity = uint256(totalLiquidity).mul(shares).div(totalSupply);
        if (liquidity > 0) {
            (uint256 burned0, uint256 burned1, uint256 fees0, uint256 fees1) = _burnAndCollect(tickLower, tickUpper, _toUint128(liquidity));
            // Add share of fees
            amount0 = burned0.add(fees0.mul(shares).div(totalSupply));
            amount1 = burned1.add(fees1.mul(shares).div(totalSupply));
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
        (, int24 tick, , , , , ) = pool.slot0();
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
        feesToVault0 = collect0.sub(burned0);
        feesToVault1 = collect1.sub(burned1);
        uint256 feesToProtocol0;
        uint256 feesToProtocol1;
        // Update accrued protocol fees
        uint256 _protocolFee = protocolFee;
        if (_protocolFee > 0) {
            feesToProtocol0 = feesToVault0.mul(_protocolFee).div(1e6);
            feesToProtocol1 = feesToVault1.mul(_protocolFee).div(1e6);
            feesToVault0 = feesToVault0.sub(feesToProtocol0);
            feesToVault1 = feesToVault1.sub(feesToProtocol1);
            accruedProtocolFees0 = accruedProtocolFees0.add(feesToProtocol0);
            accruedProtocolFees1 = accruedProtocolFees1.add(feesToProtocol1);
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
        (uint256 limitAmount0, uint256 limitAmount1) =
            getPositionAmounts(limitLower, limitUpper);
        total0 = getBalance0().add(baseAmount0).add(limitAmount0);
        total1 = getBalance1().add(baseAmount1).add(limitAmount1);
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
        uint256 oneMinusFee = uint256(1e6).sub(protocolFee);
        amount0 = amount0.add(uint256(tokensOwed0).mul(oneMinusFee).div(1e6));
        amount1 = amount1.add(uint256(tokensOwed1).mul(oneMinusFee).div(1e6));
    }
    /**
     * @notice Balance of token0 in vault not used in any position.
     */
    function getBalance0() public view returns (uint256) {
        return token0.balanceOf(address(this)).sub(accruedProtocolFees0);
    }
    /**
     * @notice Balance of token1 in vault not used in any position.
     */
    function getBalance1() public view returns (uint256) {
        return token1.balanceOf(address(this)).sub(accruedProtocolFees1);
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
        require(msg.sender == address(pool));
        if (amount0 > 0) token0.safeTransfer(msg.sender, amount0);
        if (amount1 > 0) token1.safeTransfer(msg.sender, amount1);
    }
    /// @dev Callback for Uniswap V3 pool.
    function uniswapV3SwapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata data) external override {
        require(msg.sender == address(pool));
        if (amount0Delta > 0) token0.safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) token1.safeTransfer(msg.sender, uint256(amount1Delta));
    }
    /**
     * @notice Used to collect accumulated protocol fees.
     */
    function collectProtocol(uint256 amount0,uint256 amount1,address to) external onlyGovernance {
        accruedProtocolFees0 = accruedProtocolFees0.sub(amount0);
        accruedProtocolFees1 = accruedProtocolFees1.sub(amount1);
        if (amount0 > 0) token0.safeTransfer(to, amount0);
        if (amount1 > 0) token1.safeTransfer(to, amount1);
    }
    /**
     * @notice Removes tokens accidentally sent to this vault.
     */
    function sweep(IERC20 token,uint256 amount,address to) external onlyGovernance {
        require(token != token0 && token != token1, "token");
        token.safeTransfer(to, amount);
    }
    /**
     * @notice set SharpeKeeper Used to set the strategy contract that determines the position ranges and calls rebalance().
     * Must be called after this vault is deployed.
     */
    function setSharpeKeeper(address _SharpeKeeper) external onlyGovernance {SharpeKeeper = _SharpeKeeper;}
    /**
     * @notice Used to change the protocol fee charged on pool fees earned from
     * Uniswap, expressed as multiple of 1e-6.
     */
    function setProtocolFee(uint256 _protocolFee) external onlyGovernance {
        require(_protocolFee < 1e6, "protocolFee");
        protocolFee = _protocolFee;
    }
    /**
     * @notice Used to change deposit cap for a guarded launch or to ensure vault doesn't 
     * grow too large relative to the pool. Cap is on total supply rather than amounts 
     * of token0 and token1 as those amounts fluctuate naturally over time.
     */
    function setMaxTotalSupply(uint256 _maxTotalSupply) external onlyGovernance { maxTotalSupply = _maxTotalSupply;}
    /**
     * @notice Removes liquidity in case of emergency.
     */
    function emergencyBurn(int24 tickLower,int24 tickUpper,uint128 liquidity) external onlyGovernance {
        pool.burn(tickLower, tickUpper, liquidity);
        pool.collect(address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max);
    }
    /**
     * @notice Governance address is not updated until the new governance
     * address has called `acceptGovernance()` to accept this responsibility.
     */
    function setGovernance(address _governance) external onlyGovernance { pendingGovernance = _governance;}
    /**
     * @notice `setGovernance()` should be called by the existing governance address prior to calling this function.
     */
    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "pendingGovernance");
        governance = msg.sender;
    }
    modifier onlyGovernance {
        require(msg.sender == governance, "governance");
        _;
    }
}