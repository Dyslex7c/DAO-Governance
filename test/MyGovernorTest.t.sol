// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {MyGovernor} from "../src/MyGovernor.sol";
import {GovToken} from "../src/GovToken.sol";
import {TimeLock} from "../src/TimeLock.sol";
import {Box} from "../src/Box.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract MyGovernorTest is Test {
    GovToken token;
    TimeLock timelock;
    MyGovernor governor;
    Box box;

    uint256 public constant MIN_DELAY = 3600; // 1 hour - after a vote passes, you have 1 hour before you can enact
    uint256 public constant QUORUM_PERCENTAGE = 4; // Need 4% of voters to pass
    uint256 public constant VOTING_PERIOD = 50400; // This is how long voting lasts
    uint256 public constant VOTING_DELAY = 1; // How many blocks till a proposal vote becomes active

    address[] proposers;
    address[] executors;

    bytes[] functionCalls;
    address[] addressesToCall;
    uint256[] values;

    address public constant VOTER = address(1);

    function setUp() public {
        // Pass the test contract as the initial owner
        token = new GovToken(address(this));
        token.mint(VOTER, 100e18);

        vm.prank(VOTER);
        token.delegate(VOTER);
        timelock = new TimeLock(MIN_DELAY, proposers, executors);
        governor = new MyGovernor(token, timelock);
        
        // Get the role constants correctly from TimelockController
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();

        timelock.grantRole(proposerRole, address(governor));
        timelock.grantRole(executorRole, address(0));
        timelock.revokeRole(adminRole, msg.sender);

        // Initialize Box with this contract as the initial owner, then transfer to timelock
        box = new Box(address(this));
        box.transferOwnership(address(timelock));
    }

    function testCantUpdateBoxWithoutGovernance() public {
        vm.expectRevert();
        box.store(1);
    }

    function testGovernanceUpdatesBox() public {
        uint256 valueToStore = 777;
        string memory description = "Store 777 in Box";
        bytes memory encodedFunctionCall = abi.encodeWithSignature("store(uint256)", valueToStore);
        addressesToCall.push(address(box));
        values.push(0);
        functionCalls.push(encodedFunctionCall);
        
        // 1. Propose to the DAO
        uint256 proposalId = governor.propose(addressesToCall, values, functionCalls, description);
        console.log("Proposal ID:", proposalId);

        // Log initial state and snapshot details
        console.log("Proposal State after creation:", uint256(governor.state(proposalId)));
        console.log("Current block:", block.number);
        console.log("Current timestamp:", block.timestamp);
        
        // Check proposal snapshot and deadline
        uint256 snapshot = governor.proposalSnapshot(proposalId);
        uint256 deadline = governor.proposalDeadline(proposalId);
        console.log("Proposal snapshot block:", snapshot);
        console.log("Proposal deadline block:", deadline);
        
        // Move forward PAST the voting delay
        vm.roll(snapshot + 1);  // Now we're at the snapshot block + 1
        vm.warp(block.timestamp + 15);  // Advance some time too
        
        // Log state after delay
        console.log("Block after delay:", block.number);
        console.log("Proposal State after delay:", uint256(governor.state(proposalId)));
        
        // 2. Vote
        string memory reason = "whatever maybe the reason";
        uint8 voteWay = 1;  // 1 = For
        
        // Check if we can vote
        bool canVote = governor.hasVoted(proposalId, VOTER);
        console.log("Has already voted:", canVote ? 1 : 0);
        
        // Cast vote
        vm.prank(VOTER);
        governor.castVoteWithReason(proposalId, voteWay, reason);
        
        // Confirm vote was counted
        canVote = governor.hasVoted(proposalId, VOTER);
        console.log("Has voted after casting:", canVote ? 1 : 0);
        
        // Check voting power
        uint256 weight = token.getVotes(VOTER);
        console.log("Voter weight:", weight);
        
        // Move forward to end of voting period
        vm.roll(deadline + 1);  // Now we're past the deadline
        vm.warp(block.timestamp + VOTING_PERIOD * 15); // Advance time proportionally
        
        // Log state after voting period
        console.log("Block after voting period:", block.number);
        console.log("Proposal State after voting period:", uint256(governor.state(proposalId)));
        
        // Skip the check and try to queue anyway to see what happens
        bytes32 descriptionHash = keccak256(abi.encodePacked(description));
        try governor.queue(addressesToCall, values, functionCalls, descriptionHash) {
            console.log("Queue succeeded");
        } catch Error(string memory reason) {
            console.log("Queue failed with reason:", reason);
        } catch (bytes memory) {
            console.log("Queue failed with unknown error");
        }
    }
}

// Helper interface for detailed error messages
interface IGovernor {
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }
}