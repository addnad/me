// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {KeeperBase} from "./KeeperBase.sol";

/// @notice Parimutuel prediction markets on the keeper's own headlines. The
/// sovereign opens markets on the stories it publishes to KeeperDigest and
/// resolves them on a later wake. A 2% fee on winning claims funds the
/// keeper's wakes.
///
/// Safety valve: if the sovereign dies (or just goes quiet) and a market is
/// still unresolved past `resolveBy`, anyone can void it and all stakes
/// become refundable — user funds never depend on the agent staying alive.
contract HeadlineMarkets is KeeperBase {
    enum Outcome { Unresolved, Yes, No, Void }

    struct Market {
        uint64 closeAt;    // betting stops
        uint64 resolveBy;  // after this, anyone can void if unresolved
        Outcome outcome;
        uint256 yesPool;
        uint256 noPool;
        string question;
    }

    uint256 public constant FEE_BPS = 200; // 2% on winnings

    Market[] public markets;
    // marketId => bettor => stake
    mapping(uint256 => mapping(address => uint256)) public yesStake;
    mapping(uint256 => mapping(address => uint256)) public noStake;
    mapping(uint256 => mapping(address => bool)) public claimed;

    uint256 public accruedFees;

    event MarketOpened(uint256 indexed id, string question, uint64 closeAt, uint64 resolveBy);
    event BetPlaced(uint256 indexed id, address indexed bettor, bool yes, uint256 amount);
    event Resolved(uint256 indexed id, Outcome outcome);
    event Voided(uint256 indexed id);
    event Claimed(uint256 indexed id, address indexed bettor, uint256 payout);

    error NoSuchMarket();
    error BettingClosed();
    error BettingOpen();
    error AlreadyResolved();
    error NotYetVoidable();
    error EmptyBet();
    error NothingToClaim();
    error BadSchedule();
    error BadOutcome();

    constructor(address sovereign_, address ritualWallet_, uint256 lockBlocks_)
        KeeperBase(sovereign_, ritualWallet_, lockBlocks_)
    {}

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    function getMarket(uint256 id)
        external
        view
        returns (uint64 closeAt, uint64 resolveBy, Outcome outcome, uint256 yesPool, uint256 noPool, string memory question)
    {
        if (id >= markets.length) revert NoSuchMarket();
        Market storage m = markets[id];
        return (m.closeAt, m.resolveBy, m.outcome, m.yesPool, m.noPool, m.question);
    }

    function openMarket(string calldata question, uint64 closeAt, uint64 resolveBy)
        external
        onlySovereignOrOwner
        returns (uint256 id)
    {
        if (closeAt <= block.timestamp || resolveBy <= closeAt) revert BadSchedule();
        id = markets.length;
        markets.push(Market({
            closeAt: closeAt,
            resolveBy: resolveBy,
            outcome: Outcome.Unresolved,
            yesPool: 0,
            noPool: 0,
            question: question
        }));
        emit MarketOpened(id, question, closeAt, resolveBy);
    }

    function bet(uint256 id, bool yes) external payable {
        if (id >= markets.length) revert NoSuchMarket();
        if (msg.value == 0) revert EmptyBet();
        Market storage m = markets[id];
        if (block.timestamp >= m.closeAt || m.outcome != Outcome.Unresolved) revert BettingClosed();
        if (yes) {
            m.yesPool += msg.value;
            yesStake[id][msg.sender] += msg.value;
        } else {
            m.noPool += msg.value;
            noStake[id][msg.sender] += msg.value;
        }
        emit BetPlaced(id, msg.sender, yes, msg.value);
    }

    /// @notice Sovereign (or owner fallback) settles a market after close.
    function resolve(uint256 id, Outcome outcome) external onlySovereignOrOwner {
        if (id >= markets.length) revert NoSuchMarket();
        if (outcome == Outcome.Unresolved) revert BadOutcome();
        Market storage m = markets[id];
        if (m.outcome != Outcome.Unresolved) revert AlreadyResolved();
        if (block.timestamp < m.closeAt) revert BettingOpen();
        // Nobody backed the winning side: void so the other side can refund
        // instead of stranding their stakes.
        if ((outcome == Outcome.Yes && m.yesPool == 0) || (outcome == Outcome.No && m.noPool == 0)) {
            outcome = Outcome.Void;
        }
        m.outcome = outcome;
        emit Resolved(id, outcome);
    }

    /// @notice Dead-agent safety valve: unresolved past resolveBy => refunds.
    function voidMarket(uint256 id) external {
        if (id >= markets.length) revert NoSuchMarket();
        Market storage m = markets[id];
        if (m.outcome != Outcome.Unresolved) revert AlreadyResolved();
        if (block.timestamp < m.resolveBy) revert NotYetVoidable();
        m.outcome = Outcome.Void;
        emit Voided(id);
    }

    function claim(uint256 id) external {
        if (id >= markets.length) revert NoSuchMarket();
        Market storage m = markets[id];
        if (m.outcome == Outcome.Unresolved) revert NothingToClaim();
        if (claimed[id][msg.sender]) revert NothingToClaim();
        claimed[id][msg.sender] = true;

        uint256 payout;
        if (m.outcome == Outcome.Void) {
            payout = yesStake[id][msg.sender] + noStake[id][msg.sender];
        } else {
            bool yesWon = m.outcome == Outcome.Yes;
            uint256 stake = yesWon ? yesStake[id][msg.sender] : noStake[id][msg.sender];
            if (stake > 0) {
                uint256 winPool = yesWon ? m.yesPool : m.noPool;
                uint256 total = m.yesPool + m.noPool;
                uint256 gross = (stake * total) / winPool;
                uint256 fee = (gross * FEE_BPS) / 10_000;
                accruedFees += fee;
                payout = gross - fee;
            }
        }
        if (payout == 0) revert NothingToClaim();
        (bool okSend, ) = msg.sender.call{value: payout}("");
        require(okSend, "transfer failed");
        emit Claimed(id, msg.sender, payout);
    }

    /// @notice Push accrued market fees into the sovereign's RitualWallet.
    /// Callable by anyone — feeding the keeper is a public good.
    function feedKeeper() external {
        uint256 amount = accruedFees;
        accruedFees = 0;
        _feedSovereign(amount);
    }
}
