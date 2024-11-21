pragma solidity ^0.8.0;

import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {TransferVerifier} from "./TransferVerifier.sol";

contract StockToken is ERC20 {
    using CustomRevert for bytes4;
    error TransferNotAllowed();

    TransferVerifier private verifier;
    address private poolManager;

    constructor(
        string memory _name, 
        string memory _symbol, 
        uint8 _decimals,
        address verifier_address,
        address _poolManager
    ) ERC20(_name, _symbol, _decimals) {
        verifier = TransferVerifier(verifier_address);
        poolManager = _poolManager;
    }

    function mint(address to, uint256 value) public virtual {
        _mint(to, value);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (msg.sender == poolManager || to == poolManager) {
            if (!verifier.verifyTransfer(msg.sender, to, amount)) {
                TransferNotAllowed.selector.revertWith();
            }
        }
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (from == poolManager || to == poolManager) {
            if (!verifier.verifyTransfer(from, to, amount)) {
                TransferNotAllowed.selector.revertWith();
            }
        }
        super.transferFrom(from, to, amount);
    }
}