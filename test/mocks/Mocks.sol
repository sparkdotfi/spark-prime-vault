// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

contract MockERC20 {

    uint8 public constant decimals = 6;

    mapping (address account => uint256 balance) public balanceOf;
    mapping (address account => bool isBlocked)  public blocked;

    mapping (address account => mapping (address spender => uint256 amount)) public allowance;

    function setBlocked(address account, bool blocked_) external {
        blocked[account] = blocked_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!blocked[to], "MockERC20/blocked");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(!blocked[to], "MockERC20/blocked");
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

}

contract MockSavings {

    uint256 internal constant RAY = 1e27;

    MockERC20 public immutable assetToken;

    uint256 public rate = RAY;

    mapping (address account => uint256 balance) public balanceOf;

    constructor(MockERC20 assetToken_) {
        assetToken = assetToken_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * rate / RAY;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets * RAY / rate;
    }

    function deposit(uint256 assets, address recipient) external returns (uint256 shares) {
        assetToken.transferFrom(msg.sender, address(this), assets);
        shares = convertToShares(assets);
        balanceOf[recipient] += shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets            = convertToAssets(shares);
        balanceOf[owner] -= shares;
        assetToken.transfer(receiver, assets);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares            = _divUp(assets * RAY, rate);
        balanceOf[owner] -= shares;
        assetToken.transfer(receiver, assets);
    }

    function maxRedeem(address owner) external view returns (uint256) {
        uint256 liquid = convertToShares(assetToken.balanceOf(address(this)));
        return liquid < balanceOf[owner] ? liquid : balanceOf[owner];
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        uint256 liquidity = assetToken.balanceOf(address(this));
        uint256 assets    = convertToAssets(balanceOf[owner]);
        return liquidity < assets ? liquidity : assets;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        return true;
    }

    function _divUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return x == 0 ? 0 : (x - 1) / y + 1;
    }

}
