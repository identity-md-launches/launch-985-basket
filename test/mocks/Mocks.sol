// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockToken {
    enum TransferMode {
        Normal,
        Blocked,
        FalseReturn,
        NoReturn,
        ShortCredit,
        ExtraDebit,
        NoMove,
        ReturnBomb,
        BurnGas,
        Reenter,
        Malformed,
        Expensive
    }
    enum ReadMode {
        Normal,
        RevertRead,
        BurnGas,
        ShortReturn,
        ReturnBomb,
        SlowRead,
        Expensive
    }
    uint8 public decimals;
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) public allowance;
    TransferMode public mode;
    ReadMode public readMode;
    bool public paused;
    uint256 public pauseResult;
    bool public pauseReverts;
    address public callback;
    bytes public callbackData;
    bool public reentrySucceeded;
    uint256 public extraCost;
    error MockFailure();

    constructor(uint8 d) {
        decimals = d;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function mint(address to, uint256 value) external {
        _balances[to] += value;
    }

    function confiscate(address from, uint256 value) external {
        _balances[from] -= value;
    }

    function setMode(TransferMode m) external {
        mode = m;
    }

    function setReadMode(ReadMode m) external {
        readMode = m;
    }

    function setPause(bool p) external {
        paused = p;
    }

    function setPauseResponse(bool reverts_, uint256 value) external {
        pauseReverts = reverts_;
        pauseResult = value;
    }

    function setCallback(address target, bytes calldata data) external {
        callback = target;
        callbackData = data;
    }

    function setCost(uint256 cost) external {
        extraCost = cost;
    }

    function oraclePaused() external view returns (bool) {
        if (pauseReverts) revert MockFailure();
        uint256 result = paused ? 1 : pauseResult;
        assembly {
            mstore(0, result)
            return(0, 32)
        }
    }

    function balanceOf(address account) external view returns (uint256 value) {
        if (readMode == ReadMode.RevertRead) revert MockFailure();
        if (readMode == ReadMode.BurnGas) {
            assembly { invalid() }
        }
        if (readMode == ReadMode.ShortReturn) {
            assembly { return(0, 1) }
        }
        value = _balances[account];
        if (readMode == ReadMode.Expensive) {
            uint256 initial = gasleft();
            while (initial - gasleft() < 60_000) {
                assembly { pop(keccak256(0, 32)) }
            }
        }
        if (readMode == ReadMode.SlowRead) {
            assembly { for {} gt(gas(), 800) {} {} }
        }
        if (readMode == ReadMode.ReturnBomb) {
            assembly {
                mstore(0, value)
                return(0, 8192)
            }
        }
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] < amount) revert MockFailure();
        allowance[from][msg.sender] -= amount;
        return _move(from, to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function _move(address from, address to, uint256 amount) private returns (bool) {
        TransferMode m = mode;
        if (m == TransferMode.Blocked || paused) revert MockFailure();
        if (m == TransferMode.BurnGas) {
            assembly { invalid() }
        }
        if (m == TransferMode.Expensive) {
            uint256 initial = gasleft();
            while (initial - gasleft() < extraCost) {
                assembly { pop(keccak256(0, 32)) }
            }
        }
        if (m == TransferMode.Reenter) (reentrySucceeded,) = callback.call(callbackData);
        if (m != TransferMode.NoMove) {
            _balances[from] -= amount + (m == TransferMode.ExtraDebit ? 1 : 0);
            _balances[to] += amount - (m == TransferMode.ShortCredit ? 1 : 0);
        }
        if (m == TransferMode.NoReturn) {
            assembly { return(0, 0) }
        }
        if (m == TransferMode.ReturnBomb) {
            assembly {
                mstore(0, 1)
                return(0, 131072)
            }
        }
        if (m == TransferMode.Malformed) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return m != TransferMode.FalseReturn;
    }
}

contract MockFeed {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint8 public mode;

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
    }

    function set(int256 a, uint256 time) external {
        answer = a;
        updatedAt = time;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (mode == 1) revert();
        if (mode == 2) {
            assembly { invalid() }
        }
        if (mode == 3) {
            assembly { return(0, 32) }
        }
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract MockPool {
    address public token0;
    address public token1;
    int56 public tick0;
    int56 public tick1;
    uint160 public liquidity0;
    uint160 public liquidity1;
    uint8 public mode;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function set(int24 tick, uint128 liquidity, uint32 window) external {
        tick0 = 0;
        tick1 = int56(tick) * int56(uint56(window));
        liquidity0 = 0;
        liquidity1 = uint160((uint256(window) << 128) / liquidity);
    }

    function setRaw(int56 t0, int56 t1, uint160 l0, uint160 l1) external {
        tick0 = t0;
        tick1 = t1;
        liquidity0 = l0;
        liquidity1 = l1;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function observe(uint32[] calldata times)
        external
        view
        returns (int56[] memory ticks, uint160[] memory liquidities)
    {
        if (mode == 1) revert();
        if (mode == 2) {
            assembly { invalid() }
        }
        if (mode == 3) {
            assembly { return(0, 32) }
        }
        if (mode == 4) {
            assembly {
                mstore(0, not(0))
                return(0, 256)
            }
        }
        require(times.length == 2 && times[1] == 0);
        ticks = new int56[](2);
        liquidities = new uint160[](2);
        ticks[0] = tick0;
        ticks[1] = tick1;
        liquidities[0] = liquidity0;
        liquidities[1] = liquidity1;
    }
}
