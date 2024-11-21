interface TransferVerifier {
    function verifyTransfer(address from, address to, uint256 amount) external returns (bool);
}