contract UniswapImplementation is BaseImplementation, BaseHook {

    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint;
    using StateLibrary for IPoolManager;

    error UnknownCollection();
    error IncorrectTokenLiquidity(uint128 _delta, uint _liquidityTokenSlippage, uint _liquidityTokens);
    error CannotBeInitializedDirectly();
    error PoolNotInitialized();
    error CallerIsNotLocker();
    error FeeExemptionInvalid(uint24 _invalidFee, uint24 _maxFee);
    error NoBeneficiaryExemption(address _beneficiary);

    /// Emitted after any transaction to share pool state
    event PoolStateUpdated(address indexed _collection, uint160 _sqrtPriceX96, int24 _tick, uint24 _protocolFee, uint24 _swapFee, uint128 _liquidity);

    /// Emitted when a new default fee is set
    event DefaultFeeSet(uint24 _fee);

    /// Emitted when a Pool fee is set
    event PoolFeeSet(address indexed _collection, uint24 _fee);

    /// Emitted when the AMM Fee is updated
    event AMMFeeSet(uint24 _ammFee);

    /// Emitted when the AMM beneficiary address is updated
    event AMMBeneficiarySet(address _ammBeneficiary);

    /// Emitted when AMM fees are captured
    event AMMFeesTaken(address _recipient, address _token, uint _amount);

    /// Emitted when a beneficiary exemption is set or updated
    event BeneficiaryFeeSet(address _beneficiary, uint24 _flatFee);

    /// Emitted when a beneficiary exemption is removed
    event BeneficiaryFeeRemoved(address _beneficiary);

    /**
     * Provides information used by the Uniswap V4 hook unlock callback to define
     * the logic that should be undertaken on receipt of the lock.
     *
     * @member poolKey The PoolKey being interacted with
     * @member liquidityDelta The amount of liquidity
     * @member liquidityTokens The number of tokens being deposited
     * @member liquidityTokenSlippage The ERC20 slippage amount allowed
     */
    struct CallbackData {
        PoolKey poolKey;
        uint128 liquidityDelta;
        uint liquidityTokens;
        uint liquidityTokenSlippage;
    }

    /**
     * Contains data for each of our collection pools.
     *
     * @member _collection Collection address of the pool so that we can normalise event logic
     * @member _poolFee Fee for the pool to distribute to LPs
     * @member _initialized If the pool has been initialized
     * @member _currencyFlipped If our pool currencies were flipped, meaning that the ETH
     * equivalent will be in slot `currency1`, rather than `currency0`.
     */
    struct PoolParams {
        address collection;
        uint24 poolFee;
        bool initialized;
        bool currencyFlipped;
    }

    /// Maps the amount of claimable tokens that are available to be `distributed`
    /// for a `PoolId`.
    mapping (PoolId _poolId => ClaimableFees _fees) internal _poolFees;

    /// Maps a vault to the uniswap pool key
    mapping (address _collection => PoolKey) internal _poolKeys;

    // Maps PoolIds to the parameters
    mapping (PoolId _poolId => PoolParams _params) internal _poolParams;

    /// Stores a mapping of beneficiaries and that flat fee exemptions
    mapping (address _beneficiary => uint48 _flatFee) public feeOverrides;

    /// The tick spacing that our pools will use when created
    int24 public constant POOL_TICK_SPACING = 60;
    uint160 public constant TICK_SQRT_PRICEAX96 = 4306310044;
    uint160 public constant TICK_SQRT_PRICEBX96 = 1457652066949847389969617340386294118487833376468;
    int24 public constant MIN_USABLE_TICK = -887220;
    int24 public constant MAX_USABLE_TICK = 887220;

    /// Sets our default fee that is used if no overwriting `poolFee` is set
    uint24 public defaultFee = 1_0000; // 1%

    /// Sets our default AMM fee that is used if no overwriting `poolFee` is set
    uint24 public ammFee;

    /// Set the beneficiary of our AMM fees
    address public ammBeneficiary;

    /**
     * Sets our immutable {PoolManager} contract reference, used to initialise the BaseHook,
     * and also validates that the contract implementing this adheres to the hook address
     * validation.
     *
     * @dev The {BaseHook} inheritance ensures that our contract conforms to the expected
     * address for the desired Hook logic.
     */
    constructor (address _poolManager, address _locker, address _nativeToken) BaseHook(IPoolManager(_poolManager)) BaseImplementation(_locker, _nativeToken) {}

    /**
     * When registering a collection we only need to generate the `PoolKey` that will be used
     * when it is initialized. This will essentially define the pool that will be used, but liquidity
     * won't be able to be added until `initializeCollection` is called.
     *
     * @dev Logic to ensure that the pool does not already exist should be enforced in the preceeding
     * {Locker} function that calls this.
     *
     * @param _collection The address of the collection being registered
     * @param _collectionToken The underlying ERC20 token of the collection
     */
    function registerCollection(address _collection, ICollectionToken _collectionToken) public override {
        // Ensure that only our {Locker} can call register
        if (msg.sender != address(locker)) revert CallerIsNotLocker();

        // Check if our pool currency is flipped
        bool currencyFlipped = nativeToken > address(_collectionToken);

        // Create our Uniswap pool and store the pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(!currencyFlipped ? nativeToken : address(_collectionToken)),
            currency1: Currency.wrap(currencyFlipped ? nativeToken : address(_collectionToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(address(this))
        });

        // Store our {PoolKey} mapping against the collection
        _poolKeys[_collection] = poolKey;

        // Store our pool parameters
        _poolParams[poolKey.toId()] = PoolParams({
            collection: _collection,
            poolFee: 0,
            initialized: false,
            currencyFlipped: currencyFlipped
        });
    }

    /**
     * Once a collection has been registered via `registerCollection`, we can subsequently initialize it
     * by providing liquidity.
     *
     * @dev Logic to ensure that valid tokens have been supplied should be enforced in the preceeding
     * {Locker} function that calls this.
     *
     * @dev This first liquidity position created will be full range to ensure that there is sufficient
     * liquidity provided.
     *
     * @param _collection The address of the collection being registered
     * @param _amount0 The amount of ETH equivalent tokens being passed in
     * @param _amount1 The number of underlying tokens being supplied
     * @param _amount1Slippage The amount of slippage allowed in underlying token
     * @param _sqrtPriceX96 The initial pool price
     */
    function initializeCollection(address _collection, uint _amount0, uint _amount1, uint _amount1Slippage, uint160 _sqrtPriceX96) public override {
        // Ensure that only our {Locker} can call initialize
        if (msg.sender != address(locker)) revert CallerIsNotLocker();

        // Ensure that the PoolKey is not empty
        PoolKey memory poolKey = _poolKeys[_collection];
        if (poolKey.tickSpacing == 0) revert UnknownCollection();

        // Initialise our pool
        poolManager.initialize(poolKey, _sqrtPriceX96, '');

        // After our contract is initialized, we mark our pool as initialized and emit
        // our first state update to notify the UX of current prices, etc.
        PoolId id = poolKey.toId();
        _emitPoolStateUpdate(id);

        // Load our pool parameters and update the initialized flag
        PoolParams storage poolParams = _poolParams[id];
        poolParams.initialized = true;

        // Obtain the UV4 lock for the pool to pull in liquidity
        poolManager.unlock(
            abi.encode(CallbackData({
                poolKey: poolKey,
                liquidityDelta: LiquidityAmounts.getLiquidityForAmounts({
                    sqrtPriceX96: _sqrtPriceX96,
                    sqrtPriceAX96: TICK_SQRT_PRICEAX96,
                    sqrtPriceBX96: TICK_SQRT_PRICEBX96,
                    amount0: poolParams.currencyFlipped ? _amount1 : _amount0,
                    amount1: poolParams.currencyFlipped ? _amount0 : _amount1
                }),
                liquidityTokens: _amount1,
                liquidityTokenSlippage: _amount1Slippage
            })
        ));
    }

    /**
     * Provides the encoded `PoolKey` for the collection.
     *
     * @param _collection The address of the collection
     *
     * @return Encoded `PoolKey` struct
     */
    function getCollectionPoolKey(address _collection) public view override returns (bytes memory) {
        return abi.encode(_poolKeys[_collection]);
    }

    /**
     * Provides the {ClaimableFees} for a pool.
     *
     * @param _collection The address of the collection
     *
     * @return The {ClaimableFees} for the collection
     */
    function poolFees(address _collection) public view override returns (ClaimableFees memory) {
        return _poolFees[_poolKeys[_collection].toId()];
    }

    /**
     * When fees are collected against a collection it is sent as ETH equivalent.
     * This then handles the distribution of the allocation between the `_poolId`
     * specified and, if set, a percentage for the `beneficiary`.
     *
     * Our `amount0` must always refer to the amount of the native token provided. The
     * `amount1` will always be the underlying {CollectionToken}. The internal logic of
     * this function will rearrange them to match the `PoolKey` if needed.
     *
     * @param _collection The collection receiving the deposit
     * @param _amount0 The amount of eth equivalent to deposit
     * @param _amount1 The amount of underlying token to deposit
     */
    function depositFees(address _collection, uint _amount0, uint _amount1) public override {
        PoolKey memory _poolKey = _poolKeys[_collection];
        PoolId _poolId = _poolKey.toId();

        // Check if we have a token flip
        bool currencyFlipped = _poolParams[_poolId].currencyFlipped;

        // Deposit the fees into our internal orderbook
        if (_amount0 != 0) {
            _pullTokens(currencyFlipped ? _poolKey.currency1 : _poolKey.currency0, _amount0);
            _poolFees[_poolId].amount0 += _amount0;
        }

        // If we have sent `amount1`, then pull this in from the sender
        if (_amount1 != 0) {
            _pullTokens(currencyFlipped ? _poolKey.currency0 : _poolKey.currency1, _amount1);
            _poolFees[_poolId].amount1 += _amount1;
        }

        emit PoolFeesReceived(_collection, _amount0, _amount1);
    }

    /**
     * Takes a collection address and, if there is sufficient fees available to
     * claim, will call the `donate` function against the mapped Uniswap V4 pool.
     *
     * @dev This call could be checked in a Uniswap V4 interactions hook to
     * dynamically process fees when they hit a threshold.
     *
     * @param _poolKey The PoolKey reference that will have fees distributed
     */
    function _distributeFees(PoolKey memory _poolKey) internal {
        // If the pool is not initialized, we prevent this from raising an exception and bricking hooks
        PoolId poolId = _poolKey.toId();
        PoolParams memory poolParams = _poolParams[poolId];

        if (!poolParams.initialized) {
            return;
        }

        // Get the amount of the native token available to donate
        uint donateAmount = _poolFees[poolId].amount0;

        // Ensure that the collection has sufficient fees available
        if (donateAmount < donateThresholdMin) {
            return;
        }

        // Reduce our available fees
        _poolFees[poolId].amount0 = 0;

        // Split the donation amount between beneficiary and LP
        (uint poolFee, uint beneficiaryFee) = feeSplit(donateAmount);

        // Make our donation to the pool, with the beneficiary amount remaining in the
        // contract ready to be claimed.
        if (poolFee > 0) {
            // Determine whether the currency is flipped to determine which is the donation side
            (uint amount0, uint amount1) = poolParams.currencyFlipped ? (uint(0), poolFee) : (poolFee, uint(0));
            BalanceDelta delta = poolManager.donate(_poolKey, amount0, amount1, '');

            // Check the native delta amounts that we need to transfer from the contract
            if (delta.amount0() < 0) {
                _pushTokens(_poolKey.currency0, uint128(-delta.amount0()));
            }

            if (delta.amount1() < 0) {
                _pushTokens(_poolKey.currency1, uint128(-delta.amount1()));
            }

            emit PoolFeesDistributed(poolParams.collection, poolFee, 0);
        }

        // Check if we have beneficiary fees to distribute
        if (beneficiaryFee != 0) {
            // If our beneficiary is a Flayer pool, then we make a direct call
            if (beneficiaryIsPool) {
                // As we don't want to make a transfer call, we just extrapolate
                // the required logic from the `depositFees` function.
                _poolFees[_poolKeys[beneficiary].toId()].amount0 += beneficiaryFee;
                emit PoolFeesReceived(beneficiary, beneficiaryFee, 0);
            }
            // Otherwise, we can just update the escrow allocation
            else {
                beneficiaryFees[beneficiary] += beneficiaryFee;
                emit BeneficiaryFeesReceived(beneficiary, beneficiaryFee);
            }
        }
    }

    /**
     * Processes the actual logic during `initializeCollection` to create a liquidity
     * position. The logic processed will depend on the parameters passed in `CallbackData`
     * struct.
     *
     * @param _data The `CallbackData` passed to the unlock call
     *
     * @return The `BalanceDelta` changes against the pool
     */
    function _unlockCallback(bytes calldata _data) internal override returns (bytes memory) {
        // Unpack our passed data
        CallbackData memory params = abi.decode(_data, (CallbackData));

        // As this call should only come in when we are initializing our pool, we
        // don't need to worry about `take` calls, but only `settle` calls.
        (BalanceDelta delta,) = poolManager.modifyLiquidity({
            key: params.poolKey,
            params: IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_USABLE_TICK,
                tickUpper: MAX_USABLE_TICK,
                liquidityDelta: int(uint(params.liquidityDelta)),
                salt: ''
            }),
            hookData: ''
        });

        // Check the native delta amounts that we need to transfer from the contract
        if (delta.amount0() < 0) {
            _pushTokens(params.poolKey.currency0, uint128(-delta.amount0()));
        }

        // Check our ERC20 donation
        if (delta.amount1() < 0) {
            _pushTokens(params.poolKey.currency1, uint128(-delta.amount1()));
        }

        // If we have an expected amount of tokens being provided as liquidity, then we
        // need to ensure that this exact amount is sent. There may be some dust that is
        // lost during rounding and for this reason we need to set a small slippage
        // tolerance on the checked amount.
        if (params.liquidityTokens != 0) {
            uint128 deltaAbs = _poolParams[params.poolKey.toId()].currencyFlipped ? uint128(-delta.amount0()) : uint128(-delta.amount1());
            if (params.liquidityTokenSlippage < params.liquidityTokens - deltaAbs) {
                revert IncorrectTokenLiquidity(
                    deltaAbs,
                    params.liquidityTokenSlippage,
                    params.liquidityTokens
                );
            }
        }

        // We return our `BalanceDelta` response from the donate call
        return abi.encode(delta);
    }

    /**
     * This function defines the hooks that are required, and also importantly those which are
     * not, by our contract. This output determines the contract address that the deployment
     * must conform to and is validated in the constructor of this contract.
     *
     * @dev 1011 1111 0011 00 -> 0x..2FCC
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * We have some requirements for our initialization call, so if an external party tries
     * to call initialize, we want to prevent this from hitting.
     */
    function beforeInitialize(address /* sender */, PoolKey memory /* key */, uint160 /* sqrtPriceX96 */, bytes calldata /* hookData */) public view override onlyByPoolManager returns (bytes4) {
        revert CannotBeInitializedDirectly();
    }

    /**
     * Before a liquidity position is modified, we distribute fees before they can come in to
     * take a share of fees that they have not earned.
     */
    function beforeAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata hookData) public override onlyByPoolManager returns (bytes4) {
        if (!_poolParams[key.toId()].initialized) revert PoolNotInitialized();

        // Distribute fees to our LPs before someone can come in to take an unearned share
        _distributeFees(key);

        return IHooks.beforeAddLiquidity.selector;
    }

    /**
     * Before a swap is made, we pull in the dynamic pool fee that we have set to ensure it is
     * applied to the tx.
     *
     * We also see if we have any token1 fee tokens that we can use to fill the swap before it
     * hits the Uniswap pool. This prevents the pool from being affected and reduced gas costs.
     * This also allows us to benefit from the Uniswap routing infrastructure.
     *
     * This frontruns UniSwap to sell undesired token amounts from our fees into desired tokens
     * ahead of our fee distribution. This acts as a partial orderbook to remove impact against
     * our pool.
     *
     * @param sender The initial msg.sender for the swap call
     * @param key The key for the pool
     * @param params The parameters for the swap
     * @param hookData Arbitrary data handed into the PoolManager by the swapper to be be passed on to the hook
     *
     * @return selector_ The function selector for the hook
     * @return beforeSwapDelta_ The hook's delta in specified and unspecified currencies. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
     * @return swapFee_ The percentage fee applied to our swap
     */
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams memory params, bytes calldata hookData) public override onlyByPoolManager returns (bytes4 selector_, BeforeSwapDelta beforeSwapDelta_, uint24 swapFee_) {
        PoolId poolId = key.toId();

        // Ensure our dynamic fees are set to the correct amount and mark it with the override flag
        swapFee_ = getFee(poolId, sender) | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        // Load our PoolFees as storage as we will manipulate them later if we trigger
        ClaimableFees storage pendingPoolFees = _poolFees[poolId];
        PoolParams memory poolParams = _poolParams[poolId];

        // We want to check if our token0 is the eth equivalent, or if it has swapped to token1
        bool trigger = poolParams.currencyFlipped ? !params.zeroForOne : params.zeroForOne;
        if (trigger && pendingPoolFees.amount1 != 0) {
            // Set up our internal logic variables
            uint ethIn;
            uint tokenOut;

            // Get the current price for our pool
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

            // Since we have a positive amountSpecified, we can determine the maximum
            // amount that we can transact from our pool fees. We do this by taking the
            // max value of either the pool fees or the amount specified to swap for.
            if (params.amountSpecified >= 0) {
                uint amountSpecified = (uint(params.amountSpecified) > pendingPoolFees.amount1) ? pendingPoolFees.amount1 : uint(params.amountSpecified);

                // Capture the amount of desired token required at the current pool state to
                // purchase the amount of token speicified, capped by the pool fees available. We
                // don't apply a fee for this as it benefits the ecosystem and essentially performs
                // a free swap benefitting both parties.
                (, ethIn, tokenOut, ) = SwapMath.computeSwapStep({//@audit swap using the current price but outside of the pool
                    sqrtPriceCurrentX96: sqrtPriceX96,
                    sqrtPriceTargetX96: params.sqrtPriceLimitX96,
                    liquidity: poolManager.getLiquidity(poolId),
                    amountRemaining: int(amountSpecified),
                    feePips: 0
                });

                // Update our hook delta to reduce the upcoming swap amount to show that we have
                // already spent some of the ETH and received some of the underlying ERC20.
                beforeSwapDelta_ = toBeforeSwapDelta(-tokenOut.toInt128(), ethIn.toInt128());
            }
            // As we have a negative amountSpecified, this means that we are spending any amount
            // of token to get a specific amount of undesired token.
            else {
                (, ethIn, tokenOut, ) = SwapMath.computeSwapStep({//@audit swap using the current price but outside of the pool
                    sqrtPriceCurrentX96: sqrtPriceX96,
                    sqrtPriceTargetX96: params.sqrtPriceLimitX96,
                    liquidity: poolManager.getLiquidity(poolId),
                    amountRemaining: int(pendingPoolFees.amount1),
                    feePips: 0
                });

                // If we cannot fulfill the full amount of the internal orderbook, then we want
                // to avoid using any of it, as implementing proper support for exact input swaps
                // is significantly difficult when we want to restrict them by the output token
                // we have available.
                if (tokenOut <= uint(-params.amountSpecified)) {
                    // Update our hook delta to reduce the upcoming swap amount to show that we have
                    // already spent some of the ETH and received some of the underlying ERC20.
                    // Specified = exact input (ETH)
                    // Unspecified = token1
                    beforeSwapDelta_ = toBeforeSwapDelta(ethIn.toInt128(), -tokenOut.toInt128());
                } else {
                    ethIn = tokenOut = 0;
                }
            }

            // Reduce the amount of fees that have been extracted from the pool and converted
            // into ETH fees.
            if (ethIn != 0 || tokenOut != 0) {
                pendingPoolFees.amount0 += ethIn;
                pendingPoolFees.amount1 -= tokenOut;

                // Transfer the tokens to our PoolManager, which will later swap them to our user
                if (poolParams.currencyFlipped) {
                    poolManager.take(key.currency1, address(this), ethIn);
                    _pushTokens(key.currency0, tokenOut);
                } else {
                    poolManager.take(key.currency0, address(this), ethIn);
                    _pushTokens(key.currency1, tokenOut);
                }

                // Capture the swap cost that we captured from our drip
                emit PoolFeesSwapped(poolParams.collection, params.zeroForOne, ethIn, tokenOut);
            }
        }

        // Set our return selector
        selector_ = IHooks.beforeSwap.selector;
    }

    /**
     * Once a swap has been made, we distribute fees to our LPs and emit our price update event.
     *
     * @param sender The initial msg.sender for the swap call
     * @param key The key for the pool
     * @param params The parameters for the swap
     * @param delta The amount owed to the caller (positive) or owed to the pool (negative)
     * @param hookData Arbitrary data handed into the PoolManager by the swapper to be be passed on to the hook
     *
     * @return selector_ The function selector for the hook
     * @return hookDeltaSpecified_ The hook's delta in unspecified currency. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
     */
    function afterSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata hookData) public override onlyByPoolManager returns (bytes4 selector_, int128 hookDeltaSpecified_) {
        // If we have an AMM fee to charge, then we can process this here
        if (ammFee != 0 && ammBeneficiary != address(0)) {
            // Fee will be in the unspecified token of the swap
            bool specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);

            // Get our fee currency and swap amount
            (Currency feeCurrency, int128 swapAmount) = specifiedTokenIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());

            // If fee is on output, get the absolute output amount
            if (swapAmount < 0) swapAmount = -swapAmount;

            // Calculate our fee amount
            uint feeAmount = uint128(swapAmount) * ammFee / 100_000;

            // Capture our feeCurrency amount
            feeCurrency.take(poolManager, address(this), feeAmount, false);

            // Register ETH and burn tokens
            if (Currency.unwrap(feeCurrency) == nativeToken) {
                beneficiaryFees[ammBeneficiary] += feeAmount;
                emit AMMFeesTaken(ammBeneficiary, nativeToken, feeAmount);
            } else {
                ICollectionToken(Currency.unwrap(feeCurrency)).burn(feeAmount);
                emit AMMFeesTaken(address(0), Currency.unwrap(feeCurrency), feeAmount);
            }

            // Register our specified delta to confirm the fee
            hookDeltaSpecified_ = feeAmount.toInt128();
        }

        // Distribute fees to our LPs
        _distributeFees(key);

        // Emit our pool state update to listeners
        _emitPoolStateUpdate(key.toId());

        // Set our return selector
        selector_ = IHooks.afterSwap.selector;
    }

    /**
     * Once a liquidity has been added, we emit our price update event.
     *
     * @param sender The initial msg.sender for the add liquidity call
     * @param key The key for the pool
     * @param params The parameters for adding liquidity
     * @param delta The amount owed to the caller (positive) or owed to the pool (negative)
     * @param hookData Arbitrary data handed into the PoolManager by the liquidty provider to be be passed on to the hook
     *
     * @return selector_ The function selector for the hook
     * @return hookDelta_ The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
     */
    function afterAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, bytes calldata hookData) public override onlyByPoolManager returns (bytes4 selector_, BalanceDelta hookDelta_) {
        _emitPoolStateUpdate(key.toId());

        // Set our return selector
        selector_ = IHooks.afterAddLiquidity.selector;
    }

    /**
     * Before liquidity has been removed, we distribute fees.
     *
     * @param sender The initial msg.sender for the remove liquidity call
     * @param key The key for the pool
     * @param params The parameters for removing liquidity
     * @param hookData Arbitrary data handed into the PoolManager by the liquidty provider to be be passed on to the hook
     *
     * @return selector_ The function selector for the hook
     */
    function beforeRemoveLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata hookData) public override onlyByPoolManager returns (bytes4 selector_) {
        // Distribute fees to our LPs
        _distributeFees(key);

        // Set our return selector
        selector_ = IHooks.beforeRemoveLiquidity.selector;
    }

    /**
     * Once a liquidity has been removed, we emit our price update event.
     *
     * @param sender The initial msg.sender for the remove liquidity call
     * @param key The key for the pool
     * @param params The parameters for removing liquidity
     * @param hookData Arbitrary data handed into the PoolManager by the liquidty provider to be be passed on to the hook
     *
     * @return selector_ The function selector for the hook
     * @return hookDelta_ The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
     */
    function afterRemoveLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta balanceDelta, bytes calldata hookData) public override onlyByPoolManager returns (bytes4 selector_, BalanceDelta hookDelta_) {
        _emitPoolStateUpdate(key.toId());

        // Set our return selector
        selector_ = IHooks.afterRemoveLiquidity.selector;
    }

    /**
     * Called by the {LockerHooks} to get the Pool fee value on the `beforeSwap` hook.
     *
     * @param _poolId The PoolId to find the fee for
     * @param _sender The sender making the call
     *
     * @return fee_ The fee for the pool
     */
    function getFee(PoolId _poolId, address _sender) public view returns (uint24 fee_) {
        // Our default fee is our first port of call
        fee_ = defaultFee;

        // If we have a specific pool fee then we can overwrite that
        uint24 poolFee = _poolParams[_poolId].poolFee;
        if (poolFee != 0) {
            fee_ = poolFee;
        }

        // If we have a swap fee override, then we want to use that value. We first check
        // our flag to show that we have a valid override.
        uint48 swapFeeOverride = feeOverrides[_sender];
        if (uint24(swapFeeOverride & 0xFFFFFF) == 1) {
            // We can then extract the original uint24 fee override and apply this, only if
            // it is less that then traditionally calculated base swap fee.
            uint24 baseSwapFeeOverride = uint24(swapFeeOverride >> 24);
            if (baseSwapFeeOverride < fee_) {
                fee_ = baseSwapFeeOverride;
            }
        }
    }

    /**
     * Set our beneficiary's flat fee rate across all pools. If a beneficiary is set, then
     * the fee processed during a swap will be overwritten if this fee exemption value is
     * lower than the otherwise determined fee.
     *
     * @param _beneficiary The swap `sender` that will receive the exemption
     * @param _flatFee The flat fee value that the `_beneficiary` will receive
     */
    function setFeeExemption(address _beneficiary, uint24 _flatFee) public onlyOwner {
        // Ensure that our custom fee conforms to Uniswap V4 requirements
        if (!_flatFee.isValid()) {
            revert FeeExemptionInvalid(_flatFee, LPFeeLibrary.MAX_LP_FEE);
        }

        // We need to be able to detect if the zero value is a flat fee being applied to
        // the user, or it just hasn't been set. By packing the `1` in the latter `uint24`
        // we essentially get a boolean flag to show this.
        feeOverrides[_beneficiary] = uint48(_flatFee) << 24 | 0xFFFFFF;
        emit BeneficiaryFeeSet(_beneficiary, _flatFee);
    }

    /**
     * Removes a beneficiary fee exemption.
     *
     * @dev If the `beneficiary` does not already have an exemption, this call will revert.
     *
     * @param _beneficiary The address to remove the fee exemption from
     */
    function removeFeeExemption(address _beneficiary) public onlyOwner {
        // Check that a beneficiary is currently enabled
        uint24 hasExemption = uint24(feeOverrides[_beneficiary] & 0xFFFFFF);
        if (hasExemption != 1) {
            revert NoBeneficiaryExemption(_beneficiary);
        }

        delete feeOverrides[_beneficiary];
        emit BeneficiaryFeeRemoved(_beneficiary);
    }

    /**
     * Updates the value of the default fee that will be applied if no pool overwrite
     * is set.
     *
     * @param _defaultFee The new fee for all pools
     */
    function setDefaultFee(uint24 _defaultFee) public onlyOwner {
        // Validate the default fee amount
        _defaultFee.validate();

        // Set our default fee value
        defaultFee = _defaultFee;

        // Emit our event
        emit DefaultFeeSet(_defaultFee);
    }

    /**
     * Sets an overwritting pool fee.
     *
     * @param _poolId The PoolId to set the fee for
     * @param _fee The new fee value for the pool
     */
    function setFee(PoolId _poolId, uint24 _fee) public onlyOwner {
        // Validate the fee amount
        _fee.validate();

        // Set our pool fee overwrite value
        PoolParams memory poolParams = _poolParams[_poolId];
        poolParams.poolFee = _fee;

        // Emit our event
        emit PoolFeeSet(poolParams.collection, _fee);
    }

    /**
     * Sets an overwritting AMM fee.
     *
     * @dev Consideration should be taken when setting amounts as this will need to
     * be a valid value when added to the poolFee also.
     *
     * @param _ammFee The new fee value for the pool
     */
    function setAmmFee(uint24 _ammFee) public onlyOwner {
        // Ensure that the AMM fee is a valid amount
        _ammFee.validate();

        // Set our pool fee overwrite value
        ammFee = _ammFee;
        emit AMMFeeSet(_ammFee);
    }

    /**
     * Sets a recipient for the `ammFee`.
     *
     * @dev This can be set to a zero-address to prevent an AMM Fee being taken
     *
     * @param _ammBeneficiary New address of AMM beneficiary
     */
    function setAmmBeneficiary(address _ammBeneficiary) public onlyOwner {
        ammBeneficiary = _ammBeneficiary;
        emit AMMBeneficiarySet(_ammBeneficiary);
    }

    /**
     * Pulls in tokens from the message sender into this contract.
     *
     * @param _currency Currency to pull in
     * @param _amount Amount of tokens to pull
     */
    function _pullTokens(Currency _currency, uint _amount) internal {
        SafeTransferLib.safeTransferFrom(Currency.unwrap(_currency), msg.sender, address(this), _amount);
    }

    /**
     * Pushes tokens from the contract to the {PoolManager}.
     *
     * @param _currency Currency to send
     * @param _amount Amount of tokens to send
     */
    function _pushTokens(Currency _currency, uint _amount) internal {
        _currency.settle(poolManager, address(this), _amount, false);
    }

    /**
     * Emits an event that provides pool state updates.
     *
     * @param _poolId The PoolId that has been updated
     */
    function _emitPoolStateUpdate(PoolId _poolId) internal {
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 swapFee) = poolManager.getSlot0(_poolId);
        emit PoolStateUpdated(_poolParams[_poolId].collection, sqrtPriceX96, tick, protocolFee, swapFee, poolManager.getLiquidity(_poolId));
    }

}