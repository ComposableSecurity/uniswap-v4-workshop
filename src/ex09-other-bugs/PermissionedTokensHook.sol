// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ERC6909} from "solmate/src/tokens/ERC6909.sol";

import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TransferVerifier} from "./TransferVerifier.sol";
import {StockToken} from "./StockToken.sol";

contract PermissionedTokensHook is BaseHook, TransferVerifier, ERC6909 {
    using CustomRevert for bytes4;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    error NotAuthorizedToken();
    error NotAdmin();
    address admin;
    bool internal isLocked;
    int256 tokenDelta;
    mapping(address => bool) authorizedTokens;

    constructor(IPoolManager _manager, address _admin) BaseHook(_manager) {
        isLocked = false;
        admin = _admin;
    }

    function addAuthorizedToken(address _authorizedToken) public {
        if (msg.sender != admin) {
            NotAdmin.selector.revertWith();
        }
        authorizedTokens[_authorizedToken] = true;
    }

    function verifyTransfer(address from, address to, uint256 amount) public override returns (bool) {
        if (!authorizedTokens[msg.sender]) {
            NotAuthorizedToken.selector.revertWith();
        }
        if (from != address(poolManager) && to != address(poolManager)) {
            return false;
        }
        if (from == address(poolManager)) {
            accountDelta(-int256(amount));
        }
        if (to == address(poolManager)) {
            accountDelta(int256(amount));
        }
        return true;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyByPoolManager returns (bytes4, int128) {
        processOperation(key, delta);
		return (this.afterSwap.selector, 0);
	}

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyByPoolManager returns (bytes4, BalanceDelta) {
        processOperation(key, delta);
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyByPoolManager returns (bytes4, BalanceDelta) {
        processOperation(key, delta);
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function processOperation(PoolKey calldata key, BalanceDelta delta) internal {
        if (authorizedTokens[Currency.unwrap(key.currency0)]) {
            accountDelta(delta.amount0());
        }
        if (authorizedTokens[Currency.unwrap(key.currency1)]) {
            accountDelta(delta.amount1());
        }
    }

    function accountDelta(int256 amount) public {
        tokenDelta += amount;
        if (tokenDelta == 0 && isLocked) {
            CurrencyLibrary.NATIVE.take(poolManager, address(this), 1, false);
            isLocked = false;
        }
        if (tokenDelta != 0 && !isLocked) {
            CurrencyLibrary.NATIVE.settle(poolManager, address(this), 1, false);
            isLocked = true;
        }
    }

    fallback() external payable {}
}