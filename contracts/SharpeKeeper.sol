//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.0;
import "./Sharpe.sol";

interface KeeperCompatibleInterface{
    function checkUpkeep(bytes calldata checkData) external returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external;
}

contract SharpeKeeper is KeeperCompatibleInterface{
    uint256 public immutable interval;
    uint256 public lastTimeStamp;
    //using SafeMath for uint256;
    Sharpe public immutable vault;
    IUniswapV3Pool public immutable pool;
    int24 public immutable tickSpacing;

    int24 public baseThreshold;
    int24 public limitThreshold;
    int24 public lastTick;
    constructor(
        uint updateInterval, address _vault, int24 _baseThreshold, int24 _limitThreshold) {
        interval = updateInterval;
        lastTimeStamp = block.timestamp;
        IUniswapV3Pool _pool = Sharpe(_vault).pool();
        int24 _tickSpacing = _pool.tickSpacing();
        vault = Sharpe(_vault);
        pool = _pool;
        
        tickSpacing = _tickSpacing;
        baseThreshold = _baseThreshold;
        
        limitThreshold = _limitThreshold;
        
        _checkThreshold(_baseThreshold, _tickSpacing);
        _checkThreshold(_limitThreshold, _tickSpacing);

        (, lastTick, , , , , ) = _pool.slot0();
    }

    function checkUpkeep(bytes calldata checkData) external override returns(bool upkeepNeeded, bytes memory performData){
        upkeepNeeded = (block.timestamp - lastTimeStamp) > interval;
        performData = checkData;
    }
    function performUpkeep(bytes calldata performData) external override {
        require((block.timestamp - lastTimeStamp) > interval, "Interval");
        lastTimeStamp = block.timestamp;
        int24 _baseThreshold = baseThreshold;
        int24 _limitThreshold = limitThreshold;

        int24 tick = getTick();
        int24 maxThreshold = _baseThreshold > _limitThreshold ? _baseThreshold : _limitThreshold;
        require(tick > TickMath.MIN_TICK + maxThreshold + tickSpacing, "tick too low");
        require(tick < TickMath.MAX_TICK - maxThreshold - tickSpacing, "tick too high");

        int24 tickFloor = _floor(tick);
        int24 tickCeil = tickFloor + tickSpacing;
        vault.rebalance(
            0,
            0,
            tickFloor - baseThreshold,
            tickCeil + baseThreshold,
            tickFloor - limitThreshold,
            tickFloor,
            tickCeil,
            tickCeil + limitThreshold
        );
        lastTick = tick;
        performData;
    }

    function getTick() public view returns (int24 tick) {
        (, tick, , , , , ) = pool.slot0();
    }
    
    function _floor(int24 tick) internal view returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }
    function _checkThreshold(int24 threshold, int24 _tickSpacing) internal pure {
        require(threshold > 0, "threshold must be > 0");
        require(threshold <= TickMath.MAX_TICK, "threshold too high");
        require(threshold % _tickSpacing == 0, "threshold must be multiple of tickSpacing");
    }
    
    function setBaseThreshold(int24 _baseThreshold) external onlyGovernance {
        _checkThreshold(_baseThreshold, tickSpacing);
        baseThreshold = _baseThreshold;
    }
    function setLimitThreshold(int24 _limitThreshold) external onlyGovernance {
        _checkThreshold(_limitThreshold, tickSpacing);
        limitThreshold = _limitThreshold;
    }

    modifier onlyGovernance {
        require(msg.sender == vault.governance(), "governance");
        _;
    }
}
