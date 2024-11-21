interface MarketDataProvider {
    function getEthUsdVol() external returns(uint256);
    function getEthUsdPrice() external returns(uint256);
}

contract VolBasedDynamicFeeHook {
    uint256 constant MIN_FEE = 35e23;

    MarketDataProvider immutable marketDataProvider;//@audit external data provider

    constructor(IPoolManager _poolManager, MarketDataProvider _marketDataProvider) BaseHook(_poolManager) {
        marketDataProvider = _marketDataProvider;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function getVolatility() public view returns (uint256) {
        return marketDataProvider.getEthUsdVol();
    }

    function getPrice() public view returns (uint256) {
        return marketDataProvider.getEthUsdPrice();
    }

    function calculateFee(uint256 volume, uint256 volatility, uint256 price) internal pure returns (uint24) {//@audit fee calculation
        uint256 scaled_volume = volume / 150;
        uint256 longterm_eth_volatility = 60;
        uint256 scaled_vol = volatility / longterm_eth_volatility;
        uint256 constant_factor = 2;

        uint256 fee_per_lot = MIN_FEE + (constant_factor * scaled_volume * scaled_vol ** 2);

        return uint24((fee_per_lot / price / 1e10));
    }

    function abs(int256 x) private pure returns (uint256) {
        if (x >= 0) {
            return uint256(x);
        }
        return uint256(-x);
    }

  
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 volatility = getVolatility();
        uint256 price = getPrice();
        uint24 fee = calculateFee(abs(swapData.amountSpecified), volatility, price);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    function getFee(int256 amt) external view returns (uint24) {
        uint256 volatility = getVolatility();
        uint256 price = getPrice();
        return calculateFee(abs(amt), volatility, price);
    }
}