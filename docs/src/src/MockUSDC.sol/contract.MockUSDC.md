# MockUSDC
[Git Source](https://github.com/Kingnanaweb3/arbit-ai/blob/37697d1a4a75787403a60855974fb0b4dbd1624a/src/MockUSDC.sol)

**Inherits:**
ERC20

**Title:**
MockUSDC

Freely mintable USDC for Arbit Protocol testnet demonstrations.
Anyone can mint — no restrictions, no whitelist.
This is testnet only. Do not use on mainnet.


## Constants
### DECIMALS

```solidity
uint8 private constant DECIMALS = 6
```


## Functions
### constructor


```solidity
constructor() ERC20("USD Coin (Testnet)", "USDC");
```

### decimals


```solidity
function decimals() public pure override returns (uint8);
```

### mint


```solidity
function mint(address to, uint256 amount) external;
```

