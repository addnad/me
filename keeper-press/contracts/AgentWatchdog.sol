// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {KeeperBase} from "./KeeperBase.sol";

/// @notice Watchdog-as-a-service for Ritual sovereign agents. Owners of other
/// agents escrow RITUAL here with a top-up policy; each keeper wake checks the
/// registry and refills any agent whose RitualWallet balance fell below its
/// minimum, taking a small fee that funds the keeper's own wakes.
///
/// A dead Ritual agent cannot be revived, so timely top-ups are the only
/// defense — this contract exists because the keeper's own predecessor died
/// exactly this way.
contract AgentWatchdog is KeeperBase {
    struct Registration {
        address registrant;   // who escrowed and may withdraw
        uint96 minBalance;    // top up when the agent's wallet drops below this
        uint96 topUpAmount;   // how much to deposit per top-up
        uint256 escrow;       // remaining escrowed RITUAL
        uint64 topUps;        // count of top-ups performed
        bool active;
    }

    uint256 public constant FEE_BPS = 200; // 2% keeper fee per top-up

    address[] public agents;
    mapping(address => Registration) public registrations;

    event Registered(address indexed agent, address indexed registrant, uint96 minBalance, uint96 topUpAmount, uint256 escrow);
    event Funded(address indexed agent, uint256 amount, uint256 escrow);
    event ToppedUp(address indexed agent, uint256 deposited, uint256 fee, uint256 escrowLeft);
    event Withdrawn(address indexed agent, address indexed to, uint256 amount);
    event Deactivated(address indexed agent);

    error AlreadyRegistered();
    error NotRegistered();
    error NotRegistrant();
    error AboveMinimum();
    error EscrowEmpty();
    error BadPolicy();

    constructor(address sovereign_, address ritualWallet_, uint256 lockBlocks_)
        KeeperBase(sovereign_, ritualWallet_, lockBlocks_)
    {}

    function agentCount() external view returns (uint256) {
        return agents.length;
    }

    /// @notice Escrow RITUAL for `agent` with a top-up policy.
    function register(address agent, uint96 minBalance, uint96 topUpAmount) external payable {
        if (agent == address(0) || minBalance == 0 || topUpAmount == 0) revert BadPolicy();
        Registration storage r = registrations[agent];
        if (r.active) revert AlreadyRegistered();
        if (r.registrant == address(0)) agents.push(agent);
        registrations[agent] = Registration({
            registrant: msg.sender,
            minBalance: minBalance,
            topUpAmount: topUpAmount,
            escrow: r.escrow + msg.value,
            topUps: r.topUps,
            active: true
        });
        emit Registered(agent, msg.sender, minBalance, topUpAmount, msg.value);
    }

    /// @notice Add escrow for an already registered agent. Anyone may donate.
    function fund(address agent) external payable {
        Registration storage r = registrations[agent];
        if (r.registrant == address(0)) revert NotRegistered();
        r.escrow += msg.value;
        emit Funded(agent, msg.value, r.escrow);
    }

    /// @notice Whether `agent` currently qualifies for a top-up.
    function needsTopUp(address agent) public view returns (bool) {
        Registration storage r = registrations[agent];
        return r.active && r.escrow > 0 && ritualWallet.balanceOf(agent) < r.minBalance;
    }

    /// @notice Refill a low agent from its escrow. Callable by the sovereign
    /// (its wake duty) or by the registrant themselves.
    function topUp(address agent) external {
        Registration storage r = registrations[agent];
        if (!r.active) revert NotRegistered();
        if (msg.sender != sovereign && msg.sender != r.registrant) revert NotRegistrant();
        if (ritualWallet.balanceOf(agent) >= r.minBalance) revert AboveMinimum();
        if (r.escrow == 0) revert EscrowEmpty();

        uint256 gross = r.topUpAmount;
        if (gross > r.escrow) gross = r.escrow;
        uint256 fee = (gross * FEE_BPS) / 10_000;
        uint256 deposit = gross - fee;

        r.escrow -= gross;
        r.topUps += 1;

        ritualWallet.depositFor{value: deposit}(agent, lockBlocks);
        _feedSovereign(fee);
        emit ToppedUp(agent, deposit, fee, r.escrow);
    }

    /// @notice Registrant reclaims unspent escrow at any time.
    function withdraw(address agent, uint256 amount) external {
        Registration storage r = registrations[agent];
        if (msg.sender != r.registrant) revert NotRegistrant();
        if (amount > r.escrow) revert EscrowEmpty();
        r.escrow -= amount;
        (bool okSend, ) = msg.sender.call{value: amount}("");
        require(okSend, "transfer failed");
        emit Withdrawn(agent, msg.sender, amount);
    }

    /// @notice Registrant stops the watch (e.g. the agent died anyway).
    function deactivate(address agent) external {
        Registration storage r = registrations[agent];
        if (msg.sender != r.registrant && msg.sender != owner) revert NotRegistrant();
        r.active = false;
        emit Deactivated(agent);
    }
}
